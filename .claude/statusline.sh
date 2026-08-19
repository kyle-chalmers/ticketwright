#!/usr/bin/env bash
# statusline.sh — compact Ticketwright status line for Claude Code.
# Shows: <key_prefix> · <git branch/ticket> · tracker→warehouse tools.
# Claude Code pipes session JSON on stdin; we only need cwd/branch + stack.yaml.
set -uo pipefail

# Read (and ignore) the stdin payload so the pipe doesn't block.
cat >/dev/null 2>&1 || true

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
stack="$root/.claude/config/stack.yaml"

# A trackerless repo (id_mode: slug) has no key_prefix, so fall back to the directory name rather
# than printing a bare "?".
prefix="$(basename "$root")"; tracker="—"; warehouse="—"

# Preferred path: the three-tier resolver, so the statusline shows the SAME answer every other
# consumer sees. Deliberately guarded — a statusline that errors would break every prompt, so any
# failure falls through to the standalone scan below rather than surfacing.
resolved=""
if [[ -f "$stack" ]]; then
  resolved="$(python3 "$(dirname "$0")/../bin/effective_config.py" --root "$root" --json --quiet 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
p, seams = d.get("project") or {}, d.get("seams") or {}
prefix = p.get("key_prefix")
if not prefix:
    plural = p.get("key_prefixes")
    prefix = (plural[0] if isinstance(plural, list) and plural else plural) or ""

def tools(name):
    node = seams.get(name)
    if not isinstance(node, dict):
        return ""
    targets = node.get("targets")
    if isinstance(targets, dict) and targets:
        names = list(targets)
        default = node.get("default")
        if default in names:
            names.remove(default); names.insert(0, default)
        got = [str(targets[n].get("tool")) for n in names
               if isinstance(targets[n], dict) and targets[n].get("tool")]
        # Cap at two names plus a count so an extra warehouse cannot push the line over a terminal.
        if len(got) > 2:
            return "+".join(got[:2]) + "+" + str(len(got) - 2)
        return "+".join(got)
    return str(node.get("tool") or "")
print("\u001f".join([str(prefix), tools("tracker"), tools("warehouse")]))' 2>/dev/null)"
fi
if [[ -n "$resolved" ]]; then
  # US (0x1f), not a tab: tab is IFS *whitespace*, so bash collapses empty fields and every field
  # after them shifts. A trackerless repo has an empty prefix, which silently moved the tracker
  # name into the prefix slot.
  IFS=$'\037' read -r rprefix rtracker rwarehouse <<<"$resolved"
  [[ -n "${rprefix:-}" ]] && prefix="$rprefix"
  [[ -n "${rtracker:-}" ]] && tracker="$rtracker"
  [[ -n "${rwarehouse:-}" ]] && warehouse="$rwarehouse"
elif [[ -f "$stack" ]]; then
  p=$(grep -m1 -E '^\s*key_prefix:' "$stack" | sed -E 's/.*key_prefix:[[:space:]]*//; s/[[:space:]#].*//')
  # A keyed repo may configure only the plural `key_prefixes` — take its first entry rather than
  # falling through to the directory name, which would read as trackerless.
  [[ -z "$p" ]] && p=$(awk '/^[[:space:]]*key_prefixes:[[:space:]]*\[/{
        s=$0; sub(/^.*\[[[:space:]]*/,"",s); sub(/[],[:space:]].*$/,"",s); gsub(/["'"'"']/,"",s); print s; exit }
      /^[[:space:]]*key_prefixes:[[:space:]]*$/{ inlist=1; next }
      inlist && /^[[:space:]]*-[[:space:]]*/{
        s=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",s); gsub(/["'"'"']/,"",s); sub(/[[:space:]#].*$/,"",s); print s; exit }' "$stack")
  [[ -n "$p" ]] && prefix="$p"
  tracker=$(awk '/^  tracker:/{f=1} f&&/tool:/{print $2; exit}' "$stack")
  # A multi-target warehouse seam renders "a+b", capped at two names plus a count so one extra
  # warehouse can't push the statusline over a terminal width.
  warehouse=$(awk '
    /^[[:space:]]*#/     { next }                       # comments are not config
    /^[^[:space:]]/      { inw=0 }                      # dedent to column 0 ends the seam
    /^  [A-Za-z0-9_-]+:/ { k=$1; sub(":","",k); inw=(k=="warehouse") }
    # matches both `tool: x` on its own line and `p: {tool: x, …}` in flow style
    inw && /[ {,]tool:/ {
      s=$0; sub(/^.*[ {,]tool:[ \t]*/,"",s); sub(/[ \t,}#].*$/,"",s)
      n++; out=(n==1 ? s : (n<=2 ? out"+"s : out))
    }
    END { if (n>2) out=out"+"(n-2); print out }
  ' "$stack")
fi

branch=$(git -C "$root" branch --show-current 2>/dev/null || echo "-")

printf "⛭ %s · ⎇ %s · %s→%s" "${prefix:-?}" "${branch:--}" "${tracker:-—}" "${warehouse:-—}"
