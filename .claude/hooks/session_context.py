#!/usr/bin/env python3
"""SessionStart hook — prime every session with the configured stack + AI-layer index.

Prints a compact summary (becomes session additionalContext) so the agent always knows
which tools are wired, which skills/commands exist, and the lifecycle — without anyone
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

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _stack import MODE_ALL, MODE_OFF, db_write_mode  # noqa: E402


def project_root() -> Path:
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        return Path(os.environ["CLAUDE_PROJECT_DIR"])
    # hook lives at <root>/.claude/hooks/
    return Path(__file__).resolve().parent.parent.parent


_COMMENT = re.compile(r"^\s*#")
_BLOCK_SCALAR = re.compile(
    r"""^\s*(?:-\s+)?(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.-]+):\s*[|>][-+0-9]*\s*(?:#.*)?$"""
)
_PROP = r"(?:[&*!][^\s#]*\s*)?"      # an optional YAML anchor/alias/tag after a mapping key


def seam_block(text: str, seam: str) -> str:
    """The lines under `<seam>:` inside the top-level `seams:` mapping.

    The seam-key indent is inferred from the file rather than assumed, comment-only lines carry no
    indentation, a key may hold a YAML anchor, and block-scalar bodies are skipped. Deliberately
    duplicated from db_write_guard.py — hooks are copied individually on a vendored install, so each
    has to stand alone as a stdlib-only script.
    """
    lines = text.splitlines()
    start = next((i for i, ln in enumerate(lines)
                  if re.match(rf"^seams:\s*{_PROP}(?:#.*)?$", ln)), None)
    if start is None:
        return ""

    indent = depth = skip_deeper_than = None
    out = []
    for ln in lines[start + 1:]:
        if not ln.strip() or _COMMENT.match(ln):
            continue
        cur = len(ln) - len(ln.lstrip())
        if cur == 0:
            break
        if skip_deeper_than is not None:
            if cur > skip_deeper_than:
                continue
            skip_deeper_than = None
        if depth is None:
            if indent is None:
                indent = cur
            if cur == indent:
                km = re.match(rf"^\s*{re.escape(seam)}:\s*(.*)$", ln)
                if km:
                    rest = re.sub(r"^[&*!][^\s#]*\s*", "", km.group(1).strip())
                    rest = re.sub(r"\s*#.*$", "", rest).strip()
                    if rest.startswith("{"):
                        return rest        # inline flow mapping — the seam is all on this line
                    if rest == "":
                        depth = cur
            continue
        if cur <= depth:
            break
        if _BLOCK_SCALAR.match(ln):
            skip_deeper_than = cur
            continue
        out.append(ln)
    return "\n".join(out)


def seam_tools(text: str, seam: str) -> list[str]:
    """Every `tool:` declared in a seam — one for a single mapping, one per target otherwise.

    A multi-target seam returns the default's tool FIRST, so the banner never implies the wrong
    warehouse is the active one.
    """
    blk = seam_block(text, seam)
    if not blk:
        return []

    # A wholly inline seam (`warehouse: {default: prod, targets: {…}}`) has no lines to walk, so
    # read it positionally: tools in document order, default's tool hoisted to the front.
    if blk.lstrip().startswith("{"):
        tools = re.findall(r"\btool:\s*([A-Za-z0-9_.-]+)", blk)
        dm = re.search(r"\bdefault:\s*([A-Za-z0-9_.-]+)", blk)
        if dm:
            # `<name>: {… tool: X …}` — find the tool belonging to the default target.
            tm = re.search(rf"\b{re.escape(dm.group(1))}:\s*\{{[^}}]*\btool:\s*([A-Za-z0-9_.-]+)", blk)
            if tm and tm.group(1) in tools:
                tools = [tm.group(1)] + [t for t in tools if t != tm.group(1)]
        return tools

    pairs, cur_target, target_indent = [], None, None
    for ln in blk.splitlines():
        m = re.match(r"^(\s*)([A-Za-z0-9_.-]+):\s*(.*)$", ln)
        if not m:
            continue
        ind, key = len(m.group(1)), m.group(2)
        val = re.sub(r"\s*#.*$", "", m.group(3)).strip()
        if key == "tool" and val:
            pairs.append((cur_target, val))
            continue
        if key == "targets":
            continue
        if val == "" or val.startswith("{"):
            # the header of one target — bare `name:`, or `name: {…}` in flow style
            if target_indent is None or ind <= target_indent:
                target_indent, cur_target = ind, key
            tm = re.search(r"\btool:\s*([A-Za-z0-9_.-]+)", val)
            if tm:
                pairs.append((key, tm.group(1)))   # flow style: its tool is on this same line
    dm = re.search(r"^\s+default:\s*([A-Za-z0-9_.-]+)", blk, re.MULTILINE)
    if dm:
        d = dm.group(1)
        pairs.sort(key=lambda p: 0 if p[0] == d else 1)   # stable: others keep file order
    return [t for _, t in pairs]


def scan_stack(stack: Path) -> dict:
    text = stack.read_text(errors="replace")
    out = {}
    m = re.search(r"^\s*key_prefix:\s*([A-Za-z0-9_-]+)", text, re.MULTILINE)
    out["key_prefix"] = m.group(1) if m else "?"
    for seam in ("tracker", "warehouse", "chat", "docstore", "vcs"):
        tools = seam_tools(text, seam)
        # A multi-target seam renders as "a+b" (default first) so no target is hidden.
        out[seam] = "+".join(tools) if tools else "—"
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
    commands = sorted(
        p.stem for p in (root / ".claude/commands").glob("*.md")
    ) if (root / ".claude/commands").is_dir() else []

    lines = [
        "## Ticketwright — session context",
        f"Stack ({s['key_prefix']}-tickets): tracker={s['tracker']} · warehouse={s['warehouse']} · "
        f"chat={s['chat']} · docstore={s['docstore']} · vcs={s['vcs']}.",
        "Lifecycle: /ticket (opens + auto-primes context) → /spec-and-build → /review → /ship.",
    ]
    if skills:
        lines.append("Skills: " + ", ".join(skills) + ".")
    if commands:
        lines.append("Commands: " + ", ".join(commands) + ".")
    # Name the actual policy value: a banner that says "DB writes require approval" while the
    # guard is set to `off` teaches the agent the wrong rule.
    mode = db_write_mode(stack)
    db_rule = {
        MODE_OFF: "DB writes are NOT gated (db_write_requires_approval: off)",
        MODE_ALL: "every DB write requires approval (db_write_requires_approval: all)",
    }.get(mode, "high-risk DB writes require approval (db_write_requires_approval: high_risk) — "
                "plain CREATE/INSERT/ALTER ADD run without asking")
    lines.append(f"Policies enforced: {db_rule}; external posts require approval "
                 "(db_write_guard hook + skill hard-halts); chat defaults to draft; "
                 "outputs deterministic. See AGENTS.md.")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
