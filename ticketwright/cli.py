"""`ticketwright` CLI — stdlib only (no runtime deps; on-brand with the kit's KISS stance).

  ticketwright init [path]      scaffold the kit into a repo (the pip-native install — a versioned,
                                upgrade-safe replacement for `cp -r`; preserves existing per-repo config)
  ticketwright recall ...       run prior-art recall against the repo at $PWD  (passthrough to recall.py)
  ticketwright index  ...       (re)render / --check / --stats / --recurring the ticket index
  ticketwright enrich ...       refresh a ticket's curated index summary

The kit assets ship bundled under ticketwright/_kit/; the run-* commands exec the bundled bin/ scripts
with CLAUDE_PROJECT_DIR set to the current directory, so they read the repo you're standing in.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__

KIT = Path(__file__).resolve().parent / "_kit"
# Per-install files that init must NEVER clobber if they already exist in the target repo. Only
# stack.yaml ships in the bundle today; the rest are forward-defensive (harmless if never shipped).
PRESERVE = {
    ".claude/config/stack.yaml",
    ".claude/settings.json",
    ".claude/settings.local.json",
    "tickets/index_data.json",
}


def _run_script(script: str, rest: list[str]) -> int:
    """Exec a bundled bin/ script against the current repo (CLAUDE_PROJECT_DIR = cwd)."""
    path = KIT / "bin" / script
    if not path.is_file():
        print(f"ticketwright: bundled script missing: {path}", file=sys.stderr)
        return 2
    env = {**os.environ, "CLAUDE_PROJECT_DIR": os.getcwd()}
    return subprocess.call([sys.executable, str(path), *rest], env=env)


def cmd_init(args) -> int:
    dest = Path(args.path).resolve()
    if not KIT.is_dir():
        print(f"ticketwright: kit assets not found at {KIT} (broken install?)", file=sys.stderr)
        return 2
    dest.mkdir(parents=True, exist_ok=True)
    copied, preserved = [], []
    for top in ("bin", ".claude", "adapters", "templates"):
        src = KIT / top
        if not src.is_dir():
            continue
        for f in sorted(p for p in src.rglob("*") if p.is_file()):
            if "__pycache__" in f.parts or f.suffix in (".pyc", ".pyo"):
                continue  # pip byte-compiles the bundled scripts at install time — don't scaffold cruft
            rel = f.relative_to(KIT).as_posix()              # e.g. ".claude/skills/recall/..."
            out = dest / rel
            if rel in PRESERVE and out.exists():
                preserved.append(rel)
                continue
            if out.exists() and not args.force:
                # don't overwrite an existing non-preserve file unless --force (keeps re-runs safe)
                preserved.append(rel)
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, out)
            copied.append(rel)
    print(f"ticketwright {__version__}: scaffolded into {dest}")
    print(f"  copied {len(copied)} files · preserved {len(preserved)} existing")
    print("  next: run `/configure-workspace` (writes stack.yaml + AGENTS.md + the index), then `/start-ticket`")
    return 0


SCRIPTS = {"recall": "recall.py", "index": "build_ticket_index.py", "enrich": "enrich_ticket.py"}
HELP = """ticketwright — tool-agnostic AI layer for ticket-driven work repos

usage: ticketwright <command> [args...]

commands:
  init [path] [--force]   scaffold the kit into a repo (versioned, upgrade-safe `cp -r`;
                          preserves existing per-repo config like stack.yaml)
  recall ...              prior-art recall against the repo at $PWD (e.g. --for ID | --object NAME | --eval)
  index ...               render / --check / --stats / --recurring the ticket index
  enrich ...              refresh a ticket's curated index summary (needs `claude`)
  --version               print version
"""


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(HELP)
        return 0 if argv else 1
    if argv[0] == "--version":
        print(f"ticketwright {__version__}")
        return 0
    cmd, rest = argv[0], argv[1:]
    # passthrough commands: hand the rest of argv verbatim to the bundled script (argparse REMAINDER
    # mishandles leading-dash args, so we dispatch manually).
    if cmd in SCRIPTS:
        return _run_script(SCRIPTS[cmd], rest)
    if cmd == "init":
        ip = argparse.ArgumentParser(prog="ticketwright init")
        ip.add_argument("path", nargs="?", default=".", help="target repo (default: current dir)")
        ip.add_argument("--force", action="store_true", help="overwrite existing (still preserves per-repo config)")
        return cmd_init(ip.parse_args(rest))
    print(f"ticketwright: unknown command '{cmd}'\n", file=sys.stderr)
    print(HELP, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
