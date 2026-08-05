#!/usr/bin/env bash
# selftest.sh — the starter kit's own test suite (evals-as-first-class).
# Validates the foundation, skills, adapters, templates, and HOOKS so a reviewer (or CI) can
# trust the kit without manual poking. Read-only; no MFA/network. Exit non-zero on any failure.
#
# Run from anywhere:  bash bin/selftest.sh
set -uo pipefail

# cd to kit root (this script lives in <kit>/bin/)
cd "$(dirname "$0")/.." || exit 2
KIT="$(pwd)"
PASS=0; FAIL=0; TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
# `return 0` matters: bad() used to end on the `[ -n "$2" ]` test, so a one-arg call returned
# non-zero and any inverted check (`cond && bad ... || ok ...`) fired the `|| ok` too — printing a
# ✓ right under the ✗ and incrementing both counters. Several checks below are written that way.
bad()  { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; return 0; }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$1"; }

hdr "0 · tooling"
command -v yq  >/dev/null 2>&1 && ok "yq present" || bad "yq missing (brew install yq)"
command -v python3 >/dev/null 2>&1 && ok "python3 present" || bad "python3 missing"

hdr "1 · config parses + every seam resolves to an adapter (kit example stacks)"
for s in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
  if yq -e '.seams|keys' "$s" >/dev/null 2>&1; then ok "parses: $s"; else bad "parse error: $s"; fi
  out="$(bash bin/verify_stack.sh "$s" --dry-run 2>&1)"
  if grep -q "All seams OK" <<<"$out" && ! grep -q "adapter missing" <<<"$out"; then
    ok "kit example stack resolves: $s"
  else bad "seam resolution failed: $s" "$(grep -E 'missing|UNREACHABLE' <<<"$out" | head -2)"; fi
done

hdr "2 · adapter verb coverage matches the contract"
verbs_expected() {  # bash 3.2-safe (no associative arrays)
  case "$1" in
    tracker) echo 6;; warehouse) echo 3;; chat) echo 4;; docstore) echo 2;; vcs) echo 4;; *) echo 0;;
  esac
}
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  seam="$(basename "$(dirname "$f")")"; want="$(verbs_expected "$seam")"
  got="$(grep -c '^## verb:' "$f")"
  [ "$got" -eq "$want" ] && ok "$f ($got/$want verbs)" || bad "$f has $got verbs, expected $want"
done

hdr "3 · no tool names leak into skill/command orchestration"
# Two intentional matches are allowed: the CLI *detector* and the self-test *instruction* line.
leaks="$(grep -REn -i 'acli|\bsnow \b|snow sql|mcp__slack|slack_send|\bgh pr\b|\bgh auth\b|ACCOUNT_USAGE|SHOW VIEWS' \
          .claude/skills .claude/commands 2>/dev/null \
          | grep -v 'for c in snow acli gh' \
          | grep -v 'grep -REn "acli|snow ' || true)"
[ -z "$leaks" ] && ok "skills/commands are tool-neutral" || bad "tool name leaked into a skill" "$leaks"
# A warehouse-specific *config key* is the same leak wearing a different hat: `dev_db` is Snowflake's
# spelling, and naming it in a skill silently breaks that skill on BigQuery/Databricks/Postgres.
# The tool-neutral reference is `dev_target` (with the adapter's `dev_key:` as the legacy fallback).
devleaks="$(grep -REn 'dev_db|dev_dataset|dev_catalog|dev_schema' \
             .claude/skills .claude/commands .claude/agents 2>/dev/null || true)"
[ -z "$devleaks" ] && ok "no warehouse-specific dev key named in a skill/command/agent" \
  || bad "a skill names a tool-specific dev key (use the symbolic dev target)" "$devleaks"

