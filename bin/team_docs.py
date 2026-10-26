#!/usr/bin/env python3
"""team_docs.py — list the docs a team keeps about how it works, as a harness-neutral command.

`project.team_docs` in stack.yaml holds two optional lists:
  standards  rules for how analysis is done here; /build follows them and /review checks
             deliverables against them.
  context    anything else worth knowing about the team or its data (a wiki, onboarding notes,
             a data dictionary, metric definitions); /ticket reads it while planning.

Each item is a path or URL, or a mapping `{location: <path or url>, note: <short phrase>}`.
Omitted or empty means "none yet", the normal default.

This script only NORMALIZES the list. It never fetches a URL: a team doc can live in any wiki or
doc tool, so the agent opens it with whatever reader its runtime has, and records each doc as
opened or unreadable. A local path is checked for existence here so a missing file is never
reported as read.

Usage: team_docs.py [--root DIR] [--kind standards|context] [--json]
Exit codes: 0 ok, 2 a malformed item (stderr names its list and position).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from effective_config import resolve  # noqa: E402

KINDS = ("standards", "context")


class BadItem(ValueError):
    pass


def _is_url(location: str) -> bool:
    return urlparse(location).scheme in ("http", "https")


def normalize(raw: object, root: Path) -> list[dict]:
    """Turn `project.team_docs` into one row per doc. Raises BadItem on anything malformed."""
    if raw in (None, "", []):
        return []
    if not isinstance(raw, dict):
        raise BadItem("team_docs must be a mapping with 'standards' and/or 'context' lists")
    unknown = sorted(set(raw) - set(KINDS))
    if unknown:
        raise BadItem(f"team_docs has unknown list(s) {unknown}; expected {list(KINDS)}")
    rows: list[dict] = []
    for kind in KINDS:
        items = raw.get(kind) or []
        if not isinstance(items, list):
            raise BadItem(f"team_docs.{kind} must be a list")
        for i, item in enumerate(items):
            if isinstance(item, str):
                location, note = item, None
            elif isinstance(item, dict) and isinstance(item.get("location"), str):
                location, note = item["location"], item.get("note")
            else:
                raise BadItem(f"team_docs.{kind}[{i}] needs a path or URL, or a 'location:' key")
            location = location.strip()
            if not location:
                raise BadItem(f"team_docs.{kind}[{i}] has an empty location")
            is_url = _is_url(location)
            exists = None if is_url else (root / os.path.expanduser(location)).exists()
            rows.append({"kind": kind, "location": location,
                         "note": str(note) if note is not None else None,
                         "is_url": is_url, "exists": exists})
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="List the team's standards and context docs.")
    ap.add_argument("--root", default=os.environ.get("CLAUDE_PROJECT_DIR") or ".",
                    help="repo root (default: $CLAUDE_PROJECT_DIR, else cwd)")
    ap.add_argument("--kind", choices=KINDS, help="only this list")
    ap.add_argument("--json", action="store_true", help="emit JSON rows")
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    try:
        rows = normalize(resolve(root).get("project.team_docs"), root)
    except BadItem as exc:
        print(f"team_docs.py: {exc}", file=sys.stderr)
        return 2
    if args.kind:
        rows = [r for r in rows if r["kind"] == args.kind]

    if args.json:
        print(json.dumps(rows, indent=2))
    elif not rows:
        print("none configured")
    else:
        for r in rows:
            print(f"{r['kind']}\t{r['location']}\t{r['note'] or '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
