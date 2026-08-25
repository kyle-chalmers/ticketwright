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
import subprocess
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


_TRANSPORT_LINE = re.compile(r"^transport:\s*([A-Za-z]+)", re.MULTILINE)


def adapter_transport(adapter: object) -> str | None:
    """The `transport:` an adapter's frontmatter declares, or None when anything fails.

    Kit-relative resolution (CLAUDE_PLUGIN_ROOT, else this hook's own kit checkout) — adapters are
    KIT assets. None means UNKNOWN, and unknown must never claim an MCP path exists."""
    try:
        if not adapter or not isinstance(adapter, str):
            return None
        kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
        kit_root = Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent
        text = (kit_root / adapter).read_text(errors="replace")
        if not text.startswith("---"):
            return None
        m = _TRANSPORT_LINE.search(text.split("---", 2)[1])
        return m.group(1).lower() if m else None
    except Exception:  # noqa: BLE001 — a hook must fail open
        return None


def scan_stack_resolved(root: Path) -> dict | None:
    """The banner's fields, read through the three-tier resolver.

    Returns None if the resolver is unavailable or unhappy, so the caller falls back to the
    regex scan below. A SessionStart hook must fail open: a config the resolver declines to parse
    should still get a banner, not silence.
    """
    try:
        kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
        bindir = (Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent) / "bin"
        sys.path.insert(0, str(bindir))
        from effective_config import resolve  # type: ignore
        res = resolve(root)
    except Exception:  # noqa: BLE001
        return None
    if not res.seams and not res.project:
        return None
    out: dict = {}
    prefix = res.project.get("key_prefix")
    if not prefix:
        plural = res.project.get("key_prefixes")
        if isinstance(plural, list) and plural:
            prefix = plural[0]
        elif isinstance(plural, str):
            prefix = plural
    out["key_prefix"] = str(prefix) if prefix else None
    for seam in ("tracker", "warehouse", "chat", "docstore", "vcs"):
        node = res.seams.get(seam)
        if not isinstance(node, dict):
            out[seam] = "—"
            continue
        targets = node.get("targets")
        if isinstance(targets, dict) and targets:
            names = list(targets)
            default = node.get("default")
            if default in names:      # the DEFAULT target leads, so the banner never implies
                names.remove(default)  # the wrong active warehouse
                names.insert(0, default)
            tools = [str(targets[n].get("tool")) for n in names
                     if isinstance(targets[n], dict) and targets[n].get("tool")]
            out[seam] = "+".join(tools) if tools else "—"
        else:
            out[seam] = str(node.get("tool")) if node.get("tool") else "—"
    # Does any warehouse unit's RESOLVED transport include mcp? Three-valued on purpose:
    # True (some unit is mcp/both), False (every unit is provably shell-only), None (unknown —
    # and unknown never claims MCP). The configured value wins; adapter frontmatter is only the
    # fallback, mirroring bin/verify_stack.sh's posture advisory.
    out["warehouse_mcp"] = None
    wnode = res.seams.get("warehouse")
    if isinstance(wnode, dict):
        wtargets = wnode.get("targets")
        if isinstance(wtargets, dict) and wtargets:
            inherited = {k: v for k, v in wnode.items() if k not in ("targets", "default")}
            units = [{**inherited, **t} for t in wtargets.values() if isinstance(t, dict)]
        else:
            units = [wnode]
        flags = []
        for unit in units:
            tr = unit.get("transport")
            tr = str(tr).strip().lower() if tr else adapter_transport(unit.get("adapter"))
            flags.append(None if tr is None else tr in ("mcp", "both"))
        if any(f is True for f in flags):
            out["warehouse_mcp"] = True
        elif flags and all(f is False for f in flags):
            out["warehouse_mcp"] = False
    return out


def scan_stack(stack: Path) -> dict:
    text = stack.read_text(errors="replace")
    out = {}
    # None, not "?": a trackerless (id_mode: slug) repo has no prefix, and the caller labels the
    # workspace by its directory instead of printing "?-tickets". `key_prefixes` is checked too —
    # a keyed repo may configure only the plural form, and it should still read as keyed.
    m = re.search(r"^\s*key_prefix:\s*([A-Za-z0-9_-]+)", text, re.MULTILINE)
    if not m:
        m = re.search(r"^\s*key_prefixes:\s*\[\s*[\"']?([A-Za-z0-9_-]+)", text, re.MULTILINE) \
            or re.search(r"^\s*key_prefixes:\s*\n\s*-\s*[\"']?([A-Za-z0-9_-]+)", text, re.MULTILINE)
    out["key_prefix"] = m.group(1) if m else None
    for seam in ("tracker", "warehouse", "chat", "docstore", "vcs"):
        tools = seam_tools(text, seam)
        # A multi-target seam renders as "a+b" (default first) so no target is hidden.
        out[seam] = "+".join(tools) if tools else "—"
    return out