hdr "4 · frontmatter valid (skills + agents)"
for f in .claude/skills/*/SKILL.md .claude/agents/*.md; do
  [ -f "$f" ] || continue
  if [ "$(head -1 "$f")" = "---" ] && grep -q '^name:' "$f" && grep -q '^description:' "$f"; then
    ok "frontmatter: $f"
  else bad "bad frontmatter: $f"; fi
done

hdr "5 · render.sh round-trip (AGENTS.md.tmpl → no unresolved tokens)"
cat > "$TMP/vars.env" <<'EOF'
repo_name=demo
domain=data
ticket_path=tickets/{assignee}/{id}
tracker_tool=jira
warehouse_tool=snowflake
chat_tool=slack
docstore_tool=gdrive
vcs_tool=github
key_prefix=ENG
terminal_status=Done
wl_tracker_comment=100
wl_chat=100
wl_pr=200
wl_ticket=200
chat_always_include=Alice
default_branch=main
role_focus=**You are a senior engineer** doing ticket-driven work (filled from templates/roles/<role>.md).
EOF
err="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$TMP/vars.env" 2>&1 >/dev/null)"
[ -z "$err" ] && ok "AGENTS.md renders with zero leftover tokens" || bad "unresolved tokens in AGENTS.md" "$err"
# zero KEY=VALUE pairs must not crash (bash 3.2 empty-array under set -u)
bash bin/render.sh templates/spec.md.tmpl >/dev/null 2>"$TMP/rz.err"; rc=$?
[ "$rc" -eq 0 ] && ok "render.sh with no vars doesn't crash (bash 3.2 empty array)" || bad "render.sh crashes with zero pairs" "$(cat "$TMP/rz.err")"

hdr "6 · db_write_guard hook (PreToolUse policy enforcement)"
# The guard is repo-gated: with no project stack.yaml it emits nothing at all. So every
# case runs against a fixture repo rather than a bare payload, which also lets the policy
# value vary per assertion. The fixture carries a `vcs.cli: gh` *after* the warehouse seam
# on purpose — a seam-scoped lookup must not adopt it as the warehouse CLI.
GREPO="$TMP/guardrepo"; mkdir -p "$GREPO/.claude/config"; : > "$GREPO/.git"
mkstack() {
  printf 'seams:\n  warehouse:\n    tool: snowflake\n    cli: snow\n  vcs:\n    tool: github\n    cli: gh\npolicies:\n  db_write_requires_approval: %s\n' "$1" > "$GREPO/.claude/config/stack.yaml"
}
mkstack_nopolicy() {
  printf 'seams:\n  warehouse:\n    tool: snowflake\n    cli: snow\npolicies:\n  chat_default_draft: true\n' > "$GREPO/.claude/config/stack.yaml"
}
guard() { env -u CLAUDE_PROJECT_DIR python3 .claude/hooks/db_write_guard.py; }
# Build the payload in python so SQL never has to survive nested shell quoting.
gcall() {
  python3 - "$GREPO" "$1" "${2:-}" <<'PY' | guard
import json, sys
cwd, cmd, mode = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}
if mode:
    payload["permission_mode"] = mode
print(json.dumps(payload))
PY
}
# Collapse the hook's stdout to one token: allow | ask | deny | sysmsg | none
dec() {
  python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("none"); raise SystemExit
d = json.loads(raw)
h = d.get("hookSpecificOutput") or {}
print(h.get("permissionDecision") or ("sysmsg" if d.get("systemMessage") else "none"))'
}
# expect <want> <label> <command> [permission_mode]
expect() {
  got="$(gcall "$3" "${4:-}" | dec)"
  [ "$got" = "$1" ] && ok "$2" || bad "$2 — got '$got', want '$1'"
}

mkstack high_risk
expect allow "SELECT → allow (read-only fast-path)"        'snow sql -q "SELECT * FROM t LIMIT 5"'
expect ask   "inline UPDATE → ask"                          'snow sql -q "UPDATE t SET x=1"'
expect none  "non-warehouse bash passes through"            'ls -la'
echo "CREATE OR REPLACE TABLE foo AS SELECT 1;" > "$TMP/deploy.sql"
expect ask   "-f deploy.sql (CREATE OR REPLACE) → ask"      "snow sql -f $TMP/deploy.sql"
echo "SELECT count(*) FROM t;" > "$TMP/qc.sql"
expect allow "-f qc.sql (SELECT only) → allow"              "snow sql -f $TMP/qc.sql"
echo "DELETE FROM t WHERE 1=1;" > "$TMP/wipe.sql"
expect ask   "psql < wipe.sql (stdin redirect) → ask"       "psql mydb < $TMP/wipe.sql"
# non-Bash tool → no decision
out="$(echo '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | guard)"
[ -z "$out" ] && ok "non-Bash tool passes through" || bad "non-Bash wrongly gated" "$out"
# malformed stdin must not crash: a nonzero PreToolUse exit would BLOCK the call
echo 'not json at all' | guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "malformed payload → exit 0 (fail-open)" || bad "malformed payload did not exit 0"
# repo gating: outside a configured repo the hook is entirely silent
out="$(echo '{"tool_name":"Bash","tool_input":{"command":"snow sql -q \"DROP TABLE t\""},"cwd":"/"}' | guard)"
[ -z "$out" ] && ok "no project stack.yaml → silent (repo-gated)" || bad "guard fired outside a configured repo" "$out"

hdr "6b · db_write_guard tiers, policy enum, and permission modes"
# --- the enum, including legacy values -------------------------------------------
mkstack high_risk
expect none  "high_risk: CREATE TABLE passes (the relaxation)"   'snow sql -q "CREATE TABLE t (a int)"'
expect ask   "high_risk: DROP asks"                              'snow sql -q "DROP TABLE t"'
mkstack all
expect ask   "all: CREATE TABLE asks"                            'snow sql -q "CREATE TABLE t (a int)"'
mkstack off
expect none  "off: DROP passes silently"                         'snow sql -q "DROP TABLE t"'
mkstack true
expect none  "legacy true → high_risk (CREATE passes)"           'snow sql -q "CREATE TABLE t (a int)"'
expect ask   "legacy true → high_risk (DROP asks)"               'snow sql -q "DROP TABLE t"'
mkstack false
expect none  "legacy false → off"                                'snow sql -q "DROP TABLE t"'
mkstack strict
expect ask   "strict → all"                                      'snow sql -q "CREATE TABLE t (a int)"'
mkstack destructive
expect none  "destructive → high_risk"                           'snow sql -q "CREATE TABLE t (a int)"'
# A value the parser cannot make sense of must never resolve to something weaker.
mkstack wat
expect ask   "unknown value → all (fails safe, not open)"        'snow sql -q "CREATE TABLE t (a int)"'
mkstack_nopolicy
expect ask   "policy key absent → all (fails safe)"              'snow sql -q "CREATE TABLE t (a int)"'

# --- permission modes ------------------------------------------------------------
mkstack high_risk
for m in default plan acceptEdits auto dontAsk; do
  expect ask "permission_mode=$m: DROP still asks" 'snow sql -q "DROP TABLE t"' "$m"
done
expect sysmsg "bypassPermissions: DROP → systemMessage, no prompt" 'snow sql -q "DROP TABLE t"' bypassPermissions

# --- classification is default-deny ----------------------------------------------
# The inverse rule (enumerate the dangerous forms) let ALTER … MODIFY / SET slip through
# as "not destructive"; MODIFY COLUMN can change a type and truncate data.
expect ask  "ALTER … MODIFY COLUMN → high-risk"        'snow sql -q "ALTER TABLE t MODIFY COLUMN c varchar(2)"'
expect ask  "ALTER … SET → high-risk"                  'snow sql -q "ALTER TABLE t SET COMMENT = x"'
expect none "ALTER … ADD COLUMN is additive"           'snow sql -q "ALTER TABLE t ADD COLUMN c int"'
expect ask  "CREATE OR REPLACE VIEW → high-risk"       'snow sql -q "CREATE OR REPLACE VIEW v AS SELECT 1"'
expect ask  "CREATE OR REPLACE TABLE → high-risk"      'snow sql -q "CREATE OR REPLACE TABLE t AS SELECT 1"'
expect none "INSERT INTO is additive"                  'snow sql -q "INSERT INTO t VALUES (1)"'
expect ask  "INSERT OVERWRITE → high-risk"             'snow sql -q "INSERT OVERWRITE INTO t SELECT 1"'
expect none "COMMENT ON is additive"                   'snow sql -q "COMMENT ON TABLE t IS x"'
expect ask  "MERGE → high-risk"                        'snow sql -q "MERGE INTO t USING s ON t.i=s.i WHEN MATCHED THEN UPDATE SET t.v=s.v"'
expect ask  "GRANT → high-risk (access control)"       'snow sql -q "GRANT SELECT ON t TO ROLE r"'
expect ask  "TRUNCATE → high-risk"                     'snow sql -q "TRUNCATE TABLE t"'
expect ask  "EXECUTE IMMEDIATE (dynamic SQL) → high-risk" 'snow sql -q "EXECUTE IMMEDIATE $$ SELECT 1 $$"'
expect ask  "unrecognized verb → high-risk (default-deny)" 'snow sql -q "VACUUM ANALYZE t"'

# --- noise that should NOT prompt -------------------------------------------------
expect allow "DROP inside a line comment is not a statement"  'snow sql -q "SELECT 1 -- DROP TABLE x"'
expect allow "DROP inside a string literal is data"           "snow sql -q \"SELECT 'DROP TABLE x' AS s\""
expect allow "WITH … SELECT is a read"                        'snow sql -q "WITH c AS (SELECT 1) SELECT * FROM c"'
expect ask   "WITH … DELETE is not"                           'snow sql -q "WITH c AS (SELECT 1) DELETE FROM t"'
expect ask   "multi-statement reports the highest tier"       'snow sql -q "SELECT 1; DROP TABLE t"'
# Seam-scoped cli lookup: the fixture's `vcs.cli: gh` must not become a warehouse CLI,
# or `gh pr create` matches CREATE and prompts.
expect none  "gh pr create is not a warehouse command"        'gh pr create --title x'

# --- the allow fast-path stays narrow --------------------------------------------
expect none "shell operator defeats the allow fast-path"      'snow sql -q "SELECT 1" && rm -rf /tmp/nope'
expect none "command substitution defeats the fast-path"      'snow sql -q "SELECT $(whoami)"'
expect none "unreadable -f file is never auto-allowed"        'snow sql -f /nonexistent/missing.sql'

# --- command-injection regressions (all of these once returned `allow`) -----------
# A newline separates commands exactly like `;`. While the operator scan omitted \n, a
# read-only query with a second command on the next line was auto-approved — the guard
# handing out `allow` for arbitrary follow-on commands, including a DROP.
expect none "newline-chained second command is not auto-allowed" 'snow sql -q "SELECT 1"
rm -rf /tmp/nope'
expect ask  "newline-chained DROP is classified and asks"        'snow sql -q "SELECT 1"
snow sql -q "DROP TABLE t"'
expect none "carriage return is treated as a separator too"      'snow sql -q "SELECT 1"'$'\r''rm -rf /tmp/nope'
# `is_simple_command` masks quoted spans before scanning, so it cannot see inside an
# interpreter. The leading-CLI anchor is what keeps these off the fast-path.
expect none "sh -c wrapping the CLI is not auto-allowed"         'sh -c "snow sql -q \"SELECT 1\""'
expect none "eval wrapping the CLI is not auto-allowed"          'eval "snow sql -q \"SELECT 1\""'
# Extraction reads every -q payload; `.search()` saw only the first and missed the rest.
expect ask  "a second -q payload is classified, not ignored"     'snow sql -q "SELECT 1" -q "DROP TABLE t"'

# --- warehouse-seam CLI harvest: scoped to the seam, indent-agnostic ---------------------------
# The `cli:` scan must read the warehouse seam and nothing else. Each case builds a throwaway
# project whose cwd the hook resolves stack.yaml from.
gstack() {  # gstack <name> <<'YAML' ... YAML   → echoes the project dir
  local d="$TMP/guard-$1"; mkdir -p "$d/.claude/config"; cat > "$d/.claude/config/stack.yaml"
  printf '%s' "$d"
}
gask() {  # gask <command> <project-dir> — payload built by a JSON encoder. Hand-escaping is a trap
  #        here: a malformed payload makes the hook fail open, so a *negative* assertion would
  #        pass vacuously and silently stop testing anything.
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2" | guard
}

# A cli-less warehouse seam listed BEFORE the tracker must not adopt the tracker's CLI — else a
# plain `create` on a ticket raises a bogus DB-write prompt.
d="$(gstack nocli <<'YAML'
seams:
  warehouse:
    tool: bigquery
    dataset: analytics
  tracker:
    tool: jira
    cli: acli
YAML
)"
out="$(gask 'acli jira workitem create --summary x' "$d")"
[ -z "$out" ] && ok "cli-less warehouse before tracker: tracker CLI not gated" || bad "warehouse seam scan leaked into the tracker seam" "$out"

# Four-space indentation is valid YAML that yq reads; the scan must not assume two.
d="$(gstack indent4 <<'YAML'
seams:
    warehouse:
        tool: custom
        cli: whcli
YAML
)"
out="$(gask 'whcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "4-space-indented stack: warehouse CLI still gated" || bad "indent width narrowed CLI gating (destructive write would slip through)" "$out"

# A multi-target seam declares one CLI per target; a non-default target's CLI must be gated too.
d="$(gstack multi <<'YAML'
seams:
  warehouse:
    default: prod
    targets:
      prod:
        tool: snowflake
        cli: snow
      lake:
        tool: trino
        cli: trino
YAML
)"
out="$(gask 'trino --execute "UPDATE t SET x=1"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "multi-target: non-default target CLI gated" || bad "a non-default target's CLI is not gated" "$out"

# Prose inside a block scalar is not configuration — and the scan resumes after it, so a real
# `cli:` following the scalar is still harvested. Uses `|-` to cover the indicator modifiers.
#            `realcli` sits DEEPER than the `note:` header on purpose — that is what proves the
#            skip actually *ends*, rather than swallowing every remaining nested line.
d="$(gstack blockscalar <<'YAML'
seams:
  warehouse:
    note: |-
      cli: not-a-cli
    default: prod
    targets:
      prod:
        cli: realcli
YAML
)"
out="$(gask 'not-a-cli --do-something CREATE' "$d")"
[ -z "$out" ] && ok "block-scalar prose not harvested as a CLI" || bad "block-scalar body read as config" "$out"
out="$(gask 'realcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "scan resumes after a block scalar (deeper cli: still gated)" || bad "block-scalar skip swallowed the rest of the seam" "$out"

# A comment between `seams:` and the first seam must not hide it (comments carry no indentation).
d="$(gstack comment <<'YAML'
seams:
    # which warehouse we point at
  warehouse:
    cli: cmtcli
YAML
)"
out="$(gask 'cmtcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "comment before the first seam doesn't hide it" || bad "a comment's indentation hid the warehouse seam (gating narrowed)" "$out"

# A mapping key may carry a YAML anchor before its nested block; yq resolves it, so must the scan.
d="$(gstack yamlanchor <<'YAML'
seams: &seam_map
  warehouse: &wh
    cli: anchcli
YAML
)"
out="$(gask 'anchcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "YAML anchor on seams:/warehouse: still gates" || bad "a YAML anchor hid the warehouse seam (gating narrowed)" "$out"

# A partial/malformed config with no `seams:` anchor is scanned whole rather than skipped —
# over-gating costs a prompt, under-gating runs an unreviewed write.
d="$(gstack noanchor <<'YAML'
warehouse:
  cli: barecli
YAML
)"
out="$(gask 'barecli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "no seams: anchor → still gates (fails safe)" || bad "config without a seams: key stopped gating entirely" "$out"

hdr "7 · session_context hook (SessionStart priming)"
out="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$KIT" python3 .claude/hooks/session_context.py 2>&1)"
grep -q "ENG" <<<"$out" && grep -qi "Lifecycle" <<<"$out" && ok "emits stack + lifecycle summary" || bad "session context missing/empty" "$out"

hdr "8 · statusline renders"
out="$(echo '{}' | CLAUDE_PROJECT_DIR="$KIT" bash .claude/statusline.sh 2>&1)"
grep -q "ENG" <<<"$out" && ok "statusline: $out" || bad "statusline empty/broken" "$out"

hdr "9 · productize stamp smoke (SKILL.md.tmpl → 0 leftover tokens)"
err="$(bash bin/render.sh templates/productized-skill/SKILL.md.tmpl \
  skill_name=x one_line_description=x argument_hint=x workflow_name=x params_table=x \
  param_validation=x precondition=x render_run_steps=x qc_table=x output_filenames=x \
  golden_invocation=x golden_fixture=x golden_assertions=x failure_mode_tests=x side_effects=x \
  2>&1 >/dev/null)"
[ -z "$err" ] && ok "productized SKILL.md stamps clean" || bad "leftover tokens in stamped SKILL.md" "$err"

hdr "10 · ticket index (renderer + url template + hooks)"
P="$TMP/proj"
mkdir -p "$P/.claude/config" "$P/bin" "$P/tickets/alice/ENG-1"
cp bin/build_ticket_index.py bin/ingest_index_records.py "$P/bin/"
cat > "$P/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
  key_prefixes: [ENG]
  ticket_url_template: "https://acme.example/browse/{id}"
EOF
printf '# ENG-1: Demo index ticket\n\nA demo ticket used by the kit self-test to exercise the index renderer.\n' > "$P/tickets/alice/ENG-1/README.md"
CLAUDE_PROJECT_DIR="$P" python3 bin/build_ticket_index.py >/dev/null 2>&1
if grep -q 'ENG-1' "$P/tickets/INDEX.md" 2>/dev/null && grep -q '▱' "$P/tickets/INDEX.md" 2>/dev/null; then
  ok "renderer writes INDEX.md with an un-enriched row"; else bad "renderer did not produce expected INDEX.md"; fi
grep -q 'acme.example/browse/ENG-1' "$P/tickets/INDEX.md" 2>/dev/null && ok "ticket_url_template applied" || bad "ticket_url_template not applied"
if CLAUDE_PROJECT_DIR="$P" python3 bin/build_ticket_index.py --check >/dev/null 2>&1; then
  ok "--check passes after render (deterministic)"; else bad "--check reported stale immediately after render"; fi
mkdir -p "$P/tickets/alice/ENG-2"
printf '# ENG-2: Second demo ticket\n\nAnother demo ticket.\n' > "$P/tickets/alice/ENG-2/README.md"
echo "{\"tool_input\":{\"file_path\":\"$P/tickets/alice/ENG-2/README.md\"},\"cwd\":\"$P\"}" | CLAUDE_PROJECT_DIR="$P" python3 .claude/hooks/regenerate_ticket_index.py >/dev/null 2>&1
grep -q 'ENG-2' "$P/tickets/INDEX.md" 2>/dev/null && ok "PostToolUse hook auto-adds a new ticket row" || bad "PostToolUse hook did not regenerate"
out="$(echo '{}' | CLAUDE_PROJECT_DIR="$P" python3 .claude/hooks/ticket_index_context.py 2>&1)"
grep -qi 'INDEX.md' <<<"$out" && ok "SessionStart index hook emits a catalog pointer" || bad "SessionStart index hook silent" "$out"

hdr "11 · prior-art recall + object reverse-index"
R="$TMP/recall"
mkdir -p "$R/.claude/config" "$R/tickets/dana/ENG-1" "$R/tickets/dana/ENG-2" "$R/tickets/dana/ENG-3"
printf 'project:\n  key_prefix: ENG\n' > "$R/.claude/config/stack.yaml"
printf '# ENG-1: Loan tape base\n\nbase pull.\n' > "$R/tickets/dana/ENG-1/README.md"
printf 'SELECT * FROM BI.ANALYTICS.VW_LOAN;\n' > "$R/tickets/dana/ENG-1/q.sql"
printf '# ENG-2: Loan tape follow-up\n\nFollow-on to ENG-1.\n' > "$R/tickets/dana/ENG-2/README.md"
printf 'SELECT * FROM BI.ANALYTICS.VW_LOAN;\n' > "$R/tickets/dana/ENG-2/q.sql"
printf '# ENG-3: Genesys call metrics\n\nunrelated work.\n' > "$R/tickets/dana/ENG-3/README.md"
printf 'SELECT * FROM BI.OPS.VW_CALL;\n' > "$R/tickets/dana/ENG-3/q.sql"
printf 'from os.path import join\nimport collections.abc\n' > "$R/tickets/dana/ENG-3/munge.py"  # must NOT be indexed
CLAUDE_PROJECT_DIR="$R" python3 bin/build_ticket_index.py >/dev/null 2>&1
if grep 'VW_LOAN' "$R/tickets/OBJECTS.md" 2>/dev/null | grep -q 'ENG-1' && grep 'VW_LOAN' "$R/tickets/OBJECTS.md" | grep -q 'ENG-2'; then
  ok "OBJECTS.md maps shared object → both tickets"; else bad "OBJECTS.md reverse map wrong" "$(cat "$R/tickets/OBJECTS.md" 2>/dev/null)"; fi
CLAUDE_PROJECT_DIR="$R" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 && ok "--check covers INDEX.md + OBJECTS.md" || bad "--check failed after render"
rj="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --for ENG-1 --json 2>/dev/null)"
top="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$rj")"
ids="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(','.join(x['id'] for x in d))" <<<"$rj")"
[ "$top" = "ENG-2" ] && ok "recall ranks the related ticket first (ENG-2)" || bad "recall mis-ranked" "top=$top ids=$ids"
grep -q 'ENG-3' <<<"$ids" && bad "recall surfaced the unrelated ticket (ENG-3)" || ok "recall excludes the unrelated ticket"
rl="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --object BI.ANALYTICS.VW_LOAN --json 2>/dev/null | python3 -c "import json,sys; print(sorted(x['id'] for x in json.load(sys.stdin)))")"
[ "$rl" = "['ENG-1', 'ENG-2']" ] && ok "recall --object reverse lookup → ENG-1, ENG-2" || bad "reverse lookup wrong" "$rl"
# regression: unqualified --object must leaf-match the qualified stored object
ul="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --object VW_LOAN --json 2>/dev/null | python3 -c "import json,sys; print(sorted(x['id'] for x in json.load(sys.stdin)))")"
[ "$ul" = "['ENG-1', 'ENG-2']" ] && ok "recall --object leaf match (unqualified VW_LOAN → ENG-1, ENG-2)" || bad "leaf-match lookup wrong" "$ul"
# regression: Python `from os.path import` must not be indexed as a data object
grep -qi 'os\.path\|collections\.abc' "$R/tickets/OBJECTS.md" 2>/dev/null && bad "Python import indexed as object" "$(grep -i 'os.path\|collections' "$R/tickets/OBJECTS.md")" || ok "Python import lines excluded from object index"
grep -q 'recall.py' .claude/skills/ticket/priming.md && ok "/ticket priming wires the recall engine" || bad "/ticket priming missing recall wiring"
# --eval diagnostic: ENG-2's README references ENG-1, so there's one labeled seed to score
ev="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --eval 2>/dev/null)"
grep -q 'MRR=' <<<"$ev" && ok "recall --eval reports recall-quality metrics" || bad "recall --eval produced no metrics" "$ev"
# IDF down-weighting: a ticket sharing a RARE object must outrank tickets sharing a UBIQUITOUS one
I="$TMP/idf"; mkdir -p "$I/.claude/config"
printf 'project:\n  key_prefix: ENG\n' > "$I/.claude/config/stack.yaml"
for n in 1 2 3 4 5 6; do mkdir -p "$I/tickets/dana/ENG-$n"; printf '# ENG-%s x\n\nx.\n' "$n" > "$I/tickets/dana/ENG-$n/README.md"; printf 'SELECT * FROM S.VW_COMMON;\n' > "$I/tickets/dana/ENG-$n/q.sql"; done
mkdir -p "$I/tickets/dana/ENG-7"; printf '# ENG-7 x\n\nx.\n' > "$I/tickets/dana/ENG-7/README.md"; printf 'SELECT * FROM S.VW_RARE;\n' > "$I/tickets/dana/ENG-7/q.sql"
mkdir -p "$I/tickets/dana/ENG-9"; printf '# ENG-9 x\n\nx.\n' > "$I/tickets/dana/ENG-9/README.md"; printf 'SELECT * FROM S.VW_COMMON JOIN S.VW_RARE;\n' > "$I/tickets/dana/ENG-9/q.sql"
CLAUDE_PROJECT_DIR="$I" python3 bin/build_ticket_index.py >/dev/null 2>&1
idf="$(CLAUDE_PROJECT_DIR="$I" python3 bin/recall.py --for ENG-9 --json 2>/dev/null | python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')")"
[ "$idf" = "ENG-7" ] && ok "IDF down-weighting ranks the rare-object ticket first (ENG-7 over VW_COMMON crowd)" || bad "IDF ranking wrong" "top=$idf"
# regression: same id under two owners — --for --owner must keep the OTHER owner's ticket as a candidate
M="$TMP/multiowner"; mkdir -p "$M/.claude/config" "$M/tickets/alice/ENG-5" "$M/tickets/bob/ENG-5"
printf 'project:\n  key_prefix: ENG\n' > "$M/.claude/config/stack.yaml"
printf '# ENG-5: alice payment recovery\n\nshared payment recovery loan tape work.\n' > "$M/tickets/alice/ENG-5/README.md"
printf '# ENG-5: bob payment recovery\n\nshared payment recovery loan tape work.\n' > "$M/tickets/bob/ENG-5/README.md"
mo="$(CLAUDE_PROJECT_DIR="$M" python3 bin/recall.py --for ENG-5 --owner alice --json 2>/dev/null | python3 -c "import json,sys; print(','.join(x['owner']+'/'+x['id'] for x in json.load(sys.stdin)))")"
grep -q 'bob/ENG-5' <<<"$mo" && ok "recall --for keeps same-id ticket under another owner" || bad "seed exclusion dropped same-id/other-owner" "$mo"
amb="$(CLAUDE_PROJECT_DIR="$M" python3 bin/recall.py --for ENG-5 2>&1 >/dev/null)"
grep -q 'multiple owners' <<<"$amb" && ok "recall errors on ambiguous seed (no --owner)" || bad "ambiguous seed not flagged" "$amb"
# --recurring surfaces a frequently-touched object (VW_COMMON is in 7 of the IDF fixture's tickets)
rec="$(CLAUDE_PROJECT_DIR="$I" python3 bin/build_ticket_index.py --recurring --min-tickets 3 2>/dev/null)"
grep -q 'VW_COMMON' <<<"$rec" && ok "--recurring lists a frequently-touched object" || bad "--recurring missed it" "$rec"

hdr "12 · ingest validators (the LLM-record trust boundary)"
G="$TMP/ingest"; mkdir -p "$G/.claude/config" "$G/tickets/dana/ENG-1"
printf 'project:\n  key_prefix: ENG\n' > "$G/.claude/config/stack.yaml"
printf '# ENG-1 x\n\nx.\n' > "$G/tickets/dana/ENG-1/README.md"
printf '%s' '{"records":[{"id":"ENG-1","owner":"dana","title":"T","status":"Completed","date":"not-a-date","objects":["bare_name","S.VW_X"],"tags":["Has Spaces!","Has Spaces!"],"summary":"s"}]}' \
  | CLAUDE_PROJECT_DIR="$G" python3 bin/ingest_index_records.py --from-json - >/dev/null 2>&1
chk="$(python3 -c "import json; t=json.load(open('$G/tickets/index_data.json'))['tickets'][0]; print(repr(t['date']), t['objects'], t['tags'])")"
[ "$chk" = "None ['S.VW_X'] ['has-spaces']" ] && ok "ingest drops bad date + bare object, coerces/dedups tags" || bad "ingest validators wrong" "$chk"

hdr "13 · privacy guard (no real ticket store committed to the public kit)"
# The store is per-install PRIVATE business data. It must be gitignored here; if it is ever tracked,
# it must be empty or fixture-only (ENG-/DEMO-/TEST-/SAMPLE-). This catches an accidental `cp` of a
# real index_data.json + commit before it reaches the public repo.
if git ls-files --error-unmatch tickets/index_data.json >/dev/null 2>&1; then
  realids="$(python3 - <<'PY'
import json, re
try:
    d = json.load(open("tickets/index_data.json"))
except Exception:
    d = {}
ts = d.get("tickets", []) if isinstance(d, dict) else []
bad = [str(t.get("id", "")) for t in ts if not re.match(r"^(ENG|DEMO|TEST|SAMPLE)-", str(t.get("id", "")))]
print(" ".join(bad))
PY
)"
  [ -z "$realids" ] && ok "tracked index_data.json is empty/fixture-only" \
    || bad "REAL ticket ids committed to the public kit — scrub before pushing" "$realids"
else
  ok "tickets/index_data.json is gitignored (a private store can't be committed)"
fi
[ -f tickets/index_data.example.json ] && ok "index_data.example.json shipped as the schema reference" \
  || bad "tickets/index_data.example.json missing"

hdr "14 · scrub + structure (public-kit hygiene)"
# scrub: generic secret / PII patterns must not appear in tracked kit files (selftest excluded — it
# carries the patterns themselves; we deliberately do NOT hardcode any employer name here).
scrub="$(grep -rIlE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[0-9]{3}-[0-9]{2}-[0-9]{4}' \
  --exclude-dir=.git --exclude=selftest.sh . 2>/dev/null || true)"
[ -z "$scrub" ] && ok "no secret/PII patterns in tracked files" || bad "scrub hit" "$scrub"
# structure: every command/skill has PARSEABLE frontmatter (a substring grep false-greens on broken
# YAML — e.g. `argument-hint: [a] [b]` parses as a flow seq + trailing junk and drops ALL metadata when
# loaded as a plugin). Validate flow-node values are complete + a description is present. Stdlib only.
fm_bad="$(python3 - <<'PY'
import re, glob
def check(f):
    m = re.match(r'^---\n(.*?)\n---', open(f, encoding='utf-8').read(), re.S)
    if not m:
        return f + " (no frontmatter)"
    desc = False
    for ln in m.group(1).splitlines():
        mm = re.match(r'^([A-Za-z_][\w-]*):\s*(.*)$', ln)
        if not mm:
            continue
        k, v = mm.group(1), mm.group(2).strip()
        if k == "description" and v:
            desc = True
        if v[:1] in '["\'':            # a flow node must be the WHOLE value (only trailing whitespace)
            if v[0] == "[":
                depth = idx = 0; idx = -1
                for i, c in enumerate(v):
                    if c == "[": depth += 1
                    elif c == "]":
                        depth -= 1
                        if depth == 0: idx = i; break
            else:
                idx = v.find(v[0], 1)
            if idx == -1 or v[idx + 1:].strip():
                return f + ": invalid YAML flow value for '" + k + "'"
    return None if desc else f + " (no description)"
bad = [r for r in (check(f) for f in glob.glob('.claude/commands/*.md') + glob.glob('.claude/skills/*/SKILL.md')) if r]
print("\n".join(bad))
PY
)"
[ -z "$fm_bad" ] && ok "every command/skill has valid, parseable frontmatter (+ a description)" || bad "frontmatter problem (would drop metadata as a plugin)" "$fm_bad"
afail=""
for f in adapters/*/*.md; do
  h="$(head -12 "$f")"; { grep -q '^seam:' <<<"$h" && grep -q '^tool:' <<<"$h"; } || afail="$afail $f"
done
[ -z "$afail" ] && ok "every adapter declares seam + tool" || bad "adapter frontmatter incomplete" "$afail"
# role modes: 4 snippets present + the template token is wired
roles_ok=1; for r in generalist analyst engineer scientist; do [ -f "templates/roles/$r.md" ] || roles_ok=0; done
{ [ "$roles_ok" = 1 ] && grep -q '{{role_focus}}' templates/AGENTS.md.tmpl; } \
  && ok "role-mode snippets present + {{role_focus}} wired into AGENTS.md.tmpl" || bad "role modes incomplete"

hdr "14b · v2 skill surface (7 skills; v1 alias stubs removed in v3)"
sk_missing=""
for s in setup ticket spec-and-build review ship productize refresh; do
  [ -f ".claude/skills/$s/SKILL.md" ] || sk_missing="$sk_missing $s"
done
[ -z "$sk_missing" ] && ok "all 7 v2 skills present (setup ticket spec-and-build review ship productize refresh)" \
  || bad "v2 skill missing:$sk_missing"
extra="$(ls -d .claude/skills/*/ | grep -Ev '/(setup|ticket|spec-and-build|review|ship|productize|refresh)/$' || true)"
[ -z "$extra" ] && ok "no stray skill folders beyond the 7" || bad "unexpected skill folder (v1 leftover?)" "$extra"
al_bad=""
for a in configure-workspace onboard-teammate start-ticket qc-review deliver-ticket productize-workflow \
         build-ticket-index build-context-pack prime-ticket prime-warehouse prime-domain recall; do
  [ -f ".claude/commands/$a.md" ] && al_bad="$al_bad $a"
