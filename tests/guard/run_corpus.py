#!/usr/bin/env python3
"""Golden stdin→stdout corpus for the DB-write guard's Claude protocol.

This is the behavior-identity contract for the sql_scan extraction (PROMPT 7 / U3): the corpus
was GENERATED from the pre-extraction .claude/hooks/db_write_guard.py, committed as golden.json,
and every later revision of the hook must reproduce it byte-for-byte — same stdout, same exit
code, on the same fixture repos. A deliberate behavior change regenerates the golden file in the
same commit and says why; an accidental one turns the suite red.

Modes:
  --check              replay every case against the hook and diff stdout+exit (default)
  --generate           (re)write golden.json from the current hook — deliberate changes only
  --agreement          also replay each case's command through bin/sql_scan.py and assert the
                       scanner's decision kind agrees with the hook's emitted decision
  --hook <path>        hook to exercise (default: <repo>/.claude/hooks/db_write_guard.py)

Repo-only test material (tests/ ships in neither the wheel nor the plugin). Stdlib only.
Every case runs in its own mktemp fixture repo with CLAUDE_PROJECT_DIR scrubbed; commands
reference files RELATIVE to the fixture repo (the hook resolves them against the payload's cwd),
so golden stdout is path-free and byte-stable across machines.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GOLDEN = Path(__file__).resolve().parent / "golden.json"

STACK_STD = (
    "seams:\n"
    "  warehouse:\n"
    "    tool: snowflake\n"
    "    cli: snow\n"
    "  vcs:\n"
    "    tool: github\n"
    "    cli: gh\n"
    "policies:\n"
    "  db_write_requires_approval: {policy}\n"
)
STACK_NOPOLICY = (
    "seams:\n"
    "  warehouse:\n"
    "    tool: snowflake\n"
    "    cli: snow\n"
    "policies:\n"
    "  chat_default_draft: true\n"
)
STACK_INDENT4 = (
    "seams:\n"
    "    warehouse:\n"
    "        tool: custom\n"
    "        cli: whcli\n"
)
STACK_MULTI = (
    "seams:\n"
    "  warehouse:\n"
    "    default: prod\n"
    "    targets:\n"
    "      prod:\n"
    "        tool: snowflake\n"
    "        cli: snow\n"
    "      lake:\n"
    "        tool: trino\n"
    "        cli: trino\n"
    "policies:\n"
    "  db_write_requires_approval: high_risk\n"
)

# Each case: name, stack (None = unconfigured repo), files {relpath: content}, command,
# and optionally permission_mode / tool_name / raw_stdin (overrides the payload entirely).
CASES = [
    # --- the gate-2 triad: destructive, read-only, hidden-in-file --------------------------------
    {"name": "read_inline_allow", "policy": "high_risk",
     "command": 'snow sql -q "SELECT * FROM t LIMIT 5"'},
    {"name": "update_inline_ask", "policy": "high_risk",
     "command": 'snow sql -q "UPDATE t SET x=1"'},
    {"name": "drop_inline_ask", "policy": "high_risk",
     "command": 'snow sql -q "DROP TABLE t"'},
    {"name": "file_create_or_replace_ask", "policy": "high_risk",
     "files": {"deploy.sql": "CREATE OR REPLACE TABLE foo AS SELECT 1;\n"},
     "command": "snow sql -f deploy.sql"},
    {"name": "file_read_only_allow", "policy": "high_risk",
     "files": {"qc.sql": "SELECT count(*) FROM t;\n"},
     "command": "snow sql -f qc.sql"},
    {"name": "stdin_redirect_delete_ask", "policy": "high_risk",
     "files": {"wipe.sql": "DELETE FROM t WHERE 1=1;\n"},
     "command": "psql mydb < wipe.sql"},
    # --- tiers and the policy enum, legacy aliases included --------------------------------------
    {"name": "additive_create_passes", "policy": "high_risk",
     "command": 'snow sql -q "CREATE TABLE t (a int)"'},
    {"name": "all_gates_additive", "policy": "all",
     "command": 'snow sql -q "CREATE TABLE t (a int)"'},
    {"name": "off_drop_silent", "policy": "off",
     "command": 'snow sql -q "DROP TABLE t"'},
    {"name": "legacy_true_is_high_risk", "policy": "true",
     "command": 'snow sql -q "CREATE TABLE t (a int)"'},
    {"name": "legacy_false_is_off", "policy": "false",
     "command": 'snow sql -q "DROP TABLE t"'},
    {"name": "unknown_value_fails_safe", "policy": "wat",
     "command": 'snow sql -q "CREATE TABLE t (a int)"'},
    {"name": "absent_key_fails_safe", "stack": STACK_NOPOLICY,
     "command": 'snow sql -q "CREATE TABLE t (a int)"'},
    # --- permission modes -------------------------------------------------------------------------
    {"name": "bypass_drop_sysmsg", "policy": "high_risk", "permission_mode": "bypassPermissions",
     "command": 'snow sql -q "DROP TABLE t"'},
    {"name": "dontask_drop_still_asks", "policy": "high_risk", "permission_mode": "dontAsk",
     "command": 'snow sql -q "DROP TABLE t"'},
    # --- default-deny classification ---------------------------------------------------------------
    {"name": "alter_modify_ask", "policy": "high_risk",
     "command": 'snow sql -q "ALTER TABLE t MODIFY COLUMN c varchar(2)"'},
    {"name": "alter_add_passes", "policy": "high_risk",
     "command": 'snow sql -q "ALTER TABLE t ADD COLUMN c int"'},
    {"name": "insert_into_passes", "policy": "high_risk",
     "command": 'snow sql -q "INSERT INTO t VALUES (1)"'},
    {"name": "insert_overwrite_ask", "policy": "high_risk",
     "command": 'snow sql -q "INSERT OVERWRITE INTO t SELECT 1"'},
    {"name": "merge_ask", "policy": "high_risk",
     "command": 'snow sql -q "MERGE INTO t USING s ON t.i=s.i WHEN MATCHED THEN UPDATE SET t.v=s.v"'},
    {"name": "comment_on_passes", "policy": "high_risk",
     "command": 'snow sql -q "COMMENT ON TABLE t IS x"'},
    {"name": "grant_ask", "policy": "high_risk",
     "command": 'snow sql -q "GRANT SELECT ON t TO ROLE r"'},
    {"name": "unrecognized_verb_ask", "policy": "high_risk",
     "command": 'snow sql -q "VACUUM ANALYZE t"'},
    # --- noise that must not prompt ----------------------------------------------------------------
    {"name": "drop_in_comment_allow", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1 -- DROP TABLE x"'},
    {"name": "drop_in_string_allow", "policy": "high_risk",
     "command": "snow sql -q \"SELECT 'DROP TABLE x' AS s\""},
    {"name": "with_select_allow", "policy": "high_risk",
     "command": 'snow sql -q "WITH c AS (SELECT 1) SELECT * FROM c"'},
    {"name": "with_delete_ask", "policy": "high_risk",
     "command": 'snow sql -q "WITH c AS (SELECT 1) DELETE FROM t"'},
    {"name": "multi_statement_highest_tier", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1; DROP TABLE t"'},
    {"name": "tracker_cli_not_gated", "policy": "high_risk",
     "command": "gh pr create --title x"},
    {"name": "non_warehouse_silent", "policy": "high_risk", "command": "ls -la"},
    # --- the allow fast-path stays narrow ----------------------------------------------------------
    {"name": "shell_operator_defeats_fastpath", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1" && rm -rf ./nope'},
    {"name": "cmdsub_defeats_fastpath", "policy": "high_risk",
     "command": 'snow sql -q "SELECT $(whoami)"'},
    {"name": "unreadable_file_never_allowed", "policy": "high_risk",
     "command": "snow sql -f missing.sql"},
    {"name": "newline_chain_not_allowed", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1"\nrm -rf ./nope'},
    {"name": "newline_chain_drop_asks", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1"\nsnow sql -q "DROP TABLE t"'},
    {"name": "sh_c_wrap_not_allowed", "policy": "high_risk",
     "command": 'sh -c "snow sql -q \\"SELECT 1\\""'},
    {"name": "second_q_payload_classified", "policy": "high_risk",
     "command": 'snow sql -q "SELECT 1" -q "DROP TABLE t"'},
    # --- wrong-warehouse detection ------------------------------------------------------------------
    {"name": "wrong_target_mismatch_ask", "stack": STACK_MULTI,
     "files": {"q.sql": "-- warehouse-target: lake\nSELECT 1;\n"},
     "command": "snow sql -f q.sql"},
    {"name": "wrong_target_match_allow", "stack": STACK_MULTI,
     "files": {"ok.sql": "-- warehouse-target: prod\nSELECT 1;\n"},
     "command": "snow sql -f ok.sql"},
    {"name": "wrong_target_typo_no_gate", "stack": STACK_MULTI,
     "files": {"typo.sql": "-- warehouse-target: nosuch\nSELECT 1;\n"},
     "command": "snow sql -f typo.sql"},
    {"name": "wrong_target_bypass_sysmsg", "stack": STACK_MULTI,
     "permission_mode": "bypassPermissions",
     "files": {"q.sql": "-- warehouse-target: lake\nSELECT 1;\n"},
     "command": "snow sql -f q.sql"},
    {"name": "nondefault_target_cli_gated", "stack": STACK_MULTI,
     "command": 'trino --execute "UPDATE t SET x=1"'},
    # --- config shapes ------------------------------------------------------------------------------
    {"name": "indent4_custom_cli_gated", "stack": STACK_INDENT4,
     "command": 'whcli -e "DROP TABLE x"'},
    # --- protocol edges -----------------------------------------------------------------------------
    {"name": "malformed_stdin_exit0_silent", "policy": "high_risk", "raw_stdin": "not json at all"},
    {"name": "non_bash_tool_silent", "policy": "high_risk", "tool_name": "Read",
     "command": ""},
    {"name": "unconfigured_repo_silent", "stack": None,
     "command": 'snow sql -q "DROP TABLE t"'},
]


def build_fixture(case: dict, root: Path) -> None:
    (root / ".git").write_text("gitdir: fixture\n", encoding="utf-8")  # bounds _iter_up
    if "stack" in case:
        stack = case["stack"]
    else:
        stack = STACK_STD.format(policy=case.get("policy", "high_risk"))
    if stack is not None:
        cfg = root / ".claude" / "config"
        cfg.mkdir(parents=True)
        (cfg / "stack.yaml").write_text(stack, encoding="utf-8")
    for rel, content in (case.get("files") or {}).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")


def payload_for(case: dict, root: Path) -> str:
    if "raw_stdin" in case:
        return case["raw_stdin"]
    payload = {
        "tool_name": case.get("tool_name", "Bash"),
        "tool_input": {"command": case["command"]},
        "cwd": str(root),
    }
    if case.get("permission_mode"):
        payload["permission_mode"] = case["permission_mode"]
    return json.dumps(payload)


def run_case(case: dict, hook: Path) -> dict:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "repo"
        root.mkdir()
        build_fixture(case, root)
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_PROJECT_DIR"}
        proc = subprocess.run(
            [sys.executable, str(hook)],
            input=payload_for(case, root),
            capture_output=True, text=True, env=env, cwd=str(root),
        )
    return {"stdout": proc.stdout, "exit": proc.returncode}


def decision_of(stdout: str) -> str:
    """Collapse hook stdout to one token: allow | ask | sysmsg | none."""
    raw = stdout.strip()
    if not raw:
        return "none"
    d = json.loads(raw)
    h = d.get("hookSpecificOutput") or {}
    return h.get("permissionDecision") or ("sysmsg" if d.get("systemMessage") else "none")


def scanner_agreement(case: dict, hook_result: dict, scan_cli: Path) -> str | None:
    """Replay the case's command through bin/sql_scan.py; return a mismatch description or None.

    The scanner has no Claude protocol: it reports a decision KIND. The mapping the hook applies is
    kind->protocol: gate/wrong_target -> ask (sysmsg under bypassPermissions), allow_fastpath ->
    allow, silent/none -> no output. Non-command cases (malformed stdin, non-Bash) have no scanner
    verdict and are skipped.
    """
    if "raw_stdin" in case or case.get("tool_name", "Bash") != "Bash" or not case.get("command"):
        return None
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "repo"
        root.mkdir()
        build_fixture(case, root)
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_PROJECT_DIR"}
        proc = subprocess.run(
            [sys.executable, str(scan_cli), "--root", str(root)],
            input=json.dumps({"command": case["command"], "cwd": str(root)}),
            capture_output=True, text=True, env=env, cwd=str(root),
        )
    if proc.returncode != 0:
        return f"sql_scan exited {proc.returncode}: {proc.stderr.strip()[:200]}"
    try:
        kind = json.loads(proc.stdout)["kind"]
    except (ValueError, KeyError):
        return f"sql_scan printed no decision kind: {proc.stdout[:200]!r}"
    got = decision_of(hook_result["stdout"])
    want = {
        "gate": "sysmsg" if case.get("permission_mode") == "bypassPermissions" else "ask",
        "wrong_target": "sysmsg" if case.get("permission_mode") == "bypassPermissions" else "ask",
        "allow_fastpath": "allow",
        "none": "none",
        "silent": "none",
    }.get(kind)
    if want is None:
        return f"sql_scan reported an unknown kind {kind!r}"
    if got != want:
        return f"scanner kind {kind!r} implies hook decision {want!r}, but the hook said {got!r}"
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--generate", action="store_true")
    ap.add_argument("--agreement", action="store_true",
                    help="also assert bin/sql_scan.py verdicts agree with the hook's decisions")
    ap.add_argument("--hook", default=str(REPO / ".claude" / "hooks" / "db_write_guard.py"))
    args = ap.parse_args()
    # Resolve now: run_case executes the hook with cwd set to the fixture repo, where a relative
    # --hook path would no longer exist.
    hook = Path(args.hook).resolve()
    if not hook.is_file():
        print(f"run_corpus: no hook at {hook}", file=sys.stderr)
        return 2

    names = [c["name"] for c in CASES]
    if len(set(names)) != len(names):
        print("run_corpus: duplicate case names", file=sys.stderr)
        return 2

    results = {c["name"]: run_case(c, hook) for c in CASES}

    if args.generate:
        GOLDEN.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"run_corpus: wrote {len(results)} golden cases to {GOLDEN}")
        return 0

    try:
        golden = json.loads(GOLDEN.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"run_corpus: cannot read {GOLDEN}: {e}", file=sys.stderr)
        return 2

    failures = []
    for name, want in sorted(golden.items()):
        got = results.get(name)
        if got is None:
            failures.append(f"{name}: case missing from the corpus (golden has it)")
        elif got != want:
            failures.append(f"{name}: got {got!r}, golden {want!r}")
    for name in sorted(set(results) - set(golden)):
        failures.append(f"{name}: case has no golden entry (run --generate deliberately)")

    if args.agreement:
        scan_cli = REPO / "bin" / "sql_scan.py"
        if not scan_cli.is_file():
            failures.append("agreement: bin/sql_scan.py does not exist")
        else:
            for c in CASES:
                mismatch = scanner_agreement(c, results[c["name"]], scan_cli)
                if mismatch:
                    failures.append(f"{c['name']}: {mismatch}")

    if failures:
        print("run_corpus: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    extra = " + scanner agreement" if args.agreement else ""
    print(f"run_corpus: {len(golden)} golden cases byte-identical{extra}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
