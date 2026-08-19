#!/usr/bin/env bash
# verify_stack.sh — the "verify" half of the hybrid wiring.
#
# Reads a stack.yaml, and for each seam: confirms the adapter file exists, then runs the seam's
# read-only `verify` command (with {token} interpolation) to confirm the tool is reachable.
# Halts on the first failing seam so a broken tool is caught before any skill relies on it.
#
# Usage:
#   bin/verify_stack.sh [STACK_YAML]            # default: .claude/config/stack.yaml
#   bin/verify_stack.sh [STACK_YAML] --dry-run  # don't run verify cmds; just resolve + show them
#
# Exit: 0 if all seams reachable (or dry-run), 1 if any seam unreachable.
set -uo pipefail

stack="${1:-.claude/config/stack.yaml}"
dry=0
[[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && dry=1
[[ "${1:-}" == "--dry-run" ]] && stack=".claude/config/stack.yaml"

command -v yq >/dev/null 2>&1 || { echo "verify_stack: 'yq' required (brew install yq)" >&2; exit 1; }
[[ -f "$stack" ]] || { echo "verify_stack: stack file not found: $stack" >&2; exit 1; }
# Adapters are KIT assets (they ship with the plugin); stack.yaml is PROJECT data. On a plugin/pip
# install those roots diverge, so resolve adapters against the kit ($CLAUDE_PLUGIN_ROOT, else this
# script's own dir) and keep the project root as a fallback for repo-vendored/custom adapters.
kit_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
proj_root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$stack")/../.." && pwd)}"

# Flatten project.* into a token file (key<TAB>value) so verify strings like "{default_epic}" /
# "{base_path}" resolve. Plain file + loop (no associative arrays) keeps this bash 3.2-compatible.
BASETOK="$(mktemp)"; trap 'rm -f "$BASETOK"' EXIT
yq -r '.project | to_entries | .[] | [.key, (.value|tostring)] | @tsv' "$stack" 2>/dev/null > "$BASETOK" || true

interp() {  # interp "<string>" "<tokfile>": replace {key} with value for each key<TAB>value line
  local s="$1" f="$2" k v
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && s="${s//\{$k\}/$v}"
  done < "$f"
  printf '%s' "$s"
}

echo "verify_stack: $stack  $([[ $dry -eq 1 ]] && echo '(dry-run)')"
echo "─────────────────────────────────────────────────────────"
fail=0