def viewer_tool(root: Path, stack_text: str) -> str | None:
    """The configured `viewer` tool, or None.

    Unlike every other seam this one is PER-USER: which app opens a .sql is a personal choice, so
    it lives in a gitignored file rather than the shared stack.yaml. Same first-hit-wins order
    bin/handoff.sh uses. Returns None when nothing is configured or the user set enabled: false,
    so the banner never advertises a gate that will not open anything.
    """
    # Preferred: the resolver's viewer plan, so the banner and bin/handoff.sh can never disagree
    # about which config is live — including the composed tier-2/tier-3 form, which a local regex
    # ladder cannot see at all.
    try:
        kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
        bindir = (Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent) / "bin"
        sys.path.insert(0, str(bindir))
        from effective_config import resolve, viewer_plan  # type: ignore
        plan = viewer_plan(resolve(root))
        if plan.get("source"):
            if not plan.get("enabled"):
                return None          # explicitly configured off: never advertise a gate
            return plan.get("tool") or "configured"
        return None
    except Exception:  # noqa: BLE001 — fall through to the standalone scan; a hook must fail open
        pass

    candidates = [
        root / ".claude/config/viewer.local.yaml",
        Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ticketwright/viewer.yaml",
    ]
    for path in candidates:
        try:
            if not path.is_file():
                continue
            text = path.read_text(errors="replace")
        except OSError:
            continue
        # Trailing `# comment` must not defeat the opt-out: handoff.sh reads this through yq, which
        # strips comments, so a stricter regex here would advertise a gate that opens nothing.
        if re.search(r"^\s*enabled:\s*(false|no|off|0)\s*(#.*)?$", text, re.MULTILINE | re.IGNORECASE):
            return None
        m = re.search(r"^\s*tool:\s*([A-Za-z0-9_.-]+)", text, re.MULTILINE)
        return m.group(1) if m else "configured"
    tools = seam_tools(stack_text, "viewer")   # layer 3: a team-wide block in stack.yaml
    return tools[0] if tools else None


def update_notice_line(root: Path) -> list[str]:
    """The "a newer release is available" line from bin/update_notice.py, or nothing.

    PRESENTATION ONLY — the decision (is a release pending, which versions, which command pair)
    lives in the harness-neutral CLI so every runtime can ask the same question. This hook is the
    Claude-Code way of showing the answer.

    FAILS OPEN, and the shape of the check is the point: the line is appended ONLY when the CLI
    exits cleanly having printed exactly one non-empty line. A timeout, a nonzero exit, an
    unreadable script, multi-line output or anything on stderr all yield NOTHING — the banner must
    be byte-identical to a run where this feature does not exist. (Do not read this as the house
    rule for every hook: db_write_guard deliberately fails SAFE, asking MORE when its scanner is
    unavailable. A notice and a guard degrade in opposite directions on purpose.)

    THE TIMEOUT IS A BUDGET, NOT A GUESS. This hook already resolves the config resolver, the viewer
    plan and the identity map from the kit before reaching here, so the child's share of the 10s
    SessionStart budget declared in plugin.json is not the whole 10s. 3s is several times what the
    CLI needs (it reads three small local files, no network) and leaves the parent room to finish;
    selftest section 51 pins the WHOLE hook under the 10s budget with the CLI deliberately hung.
    """
    try:
        kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
        bindir = (Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent) / "bin"
        script = bindir / "update_notice.py"
        if not script.is_file():
            return []
        proc = subprocess.run(
            [sys.executable or "python3", str(script), "--root", str(root)],
            capture_output=True, text=True, timeout=3,
        )
    except Exception:  # noqa: BLE001 — including TimeoutExpired; a hook must fail open
        return []
    if proc.returncode != 0 or proc.stderr:
        return []                       # ANY stderr, not just non-whitespace: a child that writes
                                        # a bare newline there is misbehaving, and a misbehaving
                                        # child does not get to put a line in the banner
    # Validate the RAW stdout, then strip — not the other way round. str.strip() removes U+2028 and
    # collapses a doubled trailing newline, so stripping FIRST would quietly admit output that was
    # never one line and call the gate exact. The only normalization allowed before the check is the
    # single trailing newline a well-behaved print() produces.
    raw = proc.stdout[:-1] if proc.stdout.endswith("\n") else proc.stdout
    if not raw.strip():
        return []                       # empty, or whitespace-only ("   " once slipped through)
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw):
        return []                       # a C0 control or DEL — CR could redraw the lines above
    if raw.splitlines() != [raw]:
        return []                       # U+2028/U+2029, \x0b, \x0c, U+0085 — none contain "\n",
                                        # and every one of them renders as a second line somewhere
    return [raw.strip()]


