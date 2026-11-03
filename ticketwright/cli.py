"""`ticketwright` CLI — stdlib only (no runtime deps; on-brand with the kit's KISS stance).

  ticketwright init [path]      scaffold the kit into a repo (the pip-native install — a versioned,
                                upgrade-safe replacement for `cp -r`; preserves existing per-repo config)
  ticketwright recall ...       run prior-art recall against the repo at $PWD  (passthrough to recall.py)
  ticketwright index  ...       (re)render / --check / --stats / --recurring the ticket index
  ticketwright enrich ...       refresh a ticket's curated index summary

The kit assets ship bundled under ticketwright/_kit/; the run-* commands exec the bundled tools/ scripts
with the project root set to the current directory, so they read the repo you're standing in.
"""
from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__

KIT = Path(__file__).resolve().parent / "_kit"
# Per-install files that init must NEVER clobber if they already exist in the target repo. None of
# these ship in the bundle today (stack.yaml is deliberately excluded from the wheel — `/setup`
# writes it), so every entry is forward-defensive: harmless now, a guard if one starts shipping.
# The two launcher files every install keeps in <project>/bin/. The skills call
# "$(git rev-parse --show-toplevel)/bin/tw", so a vendored kit needs them there too.
LAUNCHER = ("tw", "kit_paths.py")
PRESERVE = {
    ".claude/config/stack.yaml",
    ".claude/settings.json",
    ".claude/settings.local.json",
    "tickets/index_data.json",
}


def _run_script(script: str, rest: list[str]) -> int:
    """Exec a bundled tools/ script against the current repo (CLAUDE_PROJECT_DIR = cwd)."""
    path = KIT / "tools" / script
    if not path.is_file():
        print(f"ticketwright: bundled script missing: {path}", file=sys.stderr)
        return 2
    # TICKETWRIGHT_PROJECT is the harness-neutral name; CLAUDE_PROJECT_DIR stays for older kits
    # vendored into a repo that predate it.
    env = {**os.environ, "TICKETWRIGHT_PROJECT": os.getcwd(), "CLAUDE_PROJECT_DIR": os.getcwd()}
    return subprocess.call([sys.executable, str(path), *rest], env=env)


def _install_launcher(dest: Path, force: bool, preserved: list[str], foreign: list[str]) -> list[str]:
    """Write the launcher pair into <dest>/bin/, as /setup does on a plugin install.

    A copy whose stamp is older than the bundled one is replaced; a current one is kept unless
    --force. A file there that is not Ticketwright's launcher (no stamp, no launcher marker) is never
    touched: it belongs to the team.
    """
    sys.path.insert(0, str(KIT / "tools"))
    try:
        from kit_paths import LAUNCHER_STAMP, launcher_stamp
    finally:
        sys.path.pop(0)
    written = []
    for name in LAUNCHER:
        out = dest / "bin" / name
        rel = f"bin/{name}"
        if out.is_symlink():
            preserved.append(rel)
            continue
        if out.exists():
            stamp = launcher_stamp(out)
            if stamp == 0:
                preserved.append(rel)
                foreign.append(rel)
                continue
            if stamp is not None and stamp >= LAUNCHER_STAMP and not force:
                preserved.append(rel)
                continue
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(KIT / "tools" / name, out)
        written.append(rel)
    return written


