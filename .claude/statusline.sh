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
if [[ -f "$stack" ]]; then
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
