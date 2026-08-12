#!/usr/bin/env bash
# handoff.sh — hand finished artifacts to the human's own applications (the `viewer` seam).
#
# The review gate that lets a person LOOK at a deliverable in a tool that can actually show it:
# generated SQL into their IDE, result CSVs into their spreadsheet app. Skills stay tool-agnostic
# and call this; the app names live in per-user config, never in a skill.
#
# Usage:
#   bin/handoff.sh [--dry-run] [--reveal] PATH [PATH ...]
#   bin/handoff.sh --dry-run tickets/alice/ENG-1/final_deliverables/out.csv
#
#   --dry-run  resolve routes and print the commands; never launch anything
#   --reveal   show each path in the OS file manager instead of opening it
#
# Config (first hit wins; none = feature off, exit 0 silently):
#   1. <project>/.claude/config/viewer.local.yaml                  you, this repo   (gitignored)
#   2. ${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml  you, every repo
#   3. `seams.viewer` in <project>/.claude/config/stack.yaml       whole team       (committed)
# Shape + all keys: .claude/config/viewer.example.yaml
#
# Exit 0 unless every requested path failed. This is a courtesy channel — it must never be the
# reason a ticket stops moving.
set -uo pipefail

dry=0; reveal=0; paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --reveal)  reveal=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done ;;
    -*) echo "handoff: unrecognized option: $1" >&2; exit 2 ;;
    *)  paths+=("$1"); shift ;;
  esac
done
[ ${#paths[@]} -gt 0 ] || { echo "usage: $0 [--dry-run] [--reveal] PATH [PATH ...]" >&2; exit 2; }

note() { echo "handoff: $*" >&2; }

# ---- project root ---------------------------------------------------------------------------
# CLAUDE_PROJECT_DIR when the agent set it, else walk up to the .git boundary. Bounded so a
# subdirectory invocation still finds the project without escaping into a parent checkout.
proj="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$proj" ]; then
  d="$(pwd -P)"
  while :; do
    [ -e "$d/.git" ] && { proj="$d"; break; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  [ -n "$proj" ] || proj="$(pwd -P)"
fi
# Canonicalize: the containment check below compares against paths resolved with `pwd -P`, so a
# CLAUDE_PROJECT_DIR carrying a symlink (macOS /tmp → /private/tmp, or a symlinked checkout) would
# make every single file look like it lives outside the project and get refused.
if canon="$(cd "$proj" 2>/dev/null && pwd -P)"; then proj="$canon"; fi

# ---- locate config --------------------------------------------------------------------------
# PFX is the yq path prefix: "" for a standalone viewer file, ".seams.viewer" inside a stack.yaml.
CFG=""; PFX=""
user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml"
if   [ -f "$proj/.claude/config/viewer.local.yaml" ]; then CFG="$proj/.claude/config/viewer.local.yaml"; PFX=""
elif [ -f "$user_cfg" ];                              then CFG="$user_cfg";                              PFX=""
elif [ -f "$proj/.claude/config/stack.yaml" ] \
     && grep -qE '^[[:space:]]+viewer:[[:space:]]*(#.*)?$' "$proj/.claude/config/stack.yaml"; then
  CFG="$proj/.claude/config/stack.yaml"; PFX=".seams.viewer"
fi
if [ -z "$CFG" ]; then
  # Not configured = the feature is off. Silent on stdout so a gate never nags; under --dry-run
  # the whole point is to explain, so say where config would go.
  [ $dry -eq 1 ] && note "no viewer config found — see .claude/config/viewer.example.yaml"
  exit 0
fi

# ---- read config ----------------------------------------------------------------------------
# yq is the kit's existing seam reader (verify_stack.sh). Degrade soft when it is absent: a
# missing dev tool must not turn a courtesy step into a hard failure.
if ! command -v yq >/dev/null 2>&1; then
  note "'yq' not installed — cannot resolve viewer routes. Files ready for review:"
  printf '  %s\n' "${paths[@]}" >&2
  exit 0
fi
yqv() { yq -r "${PFX}${1} // \"\"" "$CFG" 2>/dev/null; }

# NOT `.enabled // "true"`: the `//` alternative operator treats a literal `false` as absent (same
# semantics as jq), so the default would silently override the one value that must be honored.
# Read it raw; null/missing simply falls through to enabled.
enabled="$(yq -r "${PFX}.enabled" "$CFG" 2>/dev/null)"
case "$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]')" in
  false|no|off|0) exit 0 ;;   # explicitly configured to stay quiet; never prompts again
esac

open_cmd="$(yqv .open_cmd)"; default_cmd="$(yqv .default_cmd)"; reveal_cmd="$(yqv .reveal_cmd)"
[ -n "$default_cmd" ] || default_cmd="$open_cmd"
if [ $reveal -eq 1 ] && [ -z "$reveal_cmd" ]; then
  note "config has no reveal_cmd; nothing to do"; exit 0
fi
if [ $reveal -eq 0 ] && [ -z "$open_cmd" ] && [ -z "$default_cmd" ]; then
  note "config has no open_cmd; nothing to do"; exit 0
fi

ROUTES="$(mktemp)"; TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD" "$ROUTES"' EXIT
yq -r "${PFX}.routes[]? | [(.glob // \"\"), (.app // \"\")] | @tsv" "$CFG" 2>/dev/null > "$ROUTES" || true

# The unrouted group is spelled with a sentinel, never as an empty string: it becomes the LAST
# grouping key whenever the last file matches no route, and `$(...)` strips trailing newlines —
# so an empty key silently dropped those files instead of opening them with the OS default.
NO_ROUTE=$'\001default'

route_for() {  # route_for BASENAME -> the routed app, or $NO_ROUTE for the default association
  local base="$1" glob app
  while IFS=$'\t' read -r glob app; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254 — $glob is a deliberate glob pattern from config
    case "$base" in $glob) [ -n "$app" ] && { printf '%s' "$app"; return 0; } ;; esac
  done < "$ROUTES"
  printf '%s' "$NO_ROUTE"
}

