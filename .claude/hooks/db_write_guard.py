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

Classification is default-deny. Only a narrow allowlist counts as additive (plain
CREATE, INSERT INTO, ALTER … ADD, COMMENT ON); everything else that mutates is
high-risk, *including anything the scanner does not recognize*. The inverse rule —
enumerating the dangerous forms — leaves holes: `ALTER TABLE … MODIFY COLUMN` can
change a type and truncate data while matching no "destructive" verb list.

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
path, including unexpected exceptions, returns 0.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _stack import MODE_HIGH_RISK, MODE_OFF, db_write_mode, find_stack  # noqa: E402

DEFAULT_WAREHOUSE_CLIS = ["snow", "snowsql", "bq", "databricks", "dbsqlcli", "psql",
                          "mysql", "sqlcmd", "duckdb", "redshift-data"]

# Tiers, ordered. Higher wins when a script mixes statements.
READ, ADDITIVE, HIGH = 0, 1, 2

READ_VERBS = {"select", "show", "describe", "desc", "explain", "list", "use", "get_ddl"}

_COMMENT = re.compile(r"^\s*#")
# `note: |`, `- note: |-`, `"note": >2`, … — a key whose value is a literal/folded block scalar.
_BLOCK_SCALAR = re.compile(
    r"""^\s*(?:-\s+)?(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.-]+):\s*[|>][-+0-9]*\s*(?:#.*)?$"""
)


# NOTE: this scanner is deliberately NOT replaced by bin/effective_config.py. See the long comment
# at the top of _stack.py — routing the guard through a subprocess resolver turns its failure mode
# from fail-safe into fail-open, and a resolver would parse config shapes this scanner intentionally
# refuses to guess about. Every other consumer in the kit was migrated; these two were not, on
# purpose.
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


# Statements that mutate but are safe to let through under `high_risk`. This list is
# exhaustive by design — anything not matched here is treated as high-risk.
_ADDITIVE_FORMS = (
    re.compile(r"^CREATE\s+(?!OR\s+REPLACE\b)", re.I),
    re.compile(r"^INSERT\s+(?!OVERWRITE\b)", re.I),
    re.compile(r"^ALTER\s+\w+\s+(?:IF\s+EXISTS\s+)?[\w.\"'`\[\]-]+\s+ADD\b", re.I),
    re.compile(r"^COMMENT\s+ON\b", re.I),
)

# Used only when no SQL could be extracted and we are grepping a raw shell command.
_HIGH_RISK_SEARCH = re.compile(
    r"\b(CREATE\s+OR\s+REPLACE|DROP|TRUNCATE|DELETE|UPDATE|MERGE|REPLACE\s+INTO"
    r"|INSERT\s+OVERWRITE|GRANT|REVOKE|CALL|EXECUTE\s+IMMEDIATE|EXECUTE\s+TASK"
    r"|COPY\s+INTO|PUT|REMOVE|UNSET)\b",
    re.I,
)
_ALTER_SEARCH = re.compile(r"\bALTER\b", re.I)
_ALTER_ADD_SEARCH = re.compile(r"\bALTER\s+\w+\s+[\w.\"'`\[\]-]+\s+ADD\b", re.I)
_ADDITIVE_SEARCH = re.compile(r"\b(CREATE|INSERT|COMMENT\s+ON)\b", re.I)

_QUERY_FLAG = re.compile(r"""(?:-q|--query)[=\s]+("([^"\\]|\\.)*"|'([^'\\]|\\.)*'|\S+)""")
_FILE_FLAG = re.compile(r"(?:-f|-i|--file|--filename|--input-file)[=\s]+([^\s;|&]+)")
_STDIN_REDIR = re.compile(r"<\s*([^\s;|&<>]+)")


_TARGET_HEADER = re.compile(r"^[ \t]*--[ \t]*warehouse-target:[ \t]*([A-Za-z0-9_.-]+)")


