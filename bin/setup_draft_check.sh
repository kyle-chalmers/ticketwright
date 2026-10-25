#!/usr/bin/env bash
# setup_draft_check.sh: check a DRAFT setup config before anything is written to the repo.
#
# /setup used to write stack.yaml first and validate it afterwards, so the person confirmed a plan
# and then heard it was broken (a refused character in a folder name, a chat target with no
# destination). This runs the same checks on the draft, in a throwaway copy, before the confirm.
#
# Isolation is the point. The config resolver reads tier 3 from <root>/.claude/config/ and prefers
# CLAUDE_PROJECT_DIR when choosing <root>, so a draft checked in place would be validated against
# the REAL repo's machine file. Here the draft gets its own scratch repo, both Claude root variables
# are unset, and the check runs from inside the scratch copy.
#
# Read-only for the real repo, no network: verify_stack runs with --dry-run, so no verify command
# executes. Every structural check (destinations, recipients lists, refused characters, unset
# required keys, unknown targets) still runs.
#
# Usage: bash bin/setup_draft_check.sh <draft stack.yaml> [<draft connections.local.yaml>]
# Exit:  verify_stack's own exit code (0 clean · 1 something to fix) · 2 usage.
set -uo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
DRAFT="${1:-}"; DRAFT_T3="${2:-}"
if [ -z "$DRAFT" ] || [ ! -f "$DRAFT" ]; then
  echo "setup_draft_check: give the draft stack.yaml to check. Details: usage: bash bin/setup_draft_check.sh <draft stack.yaml> [<draft connections.local.yaml>]" >&2
  exit 2
fi
if [ -n "$DRAFT_T3" ] && [ ! -f "$DRAFT_T3" ]; then
  echo "setup_draft_check: the draft machine file was not found. Details: no such file: $DRAFT_T3" >&2
  exit 2
fi

# Every step is checked: an empty SCRATCH would point `git init` and `cd` at the caller's folder (the
# real repo), and a failed copy of the draft machine file would let the check pass without it.
SCRATCH="$(mktemp -d)" && [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || {
  echo "setup_draft_check: could not make a scratch folder, so nothing was checked. Details: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.claude/config" || exit 2
git -C "$SCRATCH" init -q 2>/dev/null || { echo "setup_draft_check: could not start the scratch repository. Details: git init failed in $SCRATCH" >&2; exit 2; }
cp "$DRAFT" "$SCRATCH/.claude/config/stack.yaml" || exit 2
if [ -n "$DRAFT_T3" ]; then cp "$DRAFT_T3" "$SCRATCH/.claude/config/connections.local.yaml" || exit 2; fi

cd "$SCRATCH" || exit 2
env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT \
  bash "$KIT/bin/verify_stack.sh" "$SCRATCH/.claude/config/stack.yaml" --dry-run