def whoami_lines(root: Path) -> list[str]:
    """The one-line identity display (plus the conflict warning), so a wrong resolution is caught
    the moment a session starts — before work lands in a colleague's folder.

    DISPLAY ONLY. This hook is never the resolver's write path and never asks a question — a
    command hook can print text, it cannot run an interactive interview. On a `miss` it stays
    silent: the ticket/ship workflows own the self-healing `whoami.py --bind` interview.
    """
    try:
        kit = os.environ.get("CLAUDE_PLUGIN_ROOT")
        bindir = (Path(kit).resolve() if kit else Path(__file__).resolve().parent.parent.parent) / "bin"
        sys.path.insert(0, str(bindir))
        import whoami  # type: ignore
        res = whoami.resolve(root)
    except Exception:  # noqa: BLE001 — a hook must fail open
        return []
    if res.get("status") in ("resolved", "conflict") and res.get("display"):
        out = [str(res["display"])]
        if res.get("warning"):
            out.append(str(res["warning"]))
        return out
    return []


def policy_advisory_lines(s: dict, mode: str) -> list[str]:
    """Per-policy advisory lines under the policy summary — today, one line about DB writes.

    An appender (returns a list) rather than string surgery, so a future always-print line (e.g. a
    meetings slot) slots in without touching main(). Honesty rules: the line prints only when a
    warehouse is configured AND the policy is on; the MCP clause appears only when some warehouse
    unit's resolved transport provably includes mcp (`warehouse_mcp is True`); False or unknown
    (None — including the regex fallback scan, which never sets the key) states the plain Bash
    jurisdiction and claims nothing about a path it cannot see. Fail-open string logic — any
    surprise yields no line, never a crash."""
    lines: list[str] = []
    try:
        if s.get("warehouse") in (None, "—") or mode == MODE_OFF:
            return lines
        if s.get("warehouse_mcp") is True:
            lines.append(f"DB writes: policy {mode} — Bash path hook-gated; MCP path advisory "
                         "(tool-side controls, posture recorded at setup).")
        else:
            lines.append(f"DB writes: policy {mode} — hook-gated (Bash jurisdiction).")
    except Exception:  # noqa: BLE001 — a hook must fail open
        return []
    return lines


def main() -> int:
    root = project_root()
    stack = root / ".claude/config/stack.yaml"
    if not stack.is_file():
        return 0  # not configured — say nothing

    try:
        s = scan_stack_resolved(root) or scan_stack(stack)
    except OSError:
        return 0

    skills = sorted(p.parent.name for p in (root / ".claude/skills").glob("*/SKILL.md")) \
        if (root / ".claude/skills").is_dir() else []
    commands = sorted(
        p.stem for p in (root / ".claude/commands").glob("*.md")
    ) if (root / ".claude/commands").is_dir() else []

    try:
        viewer = viewer_tool(root, stack.read_text(errors="replace"))
    except OSError:
        viewer = None
    viewer_note = f" · viewer={viewer}" if viewer else ""

    lines = [
        "## Ticketwright — session context",
        f"Stack ({s['key_prefix'] + '-tickets' if s['key_prefix'] else root.name}): "
        f"tracker={s['tracker']} · warehouse={s['warehouse']} · "
        f"chat={s['chat']} · docstore={s['docstore']} · vcs={s['vcs']}{viewer_note}.",
        "Lifecycle: /ticket (opens + auto-primes context) → /spec-and-build → /review → /ship.",
    ]
    lines[2:2] = whoami_lines(root)
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
    # Where the DB-write gate actually reaches, per transport — before the footer, appended from a
    # list that is empty whenever the line would not be true (no warehouse, policy off, failure).
    lines.extend(policy_advisory_lines(s, mode))
    # Last, so it reads as a footer rather than interrupting the stack summary — and appended from a
    # list that is empty on every failure, which is what keeps the rest byte-identical.
    lines.extend(update_notice_line(root))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