done
[ -z "$al_bad" ] && ok "12 deprecated v1 alias stubs removed (v3)" || bad "v1 alias stub still present:$al_bad"

hdr "15 · plugin manifest (Claude Code plugin packaging)"
python3 -c "import json; m=json.load(open('.claude-plugin/plugin.json')); assert m['name']=='ticketwright' and m.get('version') and 'hooks' in m" 2>/dev/null \
  && ok "plugin.json valid + has name/version/hooks" || bad "plugin.json invalid/missing fields"
python3 -c "import json; d=json.load(open('.claude-plugin/marketplace.json')); assert any(p.get('name')=='ticketwright' for p in d['plugins'])" 2>/dev/null \
  && ok "marketplace.json valid + lists ticketwright" || bad "marketplace.json invalid"
# auto-discovery symlinks must resolve into .claude/* (loader rejected custom .claude paths in the manifest)
{ [ -L commands ] && [ -L skills ] && [ -L agents ] && [ -d commands ] && [ -d skills ] && [ -d agents ]; } \
  && ok "component symlinks resolve (commands/skills/agents → .claude/*)" || bad "plugin component symlinks broken"
# every hook script the plugin manifest declares must exist
hk=1; for h in db_write_guard regenerate_ticket_index session_context ticket_index_context; do [ -f ".claude/hooks/$h.py" ] || hk=0; done
[ "$hk" = 1 ] && ok "all plugin-declared hook scripts present" || bad "a plugin-declared hook script is missing"