def cmd_init(args) -> int:
    dest = Path(args.path).resolve()
    if not KIT.is_dir():
        print(f"ticketwright: kit assets not found at {KIT} (broken install?)", file=sys.stderr)
        return 2
    # The kit's scripts land in <repo>/tools/. A team may already have a tools/ folder of its own:
    # refuse rather than mix files into it. tools/KIT_VERSION is the mark of one init wrote.
    tools = dest / "tools"
    if tools.is_dir() and any(tools.iterdir()) and not (tools / "KIT_VERSION").is_file():
        print(f"ticketwright: {tools} already exists and was not written by `ticketwright init`, so "
              "nothing was copied. Details: move or rename that folder, then run init again.",
              file=sys.stderr)
        return 2
    dest.mkdir(parents=True, exist_ok=True)
    copied, preserved = [], []
    for top in ("tools", ".claude", "adapters", "templates"):
        src = KIT / top
        if not src.is_dir():
            continue
        for f in sorted(p for p in src.rglob("*") if p.is_file()):
            if "__pycache__" in f.parts or f.suffix in (".pyc", ".pyo"):
                continue  # pip byte-compiles the bundled scripts at install time — don't scaffold cruft
            rel = f.relative_to(KIT).as_posix()              # e.g. ".claude/skills/ticket/..."
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
    # An init run before the scripts moved to tools/ copied them all into bin/ and marked that with
    # bin/KIT_VERSION. Clear them, but only once .claude/hooks/ matches this kit: an older hook
    # imports its scanner from bin/, so removing bin/ first would leave the guards unable to load
    # (and a re-run without --force keeps the older hooks). tools/old_layout.py removes only files
    # whose bytes match a version Ticketwright shipped, and names any it keeps.
    removed, kept, deferred = [], [], False
    if (dest / "bin" / "KIT_VERSION").is_file():
        hooks = sorted((KIT / ".claude" / "hooks").glob("*.py"))
        if all((dest / ".claude" / "hooks" / f.name).is_file()
               and filecmp.cmp(f, dest / ".claude" / "hooks" / f.name, shallow=False) for f in hooks):
            sys.path.insert(0, str(KIT / "tools"))
            try:
                from old_layout import clear_old_bin
            finally:
                sys.path.pop(0)
            names, kept = clear_old_bin(dest / "bin")
            removed = [f"bin/{n}" for n in names]
        else:
            deferred = True
    foreign: list[str] = []
    copied += _install_launcher(dest, args.force, preserved, foreign)
    # A vendored kit carries no version marker of its own (init deliberately copies only the four
    # kit dirs, never ticketwright/__init__.py) — write one so `ticketwright install`'s provenance
    # header can name the version that vendored these files. It follows the same preserve/--force
    # rule as every copied file, and must: a re-run without --force keeps the OLD files, so
    # refreshing the marker would make it name a version the tree does not have. The single source
    # of truth stays ticketwright/__init__.py, which this value is read from.
    marker = tools / "KIT_VERSION"
    if args.force or not marker.exists():
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(__version__ + "\n", encoding="utf-8")
        copied.append("tools/KIT_VERSION")
    else:
        preserved.append("tools/KIT_VERSION")
    # `init` copies; it never mirrors. A repo scaffolded before a skill was renamed keeps the OLD
    # skill directory beside the new one, and both show up in the slash menu. tools/retired_skills.py
    # removes a retired directory only when every file in it is an unedited shipped version, and
    # names any edited one instead. Loaded from the bundled kit, so the rule has one home.
    sys.path.insert(0, str(KIT / "tools"))
    try:
        from retired_skills import prune_retired
    finally:
        sys.path.pop(0)
    prune_retired(dest / ".claude" / "skills", "ticketwright init")
    print(f"ticketwright {__version__}: scaffolded into {dest}")
    print(f"  copied {len(copied)} files · preserved {len(preserved)} existing")
    for rel in removed:
        print(f"  removed {rel} (an older init put the kit's scripts in bin/; they now live in tools/)")
    for name in kept:
        print(f"  kept bin/{name}: it has a kit script's name but differs from every version "
              "Ticketwright shipped, so it may be yours. Delete it once nothing uses it.")
    if deferred:
        print("  bin/ still holds the kit's scripts from an older init, because .claude/hooks/ has "
              "older copies that load them. Run `ticketwright init --force` to finish the move; it "
              "replaces the kit's files and keeps stack.yaml and your settings.")
    for rel in foreign:
        print(f"  left {rel} alone: it is not Ticketwright's launcher, so skills that call it will "
              "run your file instead. Details: move it aside and run init again to install the launcher.")
    print("  next: run `/setup` (writes stack.yaml + AGENTS.md + the index), then `/ticket <id>`")
    print("  on a non-Claude runtime: `ticketwright install --runtime <name>` translates the skills")
    return 0


# `install` registers the PYTHON entrypoint (emit_runtime.py), not tools/install.sh — _run_script
# invokes every registered script with sys.executable, so registering the .sh would run
# `python install.sh` and fail. The .sh is the standalone shell convenience wrapping the same file.
SCRIPTS = {"recall": "recall.py", "index": "build_ticket_index.py", "enrich": "enrich_ticket.py",
           "install": "emit_runtime.py"}
HELP = """ticketwright — tool-agnostic AI layer for ticket-driven work repos

usage: ticketwright <command> [args...]

commands:
  init [path] [--force]   scaffold the kit into a repo (versioned, upgrade-safe `cp -r`;
                          preserves existing per-repo config like stack.yaml). On a non-Claude
                          runtime, follow with `ticketwright install --runtime <name>`.
  install --runtime <name> [--local|--global] [--root <path>]
                          install the skills + agent definitions for any of the seven runtimes:
                          verify-only where the runtime reads the canonical .claude/skills/ copy
                          (claude-code natively; cursor/opencode/cline/devin read it directly),
                          translate-on-emit where it cannot (codex-cli/antigravity). Metadata a
                          runtime cannot express is stated, never silently dropped.
  recall ...              prior-art recall against the repo at $PWD (e.g. --for ID | --object NAME | --eval)
  index ...               render / --check / --stats / --recurring the ticket index
  enrich ...              refresh a ticket's curated index summary (needs a model CLI; see --model-cmd)
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
