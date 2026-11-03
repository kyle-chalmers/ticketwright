#!/usr/bin/env python3
"""refresh_launcher.py — check, and on request replace, the project's copy of the launcher.

/setup copies two kit files into <project>/bin/ and the team commits them: `tw` (the launcher every
skill calls) and `kit_paths.py` (which finds the installed kit). Until stamping, nothing ever updated
those copies, because /setup copied them only when they were missing. That matters: the kit's
scripts moved from a top-level bin/ to tools/ (LABS-209), and a copy older than launcher stamp 2
only knows bin/, so it cannot find a kit that has moved.

Each file carries a `# tw-launcher: N` stamp near the top; a copy without one counts as 1. This
script compares the project's copies against the kit's own:

  current   the copies match the kit's stamp; nothing to do
  stale     a copy is older; --write replaces it
  missing   no copy yet; --write installs it, as /setup does on its first run
  kit       the project IS the kit (a vendored or `ticketwright init` install); nothing to refresh
  newer     a copy is newer than this kit (another version is installed for this repo); left alone
  foreign   a file at bin/tw or bin/kit_paths.py that is not Ticketwright's; left alone
  linked    a symlink there, which a copy would write through to its target; left alone

It never replaces a copy that is current or newer, never touches any other file, and never commits:
it prints each file it wrote so the person can review and commit them.

Usage: refresh_launcher.py [--root DIR] [--write] [--json]
Exit codes: 0 nothing left to do (or --write fixed it), 1 a copy is stale or missing and --write
was not given, 3 the kit could not be located.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kit_paths import launcher_status, resolve_kit, resolve_project, scripts_dir  # noqa: E402

NEEDS_WRITE = ("stale", "missing")


def refresh(project: Path, kit: Path) -> list[str]:
    """Copy each stale or missing launcher file from the kit into <project>/bin/; return what changed."""
    status = launcher_status(project, kit)
    src_dir = scripts_dir(kit)
    written = []
    for name, entry in status["files"].items():
        if entry["state"] not in NEEDS_WRITE or src_dir is None:
            continue
        dest = project / "bin" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src_dir / name, dest)
        if name == "tw":
            dest.chmod(dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        written.append(str(dest.relative_to(project)))
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Check or refresh the project's copy of the Ticketwright launcher.")
    ap.add_argument("--root", help="the project repo (default: $TICKETWRIGHT_PROJECT, git toplevel, cwd)")
    ap.add_argument("--write", action="store_true", help="replace a stale copy, or install a missing one")
    ap.add_argument("--json", action="store_true", help="print the status as JSON")
    args = ap.parse_args(argv)

    project, _ = resolve_project(args.root)
    # This script runs from the kit, so its own location is the kit to compare against. The
    # resolver is the fallback for a copy run some other way.
    own = Path(__file__).resolve().parent.parent
    kit = own if scripts_dir(own) and (own / "adapters").is_dir() else resolve_kit(project)[0]
    if kit is None:
        print("Could not find the Ticketwright kit, so there is nothing to compare the launcher with. "
              "Details: set TICKETWRIGHT_KIT=<path to the kit>.", file=sys.stderr)
        return 3

    written = refresh(project, kit) if args.write else []
    status = launcher_status(project, kit)
    if args.json:
        print(json.dumps({**status, "written": written}, indent=2))
    elif written:
        print(f"Updated the launcher in {project / 'bin'}. Commit these files: {', '.join(written)}.")
    elif status["state"] == "stale":
        print("This project's copy of the launcher is out of date. Run this again with --write, then "
              "commit `bin/tw` and `bin/kit_paths.py`. Details: stamp older than the kit's.")
    elif status["state"] == "missing":
        print("This project has no launcher yet. Run this again with --write, or run /setup. "
              "Details: no `bin/tw` or `bin/kit_paths.py`.")
    elif status["state"] == "foreign":
        print("A file in `bin/` has the launcher's name but is not Ticketwright's, so it was left "
              "alone. Details: move it, then run this again.")
    elif status["state"] == "linked":
        print("The launcher in `bin/` is a symlink, so it was left alone: a copy would change the file "
              "it points to. Details: replace the link with a plain file, then run this again.")
    elif status["state"] == "newer":
        print("This project's launcher is newer than this kit, so it was left alone. "
              "Details: another Ticketwright version is installed for this repo.")
    else:
        print("The launcher is up to date. Details: state " + status["state"] + ".")
    return 1 if status["state"] in NEEDS_WRITE else 0


if __name__ == "__main__":
    raise SystemExit(main())