hdr "16 · PyPI package (manifest + version sync + CLI)"
{ [ -f pyproject.toml ] && [ -f ticketwright/__init__.py ] && [ -f ticketwright/cli.py ]; } \
  && ok "package files present (pyproject + ticketwright/)" || bad "package files missing"
# pyproject sources its version dynamically from __init__.py, so __init__ is the ONE source of truth;
# plugin.json + marketplace.json must agree with it (release bumps these three in lockstep).
grep -q 'dynamic = \["version"\]' pyproject.toml \
  && ok "pyproject version is dynamic (single source: ticketwright/__init__.py)" \
  || bad "pyproject should declare dynamic = [\"version\"] (no static version)"
iv="$(grep '__version__' ticketwright/__init__.py | sed 's/[^0-9.]//g')"
jv="$(grep -m1 '"version"' .claude-plugin/plugin.json | sed 's/[^0-9.]//g')"
mv="$(grep -m1 '"version"' .claude-plugin/marketplace.json | sed 's/[^0-9.]//g')"
{ [ -n "$iv" ] && [ "$iv" = "$jv" ] && [ "$iv" = "$mv" ]; } \
  && ok "version synced across __init__/plugin/marketplace ($iv)" \
  || bad "version drift" "init=$iv plugin=$jv market=$mv"
