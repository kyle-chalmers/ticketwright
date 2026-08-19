#!/usr/bin/env bash
# install.sh — shell convenience for the runtime installer, in the bin/tw launcher pattern.
#
#   bash bin/install.sh --runtime <name> [--local|--global] [--root <path>]
#
# One implementation, reachable three ways: `ticketwright install` (pip entrypoint),
# this wrapper (repo / cp -r installs), and `bin/emit_runtime.py` directly. This file adds no
# logic — it resolves its own directory (symlinks followed, same as bin/tw) and hands everything
# to the launcher, which owns kit location and python dispatch. Do not grow a fourth install route.
#
# bash 3.2-safe (macOS system bash): no associative arrays, no ${var,,}, no mapfile.
set -uo pipefail

self_dir() {
  local src="$0" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" && pwd
}

DIR="$(self_dir)"
[ -f "$DIR/tw" ] || { printf 'install.sh: launcher missing: %s/tw\n' "$DIR" >&2; exit 3; }
exec bash "$DIR/tw" emit_runtime.py "$@"
