#!/usr/bin/env python3
"""Wait for a Google Drive for desktop file to get its Drive id, then print its share link.

The gdrive docstore adapter's `link_for` verb builds a link from the `item-id` extended attribute
Drive for desktop sets on a synced file. Right after a copy that attribute is blank for a while, and
the adapter used to say "wait", which every agent turned into its own sleep loop. This is that loop,
once: poll `xattr -l <path>` until an `item-id` appears or the timeout passes.

Usage:
  gdrive_item_id.py "<file or folder inside the Drive mount>" [--timeout 300] [--interval 5]

Prints the URL on stdout (a folder gets a folders/ link). Exit codes: 0 found · 1 timed out ·
2 the path does not exist or `xattr` is not available (macOS only). Local only: it reads one
attribute of one path and makes no network call. Stdlib only.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

ITEM_ID = re.compile(r"item-id[^:]*:\s*(\S+)")


def read_item_id(path: Path) -> str | None:
    """The `item-id` value from `xattr -l` (NOT `xattr -p`: the attribute name carries a `#S`
    suffix that shells mangle), or None while Drive has not assigned one yet."""
    out = subprocess.run(["xattr", "-l", str(path)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = ITEM_ID.search(line)
        if m:
            return m.group(1)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Wait for a Drive item-id and print the share link")
    ap.add_argument("path")
    ap.add_argument("--timeout", type=float, default=300.0, help="seconds to wait (default 300)")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between checks (default 5)")
    args = ap.parse_args()

    path = Path(args.path)
    if not path.exists():
        print(f"There is no file at {path}. Check the backup finished and the path is inside the "
              f"Drive folder. Details: path not found.", file=sys.stderr)
        return 2
    deadline = time.monotonic() + max(0.0, args.timeout)
    while True:
        try:
            item_id = read_item_id(path)
        except FileNotFoundError:
            print("Drive links can only be read on a Mac with Google Drive for desktop. Share the "
                  "link from Drive by hand. Details: the xattr command is not available.", file=sys.stderr)
            return 2
        if item_id:
            kind = "drive/folders" if path.is_dir() else "file/d"
            print(f"https://drive.google.com/{kind}/{item_id}")
            return 0
        if time.monotonic() >= deadline:
            print(f"Drive has not finished syncing {path.name} after {args.timeout:g} seconds, so "
                  f"there is no link yet. Run this again in a few minutes, or copy the link from "
                  f"Drive. Details: no item-id attribute on {path}.", file=sys.stderr)
            return 1
        time.sleep(max(0.1, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