# the CLI module imports + exposes main(); console-script entry point declared
python3 -c "import sys; sys.path.insert(0,'.'); import ticketwright.cli as c; raise SystemExit(0 if callable(c.main) else 1)" 2>/dev/null \
  && ok "ticketwright.cli imports + exposes main()" || bad "ticketwright.cli broken"
grep -q 'ticketwright = "ticketwright.cli:main"' pyproject.toml \
  && ok "console_script entry point declared" || bad "console_script entry point missing"
# bumping the three version files by hand is what let PyPI drift behind the plugin — keep the script
{ [ -f bin/bump_version.sh ] && [ -x bin/bump_version.sh ]; } \
  && ok "bin/bump_version.sh present + executable" || bad "bin/bump_version.sh missing or not executable"
# The wheel must NOT ship the repo's own stack.yaml (a fictional "Acme" example) — `init` would
# scaffold it into a fresh repo as real config. Examples + schema DO ship, enumerated one per line.
grep -q '^"\.claude/config" =' pyproject.toml \
  && bad "pyproject force-includes .claude/config wholesale (ships the Acme stack.yaml)" \
  || ok "pyproject does not force-include .claude/config wholesale"
grep -q '^"\.claude/config/stack\.yaml" =' pyproject.toml \
  && bad "pyproject force-includes .claude/config/stack.yaml (Acme example would ship)" \
  || ok "stack.yaml excluded from the wheel (/setup writes the real one)"
cfgmiss=""
for f in .claude/config/*; do
  [ -f "$f" ] || continue
  [ "$f" = ".claude/config/stack.yaml" ] && continue
  grep -q "^\"$f\" = " pyproject.toml || cfgmiss="$cfgmiss $f"
done
[ -z "$cfgmiss" ] \
  && ok "every shipped .claude/config file is force-included by name" \
  || bad "config file(s) missing a force-include line (add to pyproject)" "$cfgmiss"

hdr "17 · render-validation gate (render_and_validate.sh) — items 1+2"
RV="bin/render_and_validate.sh"
cat > "$TMP/clean.sql.tmpl" <<'EOF'
-- step SQL — params described in prose, never as tokens
SET d = '{{asof}}'::DATE;
SELECT id FROM {{src}} WHERE dt <= '{{asof}}' ORDER BY id;
EOF
bash "$RV" "$TMP/clean.sql.tmpl" asof=2026-06-30 src=T >/dev/null 2>&1 \
  && ok "passes a clean template (quoted literal, no comment tokens)" || bad "clean template wrongly rejected"
cat > "$TMP/cmt.sql.tmpl" <<'EOF'
-- NOTE: substitutes {{vals}} before the run
SELECT * FROM t WHERE x IN ({{vals}}) ORDER BY 1;
EOF
bash "$RV" "$TMP/cmt.sql.tmpl" vals="1,2" >/dev/null 2>&1 \
  && bad "token-in-comment NOT caught (the Fortress hard-failure class)" || ok "rejects a {{token}} inside a SQL comment"
cat > "$TMP/unq.sql.tmpl" <<'EOF'
SET d = {{asof}};
SELECT 1 AS x ORDER BY 1;
EOF
bash "$RV" "$TMP/unq.sql.tmpl" asof=2026-06-30 >/dev/null 2>&1 \
  && ok "unquoted SQL literal is a warning (non-strict passes)" || bad "unquoted literal wrongly failed non-strict"
bash "$RV" "$TMP/unq.sql.tmpl" asof=2026-06-30 --strict >/dev/null 2>&1 \
  && bad "unquoted literal NOT escalated under --strict" || ok "unquoted literal fails under --strict"
cat > "$TMP/par.sql.tmpl" <<'EOF'
SELECT count(* FROM {{src}} ORDER BY 1;
EOF
bash "$RV" "$TMP/par.sql.tmpl" src=T >/dev/null 2>&1 \
  && bad "unbalanced parens NOT caught" || ok "rejects unbalanced parens in rendered SQL"
# the SHIPPED productized templates must obey their own rules (render clean under --strict)
bash "$RV" templates/productized-skill/sql/step.sql.tmpl --strict \
  period=Q src=T as_of_date=2026-06-30 select_columns=id source_object=T filter="1=1" order_key=id >/dev/null 2>&1 \
  && ok "shipped step.sql.tmpl passes its own gate (--strict)" || bad "step.sql.tmpl fails the render gate"
bash "$RV" templates/productized-skill/sql/qc.sql.tmpl --strict \
  grain_key=id output_object=O source_object=S filter="1=1" required_col=id >/dev/null 2>&1 \
  && ok "shipped qc.sql.tmpl passes its own gate (--strict)" || bad "qc.sql.tmpl fails the render gate"

hdr "18 · export helpers (split_and_export.sh) — items 3+4"
SE="bin/split_and_export.sh"
cat > "$TMP/multi.sql" <<'EOF'
USE WAREHOUSE WH;
-- Query 1: alpha
SELECT 1 AS a ORDER BY 1;
-- Query 2: beta
SELECT 2 AS b ORDER BY 1;
EOF
bash "$SE" "$TMP/multi.sql" "$TMP/mout" >/dev/null 2>&1
n="$(ls "$TMP/mout"/*.sql 2>/dev/null | wc -l | tr -d ' ')"
{ [ "$n" = "2" ] && grep -q 'USE WAREHOUSE WH' "$TMP/mout/02-beta.sql"; } \
  && ok "split on -- Query N markers → N files, shared preamble replicated into each" \
  || bad "split/preamble wrong (n=$n)" "$(ls "$TMP/mout" 2>/dev/null)"
printf 'status\nStatement executed successfully.\nStatement executed successfully.\n\nID,X\n1,a\n' > "$TMP/raw.csv"
bash "$SE" --strip-only "$TMP/raw.csv" >/dev/null 2>&1
[ "$(head -1 "$TMP/raw.csv")" = "ID,X" ] \
  && ok "--strip-only drops the multi-statement CLI preamble (header is row 1)" \
  || bad "strip-only left preamble" "$(head -1 "$TMP/raw.csv")"

hdr "19 · gitignore template (deliverables committed by default; PII opt-out) — item 6"
# Policy: deliverable exports are COMMITTED by default (results live with the ticket / show in the PR);
# PII opts out via a *.private.csv name or a private/ subfolder. Assert the blanket ignore is gone and
# the opt-out patterns are present + functional.
grep -Eq '^\*\*/final_deliverables/\*\.csv' templates/gitignore.tmpl \
  && bad "gitignore.tmpl still ACTIVELY ignores all deliverable CSVs (policy is commit-by-default)" \
  || ok "gitignore.tmpl no longer blanket-ignores deliverable CSVs"
{ grep -q '^\*\*/\*\.private\.csv' templates/gitignore.tmpl \
  && grep -q '^\*\*/final_deliverables/\*\*/private/' templates/gitignore.tmpl; } \
  && ok "gitignore.tmpl ships the PII opt-out patterns (*.private.csv + private/)" \
  || bad "gitignore.tmpl missing a PII opt-out pattern"
GI="$TMP/gi"; mkdir -p "$GI/tickets/d/ENG-1/final_deliverables/private"
git -C "$GI" init -q 2>/dev/null
cp templates/gitignore.tmpl "$GI/.gitignore"
: > "$GI/tickets/d/ENG-1/final_deliverables/x.csv"
: > "$GI/tickets/d/ENG-1/final_deliverables/x.sql"
: > "$GI/tickets/d/ENG-1/final_deliverables/secret.private.csv"
: > "$GI/tickets/d/ENG-1/final_deliverables/private/rows.csv"
csv_committed=1; git -C "$GI" check-ignore -q tickets/d/ENG-1/final_deliverables/x.csv && csv_committed=0
sql_committed=1; git -C "$GI" check-ignore -q tickets/d/ENG-1/final_deliverables/x.sql && sql_committed=0
priv_named=0;    git -C "$GI" check-ignore -q tickets/d/ENG-1/final_deliverables/secret.private.csv && priv_named=1
priv_dir=0;      git -C "$GI" check-ignore -q tickets/d/ENG-1/final_deliverables/private/rows.csv && priv_dir=1
{ [ "$csv_committed" = 1 ] && [ "$sql_committed" = 1 ] && [ "$priv_named" = 1 ] && [ "$priv_dir" = 1 ]; } \
  && ok "plain CSV + deliverable SQL committed; *.private.csv and private/ ignored" \
  || bad "gitignore policy wrong" "csv=$csv_committed sql=$sql_committed private_named=$priv_named private_dir=$priv_dir"

