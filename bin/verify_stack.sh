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
# Exit: 0 if no seam failed (or dry-run), 1 if any seam unreachable or misconfigured. A seam that
# could not be checked at all (MCP-only with no verify command, or an unresolved {token}) is a
# WARNING: it keeps exit 0, but the summary counts it as unverified instead of claiming it OK.
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

# Three states per seam, COUNTED, so the summary line carries the truth. "All seams OK." used to
# print whenever nothing failed — including when a seam was never checked at all (MCP-only with no
# verify command, or an unresolved {token} skip), which put a completely unauthenticated seam
# under an all-green banner. Warnings still exit 0; they just stop masquerading as verified.
ok_count=0
warn_count=0; warn_list=""
fail_count=0; fail_list=""
count_ok()   { ok_count=$((ok_count + 1)); }
count_warn() { warn_count=$((warn_count + 1)); warn_list="$warn_list${warn_list:+, }$1"; }
count_fail() { fail_count=$((fail_count + 1)); fail_list="$fail_list${fail_list:+, }$1"; fail=1; }

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
    seam_error) echo "  ✗ $message"; count_fail "${label:-config}"; continue ;;
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
    echo "  ✗ adapter missing ($adapter)"; count_fail "$label"; continue
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
    # Unverifiable is not verified. Say WHY, and say it differently for the case a person can fix
    # from the shell (write a verify) vs the case nobody can (MCP transport has no shell surface —
    # the agent must probe the server in-session). Transport comes from the adapter frontmatter;
    # the plan rows don't carry it, and the wording is the only thing that hangs on it.
    transport="$(sed -n '2,/^---$/p' "$adapter_path" 2>/dev/null \
                 | sed -n 's/^transport:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -n 1)"
    if [[ "$transport" == "mcp" ]]; then
      echo "  ⚠ MCP-only: not checkable from the shell — the agent must probe the MCP server in-session"
    else
      echo "  ⚠ no verify command — NOT verified (skills will warn)"
    fi
    count_warn "$label"; continue
  fi
  # An UNRESOLVED {token} must never be executed. The shell interpolation this replaced left a
  # missing token literal, so a tokenized verify ran `databricks --profile {profile} …` verbatim on
  # any machine without a tier-3 file — a confusing failure that looks like broken auth.
  if [[ -n "$unresolved" ]]; then
    echo "  ⚠ skipped: unresolved {$unresolved} — set it in .claude/config/connections.local.yaml"
    count_warn "$label"; continue
  fi
  # A verify is executed with `eval`, and a {token} value can come from a gitignored local file, so
  # a value carrying shell syntax is REFUSED rather than run. Quoting is not an option: the token is
  # often already inside quotes in the template, so quoting again would corrupt legitimate paths.
  if [[ -n "$unsafe" ]]; then
    echo "  ✗ refusing to run: value for {$unsafe} contains shell metacharacters"; count_fail "$label"; continue
  fi
  if [[ $dry -eq 1 ]]; then
    echo "  → would run: $verify"; count_ok; continue
  fi
  if eval "$verify" >/dev/null 2>&1; then
    echo "  ✓ reachable"; count_ok
  else
    echo "  ✗ UNREACHABLE → $verify"; count_fail "$label"
  fi
done < "$PLAN"

# ── delivery routing: the rules a multi-target chat/docstore slot must satisfy ───────────────
# THESE FAIL, they do not warn. `always_include` — the never-solo-DM stakeholder list — had ZERO
# mechanical enforcement before this block: it was prose in an adapter, and a config could omit it
# forever without anything noticing. Replacing an unenforced prose convention with a new prose
# convention would change nothing, so the check runs here, and a finding exits 1.
#
# Scope is deliberate and narrow: every rule binds ONLY when the slot declares `targets:`. A
# single-mapping chat slot that omits `always_include` still verifies clean — otherwise every
# shipped example config would break, which is a regression rather than a stricter rule.
#
# The semantics live in Python (one YAML reader, one resolver — the audit resolves through
# bin/effective_config.py); the FAILURE lives here, where a person runs it.
router="$kit_root/bin/delivery_plan.py"
[[ -f "$router" ]] || router="$(cd "$(dirname "$0")" && pwd)/delivery_plan.py"
if [[ -f "$router" ]]; then
  ROUTE="$(python3 "$router" --stack "$stack" --audit --quiet 2>/dev/null)"; rrc=$?
  if [[ -n "$ROUTE" ]]; then
    echo "─────────────────────────────────────────────────────────"
    while IFS="$SEP" read -r level message; do
      [ -n "$message" ] || continue
      if [[ "$level" == "error" ]]; then echo "  ✗ $message"; else echo "  ⚠ $message"; fi
    done <<<"$ROUTE"
  fi
  [[ $rrc -ne 0 ]] && fail=1
elif grep -Eq '"seam": "(chat|docstore)", "target": "' "$PLAN"; then
  # The config declares chat/docstore targets but the router that ENFORCES their rules is gone.
  # A silent skip here would report "All seams OK" on exactly the config class whose rules exist
  # to prevent a client-data leak — an absent enforcer is a FAILURE on the configs it guards, and
  # only on those (a repo with no such targets loses nothing when the router is absent).
  echo "─────────────────────────────────────────────────────────"
  echo "  ✗ this stack declares chat/docstore targets, but the delivery-routing checker is missing: $router"
  fail=1
fi

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
# The summary tells the truth about all three states. "All seams OK." is reserved for the run where
# every seam actually verified (or, in dry-run, resolved to a runnable verify) — an unverifiable
# seam is named, not absorbed into the green line. Exit codes are unchanged: failures exit 1,
# warnings alone still exit 0.
if [[ $fail -ne 0 ]]; then
  summary="$ok_count OK"
  [[ $warn_count -gt 0 ]] && summary="$summary, $warn_count unverified ($warn_list)"
  [[ $fail_count -gt 0 ]] && summary="$summary, $fail_count failing ($fail_list)"
  echo "$summary."
  echo "One or more seams need attention (auth/install)."
elif [[ $warn_count -gt 0 ]]; then
  echo "$ok_count OK, $warn_count unverified ($warn_list)."
else
  echo "All seams OK."
fi
exit $fail