def leading_target(sql: str) -> str | None:
    """The target declared in a file's LEADING comment block, per the one-file-one-target contract.

    Only the run of `--` comment lines at the top of the file counts. Scanning the whole text would
    accept the marker from inside a `/* … */` block or a multi-line string literal, which is prose
    about a target, not a declaration of one.
    """
    for line in sql.splitlines():
        s = line.strip()
        if not s:
            continue
        if not s.startswith("--"):
            return None                     # first real SQL line ends the header block
        m = _TARGET_HEADER.match(line)
        if m:
            return m.group(1)
    return None


def referenced_targets(command: str, cwd: str) -> list[str]:
    """Targets declared by the leading header of each `.sql` file this command runs."""
    out = []
    for raw in _FILE_FLAG.findall(command) + _STDIN_REDIR.findall(command):
        p = Path(raw)
        if not p.is_absolute() and cwd:
            p = Path(cwd) / raw
        try:
            if p.is_file() and p.stat().st_size < 1_000_000:
                t = leading_target(p.read_text(errors="replace"))
                if t and t not in out:
                    out.append(t)
        except OSError:
            continue
    return out


def target_cli(stack: Path | None, target: str) -> str | None:
    """The CLI a named warehouse target would use — its own `cli:`, else the seam-level one.

    **Best effort, and deliberately biased toward silence.** Returns None whenever the target can't be
    resolved confidently — an unknown name, an empty `targets:`, or a form this stdlib scan doesn't
    read (a flow mapping for the whole `targets:` value, or a target defined via a YAML alias). None
    means "don't gate", so an exotic config loses this second net rather than gaining false prompts.

    That trade is deliberate: the authoritative wrong-warehouse check is the `/review` Should-fix
    finding, which reads the same header and needs no YAML parsing at all — and which is also the only
    half that works outside Claude Code, since hooks don't run under other agents. A missed catch here
    degrades to that. A *false* prompt would be worse than either, because prompts people learn to
    dismiss stop working.
    """
    if not stack:
        return None
    try:
        blk = seam_block(stack.read_text(errors="replace"), "warehouse")
    except OSError:
        return None
    if not blk:
        return None

    lines = [l for l in blk.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    if not lines:
        return None
    base = min(len(l) - len(l.lstrip()) for l in lines)

    def key_of(line):
        """The mapping key on a line, unquoted, or None."""
        m = re.match(r"""^\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_.-]+))\s*:(.*)$""", line)
        if not m:
            return None, ""
        return (m.group(1) or m.group(2) or m.group(3)), m.group(4)

    def unquote(v):
        v = v.strip().split("#")[0].strip()
        if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        return v or None

    def cli_in(rest):
        m = re.search(r"""[\s{,]cli\s*:\s*("[^"]*"|'[^']*'|[A-Za-z0-9_.-]+)""", " " + rest)
        return unquote(m.group(1)) if m else None

    # The seam's own `cli:` — only at the seam's own indent, never a nested one.
    seam_cli = None
    for ln in lines:
        if len(ln) - len(ln.lstrip()) != base:
            continue
        k, rest = key_of(ln)
        if k == "cli":
            seam_cli = unquote(rest)
            break

    # Locate `targets:` at the seam's indent, then consider ONLY its direct children. Matching the
    # target name anywhere in the block is wrong: `default: prod` is a *selector*, not a target, and a
    # nested `metadata.targets.lake` is not a warehouse target either.
    ti = next((i for i, ln in enumerate(lines)
               if len(ln) - len(ln.lstrip()) == base and key_of(ln)[0] == "targets"), None)
    if ti is None:
        return None                                  # single mapping: no named targets at all
    child = None
    for ln in lines[ti + 1:]:
        cur = len(ln) - len(ln.lstrip())
        if cur <= base:
            break                                     # left the targets: block
        if child is None:
            child = cur                                # the depth of a target name
        if cur != child:
            continue                                   # deeper: a key inside some target
        k, rest = key_of(ln)
        if k != target:
            continue
        stripped = rest.strip().split("#")[0].strip()
        if stripped.startswith("*"):
            return None            # `prod: *ref` — the alias may carry its own cli; don't guess one
        own = cli_in(rest)                             # flow form: prod: {tool: x, cli: y}
        if own:
            return own
        # Block form: only this target's OWN keys count, at one consistent depth. A `cli:` nested
        # deeper (say under an `opts:` sub-map) belongs to that sub-map, not to the target.
        own_depth = None
        for sub in lines[lines.index(ln) + 1:]:
            scur = len(sub) - len(sub.lstrip())
            if scur <= child:
                break
            if own_depth is None:
                own_depth = scur
            if scur != own_depth:
                continue
            sk, srest = key_of(sub)
            if sk == "cli":
                return unquote(srest) or seam_cli
        return seam_cli                                # target exists, inherits the seam's cli
    return None                                        # no such target


def invokes_warehouse(command: str, clis: list[str]) -> str | None:
    for cli in clis:
        # word-boundary match so "show" doesn't match inside another word
        if re.search(rf"(^|[\s;&|(]){re.escape(cli)}(\s|$)", command):
            return cli
    return None


def extract_inline_sql(command: str) -> str:
    """Every `-q`/`--query` payload on the line, not just the first.

    `.search()` here was a real hole: `snow sql -q "SELECT 1"` followed by a second
    `snow sql -q "DROP TABLE t"` classified on the SELECT alone and the DROP was never
    seen. Anything that can carry SQL has to be classified, or the tier is a guess.
    """
    out = []
    for match in _QUERY_FLAG.finditer(command):
        payload = match.group(1)
        if payload and payload[0] in "\"'" and payload[-1] == payload[0]:
            payload = payload[1:-1]
        out.append(payload)
    return "\n;\n".join(out)


def referenced_sql(command: str, cwd: str) -> tuple[str, bool]:
    """Text of SQL files run via -f/--filename or `< file`, and whether all were read.

    `complete=False` (unreadable or oversized) must never enable the allow fast-path:
    we cannot claim SQL is read-only when part of it was never seen.
    """
    text, complete = "", True
    for raw in _FILE_FLAG.findall(command) + _STDIN_REDIR.findall(command):
        path = Path(raw)
        if not path.is_absolute() and cwd:
            path = Path(cwd) / raw
        try:
            if path.is_file() and path.stat().st_size < 1_000_000:
                text += "\n" + path.read_text(errors="replace")
            else:
                complete = False
        except OSError:
            complete = False
    return text, complete


def strip_sql_noise(sql: str) -> str:
    """Remove block comments, line comments, and string literals.

    Without this a verb mentioned in a comment or quoted as data reads as a real
    statement — `SELECT 'DROP TABLE x'` is a read, and prompting on it is exactly the
    kind of false positive that makes a guard feel arbitrary.
    """
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"'(?:[^'\\]|\\.)*'", "''", sql)
    return sql


