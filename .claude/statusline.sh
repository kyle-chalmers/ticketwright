#!/usr/bin/env bash
# statusline.sh — compact Ticketwright status line for Claude Code.
# Shows: <key_prefix> · <git branch/ticket> · tracker→warehouse tools.
# Claude Code pipes session JSON on stdin; we only need cwd/branch + stack.yaml.
set -uo pipefail

# Read (and ignore) the stdin payload so the pipe doesn't block.
cat >/dev/null 2>&1 || true

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
stack="$root/.claude/config/stack.yaml"

prefix="?"; tracker="—"; warehouse="—"
if [[ -f "$stack" ]]; then
  prefix=$(grep -m1 -E '^\s*key_prefix:' "$stack" | sed -E 's/.*key_prefix:[[:space:]]*//; s/[[:space:]#].*//')
  tracker=$(awk '/^  tracker:/{f=1} f&&/tool:/{print $2; exit}' "$stack")
  warehouse=$(awk '/^  warehouse:/{f=1} f&&/tool:/{print $2; exit}' "$stack")
fi

branch=$(git -C "$root" branch --show-current 2>/dev/null || echo "-")

printf "⛭ %s · ⎇ %s · %s→%s" "${prefix:-?}" "${branch:--}" "${tracker:-—}" "${warehouse:-—}"
