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

    # Don't react to the *generated* artifacts (else the hook's own write re-triggers it).
    # index_data.json is source, NOT generated — editing the store SHOULD re-render.
    if changed.name in ("INDEX.md", "OBJECTS.md"):
        return 0
    # generated graph layer (tickets/graph/, tickets/objects/) — regenerated below; never react to it
    if any(part in ("graph", "objects") for part in changed.relative_to(tickets_dir).parts[:-1]):
        return 0

    # The renderer module ships with the kit (bin/), not the user's project — resolve it against
    # CLAUDE_PLUGIN_ROOT (else this hook's own kit dir). `root` stays the project for the data.
    kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
    bindir = (Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent) / "bin"
    sys.path.insert(0, str(bindir))
    try:
        from build_ticket_index import build_rows, render, render_objects, render_graph_layer, load_config  # type: ignore
        rows = build_rows(root)
        cfg = load_config(root)
        fresh = {tickets_dir / "INDEX.md": render(rows), tickets_dir / "OBJECTS.md": render_objects(rows)}
        graph_dirs = [tickets_dir / "graph", tickets_dir / "objects"]  # always tracked so disabling cleans up
        if cfg.get("graph_notes", True):
            fresh.update(render_graph_layer(rows, root))
    except SystemExit:
        return 0  # malformed index_data.json — surfaced when the agent runs the renderer
    except Exception:
        return 0  # fail open

    try:
        changed_any = False
        for p, txt in fresh.items():
            if (p.read_text() if p.is_file() else None) != txt:
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(txt.encode("utf-8")); changed_any = True
        fresh_keys_ci = {str(p).lower() for p in fresh}  # orphan cleanup (case-insensitive for macOS)
        for gd in graph_dirs:
            if gd.is_dir():
                for existing in gd.glob("*.md"):
                    if str(existing).lower() not in fresh_keys_ci:
                        existing.unlink(); changed_any = True
                if not any(gd.iterdir()):
                    gd.rmdir()
        if changed_any:
            print("Auto-regenerated tickets/INDEX.md + OBJECTS.md + graph layer (ticket folder changed). "
                  "Run bin/ingest_index_records.py to refresh a ticket's curated summary.")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
