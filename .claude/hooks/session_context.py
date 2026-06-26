#!/usr/bin/env python3
"""SessionStart hook — prime every session with the configured stack + AI-layer index.

Prints a compact summary (becomes session additionalContext) so the agent always knows
which tools are wired, which skills/commands exist, and the PIV loop — without anyone
having to load all of AGENTS.md. This is the always-on, *tiny* slice of context; the
`/prime-*` commands load the rest on demand.

Wire it in settings.json:
  "hooks": { "SessionStart": [ { "hooks": [
    { "type": "command", "command": "python3 .claude/hooks/session_context.py" } ] } ] }

Stdlib only. Fails open (prints nothing) if the kit isn't configured yet.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path


def project_root() -> Path:
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        return Path(os.environ["CLAUDE_PROJECT_DIR"])
    # hook lives at <root>/.claude/hooks/
    return Path(__file__).resolve().parent.parent.parent


def scan_stack(stack: Path) -> dict:
    text = stack.read_text(errors="replace")
    out = {}
    m = re.search(r"^\s*key_prefix:\s*([A-Za-z0-9_-]+)", text, re.MULTILINE)
    out["key_prefix"] = m.group(1) if m else "?"
    # tool per seam: find "  <seam>:" then the nested "    tool: <x>"
    for seam in ("tracker", "warehouse", "chat", "docstore", "vcs"):
        m = re.search(rf"^\s{{2}}{seam}:\s*\n(?:\s+.*\n)*?\s+tool:\s*([A-Za-z0-9_-]+)", text, re.MULTILINE)
        out[seam] = m.group(1) if m else "—"
    return out


def main() -> int:
    root = project_root()
    stack = root / ".claude/config/stack.yaml"
    if not stack.is_file():
        return 0  # not configured — say nothing

    try:
        s = scan_stack(stack)
    except OSError:
        return 0

    skills = sorted(p.parent.name for p in (root / ".claude/skills").glob("*/SKILL.md")) \
        if (root / ".claude/skills").is_dir() else []
    commands = sorted(p.stem for p in (root / ".claude/commands").glob("*.md")) \
        if (root / ".claude/commands").is_dir() else []

    lines = [
        "## Ticketwright — session context",
        f"Stack ({s['key_prefix']}-tickets): tracker={s['tracker']} · warehouse={s['warehouse']} · "
        f"chat={s['chat']} · docstore={s['docstore']} · vcs={s['vcs']}.",
        "PIV loop: /start-ticket → /spec-and-build → /qc-review → /deliver-ticket "
        "(+ /prime-ticket /prime-warehouse /prime-domain for scoped context).",
    ]
    if skills:
        lines.append("Skills: " + ", ".join(skills) + ".")
    if commands:
        lines.append("Commands: " + ", ".join(commands) + ".")
    lines.append("Policies enforced: DB writes & external posts require approval (db_write_guard hook + "
                 "skill hard-halts); chat defaults to draft; outputs deterministic. See AGENTS.md.")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
