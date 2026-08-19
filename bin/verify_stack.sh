#!/usr/bin/env bash
# verify_stack.sh — the "verify" half of the hybrid wiring.
#
# Reads a stack.yaml THROUGH THE THREE-TIER RESOLVER, and for each seam: confirms the adapter file
# exists, then runs the seam's read-only `verify` command (with {token} interpolation) to confirm
# the tool is reachable. Halts on the first failing seam so a broken tool is caught before any skill
# relies on it.
#
# It also LINTS the committed config for machine-local values that leaked into a team artifact
# (a profile name, a connection name, a home-directory path). Those warn; they never fail.
#
# NO `yq`. This script used to hard-require it and exit 1 without it, which made a shell binary a
# de-facto dependency of a package advertising none. Structure now comes from
# bin/effective_config.py (stdlib Python), which also means the seam semantics live in ONE place
# instead of being reimplemented in shell.
#
# Usage:
#   bin/verify_stack.sh [STACK_YAML]            # default: .claude/config/stack.yaml
#   bin/verify_stack.sh [STACK_YAML] --dry-run  # don't run verify cmds; just resolve + show them
#
# Exit: 0 if all seams reachable (or dry-run), 1 if any seam unreachable or misconfigured.
set -uo pipefail

stack="${1:-.claude/config/stack.yaml}"
dry=0
[[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && dry=1
[[ "${1:-}" == "--dry-run" ]] && stack=".claude/config/stack.yaml"

command -v python3 >/dev/null 2>&1 || { echo "verify_stack: python3 required" >&2; exit 1; }
[[ -f "$stack" ]] || { echo "verify_stack: stack file not found: $stack" >&2; exit 1; }

# Adapters are KIT assets (they ship with the plugin); stack.yaml is PROJECT data. On a plugin/pip
# install those roots diverge, so resolve adapters against the kit ($CLAUDE_PLUGIN_ROOT, else this
# script's own dir) and keep the project root as a fallback for repo-vendored/custom adapters.
# Kit location comes from the location CLI, not a raw Claude variable — that is what makes this
# script work under any runtime. The env-var line stays as the fallback for a plugin install
# where `tw` is not on disk next to us.
kit_root="$("$(dirname "$0")/tw" --kit 2>/dev/null)" || kit_root=""
[[ -n "$kit_root" ]] || kit_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
proj_root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$stack")/../.." 2>/dev/null && pwd || pwd)}"
resolver="$kit_root/bin/effective_config.py"
[[ -f "$resolver" ]] || resolver="$(cd "$(dirname "$0")" && pwd)/effective_config.py"

echo "verify_stack: $stack  $([[ $dry -eq 1 ]] && echo '(dry-run)')"
echo "─────────────────────────────────────────────────────────"
fail=0

PLAN="$(mktemp)"; LINT="$(mktemp)"; trap 'rm -f "$PLAN" "$LINT"' EXIT
python3 "$resolver" --stack "$stack" --verify-plan > "$PLAN" 2>"$LINT"; rc=$?
if [[ $rc -ne 0 ]]; then
  sed 's/^/  ✗ /' "$LINT" >&2
  # A rejected override or an unparseable config is a FAILURE, not a note. Reporting "All seams OK"
  # after refusing a prohibited `catalog:` or `policies:` override would defeat the entire
  # reject-not-ignore rule: the person would believe their local file was in effect AND that the
  # stack was healthy. Exit 5 (stale) is advisory, so it warns instead.
  #   4 malformed · 6 prohibited override → fail    5 stale → warn
  case "$rc" in
    5) echo "  ⚠ machine config is stale — re-run the per-person setup" ;;
    *) fail=1 ;;
  esac
  [[ -s "$PLAN" ]] || { echo "─────────────────────────────────────────────────────────";
                        echo "One or more seams need attention (auth/install)."; exit 1; }
fi

