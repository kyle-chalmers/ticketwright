#!/usr/bin/env python3
"""PreToolUse hook — mechanical enforcement of the `db_write_requires_approval` policy.

The starter kit's policies are only as good as the agent's memory unless something
enforces them. This hook makes the DB-write rule mechanical: when a Bash tool call
invokes a configured warehouse CLI with a *destructive* statement (CREATE/ALTER/DROP/
DELETE/UPDATE/INSERT/TRUNCATE/MERGE/GRANT/REVOKE/REPLACE), it returns an `ask`
permission decision so the human must confirm — exactly the "show SQL → explain →
wait for yes" protocol, applied by the runtime rather than trusted to the model.

Read-only statements (SELECT/DESCRIBE/SHOW/EXPLAIN/WITH/LIST/GET_DDL) pass straight
through. Non-warehouse Bash and non-Bash tools pass through untouched.

Wire it in settings.json:
  "hooks": { "PreToolUse": [ { "matcher": "Bash",
    "hooks": [ { "type": "command", "command": "python3 .claude/hooks/db_write_guard.py" } ] } ] }

Input  (stdin): Claude Code PreToolUse JSON { tool_name, tool_input:{command}, cwd, ... }
Output (stdout): on a destructive write, the permissionDecision JSON below; otherwise nothing.
Stdlib only. Always exits 0 — a guard must never crash a session (fail-open, but it
only ever *adds* a confirmation, never bypasses one).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

# CLIs that talk to a data warehouse / database. Extended from stack.yaml if present.
DEFAULT_WAREHOUSE_CLIS = ["snow", "snowsql", "bq", "databricks", "dbsqlcli", "psql", "mysql", "sqlcmd", "duckdb", "redshift-data"]

DESTRUCTIVE = re.compile(
    r"\b(CREATE\s+OR\s+REPLACE|CREATE|ALTER|DROP|DELETE|UPDATE|INSERT|TRUNCATE|MERGE|GRANT|REVOKE|REPLACE\s+INTO)\b",
    re.IGNORECASE,
)


def find_stack_yaml(cwd: str) -> Path | None:
    candidates = []
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        candidates.append(Path(os.environ["CLAUDE_PROJECT_DIR"]) / ".claude/config/stack.yaml")
    if cwd:
        candidates.append(Path(cwd) / ".claude/config/stack.yaml")
    # hook lives at <kit>/.claude/hooks/ → config is a sibling
    candidates.append(Path(__file__).resolve().parent.parent / "config/stack.yaml")
    for c in candidates:
        if c.is_file():
            return c
    return None


def warehouse_clis(stack: Path | None) -> list[str]:
    clis = list(DEFAULT_WAREHOUSE_CLIS)
    if stack:
        try:
            text = stack.read_text(errors="replace")
            # tiny scan: a `cli: <name>` line under the warehouse seam (no yaml dep)
            m = re.search(r"warehouse:.*?(?:\n\s+cli:\s*([A-Za-z0-9_-]+))", text, re.DOTALL)
            if m and m.group(1) not in clis:
                clis.insert(0, m.group(1))
        except OSError:
            pass
    return clis


def invokes_warehouse(command: str, clis: list[str]) -> str | None:
    for cli in clis:
        # word-boundary match so "show" doesn't match inside another word
        if re.search(rf"(^|[\s;&|(]){re.escape(cli)}(\s|$)", command):
            return cli
    return None


# SQL can live in a file rather than the command line — via -f/--file/--filename, OR via a shell
# stdin redirect (`psql db < deploy.sql`). Scan both so a destructive statement can't slip past.
_FILE_FLAG = re.compile(r"(?:-f|-i|--file|--filename|--input-file)[=\s]+([^\s;|&]+)")
_STDIN_REDIR = re.compile(r"<\s*([^\s;|&<>]+)")


def referenced_sql(command: str, cwd: str) -> str:
    """Concatenate the text of any SQL files the command runs via -f/--filename or `< file`, so the
    destructive scan sees `snow sql -f deploy.sql` / `psql < deploy.sql` content too. Size-capped."""
    text = ""
    for raw in _FILE_FLAG.findall(command) + _STDIN_REDIR.findall(command):
        p = Path(raw)
        if not p.is_absolute() and cwd:
            p = Path(cwd) / raw
        try:
            if p.is_file() and p.stat().st_size < 1_000_000:
                text += "\n" + p.read_text(errors="replace")
        except OSError:
            continue
    return text


def emit_ask(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # not invoked as a hook / no payload — do nothing

    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command", "") or ""
    if not command.strip():
        return 0

    stack = find_stack_yaml(payload.get("cwd", ""))
    clis = warehouse_clis(stack)

    cli = invokes_warehouse(command, clis)
    if not cli:
        return 0  # not a warehouse command

    # Scan the inline command AND any SQL files it runs via -f/--filename.
    scan_text = command + referenced_sql(command, payload.get("cwd", ""))

    verb_match = DESTRUCTIVE.search(scan_text)
    if not verb_match:
        return 0  # read-only / non-destructive — let it through

    verb = verb_match.group(1).upper()
    reason = (
        f"db_write_requires_approval: this `{cli}` command contains a destructive statement "
        f"({verb}). Per the kit's policy, confirm the exact SQL and target environment before "
        f"running — show what it changes and proceed only on explicit approval."
    )
    emit_ask(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