hdr "20 · path resolution + adapter hygiene (regressions from real-session bugs)"
# E1 — sibling scripts resolve to the KIT, not the project root (the /ship enrich crash).
grep -Eq 'root[[:space:]]*/[[:space:]]*"bin"[[:space:]]*/[[:space:]]*"(ingest_index_records|build_ticket_index)' bin/enrich_ticket.py \
  && bad "enrich_ticket.py resolves sibling scripts off the project root (breaks on a plugin install)" \
  || ok "enrich_ticket.py resolves sibling scripts from its own kit dir, not the project root"
# E2 — the two index hooks import the renderer from the kit, not the project's bin/.
hook_bad=""
for h in regenerate_ticket_index ticket_index_context; do
  grep -q 'root / "bin"' ".claude/hooks/$h.py" && hook_bad="$hook_bad $h"
done
[ -z "$hook_bad" ] && ok "index hooks import the renderer from the kit (CLAUDE_PLUGIN_ROOT/__file__)" \
  || bad "hook inserts project-root/bin on sys.path (renderer won't import on a plugin install):$hook_bad"
# E3 — verify_stack resolves adapters against the kit even when the stack lives OUTSIDE the kit.
VS="$TMP/vsext"; mkdir -p "$VS/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  tracker:\n    tool: jira\n    adapter: adapters/tracker/jira.md\n    transport: cli\n    verify: null\n' > "$VS/.claude/config/stack.yaml"
vout="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$VS/.claude/config/stack.yaml" --dry-run 2>&1)"
# Require positive success ("All seams OK"), not just the absence of "adapter missing" — else a
# fixture that failed to create would falsely pass (the seam here has verify:null, so success prints).
{ grep -q 'All seams OK' <<<"$vout" && ! grep -q 'adapter missing' <<<"$vout"; } \
  && ok "verify_stack resolves adapters via CLAUDE_PLUGIN_ROOT (project-external stack)" \
  || bad "verify_stack failed on a project-external stack (adapter missing / no success line)" "$vout"
# E4 — adapters use the {mcp} token, never a hardcoded MCP server literal.
lit="$(grep -REn 'mcp__[A-Za-z0-9]' adapters/ | grep -v 'mcp__{mcp}__' || true)"
[ -z "$lit" ] && ok "adapters use the {mcp} token (no hardcoded MCP server names)" \
  || bad "adapter hardcodes an MCP server name (should be mcp__{mcp}__…)" "$lit"
# E5 — no seam verify depends on the nullable {default_epic}.
ve="$(grep -REn 'verify.*\{default_epic\}' .claude/config/*.yaml 2>/dev/null || true)"
va="$(sed -n '/^auth:/,/^---/p' adapters/tracker/jira.md | grep -c 'default_epic' || true)"
{ [ -z "$ve" ] && [ "$va" = "0" ]; } && ok "no seam verify references the nullable {default_epic}" \
  || bad "a verify depends on {default_epic} (fails when a project has no required epic)" "$ve"
# E6 — no org-specific business vocabulary leaked into an adapter (public plugin).
leak="$(grep -REn 'Data Pull|Data Engineering Task|Data Engineering Bug|every DI type' adapters/ || true)"
[ -z "$leak" ] && ok "no org-specific Jira vocabulary in adapters" \
  || bad "org-specific business content leaked into an adapter (public plugin!)" "$leak"
# E7 — the DECLARE→CTE-params portability guardrail shipped where scripting is common.
wq_bad=""
for w in bigquery snowflake synapse; do
  grep -qiE 'CTE param|CROSS JOIN params' "adapters/warehouse/$w.md" || wq_bad="$wq_bad $w"
done
[ -z "$wq_bad" ] && ok "bigquery/snowflake/synapse carry the CTE-params (vs session DECLARE) note" \
  || bad "a warehouse adapter is missing the portable-params guardrail:$wq_bad"
grep -qiE 'DECLARE|session-variable' .claude/skills/review/SKILL.md \
  && ok "/review lints session-DECLARE parameterization" || bad "/review missing the DECLARE lint"
# E8 — /ticket renders the index in its scaffold path (a new ticket shows immediately).
grep -q 'build_ticket_index.py' .claude/skills/ticket/SKILL.md \
  && ok "/ticket runs build_ticket_index.py after scaffolding (new ticket appears in INDEX.md)" \
  || bad "/ticket never renders the index — a new ticket won't show until a manual run"
# E9 — CSV cell-value ASCII-punctuation rule (no em dashes, which don't render in CSV) documented + enforced.
{ grep -q 'ASCII punctuation only in cell values' templates/AGENTS.md.tmpl \
  && grep -q 'ASCII punctuation only in cell values' .claude/skills/review/SKILL.md; } \
  && ok "CSV cell-value ASCII-punctuation rule documented (AGENTS.md) + enforced (/review)" \
  || bad "CSV ASCII-punctuation rule missing from AGENTS.md.tmpl or /review"
# E10 — the 'commandify_everything' policy was renamed to 'skillify_everything' (skills-first framing).
cf="$(grep -REn 'commandify' .claude/config .claude/skills templates 2>/dev/null || true)"
{ [ -z "$cf" ] && grep -q 'skillify_everything' .claude/config/stack.yaml; } \
  && ok "policy is skillify_everything (no legacy 'commandify' left)" \
  || bad "legacy 'commandify' policy name still present (rename to skillify_everything)" "$cf"
# E11 — the scaffolded CLAUDE.md import (Claude Code → AGENTS.md) ships as a bare one-line template.
{ [ -f templates/CLAUDE.md.tmpl ] \
  && [ "$(grep -cvE '^[[:space:]]*$' templates/CLAUDE.md.tmpl)" = "1" ] \
  && grep -q '^@AGENTS.md' templates/CLAUDE.md.tmpl; } \
  && ok "CLAUDE.md.tmpl is a bare @AGENTS.md import (Claude Code auto-loads the rules)" \
  || bad "templates/CLAUDE.md.tmpl must be exactly one line: @AGENTS.md"

hdr "21 · Obsidian graph layer (tickets/graph/ + tickets/objects/)"
GX="$TMP/graph"; mkdir -p "$GX/.claude/config" "$GX/tickets/alice/ENG-1" "$GX/tickets/alice/ENG-2" "$GX/tickets/bob/ENG-3"
printf 'project:\n  key_prefix: ENG\n' > "$GX/.claude/config/stack.yaml"
printf '# ENG-1: Loan tape base\n\nbase.\n' > "$GX/tickets/alice/ENG-1/README.md"
printf 'SELECT * FROM ANALYTICS.VW_LOAN;\n' > "$GX/tickets/alice/ENG-1/q.sql"
printf '# ENG-2: Loan tape follow-up to ENG-1\n\nsee ENG-1.\n' > "$GX/tickets/alice/ENG-2/README.md"
printf 'SELECT * FROM ANALYTICS.VW_LOAN;\n' > "$GX/tickets/alice/ENG-2/q.sql"
printf '# ENG-3: Unrelated\n\nx.\n' > "$GX/tickets/bob/ENG-3/README.md"
printf 'SELECT * FROM OPS.VW_CALL;\n' > "$GX/tickets/bob/ENG-3/q.sql"
CLAUDE_PROJECT_DIR="$GX" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ -f "$GX/tickets/graph/ENG-1.md" ] && [ -f "$GX/tickets/graph/ENG-2.md" ] && [ -f "$GX/tickets/graph/ENG-3.md" ]; } \
  && ok "graph stubs generated (one per ticket)" || bad "graph stubs missing"
{ [ -f "$GX/tickets/objects/ANALYTICS.VW_LOAN.md" ] && [ -f "$GX/tickets/objects/OPS.VW_CALL.md" ]; } \
  && ok "object notes generated (one per object)" || bad "object notes missing"
{ grep -q '(../graph/ENG-1.md)' "$GX/tickets/objects/ANALYTICS.VW_LOAN.md" \
  && grep -q '(../graph/ENG-2.md)' "$GX/tickets/objects/ANALYTICS.VW_LOAN.md"; } \
  && ok "object note links the ticket stubs (VW_LOAN -> ENG-1, ENG-2)" || bad "object note not linking stubs"
grep -q '](ENG-1.md)' "$GX/tickets/graph/ENG-2.md" \
  && ok "stub carries the cross-ref link (ENG-2 -> ENG-1)" || bad "stub missing cross-ref link"
if python3 - "$GX" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]); broken = 0
for sub in ("graph", "objects"):
    for md in (root/"tickets"/sub).glob("*.md"):
        for m in re.finditer(r"\]\(([^)]+\.md)\)", md.read_text()):
            if not (md.parent/m.group(1)).resolve().exists(): broken += 1
sys.exit(1 if broken else 0)
PY
then ok "all graph-layer links resolve"; else bad "graph-layer has broken links"; fi
CLAUDE_PROJECT_DIR="$GX" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 \
  && ok "--check clean after render (graph layer deterministic)" || bad "--check stale right after render"
rm -rf "$GX/tickets/bob/ENG-3"
CLAUDE_PROJECT_DIR="$GX" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ ! -f "$GX/tickets/graph/ENG-3.md" ] && [ ! -f "$GX/tickets/objects/OPS.VW_CALL.md" ]; } \
  && ok "orphan cleanup removes the stale stub + object note" || bad "orphan cleanup failed"
GO="$TMP/graphoff"; mkdir -p "$GO/.claude/config" "$GO/tickets/alice/ENG-1"
printf 'project:\n  key_prefix: ENG\n  graph_notes: false\n' > "$GO/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nx.\n' > "$GO/tickets/alice/ENG-1/README.md"
CLAUDE_PROJECT_DIR="$GO" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ ! -d "$GO/tickets/graph" ] && [ ! -d "$GO/tickets/objects" ]; } \
  && ok "graph_notes: false disables the layer" || bad "graph_notes flag not honored"