# check_unit LABEL YQ_PATH [PARENT_YQ_PATH]
#   LABEL   what to print, e.g. "warehouse" or "warehouse[prod]*"
#   YQ_PATH the mapping that owns tool/adapter/verify — a seam, or one of a seam's targets
#   PARENT  when YQ_PATH is a target: the parent seam, whose scalar keys the target inherits
# Mutates `fail`, so it MUST be called in the current shell — never in $(...) or a pipe, or the
# failure would be set in a subshell and lost.
check_unit() {
  local label="$1" path="$2" parent="${3:-}"
  local tool adapter verify seamtok adapter_path cmd

  # A target inherits any key it does not define itself — including tool/adapter/verify, so two
  # targets on one account can share all three and differ only in, say, default_warehouse.
  # Keyed on *absence*, not emptiness: an explicit `verify: null` is a deliberate "skip" and must
  # not fall through to the seam's command.
  field() {
    local k="$1"
    if [[ "$(yq -r "($path | has(\"$k\")) // false" "$stack")" == "true" ]]; then
      yq -r "$path.$k // \"null\"" "$stack"
    elif [[ -n "$parent" ]]; then
      yq -r "$parent.$k // \"\"" "$stack"
    fi
  }
  tool=$(field tool);       [[ -z "$tool" || "$tool" == "null" ]] && tool="?"
  adapter=$(field adapter); [[ "$adapter" == "null" ]] && adapter=""
  verify=$(field verify)

  # Token file = base project tokens + this unit's own scalar keys + (for a target) the parent
  # seam's shared scalars. interp() is first-match-wins, so own keys must be written BEFORE the
  # parent's for a target-level override to beat a seam-level default.
  seamtok="$(mktemp)"
  cat "$BASETOK" > "$seamtok"
  yq -r "$path | to_entries | .[] | select(.value|type==\"!!str\" or type==\"!!int\" or type==\"!!float\") | [.key,(.value|tostring)] | @tsv" "$stack" 2>/dev/null >> "$seamtok" || true
  if [[ -n "$parent" ]]; then
    yq -r "$parent | to_entries | .[] | select(.key != \"default\") | select(.value|type==\"!!str\" or type==\"!!int\" or type==\"!!float\") | [.key,(.value|tostring)] | @tsv" "$stack" 2>/dev/null >> "$seamtok" || true
  fi

  # Width stays %-10s so single-warehouse output is byte-identical to previous releases; a longer
  # target label simply overflows its column (printf pads, never truncates).
  printf "▸ %-10s tool=%-10s" "$label" "$tool"

  # 1) adapter present? (kit first, then repo-vendored/custom adapters under the project)
  adapter_path=""
  if [[ -n "$adapter" ]]; then
    [[ -f "$kit_root/$adapter" ]] && adapter_path="$kit_root/$adapter"
    [[ -z "$adapter_path" && -f "$proj_root/$adapter" ]] && adapter_path="$proj_root/$adapter"
  fi
  if [[ -z "$adapter_path" ]]; then
    echo "  ✗ adapter missing ($adapter)"; fail=1; rm -f "$seamtok"; return
  fi

  # 2) verify reachable?
  if [[ -z "$verify" || "$verify" == "null" ]]; then
    echo "  ⚠ no verify command (skills will warn)"; rm -f "$seamtok"; return
  fi
  cmd="$(interp "$verify" "$seamtok")"
  rm -f "$seamtok"
  if [[ $dry -eq 1 ]]; then
    echo "  → would run: $cmd"; return
  fi
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  ✓ reachable"
  else
    echo "  ✗ UNREACHABLE → $cmd"; fail=1
  fi
}

for seam in $(yq -r '.seams | keys | .[]' "$stack"); do
  # A seam may be MULTI-TARGET: a `targets:` map (the discriminator) plus a `default:` pointer.
  # `default` is deliberately NOT the discriminator — other seams already use default_channel /
  # default_mode / default_branch, so it must never carry type meaning.
  if [[ "$(yq -r "(.seams.$seam | has(\"targets\")) // false" "$stack")" == "true" ]]; then
    def=$(yq -r ".seams.$seam.default // \"\"" "$stack")

    # Resolve the default BEFORE listing targets, so a bad pointer reports one clear error rather
    # than also triggering the ordering warning (which would be meaningless for a nonexistent name).
    def_ok=0
    if [[ -z "$def" ]]; then
      echo "  ✗ $seam: 'targets' present but no 'default:' — skills cannot pick a target"; fail=1
    elif [[ "$(yq -r ".seams.$seam.targets | has(\"$def\")" "$stack")" != "true" ]]; then
      echo "  ✗ $seam: default '$def' is not one of the defined targets"; fail=1
    else
      def_ok=1
    fi

    first=1
    for t in $(yq -r ".seams.$seam.targets | keys | .[]" "$stack"); do
      mark=""; [[ $def_ok -eq 1 && "$t" == "$def" ]] && mark="*"
      check_unit "$seam[$t]$mark" ".seams.$seam.targets.$t" ".seams.$seam"
      # Readers that predate multi-target display the FIRST target, so listing the default first
      # keeps an un-relaunched session honest.
      if [[ $first -eq 1 && $def_ok -eq 1 && "$t" != "$def" ]]; then
        echo "  ⚠ $seam: default '$def' is not the first target — pre-multi-target readers show the first one"
      fi
      first=0
    done
  else
    check_unit "$seam" ".seams.$seam"
  fi
done
echo "─────────────────────────────────────────────────────────"
if [[ $fail -eq 0 ]]; then echo "All seams OK."; else echo "One or more seams need attention (auth/install)."; fi
exit $fail
