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


_COMMENT = re.compile(r"^\s*#")
# `note: |`, `- note: |-`, `"note": >2`, … — a key whose value is a literal/folded block scalar.
_BLOCK_SCALAR = re.compile(
    r"""^\s*(?:-\s+)?(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.-]+):\s*[|>][-+0-9]*\s*(?:#.*)?$"""
)


def seam_block(text: str, seam: str) -> str:
    """The lines under `<seam>:` inside the top-level `seams:` mapping.

    Three properties matter, all of them about never *narrowing* what gets gated:

    * The seam-key indent is **inferred** from the file, not assumed to be two spaces — a
      four-space-indented stack.yaml is valid YAML that `yq` reads fine.
    * Comment-only lines carry no indentation and never terminate the scan, so a comment
      between `seams:` and the first seam can't hide it.
    * A config with no `seams:` anchor (malformed or partial) is scanned whole rather than
      skipped. Gating too much only costs a confirmation prompt; gating too little is a
      destructive statement running unreviewed.

    Block-scalar bodies are skipped so prose can't be read as configuration. No yaml dep — this
    hook has to stay a standalone stdlib script.
    """
    # A mapping key may carry a YAML anchor/alias/tag before its nested block (`warehouse: &wh`),
    # which yq resolves fine — so the key patterns tolerate one.
    prop = r"(?:[&*!][^\s#]*\s*)?"
    lines = text.splitlines()
    start = next((i for i, ln in enumerate(lines)
                  if re.match(rf"^seams:\s*{prop}(?:#.*)?$", ln)), None)
    if start is None:
        body, min_indent = lines, 0          # no anchor: a bare `warehouse:` may sit at column 0
    else:
        body, min_indent = lines[start + 1:], 1

    indent = depth = skip_deeper_than = None
    out = []
    for ln in body:
        if not ln.strip() or _COMMENT.match(ln):
            if depth is not None and ln.strip() == "":
                out.append(ln)
            continue                              # comments define neither indent nor an end
        cur = len(ln) - len(ln.lstrip())
        if cur < min_indent:
            break                                 # dedented out of `seams:`
        if skip_deeper_than is not None:
            if cur > skip_deeper_than:
                continue                          # still inside a block scalar
            skip_deeper_than = None
        if depth is None:
            if indent is None:
                indent = cur                      # the first real child sets the seam-key column
            if cur == indent:
                km = re.match(rf"^\s*{re.escape(seam)}:\s*(.*)$", ln)
                if km:
                    rest = re.sub(r"^[&*!][^\s#]*\s*", "", km.group(1).strip())
                    rest = re.sub(r"\s*#.*$", "", rest).strip()
                    if rest.startswith("{"):
                        return rest               # inline flow mapping — the seam is all on this line
                    if rest == "":
                        depth = cur               # normal nested block
                    # any other inline scalar (`warehouse: null`) opens nothing
            continue
        if cur <= depth:
            break                                 # next seam at the same level
        if _BLOCK_SCALAR.match(ln):
            skip_deeper_than = cur
            continue
        out.append(ln)
    return "\n".join(out)


def warehouse_clis(stack: Path | None) -> list[str]:
    """Defaults + every `cli:` declared inside the warehouse seam.

    Scoped to the seam block for two reasons. A multi-target seam declares one `cli:` per target,
    so all of them must be gated. And the previous `DOTALL` scan was unanchored: on a warehouse
    seam with no `cli:` of its own (only Snowflake requires one) that was listed *before* the
    tracker, it captured the tracker's CLI — making `<tracker-cli> ... create ...` trip the
    destructive-statement check and prompt for approval on a plain ticket edit.
    """
    clis = list(DEFAULT_WAREHOUSE_CLIS)
    if stack:
        try:
            blk = seam_block(stack.read_text(errors="replace"), "warehouse")
            # Unanchored within the block (which is already scoped to the seam) so a flow mapping
            # — `prod: {tool: trino, cli: trino}` — is read too, not just one-key-per-line style.
            for c in re.findall(r"(?:^|[\s{,])cli:\s*([A-Za-z0-9_.-]+)", blk, re.MULTILINE):
                if c not in clis:
                    clis.insert(0, c)
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
