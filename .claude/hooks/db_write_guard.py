#!/usr/bin/env python3
"""PreToolUse hook — mechanical enforcement of the `db_write_requires_approval` policy.

The kit's policies are only as good as the agent's memory unless something enforces
them. This hook makes the DB-write rule mechanical: when a Bash tool call invokes the
configured warehouse CLI, the SQL is classified and — depending on the policy — the
human is asked to confirm before it runs.

The policy is a three-value enum in `.claude/config/stack.yaml`:

    policies:
      db_write_requires_approval: high_risk    # off | high_risk | all

  off        never ask; the hook stays silent
  high_risk  (default) ask only for irreversible / access-changing / unrecognized SQL
  all        ask for any mutation at all

Legacy booleans still parse: `true` → high_risk, `false` → off. A missing, malformed,
or unrecognized value falls back to `all`, never to a weaker setting — unparseable
config must not quietly widen what runs unprompted.

THE SCANNER LIVES IN bin/sql_scan.py (one deterministic implementation, shared with the
non-Claude runtime shims — see PROMPT 7 / U3); this file is the Claude-protocol presenter.
Classification is default-deny — see sql_scan.py for the tiers and the reasoning. Two
things deliberately did NOT move: the policy read (in-process via the sibling _stack.py,
where an unreadable value resolves to `all` — parse failure gates MORE), and this file's
protocol contract below. And one failure mode is new and deliberate: if bin/sql_scan.py
cannot be imported (a partial vendored copy, a corrupted file) — or imports fine but
CRASHES while classifying — this hook does NOT fall into the blanket fail-open handler:
it asks on every Bash command in the configured repo, naming the broken module, until
the kit is repaired. Nothing can be classified
without the scanner, so everything is treated as unclassified — gating MORE, never less,
and visibly rather than silently. (`policies: off` still silences it: that is an explicit
operator instruction, readable without the scanner.)

Permission modes: the payload carries `permission_mode`, and this hook special-cases
exactly one value. Under `bypassPermissions` the operator has explicitly opted out of
prompting, so returning `ask` there is incoherent; the hook stays silent and emits a
`systemMessage` instead, so the suppression is visible rather than invisible. Every
other mode gets a normal `ask` and Claude Code applies that mode's own semantics —
notably `dontAsk`, where `ask` becomes a denial. Suppressing there would turn an
allow-listed CLI into an unguarded destructive channel, which inverts what someone
selecting that mode wants.

Repo-gated: with no project `stack.yaml`, the hook produces no output at all. There is
deliberately no fallback to the kit's own shipped config — that fallback is how a
globally enabled plugin ends up enforcing the worked example's policy in unrelated repos.

Input  (stdin): PreToolUse JSON { tool_name, tool_input:{command}, cwd, permission_mode }
Output (stdout): a permissionDecision and/or systemMessage; otherwise nothing.
Stdlib only. Always exits 0 — a nonzero PreToolUse exit *blocks* the call, so every
path, including unexpected exceptions, returns 0. tests/guard/golden.json pins this
protocol byte-for-byte; selftest section 43 replays it.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _stack import MODE_OFF, db_write_mode, find_stack  # noqa: E402

# The scanner sits in the kit's bin/, a sibling of this hook's .claude/hooks/ in every install
# shape (repo, plugin cache, `ticketwright init` vendor, wheel _kit). The import is guarded, and
# the failure is handled EXPLICITLY at the top of run() — never left to the blanket handler in
# main(), which would silently gate NOTHING (see the module docstring).
try:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))
    import sql_scan as _sql_scan
    _SCAN_IMPORT_ERROR: Exception | None = None
except Exception as _e:  # noqa: BLE001 — any import failure maps to gating MORE, below
    _sql_scan, _SCAN_IMPORT_ERROR = None, _e


def emit(decision: str | None = None, reason: str = "", system_message: str = "") -> None:
    out: dict[str, object] = {}
    if decision:
        out["hookSpecificOutput"] = {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    if system_message:
        # Top-level: systemMessage is a common hook-output field, not a PreToolUse one.
        out["systemMessage"] = system_message
    if out:
        print(json.dumps(out))


def run() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # not invoked as a hook / no payload

    if payload.get("tool_name") != "Bash":
        return 0
    command = ((payload.get("tool_input") or {}).get("command", "") or "").strip()
    if not command:
        return 0

    cwd = payload.get("cwd", "") or ""
    stack = find_stack(cwd)
    if stack is None:
        return 0  # not a configured ticketwright repo — stay out of the way entirely

    policy = db_write_mode(stack)

    def scanner_down(problem: str) -> int:
        # FAIL-SAFE, not fail-open: without a working scanner nothing can be classified, so
        # every command in this configured repo is treated as unclassified and gated — more,
        # never less — and the malfunction is named instead of swallowed. `off` stays silent:
        # that is an explicit operator instruction, readable without the scanner.
        if policy == MODE_OFF:
            return 0
        if payload.get("permission_mode") == "bypassPermissions":
            emit(system_message=(
                f"db_write_guard: the SQL scanner (bin/sql_scan.py) {problem}, so commands "
                f"cannot be classified; approval not requested because the session is in "
                f"bypassPermissions mode. Restore the kit's bin/ directory."
            ))
            return 0
        emit("ask", (
            f"db_write_guard: the SQL scanner (bin/sql_scan.py, in this kit's bin/ directory) "
            f"{problem}. Nothing can be classified, so every command is treated as "
            f"unclassified and gated — more, never less. Restore or reinstall the kit's bin/ "
            f"directory to clear this."
        ))
        return 0

    if _sql_scan is None:
        return scanner_down(f"could not be loaded ({_SCAN_IMPORT_ERROR})")

    # The local fail-safe boundary covers the verdict's CONSUMPTION, not just the call: a scanner
    # that CRASHES and a scanner that returns a MALFORMED verdict ({}, None, a gate with no
    # detail) must both land in scanner_down's visible ask — never in main()'s blanket "never
    # block a session" handler, which would gate NOTHING, silently (gate-2 + adversarial-review
    # findings). Everything the presenters below need is extracted and type-checked HERE, so the
    # emit branches consume only validated plain strings.
    try:
        decision = _sql_scan.assess(command, cwd, stack, policy)
        kind = decision["kind"]
        named = want = cli = label = detail = ""
        if kind == "wrong_target":
            named, want, cli, detail = (decision["named"], decision["want"],
                                        decision["cli"], decision["detail"])
        elif kind == "gate":
            label, cli, detail = decision["label"], decision["cli"], decision["detail"]
        elif kind == "allow_fastpath":
            detail = decision["detail"]
        elif kind not in ("silent", "none"):
            raise ValueError(f"unknown decision kind {kind!r}")
        for field in (named, want, cli, label, detail):
            if not isinstance(field, str):
                raise TypeError(f"non-string field in a {kind!r} decision")
    except Exception as e:  # noqa: BLE001 — a scanner that misbehaves must gate, not fall through
        return scanner_down(f"failed while classifying ({e.__class__.__name__}: {e})")

    if kind == "wrong_target":
        if payload.get("permission_mode") == "bypassPermissions":
            emit(system_message=(
                f"db_write_guard: SQL declares target `{named}` "
                f"(`{want}`) but the command runs `{cli}`; approval "
                f"not requested because the session is in bypassPermissions mode."
            ))
            return 0
        emit("ask", detail)
        return 0

    if kind == "gate":
        if payload.get("permission_mode") == "bypassPermissions":
            # The operator turned prompting off for the session; asking would contradict
            # that. Say only that we did not request approval — other hooks or deny rules
            # may still intervene, so we cannot claim the command will run.
            emit(system_message=(
                f"db_write_guard: {label} warehouse statement detected "
                f"({cli}); approval not requested because the session is in "
                f"bypassPermissions mode."
            ))
            return 0
        emit("ask", detail)
        return 0

    if kind == "allow_fastpath":
        emit("allow", detail)
    return 0  # kinds "silent" and "none": nothing to say


def main() -> int:
    try:
        return run()
    except Exception:  # noqa: BLE001 — a guard must never block a session
        return 0


if __name__ == "__main__":
    sys.exit(main())