def classify_statement(stmt: str) -> int:
    """Tier a single SQL statement. Unrecognized ⇒ HIGH (default-deny)."""
    stmt = stmt.strip()
    if not stmt:
        return READ
    head = stmt.split(None, 1)[0].lower().strip('(')
    if head == "with":
        # A CTE is only a read if what it feeds is a read.
        rest = stmt[4:]
        return HIGH if re.search(r"\b(INSERT|UPDATE|DELETE|MERGE)\b", rest, re.I) else READ
    if head in READ_VERBS:
        return READ
    for form in _ADDITIVE_FORMS:
        if form.match(stmt):
            return ADDITIVE
    return HIGH


def classify_sql(sql: str) -> int:
    clean = strip_sql_noise(sql)
    tier = READ
    for stmt in clean.split(";"):
        if stmt.strip():
            tier = max(tier, classify_statement(stmt))
    return tier


def scan_command_tier(text: str) -> int:
    """Fallback for commands whose SQL we could not isolate (heredocs, odd flags).

    Verb *search*, not leading-verb classification: most of a shell command line is not
    SQL, so "unrecognized" here means "no evidence of a mutation", not "assume the worst".
    """
    if _HIGH_RISK_SEARCH.search(text):
        return HIGH
    if _ALTER_SEARCH.search(text) and not _ALTER_ADD_SEARCH.search(text):
        return HIGH
    if _ALTER_SEARCH.search(text) or _ADDITIVE_SEARCH.search(text):
        return ADDITIVE
    return READ