grep -q '(../objects/ANALYTICS.VW_LOAN.md)' "$GX/tickets/graph/ENG-1.md" \
  && ok "stub links its object notes (../objects/...)" || bad "stub does not link objects"
mkdir -p "$GX/tickets/alice/ENG-20"
printf '# ENG-20: hook test\n\nx.\n' > "$GX/tickets/alice/ENG-20/README.md"
printf 'SELECT * FROM ANALYTICS.VW_LOAN;\n' > "$GX/tickets/alice/ENG-20/q.sql"
echo "{\"tool_input\":{\"file_path\":\"$GX/tickets/alice/ENG-20/README.md\"},\"cwd\":\"$GX\"}" \
  | CLAUDE_PROJECT_DIR="$GX" python3 .claude/hooks/regenerate_ticket_index.py >/dev/null 2>&1
[ -f "$GX/tickets/graph/ENG-20.md" ] \
  && ok "PostToolUse hook regenerates the graph layer (ENG-20 stub appeared)" || bad "hook did not regenerate the graph layer"
CF="$TMP/graphcf"; mkdir -p "$CF/.claude/config" "$CF/tickets/a/ENG-1" "$CF/tickets/a/ENG-2"
printf 'project:\n  key_prefix: ENG\n' > "$CF/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nx.\n' > "$CF/tickets/a/ENG-1/README.md"; printf 'SELECT * FROM S.VW_MIXED;\n' > "$CF/tickets/a/ENG-1/q.sql"
printf '# ENG-2: x\n\nx.\n' > "$CF/tickets/a/ENG-2/README.md"; printf 'select * from s.vw_mixed;\n' > "$CF/tickets/a/ENG-2/q.sql"
CLAUDE_PROJECT_DIR="$CF" python3 bin/build_ticket_index.py >/dev/null 2>&1
[ "$(ls "$CF/tickets/objects" 2>/dev/null | grep -ic 'vw_mixed')" = "1" ] \
  && ok "mixed-case object folds to ONE note (macOS case-insensitive safe)" || bad "mixed-case object split into multiple notes"
printf 'project:\n  key_prefix: ENG\n  graph_notes: false\n' > "$CF/.claude/config/stack.yaml"
CLAUDE_PROJECT_DIR="$CF" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ ! -d "$CF/tickets/graph" ] && [ ! -d "$CF/tickets/objects" ]; } \
  && ok "disabling graph_notes removes the existing layer" || bad "stale graph layer left after disabling"
DR="$TMP/graphdr"; mkdir -p "$DR/.claude/config" "$DR/tickets/a/ENG-1"
printf 'project:\n  key_prefix: ENG\n' > "$DR/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nRelated: ENG-999\n' > "$DR/tickets/a/ENG-1/README.md"
CLAUDE_PROJECT_DIR="$DR" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ grep -q 'ENG-999' "$DR/tickets/graph/ENG-1.md" && ! grep -q '(ENG-999.md)' "$DR/tickets/graph/ENG-1.md"; } \
  && ok "dangling cross-ref shown as text, not a broken link" || bad "cross-ref to a nonexistent ticket was linked"
grep -q 'graph_notes' .claude/config/stack.schema.md \
  && ok "graph_notes documented in stack.schema.md" || bad "graph_notes not documented in stack.schema.md"
grep -qi 'Obsidian' README.md \
  && ok "README documents the Obsidian graph view" || bad "README missing the Obsidian section"

hdr "21 · project-scoped enablement is the default on plugin installs"
sc=".claude/skills/setup/scaffold.md"
scflat="$(tr '\n' ' ' < "$sc")"   # flatten so word-wrapped phrases still match
{ grep -q 'extraKnownMarketplaces' "$sc" && grep -q 'enabledPlugins' "$sc" \
  && grep -q '"ticketwright@ticketwright": true' "$sc" && grep -q '"autoUpdate": true' "$sc" \
  && grep -qi 'formal release' <<<"$scflat"; } \
  && ok "setup/scaffold.md documents the project-scoped enablement block (autoUpdate, release-gated)" \
  || bad "setup/scaffold.md must document extraKnownMarketplaces + enabledPlugins + autoUpdate (release-gated)"
python3 - "$sc" <<'PY' && ok "enablement snippet is valid JSON, targets kyle-chalmers/ticketwright, autoUpdate on" || bad "enablement snippet in scaffold.md is malformed / wrong repo"
import json, re, sys
t = open(sys.argv[1]).read()
m = re.search(r'```json\s*(\{.*?"enabledPlugins".*?\})\s*```', t, re.S)
if not m: sys.exit(1)
d = json.loads(m.group(1))
mk = d["extraKnownMarketplaces"]["ticketwright"]
ok = (mk["source"] == {"source": "url", "url": "https://github.com/kyle-chalmers/ticketwright.git"}
      and mk["autoUpdate"] is True
      and d["enabledPlugins"]["ticketwright@ticketwright"] is True)
sys.exit(0 if ok else 1)
PY
grep -qi 'project-scoped' README.md \
  && ok "README documents the project-scoped install as the team default" || bad "README missing the project-scoped section"

hdr "22 · Obsidian graph config (.obsidian/graph.json)"
GC="$TMP/graphcfg"; mkdir -p "$GC/.claude/config" "$GC/tickets/a/ENG-1" "$GC/tickets/a/ENG-2"
printf 'project:\n  key_prefix: ENG\n' > "$GC/.claude/config/stack.yaml"
printf '# ENG-1: base\n\nx.\n' > "$GC/tickets/a/ENG-1/README.md"; printf 'SELECT * FROM ANALYTICS.VW_LOAN;\n' > "$GC/tickets/a/ENG-1/q.sql"
printf '# ENG-2: follow-up to ENG-1\n\nx.\n' > "$GC/tickets/a/ENG-2/README.md"; printf 'SELECT * FROM ANALYTICS.VW_LOAN;\n' > "$GC/tickets/a/ENG-2/q.sql"
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
python3 - "$GC/.obsidian/graph.json" <<'PY' && ok "graph.json created: valid JSON, tickets↔objects filter + 2 color groups" || bad "graph.json missing/malformed on create"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["search"] == 'path:"tickets/graph/" OR path:"tickets/objects/"', c["search"]
qs = [g["query"] for g in c["colorGroups"]]
assert 'path:"tickets/graph/"' in qs and 'path:"tickets/objects/"' in qs, qs
for g in c["colorGroups"]:
    assert isinstance(g["color"].get("rgb"), int) and "a" in g["color"], g
PY
# non-clobber merge: user forces + custom filter + custom color group all survive; ours stay present
python3 - "$GC/.obsidian/graph.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["search"] = "tag:#important"; c["scale"] = 0.1234; c["repelStrength"] = 42
c["colorGroups"].append({"query": "path:docs/", "color": {"a": 1, "rgb": 111}})
json.dump(c, open(p, "w"), indent=2)
PY
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
python3 - "$GC/.obsidian/graph.json" <<'PY' && ok "merge preserves user filter/forces + their color group (nothing clobbered)" || bad "merge clobbered a manual graph customization"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["search"] == "tag:#important", c["search"]
assert c["scale"] == 0.1234 and c["repelStrength"] == 42
qs = [g["query"] for g in c["colorGroups"]]
assert "path:docs/" in qs, qs
assert 'path:"tickets/graph/"' in qs and 'path:"tickets/objects/"' in qs, qs
PY
# re-create: user clears the filter + deletes our groups → renderer restores them, keeps user's group
python3 - "$GC/.obsidian/graph.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["search"] = ""
c["colorGroups"] = [g for g in c["colorGroups"] if g["query"] == "path:docs/"]
json.dump(c, open(p, "w"), indent=2)
PY
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
python3 - "$GC/.obsidian/graph.json" <<'PY' && ok "re-creates the filter + color groups when cleared/deleted (keeps user's group)" || bad "did not re-create managed filter/groups"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["search"] == 'path:"tickets/graph/" OR path:"tickets/objects/"', c["search"]
qs = [g["query"] for g in c["colorGroups"]]
assert 'path:"tickets/graph/"' in qs and 'path:"tickets/objects/"' in qs and "path:docs/" in qs, qs
PY
cp "$GC/.obsidian/graph.json" "$TMP/gc_before"
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
cmp -s "$TMP/gc_before" "$GC/.obsidian/graph.json" \
  && ok "graph.json write is idempotent (no churn on a no-op re-run)" || bad "graph.json changed on a no-op re-run"
cp "$GC/.obsidian/graph.json" "$TMP/gc_off_before"
printf 'project:\n  key_prefix: ENG\n  graph_config: false\n' > "$GC/.claude/config/stack.yaml"
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
cmp -s "$TMP/gc_off_before" "$GC/.obsidian/graph.json" \
  && ok "graph_config: false leaves .obsidian/graph.json untouched" || bad "graph_config: false still wrote graph.json"
printf 'project:\n  key_prefix: ENG\n' > "$GC/.claude/config/stack.yaml"
printf 'not json {{{' > "$GC/.obsidian/graph.json"
CLAUDE_PROJECT_DIR="$GC" python3 bin/build_ticket_index.py >/dev/null 2>&1
grep -q 'not json' "$GC/.obsidian/graph.json" \
  && ok "never overwrites an unparseable graph.json (it's the user's)" || bad "overwrote an unparseable graph.json"
grep -q 'graph_config' .claude/config/stack.schema.md \
  && ok "graph_config documented in stack.schema.md" || bad "graph_config not documented in stack.schema.md"
grep -q '\.obsidian/graph\.json' docs/ticket-index.md \
  && ok "docs/ticket-index.md documents the auto-configured Graph view" || bad "docs/ticket-index.md missing .obsidian/graph.json"

