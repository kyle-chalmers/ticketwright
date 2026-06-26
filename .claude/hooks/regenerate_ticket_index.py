#!/usr/bin/env python3
"""PostToolUse hook — auto-regenerate tickets/INDEX.md when a ticket folder changes.

Fires after Write/Edit. If the edited file lives under tickets/ (and isn't the index
artifacts themselves), it re-renders tickets/INDEX.md so the catalog always reflects
reality: a new ticket appears immediately (marked ▱ until curated), and an edited README
flags its row ⚠ (summary may be stale). LLM-authored summaries are *not* regenerated here
(a hook can't run the model synchronously) — those refresh at ticket close via
bin/ingest_index_records.py.

Deterministic + fast (re-renders from disk + index_data.json). Writes only when the
rendered output actually changes, so irrelevant edits produce no churn. Fails open.

Wire in .claude/settings.json:
  "hooks": { "PostToolUse": [ { "matcher": "Write|Edit", "hooks": [
    { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/regenerate_ticket_index.py\"" } ] } ] }
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # nothing to do

    tool_input = payload.get("tool_input") or {}
    fp = tool_input.get("file_path") or tool_input.get("path") or ""
    if not fp:
        return 0

    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or ".").resolve()
    tickets_dir = root / "tickets"
    try:
        changed = Path(fp).resolve()
        changed.relative_to(tickets_dir)  # raises if not under tickets/
    except (ValueError, OSError):
        return 0  # edit was not under tickets/

    # Don't react to the index artifacts themselves.
    if changed.name in ("INDEX.md", "index_data.json"):
        return 0

    sys.path.insert(0, str(root / "bin"))
    try:
        from build_ticket_index import build_rows, render  # type: ignore
        fresh = render(build_rows(root))
    except SystemExit:
        return 0  # malformed index_data.json — surfaced when the agent runs the renderer
    except Exception:
        return 0  # fail open

    index_path = tickets_dir / "INDEX.md"
    try:
        current = index_path.read_text() if index_path.is_file() else None
        if current != fresh:
            index_path.write_bytes(fresh.encode("utf-8"))
            print("Auto-regenerated tickets/INDEX.md (ticket folder changed). "
                  "Run bin/ingest_index_records.py to refresh a ticket's curated summary.")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