# ---- may we actually launch something? --------------------------------------------------------
# NOT a TTY check: an agent's captured stdout is never a TTY, so `[ -t 1 ]` would disable the
# feature in exactly the case it exists for. What matters is whether a desktop session exists to
# open into. CI and the explicit opt-out are checked first because they are unambiguous, and they
# are what keeps selftest from spawning a GUI app on a contributor's machine.
gui_session() {
  case "$(uname -s)" in
    Darwin) [ "$(launchctl managername 2>/dev/null)" = "Aqua" ] ;;
    Linux)  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] ;;
    *)      return 0 ;;   # MINGW/MSYS/Cygwin and anything unknown: don't block
  esac
}
may_launch() {
  [ $dry -eq 1 ] && return 1
  [ "${TICKETWRIGHT_NO_OPEN:-}" = "1" ] && return 1
  [ -n "${CI:-}" ] && return 1
  gui_session
}
launching=0; may_launch && launching=1

abs_path() {  # FULLY resolved absolute path — symlinks in the final component included
  # Resolving only the parent directory (the obvious `cd $(dirname) && pwd -P` trick) left a hole
  # in the containment check below: an in-project symlink keeps its own name, so `tickets/x.sql ->
  # /etc/hosts` passed as "inside the project" and the desktop app then followed it out. A ticket
  # repo is shared, and a symlink is something a *different* author can commit — the check has to
  # see where the path actually lands. `realpath`/`readlink -f` are not portable to stock macOS;
  # python3 is already a hard dependency of this kit. Quote-free by design (bash 3.2 lexes these).
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

run_or_show() {  # run_or_show COMMAND -> honors dry/no-launch; never aborts the batch
  local cmd="$1"
  if [ $launching -eq 1 ]; then
    if bash -c "$cmd" >/dev/null 2>"$TMPD/err"; then
      echo "  opened: $cmd"
    else
      echo "  FAILED: $cmd" >&2
      [ -s "$TMPD/err" ] && sed 's/^/          /' "$TMPD/err" >&2
      return 1
    fi
  else
    echo "  would run: $cmd"
  fi
  return 0
}

# ---- collect + validate paths -----------------------------------------------------------------
MAP="$TMPD/map"; : > "$MAP"
kept=0; skipped=0
for p in "${paths[@]}"; do
  if [ ! -e "$p" ]; then note "skipping (no such file): $p"; skipped=$((skipped+1)); continue; fi
  a="$(abs_path "$p")"
  if [ -z "$a" ]; then note "skipping (unreadable path): $p"; skipped=$((skipped+1)); continue; fi
  # Containment: this opens things in desktop applications, so it only ever touches the project.
  case "$a" in
    "$proj"/*) : ;;
    *) note "refusing (outside the project): $p"; skipped=$((skipped+1)); continue ;;
  esac
  printf '%s\t%s\n' "$(route_for "$(basename "$a")")" "$a" >> "$MAP"
  kept=$((kept+1))
done
[ "$kept" -gt 0 ] || exit 1

rc=0
if [ $reveal -eq 1 ]; then
  while IFS=$'\t' read -r _app p; do
    cmd="${reveal_cmd//\{path\}/$(printf '%q' "$p")}"
    run_or_show "$cmd" || rc=1
  done < "$MAP"
else
  # Group by resolved app so N files sharing a route become ONE launch, not N windows.
  # bash 3.2: no associative arrays — first-appearance-ordered unique keys via awk, then a
  # second pass per key. An empty key means "no route matched" → default_cmd.
  apps="$(cut -f1 "$MAP" | awk '!seen[$0]++')"
  while IFS= read -r app; do
    quoted=""
    while IFS=$'\t' read -r a p; do
      [ "$a" = "$app" ] || continue
      quoted="$quoted $(printf '%q' "$p")"
    done < "$MAP"
    quoted="${quoted# }"
    if [ "$app" = "$NO_ROUTE" ]; then
      cmd="$default_cmd"
    else
      cmd="${open_cmd//\{app\}/$(printf '%q' "$app")}"
    fi
    cmd="${cmd//\{path\}/$quoted}"
    run_or_show "$cmd" || rc=1
  done <<< "$apps"
fi

if [ $launching -eq 0 ] && [ $dry -eq 0 ]; then
  note "not launching (no desktop session, CI, or TICKETWRIGHT_NO_OPEN=1) — paths listed above"
fi
[ "$skipped" -gt 0 ] && [ "$kept" -eq 0 ] && exit 1
exit "$rc"