hdr "23 · README locator (nested) + orphan store hygiene"
# (A) A ticket whose README lives in a configured subdir (final_deliverables/) — not the root — must
# still be located, enriched-capable, and LINKED at its real path (was falsely reported un-enriched).
NR="$TMP/nested"; mkdir -p "$NR/.claude/config" "$NR/tickets/alice/ENG-1/final_deliverables" "$NR/tickets/alice/ENG-2"
cat > "$NR/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
  ticket_subdirs: [source_materials, final_deliverables, qc_queries]
EOF
printf '# ENG-1: Nested readme\n\nDelivered in a subfolder; the README is not at the ticket root.\n' > "$NR/tickets/alice/ENG-1/final_deliverables/README.md"
CLAUDE_PROJECT_DIR="$NR" python3 bin/build_ticket_index.py >/dev/null 2>&1
grep -q '(alice/ENG-1/final_deliverables/README.md)' "$NR/tickets/INDEX.md" 2>/dev/null \
  && ok "locates a README nested in a configured subdir + links its real path" \
  || bad "nested README not located/linked" "$(grep 'ENG-1' "$NR/tickets/INDEX.md" 2>/dev/null)"
nrl="$(CLAUDE_PROJECT_DIR="$NR" python3 bin/build_ticket_index.py --stats 2>&1 | grep -i 'no README')"
{ grep -q 'ENG-2' <<<"$nrl" && ! grep -q 'ENG-1' <<<"$nrl"; } \
  && ok "--stats flags 'no README anywhere' (ENG-2) but not the nested-README ticket (ENG-1)" \
  || bad "--stats no-README classification wrong" "$nrl"
# (E) A curated record with no folder on disk must stay out of INDEX.md, be surfaced by --stats, and
# be removed by --prune (silent store<->disk drift otherwise erodes the catalog).
OR="$TMP/orphan"; mkdir -p "$OR/.claude/config" "$OR/tickets/dana/ENG-1"
printf 'project:\n  key_prefix: ENG\n' > "$OR/.claude/config/stack.yaml"
printf '# ENG-1: real\n\nreal ticket.\n' > "$OR/tickets/dana/ENG-1/README.md"
printf '%s' '{"schema_version":1,"tickets":[{"id":"ENG-1","owner":"dana","title":"real","status":"Completed","summary":"real ticket."},{"id":"ENG-99","owner":"dana","title":"ghost","status":"Completed","summary":"folder gone."}]}' > "$OR/tickets/index_data.json"
CLAUDE_PROJECT_DIR="$OR" python3 bin/build_ticket_index.py >/dev/null 2>&1
grep -q 'ENG-99' "$OR/tickets/INDEX.md" 2>/dev/null && bad "orphan record leaked into INDEX.md" || ok "orphan record stays out of INDEX.md (folder-driven catalog)"
sto="$(CLAUDE_PROJECT_DIR="$OR" python3 bin/build_ticket_index.py --stats 2>&1)"
{ grep -qi 'orphan' <<<"$sto" && grep -q 'ENG-99' <<<"$sto"; } \
  && ok "--stats surfaces the orphan record" || bad "--stats did not surface the orphan" "$sto"
CLAUDE_PROJECT_DIR="$OR" python3 bin/build_ticket_index.py --prune >/dev/null 2>&1
pr="$(python3 -c "import json; print(','.join(x['id'] for x in json.load(open('$OR/tickets/index_data.json'))['tickets']))")"
[ "$pr" = "ENG-1" ] && ok "--prune drops the orphan record, keeps the real one" || bad "--prune result wrong" "kept=$pr"

hdr "24 · multi-target warehouse seam (default: + targets:)"
MT=".claude/config/stack.example.multi-warehouse.yaml"
mtout="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$MT" --dry-run 2>&1)"; mtrc=$?
{ [ "$mtrc" -eq 0 ] && grep -q 'All seams OK' <<<"$mtout"; } \
  && ok "multi-warehouse example resolves" || bad "multi-warehouse example does not resolve" "$mtout"
[ "$(grep -c '▸ warehouse\[' <<<"$mtout")" -eq 2 ] \
  && ok "both warehouse targets get their own row" || bad "expected exactly 2 target rows" "$mtout"
grep -q '▸ warehouse\[prod\]\*' <<<"$mtout" \
  && ok "the default target is marked with *" || bad "default marker missing (default: pointer not read)" "$mtout"
# Each target's verify interpolates ITS OWN tokens, not a sibling's.
grep -q 'databricks --profile DEFAULT current-user me' <<<"$mtout" \
  && ok "target verify interpolates that target's own tokens" || bad "target token scoping wrong" "$mtout"
# Single-mapping stacks must still produce exactly one un-bracketed warehouse row.
for s in .claude/config/stack.yaml .claude/config/stack.example.asana-bq.yaml .claude/config/stack.example.azure.yaml; do
  o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$s" --dry-run 2>&1)"
  { [ "$(grep -c '▸ warehouse ' <<<"$o")" -eq 1 ] && ! grep -q '▸ warehouse\[' <<<"$o"; } \
    && ok "$(basename "$s"): still one plain warehouse row" || bad "$(basename "$s") regressed to target rows" "$o"
done

# --- fail closed on an unusable targets: block ---------------------------------------------------
mtstack() { local d="$TMP/mt-$1"; mkdir -p "$d"; cat > "$d/stack.yaml"; printf '%s' "$d/stack.yaml"; }
f="$(mtstack nodefault <<'YAML'
project: {key_prefix: ENG}
seams:
  warehouse:
    targets:
      prod: {tool: snowflake, adapter: adapters/warehouse/snowflake.md, verify: "true"}
YAML
)"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q "no 'default:'" <<<"$o"; } \
  && ok "targets: without default: fails closed" || bad "missing default: was accepted" "$o"
f="$(mtstack baddefault <<'YAML'
project: {key_prefix: ENG}
seams:
  warehouse:
    default: nope
    targets:
      prod: {tool: snowflake, adapter: adapters/warehouse/snowflake.md, verify: "true"}
YAML
)"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q "not one of the defined targets" <<<"$o"; } \
  && ok "default: naming an unknown target fails closed" || bad "bad default: was accepted" "$o"
# …and doesn't also emit the (meaningless) ordering warning for a name that doesn't exist.
grep -q 'is not the first target' <<<"$o" \
  && bad "bad default: also emitted a bogus ordering warning" "$o" \
  || ok "bad default: reports one clear error, not two"

# --- seam-level scalars are inherited; a target's own key wins -----------------------------------
f="$(mtstack inherit <<'YAML'
project: {key_prefix: ENG}
seams:
  warehouse:
    default: prod
    cli: snow
    pii_role: SHARED
    targets:
      prod:
        tool: snowflake
        adapter: adapters/warehouse/snowflake.md
        verify: "echo cli={cli} role={pii_role}"
      sandbox:
        tool: snowflake
        adapter: adapters/warehouse/snowflake.md
        pii_role: OWN
        verify: "echo cli={cli} role={pii_role}"
YAML
)"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"
grep -q 'echo cli=snow role=SHARED' <<<"$o" \
  && ok "seam-level scalars are inherited by a target" || bad "seam-level inheritance broken" "$o"
grep -q 'echo cli=snow role=OWN' <<<"$o" \
  && ok "a target's own key overrides the seam's" || bad "target override lost to the seam default" "$o"

# tool/adapter/verify inherit too, so two targets on one account can share all three and differ
# only in (say) default_warehouse. Keyed on absence: an explicit `verify: null` still means "skip".
f="$(mtstack opinherit <<'YAML'
project: {key_prefix: ENG}
seams:
  warehouse:
    default: prod
    tool: snowflake
    adapter: adapters/warehouse/snowflake.md
    verify: "echo shared wh={default_warehouse}"
    targets:
      prod: {default_warehouse: PROD_WH}
      sandbox: {default_warehouse: SBX_WH}
      mcponly: {verify: null}
YAML
)"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"
{ grep -q 'echo shared wh=PROD_WH' <<<"$o" && grep -q 'echo shared wh=SBX_WH' <<<"$o"; } \
  && ok "seam-level tool/adapter/verify are inherited by targets" || bad "operational fields not inherited (target shows tool=? / adapter missing)" "$o"
! grep -q 'warehouse\[mcponly\].*would run' <<<"$o" \
  && ok "an explicit 'verify: null' target does not inherit the seam's verify" || bad "verify: null wrongly inherited the seam command" "$o"

# --- display readers surface every target -------------------------------------------------------
MTP="$TMP/mtproj"; mkdir -p "$MTP/.claude/config"
cp "$MT" "$MTP/.claude/config/stack.yaml"
o="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$MTP" python3 .claude/hooks/session_context.py 2>&1)"
grep -q 'warehouse=snowflake+databricks' <<<"$o" \
  && ok "session banner lists both targets (default first)" || bad "banner hides a warehouse target" "$o"
o="$(echo '{}' | CLAUDE_PROJECT_DIR="$MTP" bash .claude/statusline.sh 2>&1)"
grep -q 'snowflake+databricks' <<<"$o" \
  && ok "statusline lists both targets" || bad "statusline hides a warehouse target" "$o"
# Non-default default: pointer must reorder the banner, so it never implies the wrong active target.
sed 's/default: prod/default: lake/' "$MT" > "$MTP/.claude/config/stack.yaml"
o="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$MTP" python3 .claude/hooks/session_context.py 2>&1)"
grep -q 'warehouse=databricks+snowflake' <<<"$o" \
  && ok "banner puts the DEFAULT target first, not the file's first" || bad "banner ignores the default: pointer" "$o"

printf "\n\033[1mselftest: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