def is_simple_command(command: str) -> bool:
    """No shell operators outside quoted regions — safe to auto-allow as one unit.

    Single and double quotes are not equivalent: the shell still performs command
    substitution inside double quotes, so `-q "SELECT $(cmd)"` must not look simple.
    Drop single-quoted spans first (inert), scan what remains for substitution, then
    mask double-quoted spans and scan for the operators those do disarm.
    """
    no_sq = re.sub(r"'(?:[^'\\]|\\.)*'", "''", command)
    if re.search(r"\$\(|`|\$\{", no_sq):
        return False
    masked = re.sub(r'"(?:[^"\\]|\\.)*"', '""', no_sq)
    # Newlines separate commands exactly like `;` does. Omitting them meant
    # `snow sql -q "SELECT 1"\nrm -rf …` counted as one simple command and was
    # auto-approved — the guard handing out `allow` for an arbitrary second command.
    return not re.search(r"[;&|<>\n\r]", masked)


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

    # Every CLI in the warehouse seam — a multi-target seam declares one per target.
    cli = invokes_warehouse(command, warehouse_clis(stack))
    if not cli:
        return 0

    inline = extract_inline_sql(command)
    filed, files_complete = referenced_sql(command, cwd)
    sql = (inline + "\n" + filed).strip()

    if sql:
        tier = classify_sql(sql)
    else:
        tier = scan_command_tier(command)

    if policy == MODE_OFF:
        return 0

    # Wrong warehouse: right SQL, wrong target. Checked independently of the tier, because a
    # *read* against the wrong target is also wrong — it returns plausible numbers about a
    # different system rather than erroring — and it must pre-empt the read-only allow
    # fast-path below, which would otherwise auto-approve it. Placed after the MODE_OFF
    # short-circuit: `off` means this hook stays silent, and that is an explicit instruction.
    # Only a CONFIRMED mismatch gates; target_cli() returns None for anything it cannot
    # resolve confidently, so a single-warehouse repo or a typo'd name changes nothing.
    for named in referenced_targets(command, cwd):
        want = target_cli(stack, named)
        if want and want != cli:
            detail = (
                f"wrong warehouse: this command runs `{cli}`, but the SQL declares "
                f"`-- warehouse-target: {named}`, which uses `{want}`. Confirm the target "
                f"before running — a query against the wrong warehouse returns plausible "
                f"wrong numbers rather than an error."
            )
            if payload.get("permission_mode") == "bypassPermissions":
                emit(system_message=(
                    f"db_write_guard: SQL declares target `{named}` (`{want}`) but the "
                    f"command runs `{cli}`; approval not requested because the session is "
                    f"in bypassPermissions mode."
                ))
                return 0
            emit("ask", detail)
            return 0

    threshold = HIGH if policy == MODE_HIGH_RISK else ADDITIVE
    if tier >= threshold:
        label = "high-risk" if tier == HIGH else "additive"
        detail = (
            f"db_write_requires_approval={policy}: this `{cli}` command carries a "
            f"{label} statement. Show the exact SQL and target environment, explain what "
            f"it changes, and proceed only on explicit approval."
        )
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

    # Read-only fast-path. Deliberately narrow: a single simple command, every
    # referenced file actually read, and every statement classified as a read. Anything
    # short of that falls through to the normal permission flow rather than auto-approving.
    # The leading-CLI anchor matters on its own: `is_simple_command` is a lexical check, not
    # a proof, and it cannot see inside an interpreter. `sh -c "…"` / `eval "…"` carry their
    # payload in a quoted string the check masks before scanning, so without this anchor an
    # interpreter invocation that merely mentions a warehouse CLI could reach `allow`.
    starts_with_cli = re.match(rf"{re.escape(cli)}(\s|$)", command.strip()) is not None
    if tier == READ and sql and files_complete and starts_with_cli and is_simple_command(command):
        emit("allow", f"read-only SQL — auto-approved by db_write_guard ({cli}).")
    return 0


def main() -> int:
    try:
        return run()
    except Exception:  # noqa: BLE001 — a guard must never block a session
        return 0


if __name__ == "__main__":
    sys.exit(main())