# Each row is one JSON object; `python3 -c` pulls the fields so bash never parses JSON.
# The separator is US (0x1f), NOT a tab: a tab is IFS *whitespace*, so bash collapses runs of them
# and every empty field shifts the ones after it. A structural row has four empty fields in a row,
# which silently moved its message into another variable and made a hard failure read as a pass.
SEP=$'\037'
fields() {  # emit US-separated fields for one row, in a fixed order
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def s(k):
    v = d.get(k)
    return "" if v is None else str(v)
print("\u001f".join([s("kind"), s("label"), s("tool"), s("adapter"), s("verify"), s("message"),
                      ",".join(d.get("unresolved") or []), ",".join(d.get("unsafe") or []),
                      ",".join(d.get("missing_required") or [])]))'
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  IFS="$SEP" read -r kind label tool adapter verify message unresolved unsafe missing <<<"$(fields "$line")"
  case "$kind" in
    seam_error) echo "  ✗ $message"; fail=1; continue ;;
    seam_warn)  echo "  ⚠ $message"; continue ;;
  esac

  printf "▸ %-10s tool=%-10s" "$label" "${tool:-?}"

  # 1) adapter present? (kit first, then repo-vendored/custom adapters under the project)
  adapter_path=""
  if [[ -n "$adapter" ]]; then
    [[ -f "$kit_root/$adapter" ]] && adapter_path="$kit_root/$adapter"
    [[ -z "$adapter_path" && -f "$proj_root/$adapter" ]] && adapter_path="$proj_root/$adapter"
  fi
  if [[ -z "$adapter_path" ]]; then
    echo "  ✗ adapter missing ($adapter)"; fail=1; continue
  fi

  # 2) are the adapter's required keys actually set? A verify command only exercises the keys its
  #    command string happens to name, so an unset key the verify never mentions used to report
  #    "reachable", and a `verify: null` seam checked nothing at all. Warn — /setup deliberately
  #    leaves keys as a `# TODO` and promises verify will point at them.
  if [[ -n "$missing" ]]; then
    echo "  ⚠ required key(s) not set: ${missing//,/ } → see $adapter"
    printf "▸ %-10s tool=%-10s" "$label" "${tool:-?}"
  fi

  # 3) verify reachable?
  if [[ -z "$verify" ]]; then
    echo "  ⚠ no verify command (skills will warn)"; continue
  fi
  # An UNRESOLVED {token} must never be executed. The shell interpolation this replaced left a
  # missing token literal, so a tokenized verify ran `databricks --profile {profile} …` verbatim on
  # any machine without a tier-3 file — a confusing failure that looks like broken auth.
  if [[ -n "$unresolved" ]]; then
    echo "  ⚠ skipped: unresolved {$unresolved} — set it in .claude/config/connections.local.yaml"
    continue
  fi
  # A verify is executed with `eval`, and a {token} value can come from a gitignored local file, so
  # a value carrying shell syntax is REFUSED rather than run. Quoting is not an option: the token is
  # often already inside quotes in the template, so quoting again would corrupt legitimate paths.
  if [[ -n "$unsafe" ]]; then
    echo "  ✗ refusing to run: value for {$unsafe} contains shell metacharacters"; fail=1; continue
  fi
  if [[ $dry -eq 1 ]]; then
    echo "  → would run: $verify"; continue
  fi
  if eval "$verify" >/dev/null 2>&1; then
    echo "  ✓ reachable"
  else
    echo "  ✗ UNREACHABLE → $verify"; fail=1
  fi
done < "$PLAN"

# ── the leak lint ────────────────────────────────────────────────────────────────────────────
# Warn, never fail: a committed value that belongs on one machine is a design problem to fix at
# leisure, not a reason to block someone's work right now.
leaks="$(python3 "$resolver" --stack "$stack" --lint --quiet 2>/dev/null)"
if [[ -n "$leaks" ]]; then
  echo "─────────────────────────────────────────────────────────"
  echo "⚠ machine-local values in committed config:"
  printf '%s\n' "$leaks" | while IFS=$'\t' read -r lbl msg; do
    [ -n "$msg" ] && echo "  · $lbl: $msg"
  done
fi

echo "─────────────────────────────────────────────────────────"
if [[ $fail -eq 0 ]]; then echo "All seams OK."; else echo "One or more seams need attention (auth/install)."; fi
exit $fail
