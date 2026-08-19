"""Shared stack.yaml resolution + reading for the hooks. Stdlib only, no yaml dep.

The four hooks each grew their own root-resolution and their own mini-YAML scanner,
three mutually inconsistent ways. This module is the seam they should converge on;
`db_write_guard` uses it today, the others can migrate without behavior change.

Two properties matter more than convenience here:

1. **No kit-relative fallback.** Resolution stops at the project. A hook that falls
   back to the kit's own shipped `stack.yaml` silently activates outside a
   configured repo and reads the worked example's policy instead of the user's —
   which is exactly how a "repo-gated" guard ends up firing everywhere.
2. **Block-scoped lookups.** `_block_lines` walks indentation rather than pattern-matching
   across the whole document, so a key is read from the block that actually owns it.

DO NOT "FINISH THE MIGRATION" BY ROUTING THIS THROUGH bin/effective_config.py. Every other config
consumer in the kit now reads through that resolver; these two hooks deliberately do not, and the
reasons are safety reasons, not inertia:

1. **Fail-safe would become fail-open.** The policy is read IN-PROCESS here, and a missing or
   unparseable value resolves to `MODE_ALL` — a parse failure gates MORE. But `db_write_guard.main`
   wraps everything in `except Exception: return 0` ("a guard must never block a session"), against
   a 10s hook budget. Shell out to a resolver and a subprocess error, a timeout, or an unmapped exit
   code all land in that blanket handler and gate NOTHING — silently, because the hook never reports
   its own malfunction, and shipped to every repo at once by `autoUpdate`.
2. **It could only ever relax the guard.** `_block_lines` matches `^\s*policies:\s*$` only, so a
   FLOW-style `policies: {db_write_requires_approval: off}` is unreadable here and therefore fails
   CLOSED. A resolver reads flow mappings — the same file would resolve to `off` and disable the
   guard outright. The asymmetry runs one way, and it is the wrong way.
3. **There is nothing to gain.** `policies:` is un-mergeable at every tier and seam `cli:` is a
   reserved key, so the resolver would return byte-identical values. All risk, no benefit.
4. **A resolver would break a deliberate guardrail.** `db_write_guard.target_cli` is biased toward
   silence on config shapes it cannot read confidently, because a FALSE wrong-warehouse prompt is
   worse than a missed one. Some of those shapes (a flow-style `targets:` mapping) are valid YAML
   the resolver parses fine — so "resolver first, this scanner as a fallback" would not fall back at
   all, and would start emitting exactly the false prompts that design avoids.

selftest asserts the guard still yields `MODE_ALL` with `bin/effective_config.py` deleted and with
it stubbed to exit non-zero. If you change this, that test is what should stop you.

Seam blocks are *not* handled here — `db_write_guard.seam_block` already does that, with
harder-won handling for inferred indent, anchors, flow mappings, and block scalars. This
module covers the top-level `policies:` mapping only; duplicating a second seam parser
would just create two things to keep correct.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

STACK_REL = ".claude/config/stack.yaml"


def _iter_up(start: Path):
    """Yield `start` and its ancestors, stopping at (and including) the repo root.

    Bounded by `.git` so a subdirectory invocation still finds the project's config
    without escaping into a parent checkout that happens to have one.
    """
    try:
        cur = start.resolve()
    except OSError:
        return
    while True:
        yield cur
        if (cur / ".git").exists() or cur.parent == cur:
            return
        cur = cur.parent


def find_stack(cwd: str | None) -> Path | None:
    """Locate the *project's* stack.yaml, or None. None means "not a ticketwright repo"."""
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        candidate = Path(project_dir) / STACK_REL
        if candidate.is_file():
            return candidate
    if cwd:
        for directory in _iter_up(Path(cwd)):
            candidate = directory / STACK_REL
            if candidate.is_file():
                return candidate
    return None


def read_text(stack: Path | None) -> str:
    if stack is None:
        return ""
    try:
        return stack.read_text(errors="replace")
    except OSError:
        return ""


def _block_lines(text: str, key: str) -> list[str]:
    """Return the lines nested under `key:`, by indentation.

    Stops at the first non-blank, non-comment line indented at or below the key's own
    level — i.e. the next sibling. Blank and comment lines inside the block are kept
    so they never terminate it early.
    """
    base: int | None = None
    header = re.compile(rf"^(\s*){re.escape(key)}\s*:\s*(?:#.*)?$")
    out: list[str] = []
    for line in text.splitlines():
        if base is None:
            match = header.match(line)
            if match:
                base = len(match.group(1))
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            out.append(line)
            continue
        if len(line) - len(line.lstrip()) <= base:
            break
        out.append(line)
    return out


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    # Only strip a trailing comment from an unquoted scalar; a quoted one may contain '#'.
    return value.split("#", 1)[0].strip()


def _scalar(lines: list[str], key: str) -> str | None:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*:\s*(\S.*)$")
    for line in lines:
        match = pattern.match(line)
        if match:
            return _unquote(match.group(1))
    return None


# ---- the db_write_requires_approval policy -------------------------------------

MODE_OFF = "off"
MODE_HIGH_RISK = "high_risk"
MODE_ALL = "all"

POLICY_KEY = "db_write_requires_approval"

# Legacy `true` relaxes to high_risk (v3.4 behavior change). A missing, malformed, or
# unrecognized value does NOT — unparseable config must never widen what runs
# unprompted, so it falls back to `all`.
_ALIASES = {
    "off": MODE_OFF, "false": MODE_OFF, "no": MODE_OFF, "none": MODE_OFF, "null": MODE_OFF,
    "high_risk": MODE_HIGH_RISK, "high-risk": MODE_HIGH_RISK,
    "destructive": MODE_HIGH_RISK, "true": MODE_HIGH_RISK, "yes": MODE_HIGH_RISK,
    "all": MODE_ALL, "strict": MODE_ALL, "always": MODE_ALL,
}


def db_write_mode(stack: Path | None) -> str:
    text = read_text(stack)
    if not text:
        return MODE_ALL
    raw = _scalar(_block_lines(text, "policies"), POLICY_KEY)
    if raw is None:
        return MODE_ALL
    return _ALIASES.get(raw.strip().lower(), MODE_ALL)
