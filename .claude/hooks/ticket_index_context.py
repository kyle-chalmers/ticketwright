#!/usr/bin/env python3
"""SessionStart hook — surface the ticket index so Claude recalls prior work.

Prints a compact block (becomes session additionalContext): the catalog size, a
status breakdown, and the most recent tickets, plus a pointer to grep the full
`tickets/INDEX.md` before starting related work. The authoritative *count* comes from
discovering ticket folders on disk (so a newly-added, not-yet-enriched ticket still
counts); the per-ticket detail comes from the enriched `tickets/index_data.json`.
Stdlib only; fails open (prints nothing) on any error.

Wire in .claude/settings.json:
  "hooks": { "SessionStart": [ { "hooks": [
    { "type": "command", "command": "python3 .claude/hooks/ticket_index_context.py" } ] } ] }
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

RECENT = 12
STATUS_ORDER = ["Deployed", "Completed", "In Review", "In Progress", "Blocked", "Unknown"]


def project_root() -> Path:
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        return Path(os.environ["CLAUDE_PROJECT_DIR"])
    return Path(__file__).resolve().parent.parent.parent  # .claude/hooks/ -> root


def ticket_number(tid: str) -> int:
    m = re.search(r"-(\d+)", tid)
    return int(m.group(1)) if m else 0


def discovered_total(root: Path) -> int | None:
    """True ticket count from the renderer's discovery (cheap globs, no README reads)."""
    try:
        import sys
        sys.path.insert(0, str(root / "bin"))
        from build_ticket_index import discover  # type: ignore
        return len(discover(root))
    except Exception:
        return None


def main() -> int:
    root = project_root()
    data_file = root / "tickets" / "index_data.json"
    index_file = root / "tickets" / "INDEX.md"

    tickets = []
    if data_file.is_file():
        try:
            loaded = json.loads(data_file.read_text())
            if isinstance(loaded, dict) and isinstance(loaded.get("tickets"), list):
                tickets = [t for t in loaded["tickets"] if isinstance(t, dict)]
        except (OSError, json.JSONDecodeError):
            tickets = []

    if not tickets:
        # Catalog may exist but not be enriched yet — emit a bare pointer if INDEX.md is there.
        if index_file.is_file():
            print("## Ticket index\nCatalog of prior ticket work: `tickets/INDEX.md` — grep it before "
                  "starting related work (same object / stakeholder / report).")
        return 0

    total = discovered_total(root) or len(tickets)
    by_status: dict[str, int] = {}
    for t in tickets:
        s = t.get("status") or "Unknown"
        by_status[s] = by_status.get(s, 0) + 1
    extra = sorted(s for s in by_status if s not in STATUS_ORDER)
    status_line = " · ".join(f"{s} {by_status[s]}" for s in (STATUS_ORDER + extra) if by_status.get(s))

    recent = sorted(tickets, key=lambda t: (t.get("date") or "0000-00-00", ticket_number(t.get("id", ""))),
                    reverse=True)[:RECENT]

    lines = [
        "## Ticket index — recall before starting work",
        f"{total} tickets indexed ({status_line}). Full catalog: `tickets/INDEX.md` — "
        "**grep it for prior work on the same object / stakeholder / report before starting a ticket, and reuse it.**",
        f"Most recent {len(recent)}:",
    ]
    for t in recent:
        title = (t.get("title") or "").strip()
        if len(title) > 72:
            title = title[:71].rstrip() + "…"
        d = t.get("date") or "—"
        lines.append(f"- {t.get('owner')}/{t.get('id')} ({d}) — {title}")
    if total > len(tickets):
        lines.append(f"({total - len(tickets)} newer ticket(s) on disk not yet enriched — run the index workflow.)")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
