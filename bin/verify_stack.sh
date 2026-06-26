#!/usr/bin/env bash
# verify_stack.sh — the "verify" half of the hybrid wiring.
#
# Reads a stack.yaml, and for each seam: confirms the adapter file exists, then runs the seam's
# read-only `verify` command (with {token} interpolation) to confirm the tool is reachable.
# Mirrors the repo's existing bin/view_drift_check.sh halt-on-fail pattern.
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
kit_root="$(cd "$(dirname "$stack")/../.." && pwd)"

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
for seam in $(yq -r '.seams | keys | .[]' "$stack"); do
  tool=$(yq -r ".seams.$seam.tool // \"?\"" "$stack")
  adapter=$(yq -r ".seams.$seam.adapter // \"\"" "$stack")
  verify=$(yq -r ".seams.$seam.verify // \"\"" "$stack")

  # Per-seam token file = base project tokens + this seam's own scalar keys.
  seamtok="$(mktemp)"
  cat "$BASETOK" > "$seamtok"
  yq -r ".seams.$seam | to_entries | .[] | select(.value|type==\"!!str\" or type==\"!!int\" or type==\"!!float\") | [.key,(.value|tostring)] | @tsv" "$stack" 2>/dev/null >> "$seamtok" || true

  printf "▸ %-10s tool=%-10s" "$seam" "$tool"

  # 1) adapter present?
  if [[ -z "$adapter" || ! -f "$kit_root/$adapter" ]]; then
    echo "  ✗ adapter missing ($adapter)"; fail=1; rm -f "$seamtok"; continue
  fi

  # 2) verify reachable?
  if [[ -z "$verify" || "$verify" == "null" ]]; then
    echo "  ⚠ no verify command (skills will warn)"; rm -f "$seamtok"; continue
  fi
  cmd="$(interp "$verify" "$seamtok")"
  rm -f "$seamtok"
  if [[ $dry -eq 1 ]]; then
    echo "  → would run: $cmd"; continue
  fi
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  ✓ reachable"
  else
    echo "  ✗ UNREACHABLE → $cmd"; fail=1
  fi
done
echo "─────────────────────────────────────────────────────────"
if [[ $fail -eq 0 ]]; then echo "All seams OK."; else echo "One or more seams need attention (auth/install)."; fi
exit $fail
