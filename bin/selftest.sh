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

# The config resolver consults ${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright for the cross-repo
# tier-2 copy and the user-level viewer config. Without this line every fixture below would read the
# CONTRIBUTOR'S OWN ~/.config, so the suite would pass or fail depending on whose machine it ran on.
# Sections that exercise resolution order still override it per invocation.
export XDG_CONFIG_HOME="$TMP/xdg-home"
mkdir -p "$XDG_CONFIG_HOME"

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
    tracker) echo 7;; warehouse) echo 3;; chat) echo 4;; docstore) echo 2;; vcs) echo 4;;
    viewer) echo 2;; *) echo 0;;
  esac
}
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  seam="$(basename "$(dirname "$f")")"; want="$(verbs_expected "$seam")"
  got="$(grep -c '^## verb:' "$f")"
  [ "$got" -eq "$want" ] && ok "$f ($got/$want verbs)" || bad "$f has $got verbs, expected $want"
done

# Counting headings proves each adapter has the RIGHT NUMBER of verbs, not the RIGHT ONES: a typo'd
# `rank_project_by_activity` still counts, still passes, and is still outside the contract every
# skill calls. `local` has had a name check since it shipped (section 27); the newest verb gets one
# across the whole seam, because it is the one verb added after six adapters were already written.
rp_miss=""
for f in adapters/tracker/*.md; do
  grep -q '^## verb: rank_projects_by_activity$' "$f" || rp_miss="$rp_miss $(basename "$f")"
done
[ -z "$rp_miss" ] && ok "every tracker adapter names rank_projects_by_activity exactly" \
  || bad "tracker adapter(s) miss or misspell rank_projects_by_activity" "$rp_miss"
# The bootstrap verb declares which config key a ranked container fills, per-adapter (the `dev_key:`
# precedent). Every adapter that CAN rank must declare it, or setup has a ranking it cannot apply.
ck_miss=""
for f in adapters/tracker/*.md; do
  [ "$(basename "$f")" = "local.md" ] && continue      # unsupported: nothing to fill
  grep -q '^container_key: ' "$f" || ck_miss="$ck_miss $(basename "$f")"
done
[ -z "$ck_miss" ] && ok "ranking tracker adapters declare container_key" \
  || bad "tracker adapter(s) rank without declaring container_key" "$ck_miss"

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
# The CLI grep above catches `snow sql` but not a warehouse's PRODUCT NAME in prose — two skills
# carried "works on Snowflake, BigQuery, Databricks" while claiming to be tool-neutral. Naming a
# product in a skill is the same leak: it silently scopes the skill to one vendor's stack.
# The CLI-detection probe in `setup` is a sanctioned exception (adapters/README.md) — it has to name
# CLIs in order to detect them, exactly as the tool-name grep above exempts it.
prodleaks="$(grep -REn -i 'snowflake|bigquery|databricks|redshift|synapse' \
              .claude/skills .claude/commands .claude/agents 2>/dev/null \
              | grep -v 'for c in snow acli gh' || true)"
[ -z "$prodleaks" ] && ok "no warehouse product name appears in a skill/command/agent" \
  || bad "a skill names a specific warehouse product (scopes a tool-neutral skill to one vendor)" "$prodleaks"
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
warehouse_adapter=`adapters/warehouse/snowflake.md`
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

# Wrong-warehouse detection: right SQL, wrong target. A READ is gated too, because it returns
# plausible numbers about the wrong system rather than erroring — the failure mode this feature
# introduces. Only a CONFIRMED mismatch gates; an unknown name must never manufacture a prompt.
d="$(gstack wrongwh <<'YAML'
seams:
  warehouse:
    default: prod
    targets:
      prod: {tool: snowflake, cli: snow}
      lake: {tool: databricks, cli: dbsqlcli}
YAML
)"
printf -- '-- warehouse-target: lake\nSELECT 1;\n' > "$d/q.sql"
out="$(gask "snow sql -f $d/q.sql" "$d")"
grep -q 'wrong warehouse' <<<"$out" \
  && ok "a read against the wrong target is gated (mismatched -- warehouse-target: header)" \
  || bad "SQL declaring one target ran on another with no prompt" "$out"
printf -- '-- warehouse-target: prod\nSELECT 1;\n' > "$d/ok.sql"
out="$(gask "snow sql -f $d/ok.sql" "$d")"
! grep -q 'wrong warehouse' <<<"$out" && ok "a matching target header raises no wrong-warehouse prompt" || bad "matching target wrongly gated" "$out"
printf -- '-- warehouse-target: typo\nSELECT 1;\n' > "$d/typo.sql"
out="$(gask "snow sql -f $d/typo.sql" "$d")"
! grep -q 'wrong warehouse' <<<"$out" && ok "an unknown target name invents no mismatch" || bad "an unresolvable target name produced a prompt" "$out"
# A single-warehouse repo has no targets, so a stray header must not resolve to the seam's own cli.
d1="$(gstack wrongwh1 <<'YAML'
seams:
  warehouse:
    tool: snowflake
    cli: snow
YAML
)"
printf -- '-- warehouse-target: lake\nSELECT 1;\n' > "$d1/q.sql"
out="$(gask "snow sql -f $d1/q.sql" "$d1")"
! grep -q 'wrong warehouse' <<<"$out" && ok "single-warehouse repo: a stray target header changes nothing" \
  || bad "a single-mapping seam resolved an undefined target and gated" "$out"
# A quoted scalar is valid YAML. Leaving the quotes attached made every comparison mismatch, i.e. a
# false prompt on a correct command — the worst outcome for a guard, since dismissed prompts stop working.
dq="$(gstack quotedcli <<'YAML'
seams:
  warehouse:
    default: prod
    targets:
      prod: {tool: snowflake, cli: "snow"}
      lake: {tool: databricks, cli: 'dbsqlcli'}
YAML
)"
printf -- '-- warehouse-target: prod\nSELECT 1;\n' > "$dq/ok.sql"
out="$(gask "snow sql -f $dq/ok.sql" "$dq")"
! grep -q 'wrong warehouse' <<<"$out" && ok "a quoted cli: value doesn't false-gate a correct command" \
  || bad "quoted YAML scalars produced a bogus wrong-warehouse prompt" "$out"
printf -- '-- warehouse-target: lake\nSELECT 1;\n' > "$dq/bad.sql"
out="$(gask "snow sql -f $dq/bad.sql" "$dq")"
grep -q 'wrong warehouse' <<<"$out" && ok "a quoted cli: value still catches a real mismatch" \
  || bad "quoting the cli hid a real mismatch" "$out"
# Exotic YAML the stdlib scan doesn't read must fall through to NO gate, never to a guess.
for shape in flowtargets aliastarget; do
  case "$shape" in
    flowtargets) y='seams:
  warehouse:
    cli: snow
    targets: {prod: {cli: snow}, lake: {cli: dbsqlcli}}' ;;
    aliastarget) y='seams:
  warehouse:
    cli: snow
    targets:
      lake: *shared' ;;
  esac
  dx="$TMP/exotic-$shape"; mkdir -p "$dx/.claude/config"
  printf '%s\n' "$y" > "$dx/.claude/config/stack.yaml"
  printf -- '-- warehouse-target: lake\nSELECT 1;\n' > "$dx/q.sql"
  out="$(gask "snow sql -f $dx/q.sql" "$dx")"
  ! grep -q 'wrong warehouse' <<<"$out" && ok "unparseable target form ($shape) falls through to no gate, not a guess" \
    || bad "an unread YAML form produced a wrong-warehouse prompt ($shape)" "$out"
done

# Inheritance: two targets sharing one seam-level cli must both resolve to it.
d2="$(gstack wrongwh2 <<'YAML'
seams:
  warehouse:
    default: prod
    cli: snow
    targets:
      prod: {tool: snowflake, default_warehouse: P}
      sbx:  {tool: snowflake, default_warehouse: S}
YAML
)"
printf -- '-- warehouse-target: sbx\nSELECT 1;\n' > "$d2/q.sql"
out="$(gask "snow sql -f $d2/q.sql" "$d2")"
! grep -q 'wrong warehouse' <<<"$out" && ok "targets inheriting one seam-level cli don't false-positive" \
  || bad "seam-level cli inheritance produced a bogus mismatch" "$out"

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
printf '# ENG-1: Order feed base\n\nbase pull.\n' > "$R/tickets/dana/ENG-1/README.md"
printf 'SELECT * FROM BI.ANALYTICS.VW_ORDERS;\n' > "$R/tickets/dana/ENG-1/q.sql"
printf '# ENG-2: Order feed follow-up\n\nFollow-on to ENG-1.\n' > "$R/tickets/dana/ENG-2/README.md"
printf 'SELECT * FROM BI.ANALYTICS.VW_ORDERS;\n' > "$R/tickets/dana/ENG-2/q.sql"
printf '# ENG-3: Sensor uptime metrics\n\nunrelated work.\n' > "$R/tickets/dana/ENG-3/README.md"
printf 'SELECT * FROM BI.OPS.VW_SENSOR;\n' > "$R/tickets/dana/ENG-3/q.sql"
printf 'from os.path import join\nimport collections.abc\n' > "$R/tickets/dana/ENG-3/munge.py"  # must NOT be indexed
CLAUDE_PROJECT_DIR="$R" python3 bin/build_ticket_index.py >/dev/null 2>&1
if grep 'VW_ORDERS' "$R/tickets/OBJECTS.md" 2>/dev/null | grep -q 'ENG-1' && grep 'VW_ORDERS' "$R/tickets/OBJECTS.md" | grep -q 'ENG-2'; then
  ok "OBJECTS.md maps shared object → both tickets"; else bad "OBJECTS.md reverse map wrong" "$(cat "$R/tickets/OBJECTS.md" 2>/dev/null)"; fi
CLAUDE_PROJECT_DIR="$R" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 && ok "--check covers INDEX.md + OBJECTS.md" || bad "--check failed after render"
rj="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --for ENG-1 --json 2>/dev/null)"
top="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$rj")"
ids="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(','.join(x['id'] for x in d))" <<<"$rj")"
[ "$top" = "ENG-2" ] && ok "recall ranks the related ticket first (ENG-2)" || bad "recall mis-ranked" "top=$top ids=$ids"
grep -q 'ENG-3' <<<"$ids" && bad "recall surfaced the unrelated ticket (ENG-3)" || ok "recall excludes the unrelated ticket"
rl="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --object BI.ANALYTICS.VW_ORDERS --json 2>/dev/null | python3 -c "import json,sys; print(sorted(x['id'] for x in json.load(sys.stdin)))")"
[ "$rl" = "['ENG-1', 'ENG-2']" ] && ok "recall --object reverse lookup → ENG-1, ENG-2" || bad "reverse lookup wrong" "$rl"
# regression: unqualified --object must leaf-match the qualified stored object
ul="$(CLAUDE_PROJECT_DIR="$R" python3 bin/recall.py --object VW_ORDERS --json 2>/dev/null | python3 -c "import json,sys; print(sorted(x['id'] for x in json.load(sys.stdin)))")"
[ "$ul" = "['ENG-1', 'ENG-2']" ] && ok "recall --object leaf match (unqualified VW_ORDERS → ENG-1, ENG-2)" || bad "leaf-match lookup wrong" "$ul"
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
printf '# ENG-5: alice inventory sync\n\nshared inventory sync order feed work.\n' > "$M/tickets/alice/ENG-5/README.md"
printf '# ENG-5: bob inventory sync\n\nshared inventory sync order feed work.\n' > "$M/tickets/bob/ENG-5/README.md"
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
    || bad "non-fixture ticket ids in the tracked store — committed ids must use ENG-/DEMO-/TEST-/SAMPLE-" "$realids"
else
  ok "tickets/index_data.json is gitignored (a private store can't be committed)"
fi
[ -f tickets/index_data.example.json ] && ok "index_data.example.json shipped as the schema reference" \
  || bad "tickets/index_data.example.json missing"

# (13b) Fixture vocabulary stays in the kit's invented orders/inventory domain. A public kit's
# examples must read as obviously invented — industry-specific vocabulary (finance, insurance,
# healthcare terms, or a vendor product name that isn't a supported adapter) appearing in a
# fixture or doc is a leak, not a naming preference.
domainre='(^|[^a-z])(loan|borrower|delinquen|charge.?off|fico|underwrit|servicing|disburse|repayment|payoff|lender|policyholder|claimant|patient|diagnos[ei]s|genesys|talkdesk|five9|(dpd|refi)([^a-z]|$))'
dleak="$(grep -rIinE "$domainre" \
          --include='*.md' --include='*.yaml' --include='*.py' --include='*.sh' \
          --include='*.tmpl' --include='*.json' \
          README.md docs bin adapters templates .claude tickets/index_data.example.json 2>/dev/null \
        | grep -viE 'download|upload|reload|preload|standalone|payload' \
        | grep -v 'domainre=' || true)"
[ -z "$dleak" ] && ok "no business-domain vocabulary in fixtures, docs, or the kit" \
  || bad "domain vocabulary leaked into the public kit (fixtures must be generic)" "$dleak"

hdr "14 · scrub + structure (public-kit hygiene)"
# scrub: generic secret / PII patterns must not appear in tracked kit files (selftest excluded — it
# carries the patterns themselves).
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
        # A flow node must be the WHOLE value (only trailing whitespace). Spell the quote set as a
        # tuple of one-char literals, never as a single string literal holding an escaped quote.
        # Reason: bash 3.2 lexes heredoc bodies while scanning a command substitution for its
        # closing paren, so an escaped quote in here leaves the shell quote-unbalanced for the
        # WHOLE REST OF THE FILE. The suite then died mid-run on macOS system bash while CI bash 5
        # parsed the same file fine. Keep this block free of stray quote and backtick characters.
        # The tuple also fixes a latent IndexError: an empty value is a substring of any string, so
        # the old membership test passed for it and then crashed indexing position 0.
        if v[:1] in ('[', '"', "'"):
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
  # *.local.yaml is per-user and gitignored (viewer.local.yaml), so it is never shipped and
  # must not demand a force-include line — otherwise this check fails for exactly the people
  # who configured a viewer, which is the feature working as intended.
  case "$f" in *.local.yaml) continue ;; esac
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
# E6 — adapter examples stay org-neutral: any ticket key shown in an adapter doc must use a
# fixture prefix (ENG/DEMO/TEST/SAMPLE), never a project key copied from a live tracker.
leak="$(python3 - <<'PY'
import pathlib, re
pat = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-\d+\b")
allow = {"ENG", "DEMO", "TEST", "SAMPLE", "UTF", "SHA", "ISO", "RFC", "CVE", "PEP", "SOC"}
hits = []
for f in sorted(pathlib.Path("adapters").rglob("*.md")):
    for n, ln in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        hits += [f"{f}:{n}:{m.group(0)}" for m in pat.finditer(ln) if m.group(1) not in allow]
print("\n".join(hits))
PY
)"
[ -z "$leak" ] && ok "adapter examples use fixture ticket keys only" \
  || bad "non-fixture ticket key in an adapter (public plugin!)" "$leak"
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
# E12 — every shipped shell script PARSES under the running bash. The kit targets bash 3.2 (macOS
# system bash), and 3.2 lexes heredoc bodies while scanning a command substitution: one escaped
# quote inside a python heredoc silently unbalanced the shell for the rest of the file. selftest
# itself died mid-run on macOS while CI's bash 5 stayed green, so half the suite stopped running
# with nothing to show for it. Parse-check on the CURRENT interpreter catches that class on the
# machine that has the old bash, which is exactly where it matters.
parse_bad=""
# bin/tw is deliberately extensionless (skills read `bin/tw <script>`), so the *.sh glob misses it —
# and it is the one script every migrated skill now depends on.
for s in bin/*.sh bin/tw .claude/statusline.sh templates/productized-skill/bin/*.sh; do
  [ -f "$s" ] || continue
  bash -n "$s" 2>/dev/null || parse_bad="$parse_bad $s"
done
[ -z "$parse_bad" ] && ok "every shipped .sh parses under bash $BASH_VERSION" \
  || bad "a shipped shell script does not parse under bash $BASH_VERSION:$parse_bad"

hdr "21 · Obsidian graph layer (tickets/graph/ + tickets/objects/)"
GX="$TMP/graph"; mkdir -p "$GX/.claude/config" "$GX/tickets/alice/ENG-1" "$GX/tickets/alice/ENG-2" "$GX/tickets/bob/ENG-3"
printf 'project:\n  key_prefix: ENG\n' > "$GX/.claude/config/stack.yaml"
printf '# ENG-1: Order feed base\n\nbase.\n' > "$GX/tickets/alice/ENG-1/README.md"
printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GX/tickets/alice/ENG-1/q.sql"
printf '# ENG-2: Order feed follow-up to ENG-1\n\nsee ENG-1.\n' > "$GX/tickets/alice/ENG-2/README.md"
printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GX/tickets/alice/ENG-2/q.sql"
printf '# ENG-3: Unrelated\n\nx.\n' > "$GX/tickets/bob/ENG-3/README.md"
printf 'SELECT * FROM OPS.VW_CALL;\n' > "$GX/tickets/bob/ENG-3/q.sql"
CLAUDE_PROJECT_DIR="$GX" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ -f "$GX/tickets/graph/ENG-1.md" ] && [ -f "$GX/tickets/graph/ENG-2.md" ] && [ -f "$GX/tickets/graph/ENG-3.md" ]; } \
  && ok "graph stubs generated (one per ticket)" || bad "graph stubs missing"
{ [ -f "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md" ] && [ -f "$GX/tickets/objects/OPS.VW_CALL.md" ]; } \
  && ok "object notes generated (one per object)" || bad "object notes missing"
{ grep -q '(../graph/ENG-1.md)' "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md" \
  && grep -q '(../graph/ENG-2.md)' "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md"; } \
  && ok "object note links the ticket stubs (VW_ORDERS -> ENG-1, ENG-2)" || bad "object note not linking stubs"
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
grep -q '(../objects/ANALYTICS.VW_ORDERS.md)' "$GX/tickets/graph/ENG-1.md" \
  && ok "stub links its object notes (../objects/...)" || bad "stub does not link objects"
mkdir -p "$GX/tickets/alice/ENG-20"
printf '# ENG-20: hook test\n\nx.\n' > "$GX/tickets/alice/ENG-20/README.md"
printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GX/tickets/alice/ENG-20/q.sql"
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

hdr "21b · project-scoped enablement is the default on plugin installs"
sc=".claude/skills/setup/scaffold.md"
scflat="$(tr '\n' ' ' < "$sc")"   # flatten so word-wrapped phrases still match
{ grep -q 'extraKnownMarketplaces' "$sc" && grep -q 'enabledPlugins' "$sc" \
  && grep -q '"ticketwright@ticketwright": true' "$sc" && grep -q '"autoUpdate": true' "$sc" \
  && grep -qi 'formal release' <<<"$scflat"; } \
  && ok "setup/scaffold.md documents the project-scoped enablement block (autoUpdate, release-gated)" \
  || bad "setup/scaffold.md must document extraKnownMarketplaces + enabledPlugins + autoUpdate (release-gated)"
{ grep -qi 'merge' <<<"$scflat" && grep -qi 'never overwrite' <<<"$scflat" \
  && grep -qi 'keep its .source. exactly as written' <<<"$scflat"; } \
  && ok "setup/scaffold.md tells setup to MERGE the enablement (preserve an existing source, not overwrite)" \
  || bad "setup/scaffold.md must tell setup to merge (preserve existing source/autoUpdate), never overwrite"
python3 - "$sc" README.md <<'PY' && ok "enablement snippet is valid JSON, source is the CLI-written git form, autoUpdate on, README block agrees" || bad "enablement snippet malformed / wrong source discriminator / README block disagrees with scaffold.md"
import json, re, sys

# The canonical marketplace source: exactly what `claude plugin marketplace add <https://...git>`
# writes itself. Asserted LITERALLY, not just "both docs agree" -- equality alone would let both
# files drift to the same wrong value, which is how the earlier `"source": "url"` bug survived.
CANON = {"source": "git", "url": "https://github.com/kyle-chalmers/ticketwright.git"}

def enablement_block(path, fence, after=None):
    """Pull the enablement block out by its FENCE LABEL, optionally only from the section
    starting at `after`. Both guards matter: the Quickstart's first fenced block is bash, so
    'first fence' logic grabs the wrong one, and without `after` an unrelated earlier json
    fence could be validated in place of the real thing."""
    t = open(path).read()
    if after is not None:
        i = t.find(after)
        if i == -1:
            print("no %r section in %s" % (after, path), file=sys.stderr)
            sys.exit(1)
        t = t[i:]
    # [^`]* keeps the match inside ONE fenced block -- a `.*?` here could span from an
    # earlier fence into a later block and silently validate the wrong snippet.
    m = re.search(r'```' + fence + r'\n([^`]*?"enabledPlugins"[^`]*)```', t, re.S)
    if not m:
        print("no ```%s enablement block in %s" % (fence, path), file=sys.stderr)
        sys.exit(1)
    return json.loads(m.group(1))   # strict JSON: no comments, no trailing commas

scaffold = enablement_block(sys.argv[1], "json")
# Anchored to the section that documents the committed block, so an unrelated json fence
# elsewhere in the README can never stand in for it.
readme = enablement_block(sys.argv[2], "json", after="### Project-scoped by default")
for label, d in (("scaffold.md", scaffold), ("README.md", readme)):
    mk = d["extraKnownMarketplaces"]["ticketwright"]
    if mk["source"] != CANON:
        print("%s: marketplace source is %s, expected %s" % (label, mk["source"], CANON), file=sys.stderr)
        sys.exit(1)
    if mk.get("autoUpdate") is not True or d["enabledPlugins"]["ticketwright@ticketwright"] is not True:
        print("%s: autoUpdate/enabledPlugins not both true" % label, file=sys.stderr)
        sys.exit(1)
PY
grep -qi 'project-scoped' README.md \
  && ok "README documents the project-scoped install as the team default" || bad "README missing the project-scoped section"
# The Quickstart must actually PRODUCE a project-scoped install. Match the two specific command
# lines, not incidental occurrences of the flag elsewhere in the file.
{ grep -qE '^claude plugin marketplace add https://github\.com/kyle-chalmers/ticketwright\.git --scope project$' README.md \
  && grep -qE '^claude plugin install ticketwright@ticketwright --scope project$' README.md; } \
  && ok "README Quickstart installs at project scope (--scope project on both commands)" \
  || bad "README Quickstart must pass --scope project to BOTH marketplace add and plugin install (both default to user scope)"

hdr "22 · Obsidian graph config (.obsidian/graph.json)"
GC="$TMP/graphcfg"; mkdir -p "$GC/.claude/config" "$GC/tickets/a/ENG-1" "$GC/tickets/a/ENG-2"
printf 'project:\n  key_prefix: ENG\n' > "$GC/.claude/config/stack.yaml"
printf '# ENG-1: base\n\nx.\n' > "$GC/tickets/a/ENG-1/README.md"; printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GC/tickets/a/ENG-1/q.sql"
printf '# ENG-2: follow-up to ENG-1\n\nx.\n' > "$GC/tickets/a/ENG-2/README.md"; printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GC/tickets/a/ENG-2/q.sql"
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
# Each target's verify interpolates ITS OWN tokens, not a sibling's — and the token now comes from
# the MACHINE tier, which is the whole point of the three-tier split. The committed example
# deliberately no longer carries `profile:`: a ~/.databrickscfg profile name is machine-local, and
# committing one is the leak this feature exists to remove.
MTT="$TMP/mt-tier3"; mkdir -p "$MTT/.claude/config"
cp "$MT" "$MTT/.claude/config/stack.yaml"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: DEFAULT\n' \
  > "$MTT/.claude/config/connections.local.yaml"
t3out="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$MTT/.claude/config/stack.yaml" --dry-run 2>&1)"
grep -q 'databricks --profile DEFAULT current-user me' <<<"$t3out" \
  && ok "a target's verify token resolves from the machine tier (tier 3)" \
  || bad "tier-3 token did not reach that target's verify" "$t3out"
grep -q 'snow connection test' <<<"$t3out" \
  && ok "the sibling target's tokenless verify is untouched by the overlay" \
  || bad "overlay disturbed a sibling target" "$t3out"
# …and with NO tier-3 file the verify must be SKIPPED, never run with a literal brace. The shell
# interpolation this replaced left `{profile}` in place and ran it verbatim, which reads as broken
# auth rather than as missing config.
grep -q 'unresolved {profile}' <<<"$mtout" \
  && ok "an unresolved {token} is skipped with a pointer, not executed" \
  || bad "unresolved token was not skipped (would run a literal brace)" "$mtout"
! grep -q 'would run: databricks --profile {profile}' <<<"$mtout" \
  && ok "no verify is ever offered with an unresolved token" || bad "a literal {token} reached the command line" "$mtout"
# Single-mapping stacks must still produce exactly one un-bracketed warehouse row.
# Derived, not hardcoded: any config without a `targets:` map is a single-mapping stack and must
# keep producing one plain row. A hardcoded list silently skipped the solo example when it was added.
# Configs with no warehouse seam at all are skipped — they have no row to produce.
for s in $(for f in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
             yq -e '.seams.warehouse' "$f" >/dev/null 2>&1 || continue
             yq -e '.seams.warehouse.targets' "$f" >/dev/null 2>&1 || echo "$f"
           done); do
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
# Two structural checks over every shipped config. yq is the authority for *which* seams have
# targets and what they resolve to — it reads block and flow forms alike, and it can't be fooled by
# an unrelated nested `targets:` elsewhere in the document. Duplicate keys are the one thing yq
# cannot report (it silently keeps the last), so those are counted from the text.
python3 - <<'PY2'
import json, pathlib, re, subprocess, sys, glob

def yq(expr, f):
    r = subprocess.run(["yq", "-o=json", expr, f], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

files = [".claude/config/stack.yaml"] + sorted(glob.glob(".claude/config/stack.example.*.yaml"))
missing_adapter, dupes, dangling = [], [], []

for f in files:
    seams = yq(".seams", f) or {}
    text = pathlib.Path(f).read_text()
    for seam, body in seams.items():
        if not isinstance(body, dict) or "targets" not in body:
            continue
        targets = body.get("targets") or {}
        # A target may INHERIT tool from the seam, so check the effective value, not just its own.
        for name, tgt in targets.items():
            tgt = tgt or {}
            tool = (tgt.get("tool") if isinstance(tgt, dict) else None) or body.get("tool")
            if not tool:
                missing_adapter.append(f"{pathlib.Path(f).name}:{seam}/{name}: no tool (own or inherited)")
            elif not pathlib.Path(f"adapters/{seam}/{tool}.md").is_file():
                missing_adapter.append(f"{pathlib.Path(f).name}:{seam}/{name} -> {tool}")
        # `default:` must name one of them. A missing default is a different assertion's job.
        d = body.get("default")
        if d is not None and d not in targets:
            dangling.append(f"{pathlib.Path(f).name}:{seam}: default '{d}' not in {sorted(targets)}")
        # Duplicate keys: compare yq's collapsed count against the raw keys in the targets region.
        m = re.search(rf"(?m)^([ \t]*){re.escape(seam)}:[ \t]*$", text)
        region = ""
        if m:
            base = len(m.group(1))
            for ln in text[m.end():].splitlines():
                if ln.strip() and (len(ln) - len(ln.lstrip())) <= base:
                    break
                region += ln + "\n"
        tm = re.search(r"(?m)^([ \t]*)targets:[ \t]*(.*)$", region)
        if tm:
            if tm.group(2).strip().startswith("{"):
                raw = len(re.findall(r"[{,]\s*(?:\"[^\"]+\"|'[^']+'|[A-Za-z0-9_.-]+)\s*:", tm.group(2)))
            else:
                tbase, raw, child = len(tm.group(1)), 0, None
                for ln in region[tm.end():].splitlines():
                    if not ln.strip() or ln.lstrip().startswith("#"):
                        continue
                    cur = len(ln) - len(ln.lstrip())
                    if cur <= tbase:
                        break
                    if child is None:
                        child = cur
                    if cur == child and re.match(r"""^\s*(?:"[^"]+"|'[^']+'|[A-Za-z0-9_.-]+)\s*:""", ln):
                        raw += 1
            if raw and raw != len(targets):
                dupes.append(f"{pathlib.Path(f).name}:{seam}: {raw} target keys in the text but "
                             f"{len(targets)} survive — a duplicate name is silently dropped")

out = {"adapter": missing_adapter, "dupes": dupes, "dangling": dangling}
pathlib.Path(".selftest_targets.json").write_text(json.dumps(out))
PY2
tj="$(cat .selftest_targets.json 2>/dev/null || echo '{}')"; rm -f .selftest_targets.json
jqf() { python3 -c "import json,sys;print(' '.join(json.loads(sys.argv[1]).get(sys.argv[2],[])))" "$1" "$2"; }
a="$(jqf "$tj" adapter)"; du="$(jqf "$tj" dupes)"; dg="$(jqf "$tj" dangling)"
[ -z "$a" ] && ok "every named target resolves a tool (own or inherited) with a shipped adapter" \
  || bad "a target's effective tool has no adapter file" "$a"
[ -z "$du" ] && ok "no multi-target seam silently drops a duplicate target name" \
  || bad "duplicate target names — the earlier config is discarded" "$du"
[ -z "$dg" ] && ok "every default: names a target that exists" || bad "a dangling default:" "$dg"

hdr "25 · id_mode: slug (folder name IS the ticket id; no tracker required)"
S="$TMP/slugmode"; mkdir -p "$S/.claude/config" "$S/bin"
cp bin/build_ticket_index.py "$S/bin/"
cat > "$S/.claude/config/stack.yaml" <<'EOF'
project:
  assignee_dir: dana
  id_mode: slug
  ticket_path: "tickets/{assignee}/{id}"
  ticket_url_template: null
EOF
mkdir -p "$S/tickets/dana/signup-funnel-lift-analysis" "$S/tickets/dana/late-shipment-audit" "$S/tickets/dana/notes" "$S/tickets/dana/data-quality"
# Ordinary prose, deliberately loaded with hyphenated words. NONE may become a cross-reference:
# that is the whole reason discovery and reference-resolution can't share one pattern.
cat > "$S/tickets/dana/signup-funnel-lift-analysis/README.md" <<'EOF'
# signup-funnel-lift-analysis: Signup funnel incremental lift

We ran a well-designed hold-out test on the signup-eligible population. The follow-up
data-quality review was end-to-end and covered opt-in state, do-not-contact flags and
long-standing send-time issues. See my notes for the day-by-day breakdown; the
first-touch attribution model is unchanged.
EOF
# Genuine references, in the two explicit forms plus a self-mention that must not count.
cat > "$S/tickets/dana/late-shipment-audit/README.md" <<'EOF'
# late-shipment-audit: Late shipment placement

Follows on from [[signup-funnel-lift-analysis]] and also [[notes]].
Self-link [[late-shipment-audit]] must not become a self-reference.
An escaped \\[[notes]] is literal text, not a link.
Nor is an example in code: `[[signup-funnel-lift-analysis]]`.
EOF
CLAUDE_PROJECT_DIR="$S" python3 bin/build_ticket_index.py >/dev/null 2>&1
grep -q 'signup-funnel-lift-analysis' "$S/tickets/INDEX.md" 2>/dev/null \
  && ok "slug mode: a folder with no tracker key IS catalogued" \
  || bad "slug mode: slug folder never reached INDEX.md"
# The load-bearing assertion for this whole mode.
refs="$(CLAUDE_PROJECT_DIR="$S" python3 - <<'PY'
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("PROSE=" + ",".join(rows["signup-funnel-lift-analysis"]["cross_refs"]))
print("REAL=" + ",".join(rows["late-shipment-audit"]["cross_refs"]))
print("TITLE=" + (rows["signup-funnel-lift-analysis"]["title"] or ""))
PY
)"
grep -q '^PROSE=$' <<<"$refs" \
  && ok "slug mode: prose-only README yields ZERO cross-refs (hyphenated words aren't ids)" \
  || bad "slug mode: ordinary prose became cross-references" "$refs"
grep -q '^REAL=notes,signup-funnel-lift-analysis$' <<<"$refs" \
  && ok "slug mode: wiki-links resolve; escaped and code examples do not; no self-reference" \
  || bad "slug mode: explicit references did not resolve as expected" "$refs"
grep -q '^TITLE=Signup funnel incremental lift$' <<<"$refs" \
  && ok "slug mode: H1 id prefix stripped from the title" \
  || bad "slug mode: title still carries its slug prefix" "$refs"
# SLUG_ID must reject ids that aren't safe as a git branch name (git rejects a..b, trailing '.', .lock).
python3 - <<'PY2'
import sys; sys.path.insert(0, "bin")
from build_ticket_index import SLUG_ID
bad_ids = ["a..b", "foo.", "foo.lock", ".hidden", "..", "Has-Upper", "has space", "-leading"]
good_ids = ["signup-funnel-lift-analysis", "notes", "a1", "x_y-z"]
assert not any(SLUG_ID.match(b) for b in bad_ids), [b for b in bad_ids if SLUG_ID.match(b)]
assert all(SLUG_ID.match(g) for g in good_ids), [g for g in good_ids if not SLUG_ID.match(g)]
PY2
[ $? -eq 0 ] && ok "SLUG_ID rejects branch-unsafe ids, accepts ordinary slugs" \
  || bad "SLUG_ID admits an id that is unsafe as a git branch/filename"
# Two folders reducing to one id must be reported, not silently dropped.
mkdir -p "$S/tickets/dana/dupe" "$S/tickets/dana/☑️ dupe"
warn="$(CLAUDE_PROJECT_DIR="$S" python3 bin/build_ticket_index.py 2>&1 >/dev/null)"
grep -q 'two folders map to one id' <<<"$warn" \
  && ok "colliding folder names are reported on stderr, not silently dropped" \
  || bad "an on-disk ticket vanished from the catalog with no explanation" "$warn"
rm -rf "$S/tickets/dana/dupe" "$S/tickets/dana/☑️ dupe"
# Only a [[wiki-link]] is a reference. These constructs each defeated an earlier, looser attempt
# (pattern-matched links, then filesystem-resolved destinations); none of them may create an edge.
cat > "$S/tickets/dana/data-quality/README.md" <<'EOF'
# data-quality: Field null-rate review

![diagram](/assets/notes)
An [external](https://example.com/notes) link and an [absolute](/var/tmp/notes) one.
\](notes) and a bare ](notes) are not links.
Inline `` [[notes]] `` is an example, not a link.

~~~
[[notes]]
~~~
EOF
refs2="$(CLAUDE_PROJECT_DIR="$S" python3 - <<'PY2'
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("DQ=" + ",".join(rows["data-quality"]["cross_refs"]))
PY2
)"
# KNOWN LIMITATION, deliberate: a wiki-link inside an INDENTED code block (4 spaces) still counts.
# Treating every 4-space line as code silently dropped real links in list continuations, which is the
# worse failure for this payload. Fenced and inline code — how examples are actually written — are
# stripped. If this ever bites, fence the example.
grep -q '^DQ=$' <<<"$refs2" \
  && ok "slug mode: images, external URLs, absolute paths and fenced/inline code yield no references" \
  || bad "a non-reference markdown construct became a cross-reference" "$refs2"
# A markdown link destination is deliberately NOT a reference: only a [[wiki-link]] is. Three
# attempts at honouring destinations (by pattern, then by resolving them on disk) each leaked a new
# markdown construct, for a payload whose worst case is a spurious OBJECTS.md row.
cat > "$S/tickets/dana/data-quality/README.md" <<'EOF'
# data-quality: Field null-rate review

Detail in [the notes](../notes/README.md#summary), see also [go][k].
[k]: ../signup-funnel-lift-analysis/

The wiki-link [[notes]] is what actually creates an edge.
EOF
refs3="$(CLAUDE_PROJECT_DIR="$S" python3 - <<'PY3'
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("DQ=" + ",".join(rows["data-quality"]["cross_refs"]))
PY3
)"
grep -q '^DQ=notes$' <<<"$refs3" \
  && ok "slug mode: only wiki-links count — markdown destinations are not references" \
  || bad "markdown link destinations leaked back in as references" "$refs3"
# _strip_code is a line scanner, not a regex, because fences nested in a blockquote/list and a
# closing fence LONGER than its opener each defeated a regex attempt. The second case matters most:
# it used to swallow the rest of the README, losing genuine links.
python3 - <<'PY2'
import sys; sys.path.insert(0, "bin")
from build_ticket_index import resolve_cross_refs, key_regex
kr, known = key_regex([]), {"notes"}
def r(x): return resolve_cross_refs(x, "self", kr, "slug", known)
checks = [
    ("> ~~~\n> [[notes]]\n> ~~~\n",            []),          # fence inside a blockquote
    ("- ```\n  [[notes]]\n  ```\n",            []),          # fence inside a list item
    ("~~~\ncode\n~~~~\nThen [[notes]].",       ["notes"]),   # closer longer than opener
    ("```\n[[notes]]\n",                        []),          # unclosed fence blanks to EOF
    ("[[\n  notes\n]]",                         []),          # not a single-line wiki-link
    ("- parent\n\n    [[notes]]\n",            ["notes"]),   # list continuation is NOT code
]
for text, want in checks:
    got = r(text)
    assert got == want, (text, got, want)
PY2
[ $? -eq 0 ] && ok "code-stripping handles nested/oversized/unclosed fences without losing real links" \
  || bad "_strip_code mishandled a fence form (stray edge, or a real link swallowed)"
# keyed mode must NOT pick these up — that is what keeps adhoc-*/scratch-* folders out of the catalog.
K="$TMP/keyedmode"; mkdir -p "$K/.claude/config" "$K/bin" "$K/tickets/dana/signup-funnel-lift-analysis"
cp bin/build_ticket_index.py "$K/bin/"
printf 'project:\n  key_prefix: ENG\n  assignee_dir: dana\n  ticket_path: "tickets/{assignee}/{id}"\n' > "$K/.claude/config/stack.yaml"
printf '# signup-funnel-lift-analysis: nope\n\nScratch work, not a ticket.\n' > "$K/tickets/dana/signup-funnel-lift-analysis/README.md"
CLAUDE_PROJECT_DIR="$K" python3 bin/build_ticket_index.py >/dev/null 2>&1
grep -q 'signup-funnel-lift-analysis' "$K/tickets/INDEX.md" 2>/dev/null \
  && bad "keyed mode catalogued a keyless folder (scratch dirs would flood INDEX.md)" \
  || ok "keyed mode still skips keyless folders (default behavior unchanged)"

hdr "26 · slug ids: ordering, branch resolution, prefix-free banner"
# ticket_number must require the id to BE a tracker key. `search` grabbed digits from anywhere, so a
# slug ending in a year sorted as that ticket number.
python3 - <<'PY2'
import sys; sys.path.insert(0, "bin")
from build_ticket_index import ticket_number, key_regex
# The configured prefixes are the authority on which ids carry a number — no fixed shape works,
# since a prefix may contain _ or - or lead with a digit, and a slug may look exactly like a key.
for prefix, tid, want in (("ENG","ENG-12",12), ("OPS","OPS-7",7), ("ACME_US","ACME_US-42",42),
                          ("ACME-WEST","ACME-WEST-42",42), ("1ENG","1ENG-42",42)):
    got = ticket_number(tid, key_regex([prefix]))
    assert got == want, (tid, got, want)
# In a slug repo a digit-suffixed folder must not read as a ticket number — including `a-1`, which
# is shaped exactly like a key, and including a repo that still carries a stale key_prefix.
# Includes a repo that kept a stale lowercase key_prefix matching the slug ('a' vs folder 'a-1'):
# the prefixes are not evidence an id is keyed once id_mode is slug.
from build_ticket_index import id_key_regex
for cfg in ({"id_mode": "slug", "prefixes": []},
            {"id_mode": "slug", "prefixes": ["ENG"]},
            {"id_mode": "slug", "prefixes": ["a"]}):
    kr = id_key_regex(cfg)
    for slug in ("signup-funnel-lift-2024", "q3-2026-audit", "a-1", "notes", "x2024"):
        got = ticket_number(slug, kr)
        assert got == 0, (cfg, slug, got)
# ...while the SAME id in a keyed repo with that prefix legitimately is ticket 1.
assert ticket_number("a-1", id_key_regex({"id_mode": "keyed", "prefixes": ["a"]})) == 1
PY2
[ $? -eq 0 ] && ok "ticket_number: keyed ids keep their number, slug ids score 0 (no phantom order)" \
  || bad "a slug id ending in digits is still ordered as a ticket number"

# --branch resolution. `claude` is kept OFF PATH so enrich_ticket stops at its own guard: reaching
# "Enriching N ticket(s)" proves the id resolved, without spending a model call.
BR="$TMP/brslug"; mkdir -p "$BR/.claude/config" "$BR/tickets/dana/signup-funnel-lift" "$BR/bin"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py "$BR/bin/"
printf 'project:\n  assignee_dir: dana\n  id_mode: slug\n  ticket_path: "tickets/{assignee}/{id}"\n' > "$BR/.claude/config/stack.yaml"
printf '# signup-funnel-lift: Signup funnel\n\nBody.\n' > "$BR/tickets/dana/signup-funnel-lift/README.md"
( cd "$BR" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git checkout -q -b claude/signup-funnel-lift ) 2>/dev/null
out="$(cd "$BR" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$BR" python3 bin/enrich_ticket.py --branch 2>&1)"
grep -q 'Enriching 1 ticket' <<<"$out" \
  && ok "--branch resolves a slug branch (claude/<slug>) to its ticket" \
  || bad "--branch could not resolve a slug branch — /ship's convenience path is dead in slug mode" "$out"
# A branch that names no ticket must resolve to nothing rather than guessing.
( cd "$BR" && git checkout -q -b claude/not-a-ticket ) 2>/dev/null
out="$(cd "$BR" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$BR" python3 bin/enrich_ticket.py --branch 2>&1)"
grep -q 'No ticket ids given' <<<"$out" \
  && ok "--branch on an unrelated branch resolves nothing (identity, not pattern)" \
  || bad "--branch invented a ticket id from an unrelated branch name" "$out"
# Keyed mode's --branch path is untouched.
BK="$TMP/brkeyed"; mkdir -p "$BK/.claude/config" "$BK/tickets/dana/ENG-12 signup" "$BK/bin"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py "$BK/bin/"
printf 'project:\n  key_prefix: ENG\n  assignee_dir: dana\n' > "$BK/.claude/config/stack.yaml"
printf '# ENG-12: Signup\n\nBody.\n' > "$BK/tickets/dana/ENG-12 signup/README.md"
( cd "$BK" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git checkout -q -b ENG-12 ) 2>/dev/null
out="$(cd "$BK" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$BK" python3 bin/enrich_ticket.py --branch 2>&1)"
grep -q 'Enriching 1 ticket' <<<"$out" \
  && ok "--branch still resolves a keyed branch (ENG-12)" \
  || bad "keyed --branch regressed" "$out"

# A trackerless repo has no key_prefix; neither reader may fall back to a bare "?".
SB="$TMP/slugbanner/my-analysis-repo"; mkdir -p "$SB/.claude/config" "$SB/tickets/dana/signup-funnel-lift"
printf 'project:\n  assignee_dir: dana\n  id_mode: slug\nseams:\n  warehouse:\n    tool: snowflake\n' > "$SB/.claude/config/stack.yaml"
o="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$SB" python3 .claude/hooks/session_context.py 2>&1)"
{ grep -q 'Stack (my-analysis-repo)' <<<"$o" && ! grep -q '?-tickets' <<<"$o"; } \
  && ok "banner labels a prefix-free repo by its directory, not '?-tickets'" \
  || bad "session banner shows a placeholder prefix on a trackerless repo" "$o"
o="$(echo '{}' | CLAUDE_PROJECT_DIR="$SB" bash .claude/statusline.sh 2>&1)"
{ grep -q 'my-analysis-repo' <<<"$o" && ! grep -q '⛭ ?' <<<"$o"; } \
  && ok "statusline labels a prefix-free repo by its directory" \
  || bad "statusline shows '?' on a trackerless repo" "$o"
# Keyed banner unchanged.
o="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$KIT" python3 .claude/hooks/session_context.py 2>&1)"
grep -q 'Stack (ENG-tickets)' <<<"$o" \
  && ok "keyed banner still reads '<PREFIX>-tickets'" || bad "keyed banner changed" "$o"
# A keyed repo may configure ONLY the plural key_prefixes; it must still read as keyed rather than
# falling through to the directory name (which is the trackerless signal).
for shape in inline block; do
  KP="$TMP/kp-$shape/keyed-repo"; mkdir -p "$KP/.claude/config"
  if [ "$shape" = inline ]; then
    printf 'project:\n  key_prefixes: [OPS, ENG]\n' > "$KP/.claude/config/stack.yaml"
  else
    printf 'project:\n  key_prefixes:\n    - OPS\n    - ENG\n' > "$KP/.claude/config/stack.yaml"
  fi
  o="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$KP" python3 .claude/hooks/session_context.py 2>&1)"
  s="$(echo '{}' | CLAUDE_PROJECT_DIR="$KP" bash .claude/statusline.sh 2>&1)"
  { grep -q 'Stack (OPS-tickets)' <<<"$o" && grep -q 'OPS' <<<"$s" && ! grep -q 'keyed-repo' <<<"$s"; } \
    && ok "key_prefixes-only ($shape) still reads as keyed in banner + statusline" \
    || bad "a key_prefixes-only keyed repo now looks trackerless ($shape)" "$o | $s"
done
# A ticket branch created before the first commit is an unborn branch; `rev-parse --abbrev-ref`
# reports the literal "HEAD" there, so --branch could never resolve a fresh ticket branch.
UB="$TMP/unborn"; mkdir -p "$UB/.claude/config" "$UB/tickets/dana/signup-funnel-lift" "$UB/bin"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py "$UB/bin/"
printf 'project:\n  assignee_dir: dana\n  id_mode: slug\n  ticket_path: "tickets/{assignee}/{id}"\n' > "$UB/.claude/config/stack.yaml"
printf '# signup-funnel-lift: R\n\nBody.\n' > "$UB/tickets/dana/signup-funnel-lift/README.md"
( cd "$UB" && git init -q . && git checkout -q -b claude/signup-funnel-lift ) 2>/dev/null
out="$(cd "$UB" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$UB" python3 bin/enrich_ticket.py --branch 2>&1)"
grep -q 'Enriching 1 ticket' <<<"$out" \
  && ok "--branch resolves on an UNBORN branch (no commits yet)" \
  || bad "--branch fails on a branch created before the first commit" "$out"
# Detached HEAD must resolve nothing rather than guessing.
( cd "$UB" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i && git checkout -q --detach HEAD ) 2>/dev/null
out="$(cd "$UB" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$UB" python3 bin/enrich_ticket.py --branch 2>&1)"
grep -q 'No ticket ids given' <<<"$out" \
  && ok "--branch on a detached HEAD resolves nothing" \
  || bad "--branch guessed an id on a detached HEAD" "$out"
# ingest persists ticket_url into index_data.json, and a persisted URL WINS over a re-render — so a
# wrong {number} there is permanent. A slug shaped like a key (`a-1`) must not become ticket 1.
IU="$TMP/ingesturl"; mkdir -p "$IU/.claude/config" "$IU/tickets/dana/a-1" "$IU/bin"
cp bin/build_ticket_index.py bin/ingest_index_records.py "$IU/bin/"
printf 'project:\n  assignee_dir: dana\n  id_mode: slug\n  ticket_url_template: "https://x/browse/{number}"\n' > "$IU/.claude/config/stack.yaml"
printf '# a-1: Looks like a key\n\nBody.\n' > "$IU/tickets/dana/a-1/README.md"
printf '{"records":[{"owner":"dana","id":"a-1","summary":"s","status":"Completed","date":"2026-01-01"}]}' \
  | CLAUDE_PROJECT_DIR="$IU" python3 "$IU/bin/ingest_index_records.py" --from-json - >/dev/null 2>&1
grep -q '"ticket_url": "https://x/browse/1"' "$IU/tickets/index_data.json" 2>/dev/null \
  && bad "a slug shaped like a tracker key was persisted with {number}=1 (links to an unrelated ticket)" \
  || ok "ingest does not invent a tracker number for a key-shaped slug id"

hdr "27 · local tracker adapter (the filesystem IS the tracker)"
# The whole point is zero skill edits: the adapter must satisfy the same 7-verb contract, so /ticket
# and /ship keep calling tracker verbs without knowing there's no API.
lv="$(grep -c '^## verb:' adapters/tracker/local.md)"
[ "$lv" -eq 7 ] && ok "local adapter implements all 7 tracker verbs" || bad "local adapter has $lv verbs, expected 7"
lvmiss=""
for v in fetch_ticket create_ticket transition comment search download_attachments \
         rank_projects_by_activity; do
  grep -q "^## verb: $v$" adapters/tracker/local.md || lvmiss="$lvmiss $v"
done
[ -z "$lvmiss" ] && ok "local adapter verb NAMES match the contract exactly" \
  || bad "local adapter verb names diverge from the contract" "$lvmiss"
# It must not require any seam config or auth — that is what makes it usable with no tracker.
grep -qE '^requires: \[\]' adapters/tracker/local.md \
  && ok "local adapter requires no seam config" || bad "local adapter declares required seam keys"
# A trackerless repo has no sibling projects to rank, and the contract distinguishes that
# (`unsupported`, skip silently) from a tracker that refused the scan (`unavailable`, say one line).
# Collapsing them here would teach the caller to swallow a fixable auth failure.
sed -n '/^## verb: rank_projects_by_activity$/,/^## /p' adapters/tracker/local.md \
  | grep -q 'unsupported' \
  && ok "local adapter returns unsupported for rank_projects_by_activity" \
  || bad "local adapter does not declare rank_projects_by_activity unsupported"

# The snippets are EXTRACTED from the adapter and executed, not reimplemented here — a copied
# implementation would keep passing after the documented one drifted or broke.
cat > "$TMP/extract_verb.py" <<'PY2'
import pathlib, re, sys
md, verb = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
sec = re.split(r"(?m)^## ", md)
body = next(s for s in sec if s.startswith(f"verb: {verb}\n"))
m = re.search(r"<<'PY'\n(.*?)\nPY\n", body, re.DOTALL)
if not m:
    sys.exit(f"no python snippet under 'verb: {verb}'")
print(m.group(1))
PY2
LA="adapters/tracker/local.md"
python3 "$TMP/extract_verb.py" "$LA" transition > "$TMP/transition.py" 2>"$TMP/x.err" \
  && ok "transition snippet extracted from the adapter (tests bind to the doc)" \
  || bad "could not extract the transition snippet" "$(cat "$TMP/x.err")"
python3 "$TMP/extract_verb.py" "$LA" comment > "$TMP/comment.py" 2>"$TMP/x.err" \
  && ok "comment snippet extracted from the adapter" \
  || bad "could not extract the comment snippet" "$(cat "$TMP/x.err")"

TL="$TMP/localadapter"; mkdir -p "$TL"
hdr_readme() { printf '# signup-funnel-lift: R\n\n## Ticket Information\n- **Link:** \n- **Type:** analysis\n- **Status:** In Progress\n- **Epic/Parent:** \n- **Assignee:** dana\n\n## Business Context\nBrief.\n' > "$1"; }

# Only the Status bullet changes, and it is re-runnable.
hdr_readme "$TL/a.md"
python3 "$TMP/transition.py" "$TL/a.md" Completed >/dev/null 2>&1
python3 "$TMP/transition.py" "$TL/a.md" Done >/dev/null 2>&1
b="$(grep -cE '^- \*\*(Link|Type|Status|Epic/Parent|Assignee):' "$TL/a.md")"
{ grep -q '^- \*\*Status:\*\* Done$' "$TL/a.md" && [ "$b" -eq 5 ]; } \
  && ok "local transition rewrites only the Status bullet and is re-runnable" \
  || bad "local transition corrupted the README" "$(cat "$TL/a.md")"

# A status is user input: in a replacement STRING, `\1` would expand and `\q` would raise.
hdr_readme "$TL/b.md"
python3 "$TMP/transition.py" "$TL/b.md" 'weird \1 \g<1> \q' >"$TMP/o.txt" 2>&1
{ grep -qF -- '- **Status:** weird \1 \g<1> \q' "$TL/b.md" && ! grep -qi 'traceback' "$TMP/o.txt"; } \
  && ok "local transition treats a status with regex escapes as literal text" \
  || bad "a status containing backreferences/escapes corrupted the file or raised" "$(cat "$TMP/o.txt"; cat "$TL/b.md")"

# Two Status bullets must not be left disagreeing with each other.
printf '# x: y\n\n- **Status:** In Progress\n- **Type:** t\n- **Status:** Blocked\n' > "$TL/c.md"
python3 "$TMP/transition.py" "$TL/c.md" Done >/dev/null 2>&1
[ "$(grep -c '^- \*\*Status:\*\* Done$' "$TL/c.md")" -eq 2 ] \
  && ok "local transition updates every Status bullet (no contradictory leftovers)" \
  || bad "a duplicated Status bullet was left disagreeing" "$(cat "$TL/c.md")"

# No bullet: say so, change nothing.
printf '# x: y\n\nNo bullets.\n' > "$TL/d.md"; before="$(cat "$TL/d.md")"
out="$(python3 "$TMP/transition.py" "$TL/d.md" Done 2>&1)"
{ [ "$before" = "$(cat "$TL/d.md")" ] && grep -q 'no Status bullet' <<<"$out"; } \
  && ok "local transition no-ops (and says so) when there is no Status bullet" \
  || bad "local transition altered a README with no Status bullet" "$out"

# comment: one heading, appended entries, and a fenced `## Log` example is not the real heading.
printf '# x: y\n\nBody.\n' > "$TL/log1.md"
python3 "$TMP/comment.py" "$TL/log1.md" 2026-08-04 "First." >/dev/null 2>&1
python3 "$TMP/comment.py" "$TL/log1.md" 2026-08-04 "Second." >/dev/null 2>&1
{ [ "$(grep -c '^## Log$' "$TL/log1.md")" -eq 1 ] && [ "$(grep -c '^\*\*2026-08-04\*\*' "$TL/log1.md")" -eq 2 ]; } \
  && ok "local comment creates '## Log' once and appends dated entries" \
  || bad "local comment duplicated the heading or lost an entry" "$(cat "$TL/log1.md")"
printf '# x: y\n\n```\n## Log\n```\n' > "$TL/log2.md"
python3 "$TMP/comment.py" "$TL/log2.md" 2026-08-04 "Note." >/dev/null 2>&1
[ "$(grep -c '^## Log$' "$TL/log2.md")" -eq 2 ] \
  && ok "local comment ignores a '## Log' inside a fenced block and creates a real one" \
  || bad "a fenced '## Log' example suppressed the real log heading" "$(cat "$TL/log2.md")"
# A README that OPENS with the heading must not gain a second one.
printf '## Log\n\n**2026-01-01** — old.\n' > "$TL/log3.md"
python3 "$TMP/comment.py" "$TL/log3.md" 2026-08-04 "New." >/dev/null 2>&1
[ "$(grep -c '^## Log$' "$TL/log3.md")" -eq 1 ] \
  && ok "local comment recognizes a leading '## Log' heading" \
  || bad "a README opening with '## Log' gained a duplicate heading" "$(cat "$TL/log3.md")"

# The clobber guard: /ticket creates via the adapter, THEN renders the template into the same file.
# With a remote tracker those are different artifacts; here an unguarded render destroys the brief.
printf '# signup-funnel-lift: R\n\n## Business Context\nInterviewed brief worth keeping.\n' > "$TL/brief.md"
printf 'ticket_id=signup-funnel-lift\ntitle=R\n' > "$TL/vars.env"
[ -s "$TL/brief.md" ] || bash bin/render.sh templates/ticket-README.md.tmpl --vars "$TL/vars.env" > "$TL/brief.md"
grep -q 'Interviewed brief worth keeping' "$TL/brief.md" \
  && ok "guarded render preserves an existing brief (the documented clobber guard)" \
  || bad "the render overwrote an interviewed brief"
grep -q 'Never render over a README that already has content' adapters/tracker/local.md \
  && ok "adapter documents the render-clobber hazard" || bad "clobber hazard undocumented"

# End to end: a slug folder under the solo stack reaches INDEX.md with a local link and no ↗.
E2E="$TMP/e2e"; mkdir -p "$E2E/.claude/config" "$E2E/bin" "$E2E/tickets/dana/signup-funnel-lift"
cp bin/build_ticket_index.py "$E2E/bin/"
cp .claude/config/stack.example.solo.yaml "$E2E/.claude/config/stack.yaml"
printf '# signup-funnel-lift: Signup funnel lift\n\n## Business Context\nMeasure lift.\n' > "$E2E/tickets/dana/signup-funnel-lift/README.md"
CLAUDE_PROJECT_DIR="$E2E" python3 "$E2E/bin/build_ticket_index.py" >/dev/null 2>&1
{ grep -q 'signup-funnel-lift' "$E2E/tickets/INDEX.md" && ! grep -q '↗' "$E2E/tickets/INDEX.md"; } \
  && ok "solo stack: a slug ticket reaches INDEX.md with no external link (index path, not the skill flow)" \
  || bad "solo stack did not produce a usable INDEX.md" "$(cat "$E2E/tickets/INDEX.md" 2>&1 | head -20)"

hdr "28 · docs stay true to the code (counts and capabilities drift silently)"
# These numbers were stale in three places before this section existed, so assert them rather than
# trusting prose: the docs are the adoption surface.
na="$(ls adapters/*/*.md | grep -v README | wc -l | tr -d ' ')"
grep -q "\*\*$na adapters\*\*" docs/architecture.md \
  && ok "architecture.md's adapter count matches the tree ($na)" \
  || bad "architecture.md states the wrong adapter count (tree has $na)" "$(grep -o '\*\*[0-9]* adapters\*\*' docs/architecture.md)"
# Derive the seam count too — hardcoding it just moves the staleness one line over, which is
# what adding the `viewer` seam proved.
ns=0
for d in adapters/*/; do
  [ "$(ls "$d"*.md 2>/dev/null | grep -cv 'README\.md$')" -gt 0 ] && ns=$((ns + 1))
done
grep -q "^- $na adapters across $ns seams" ROADMAP.md \
  && ok "ROADMAP's adapter/seam counts match the tree ($na / $ns)" \
  || bad "ROADMAP adapter or seam count stale (tree has $na adapters across $ns seams)" \
         "$(grep -n '^- [0-9]* adapters across' ROADMAP.md)"
ns="$(ls .claude/config/stack.yaml .claude/config/stack.example.*.yaml | wc -l | tr -d ' ')"
grep -q "$ns worked stacks" ROADMAP.md \
  && ok "ROADMAP's worked-stack count matches the configs ($ns)" || bad "ROADMAP worked-stack count stale (found $ns)"
# Every shipped adapter must be listed in the adapters README, or adopters can't find it.
sed -n '/^## Adapters shipped$/,/^## /p' adapters/README.md > "$TMP/shipped_list.txt"
amiss=""
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  n="$(basename "$f" .md)"
  grep -q "\`$n\`" "$TMP/shipped_list.txt" || amiss="$amiss $n"
done
[ -z "$amiss" ] && ok "every shipped adapter appears in adapters/README.md" \
  || bad "an adapter ships but is undocumented" "$amiss"
# The two new capabilities must be discoverable from the docs an adopter actually reads.
dmiss=""
for pair in "README.md:id_mode" ".claude/config/stack.schema.md:id_mode" \
            "docs/ticket-index.md:id_mode" "docs/troubleshooting.md:id_mode"; do
  f="${pair%%:*}"; k="${pair##*:}"
  grep -q "$k" "$f" || dmiss="$dmiss $f"
done
[ -z "$dmiss" ] && ok "id_mode is documented in README, schema, ticket-index and troubleshooting" \
  || bad "id_mode undocumented in an adoption-facing doc" "$dmiss"
# stack.yaml's header and architecture.md's proof list both enumerate the shipped configs, and both
# were stale. Assert every example file is named in each.
cmiss=""
for f in .claude/config/stack.example.*.yaml; do
  n="$(basename "$f")"
  grep -q "$n" .claude/config/stack.yaml || cmiss="$cmiss stack.yaml:$n"
  grep -q "$n" docs/architecture.md || cmiss="$cmiss architecture.md:$n"
done
[ -z "$cmiss" ] && ok "every example stack is named in stack.yaml's header and architecture.md" \
  || bad "an example stack ships but isn't listed where adopters look" "$cmiss"
grep -qE '^  id_mode:[[:space:]]*slug([[:space:]]|#|$)' .claude/config/stack.example.solo.yaml \
  && ok "the solo example config actually sets project.id_mode: slug" \
  || bad "solo example does not set id_mode: slug (a comment mentioning it is not the setting)"
# The no-warehouse example must genuinely omit the seam (a commented-out block doesn't count),
# and must still resolve end-to-end like every other shipped config (section 1 covers that).
if yq -e '.seams.warehouse' .claude/config/stack.example.no-warehouse.yaml >/dev/null 2>&1; then
  bad "no-warehouse example config actually configures a warehouse seam"
else
  ok "the no-warehouse example config genuinely omits the warehouse seam"
fi
# The slug cross-reference rule is the most surprising behaviour; it must be stated, not implied.
grep -qi 'wiki-link' docs/ticket-index.md && grep -qi 'wiki-link' .claude/config/stack.schema.md \
  && ok "the slug cross-reference rule (wiki-links only) is documented in both places" \
  || bad "the wiki-links-only rule is not documented where adopters will look"

# A stated check count goes stale on every added test, so the docs state a FLOOR. Assert it against
# the live counter — a static scan can't work, since loop-driven call sites each yield many checks.
# Counting this assertion itself is why it is the last one.
floor="$(grep -oE '[0-9]+\+-check' docs/troubleshooting.md | head -1 | grep -oE '^[0-9]+')"
{ [ -n "$floor" ] && [ "$((PASS + 1))" -ge "$floor" ]; } \
  && ok "the docs' stated check floor (${floor}+) is met ($((PASS + 1)) checks)" \
  || bad "the docs claim more checks than the suite runs" "floor=${floor:-unset} actual=$PASS"

hdr "25 · viewer seam + human review handoff (bin/handoff.sh)"
# This seam launches DESKTOP APPS, so the assertions below are as much about what it must NOT do as
# what it must. Everything runs --dry-run or with TICKETWRIGHT_NO_OPEN=1: selftest must never open a
# window on a contributor's machine, and CI has no desktop to open into.
vproj() {  # vproj NAME <<'YAML'  → writes a project fixture + viewer.local.yaml, echoes the dir
  local d="$TMP/v-$1"
  mkdir -p "$d/.claude/config" "$d/tickets"; : > "$d/.git"
  cat > "$d/.claude/config/viewer.local.yaml"
  printf 'SELECT 1;\n'  > "$d/tickets/q.sql"
  printf 'a,b\n1,2\n'   > "$d/tickets/one.csv"
  printf 'a,b\n3,4\n'   > "$d/tickets/two.csv"
  printf 'hi\n'         > "$d/tickets/notes.md"
  echo "$d"
}
hoff() {  # hoff PROJDIR ARGS... — never allowed to actually launch anything
  local d="$1"; shift
  CLAUDE_PROJECT_DIR="$d" TICKETWRIGHT_NO_OPEN=1 XDG_CONFIG_HOME="$TMP/noxdg" \
    bash bin/handoff.sh "$@" 2>/dev/null
}

VP="$(vproj basic <<'YAML'
tool: macos-open
adapter: adapters/viewer/macos-open.md
open_cmd: 'open -a {app} {path}'
default_cmd: 'open {path}'
reveal_cmd: 'open -R {path}'
routes:
  - glob: "*.sql"
    app: SqlApp
  - glob: "*.csv"
    app: Sheet App
YAML
)"
o="$(hoff "$VP" --dry-run "$VP/tickets/q.sql")"
grep -q 'open -a SqlApp' <<<"$o" && ok "a .sql routes to its configured app" || bad "sql route not applied" "$o"

# Batching: N files sharing a route must be ONE launch, not one window per file.
o="$(hoff "$VP" --dry-run "$VP/tickets/one.csv" "$VP/tickets/two.csv")"
{ [ "$(grep -c 'would run' <<<"$o")" = "1" ] && grep -q 'one.csv.*two.csv' <<<"$o"; } \
  && ok "files sharing a route batch into one launch" || bad "csv batch split into separate launches" "$o"

# Regression: the unrouted group used to be keyed by the EMPTY string, and $(...) strips trailing
# newlines — so whenever the last file matched no route it silently never opened.
o="$(hoff "$VP" --dry-run "$VP/tickets/q.sql" "$VP/tickets/notes.md")"
grep -qE '^  would run: open [^-]' <<<"$o" \
  && ok "an unrouted file still opens via default_cmd (even when it sorts last)" \
  || bad "unrouted file dropped — the empty grouping key regressed" "$o"

o="$(hoff "$VP" --dry-run --reveal "$VP/tickets/one.csv")"
grep -q 'open -R' <<<"$o" && ok "--reveal resolves reveal_cmd" || bad "--reveal did not use reveal_cmd" "$o"

# A real (non-dry) run must still refuse to launch when told not to, and say the command it skipped.
o="$(hoff "$VP" "$VP/tickets/q.sql")"
{ grep -q 'would run' <<<"$o" && ! grep -q 'opened:' <<<"$o"; } \
  && ok "TICKETWRIGHT_NO_OPEN=1 prints instead of launching" || bad "guard did not stop a launch" "$o"
o="$(CLAUDE_PROJECT_DIR="$VP" CI=true bash bin/handoff.sh "$VP/tickets/q.sql" 2>/dev/null)"
{ grep -q 'would run' <<<"$o" && ! grep -q 'opened:' <<<"$o"; } \
  && ok "CI=… prints instead of launching (no desktop in CI)" || bad "guard did not stop a launch under CI" "$o"

# Containment: this hands paths to desktop apps, so it only ever touches the project.
o="$(hoff "$VP" --dry-run /etc/hosts)"; rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$o" ]; } \
  && ok "a path outside the project is refused" || bad "opened a path outside the project" "$o rc=$rc"
# …and the containment check must resolve the FINAL component, not just its parent directory. A
# ticket repo is shared, so an in-project symlink is something another author can commit; resolving
# only the parent let `tickets/x.sql -> /etc/hosts` through as "inside the project".
ln -sf /etc/hosts "$VP/tickets/escape.sql"
o="$(hoff "$VP" --dry-run "$VP/tickets/escape.sql")"; rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$o" ]; } \
  && ok "an in-project symlink pointing outside the project is refused" \
  || bad "symlink escaped containment — the app would have opened the target" "$o rc=$rc"
# A symlink that stays inside the project is legitimate and must still work.
ln -sf "$VP/tickets/one.csv" "$VP/tickets/alias.csv"
o="$(hoff "$VP" --dry-run "$VP/tickets/alias.csv")"
grep -q 'one.csv' <<<"$o" && ok "an in-project symlink resolving inside the project still opens" \
  || bad "a legitimate in-project symlink was refused" "$o"

# Regression: `.enabled // "true"` in yq/jq treats a literal false as ABSENT, so the one value that
# must be honored was being overridden by its own default.
VOFF="$(vproj off <<'YAML'
enabled: false
tool: macos-open
open_cmd: 'open -a {app} {path}'
default_cmd: 'open {path}'
routes:
  - glob: "*.sql"
    app: SqlApp
YAML
)"
o="$(hoff "$VOFF" --dry-run "$VOFF/tickets/q.sql")"
[ -z "$o" ] && ok "enabled: false is honored (opt-out never re-prompts)" || bad "enabled:false still opened files" "$o"
# The opt-out must survive a trailing YAML comment, and the SessionStart banner has to agree with
# the engine — a banner advertising `viewer=…` for a config that opens nothing is a lie about state.
printf 'enabled: false # do not ask again\ntool: macos-open\n' > "$VOFF/.claude/config/viewer.local.yaml"
# session_context bails out entirely without a stack.yaml, which would make the banner half of this
# assertion pass for the wrong reason. Give it one so the banner actually renders.
printf 'project:\n  key_prefix: ENG\nseams:\n  tracker:\n    tool: jira\n' > "$VOFF/.claude/config/stack.yaml"
o="$(hoff "$VOFF" --dry-run "$VOFF/tickets/q.sql")"
b="$(echo '{"hook_event_name":"SessionStart"}' \
      | CLAUDE_PROJECT_DIR="$VOFF" XDG_CONFIG_HOME="$TMP/noxdg" python3 .claude/hooks/session_context.py 2>/dev/null)"
{ [ -z "$o" ] && ! grep -q 'viewer=' <<<"$b"; } \
  && ok "enabled: false with a trailing comment: engine and banner agree it is off" \
  || bad "trailing comment defeated the opt-out in the engine or the banner" "engine='$o' banner='$b'"

# Optionality: an unconfigured repo behaves exactly as before this feature existed.
VNONE="$TMP/v-none"; mkdir -p "$VNONE/.claude/config" "$VNONE/tickets"; : > "$VNONE/.git"
printf 'project:\n  key_prefix: ENG\n' > "$VNONE/.claude/config/stack.yaml"
printf 'SELECT 1;\n' > "$VNONE/tickets/q.sql"
o="$(hoff "$VNONE" "$VNONE/tickets/q.sql")"; rc=$?
{ [ -z "$o" ] && [ "$rc" -eq 0 ]; } \
  && ok "no viewer config → silent, exit 0 (feature is off, nothing blocks)" || bad "unconfigured repo was not silent" "$o rc=$rc"

# Resolution order: the per-user repo file must win over a team-wide seams.viewer in stack.yaml.
VORD="$(vproj order <<'YAML'
tool: macos-open
open_cmd: 'open -a {app} {path}'
default_cmd: 'open {path}'
routes:
  - glob: "*.sql"
    app: PerUserApp
YAML
)"
printf 'seams:\n  viewer:\n    tool: macos-open\n    open_cmd: %s\n    default_cmd: %s\n    routes:\n      - glob: "*.sql"\n        app: TeamApp\n' \
  "'open -a {app} {path}'" "'open {path}'" > "$VORD/.claude/config/stack.yaml"
o="$(hoff "$VORD" --dry-run "$VORD/tickets/q.sql")"
grep -q 'PerUserApp' <<<"$o" && ok "per-user viewer.local.yaml beats a team-wide seams.viewer" \
  || bad "resolution order wrong — stack.yaml won over the per-user file" "$o"
# …and with the per-user file gone, the team-wide block is what answers.
rm -f "$VORD/.claude/config/viewer.local.yaml"
o="$(hoff "$VORD" --dry-run "$VORD/tickets/q.sql")"
grep -q 'TeamApp' <<<"$o" && ok "seams.viewer in stack.yaml is the team-wide fallback" \
  || bad "team-wide seams.viewer never resolved" "$o"
# …and the user-level file sits between them.
mkdir -p "$TMP/xdg/ticketwright"
printf "tool: macos-open\nopen_cmd: 'open -a {app} {path}'\ndefault_cmd: 'open {path}'\nroutes:\n  - glob: \"*.sql\"\n    app: AllReposApp\n" \
  > "$TMP/xdg/ticketwright/viewer.yaml"
o="$(CLAUDE_PROJECT_DIR="$VORD" TICKETWRIGHT_NO_OPEN=1 XDG_CONFIG_HOME="$TMP/xdg" \
      bash bin/handoff.sh --dry-run "$VORD/tickets/q.sql" 2>/dev/null)"
grep -q 'AllReposApp' <<<"$o" && ok "user-level viewer.yaml beats stack.yaml, loses to the repo file" \
  || bad "XDG user-level viewer config not resolved" "$o"

# `yq` is no longer required AT ALL — by handoff.sh or by verify_stack.sh. This assertion used to
# check that a missing yq "degrades soft" by printing a message mentioning yq; now the correct
# behaviour is that nothing degrades, because the resolver is stdlib Python.
#
# Hiding yq by narrowing PATH to /usr/bin:/bin does NOT work on images that ship yq there —
# GitHub's ubuntu runners do — so that spelling passed locally (Homebrew keeps yq outside those
# dirs) and failed in CI, i.e. it was green for the wrong reason. Build a scratch bin holding
# only what these scripts need, minus yq, and assert the precondition so this can never silently
# stop exercising the branch it claims to cover.
NOYQ="$TMP/noyq-bin"; mkdir -p "$NOYQ"
# `git` belongs in this list: the resolver asks bin/resolve_user.py who you are, which shells out to
# `git config`. Omitting it left that call failing for a reason unrelated to yq, which made this
# assertion intermittent rather than wrong.
for c in bash sh env printf awk sed grep tr cut basename dirname realpath python3 mktemp rm cat \
         head tail sort uniq wc xargs cp mv mkdir touch chmod ln date id git; do
  src="$(command -v "$c" 2>/dev/null)" && ln -sf "$src" "$NOYQ/$c"
done
if ( PATH="$NOYQ"; command -v yq >/dev/null 2>&1 ); then
  bad "missing-yq test setup is broken: yq still resolves, so the branch was never exercised"
else
  o="$(CLAUDE_PROJECT_DIR="$VP" TICKETWRIGHT_NO_OPEN=1 PATH="$NOYQ" bash bin/handoff.sh \
        --dry-run "$VP/tickets/q.sql" 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'would run' <<<"$o" && ! grep -qi 'yq' <<<"$o"; } \
    && ok "handoff.sh resolves routes with yq absent from PATH entirely" \
    || bad "handoff.sh still depends on yq" "$o rc=$rc"
  o="$(PATH="$NOYQ" CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh \
        "$KIT/.claude/config/stack.yaml" --dry-run 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'All seams OK' <<<"$o"; } \
    && ok "verify_stack.sh resolves every seam with yq absent from PATH entirely" \
    || bad "verify_stack.sh still depends on yq (it used to exit 1 without it)" "$o rc=$rc"
fi

# The per-user file must never be committable — it is personal config, and in a work repo its app
# paths can leak local directory structure.
{ grep -q 'config/\*\.local\.yaml' .gitignore && grep -q 'config/\*\.local\.yaml' templates/gitignore.tmpl; } \
  && ok "viewer.local.yaml is gitignored (kit + scaffold template)" \
  || bad "per-user viewer config is not gitignored in .gitignore / templates/gitignore.tmpl"
[ -z "$(git ls-files '.claude/config/*.local.yaml' 2>/dev/null)" ] \
  && ok "no per-user viewer config is tracked in git" || bad "a *.local.yaml is tracked — untrack it"
[ -f .claude/config/viewer.example.yaml ] \
  && ok "viewer.example.yaml ships as the committed reference" || bad "viewer.example.yaml missing"

# Wiring: the policy is documented everywhere a reader looks, and the skills call the engine rather
# than naming anybody's application (the golden rule).
{ grep -q 'human_review_handoff' .claude/config/stack.yaml \
  && grep -q 'human_review_handoff' .claude/config/stack.schema.md \
  && grep -q 'human_review_handoff' templates/AGENTS.md.tmpl; } \
  && ok "human_review_handoff documented in stack.yaml + schema + AGENTS.md.tmpl" \
  || bad "the new policy is missing from a config/doc surface"
{ grep -q 'handoff.sh' .claude/skills/review/SKILL.md \
  && grep -q 'handoff.sh' .claude/skills/spec-and-build/SKILL.md; } \
  && ok "/review and /spec-and-build call bin/handoff.sh" || bad "a gate skill never invokes the handoff engine"
appleak="$(grep -REn -i 'DataGrip|Microsoft Excel|open -a |xdg-open|explorer\.exe' \
            .claude/skills .claude/commands 2>/dev/null || true)"
[ -z "$appleak" ] && ok "no application name or OS open-command leaked into a skill" \
  || bad "a skill names a concrete application (belongs in an adapter / per-user config)" "$appleak"

hdr "29 · voice profiles (resolver + template + ship/setup wiring + privacy)"
# (A) resolve_user.py is stdlib-only and makes no network calls (offline resolver, per kit philosophy).
imp_bad="$(grep -nE '^\s*(import|from)\s+(requests|urllib|http|socket|ssl|yaml)\b' bin/resolve_user.py || true)"
[ -z "$imp_bad" ] && ok "resolve_user.py imports are stdlib-only, no network modules" \
  || bad "resolve_user.py pulls a non-stdlib/network module" "$imp_bad"
python3 -c "import ast; ast.parse(open('bin/resolve_user.py').read())" 2>/dev/null \
  && ok "resolve_user.py parses" || bad "resolve_user.py is not valid Python"
# (B) map hit / miss / feature-off / \$USER fallback — the deterministic identity contract.
V="$TMP/voice"; mkdir -p "$V/.claude/config"
git -C "$V" init -q 2>/dev/null; git -C "$V" config user.email "alice@acme.example" 2>/dev/null; git -C "$V" config user.name "Alice Smith" 2>/dev/null
printf 'project:\n  key_prefix: ENG\n' > "$V/.claude/config/stack.yaml"
off="$( (cd "$V" && CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py") )"
[ -z "$off" ] && ok "feature off (no voice_profiles) → resolver prints nothing (fail open)" || bad "resolver spoke when feature off" "$off"
cat > "$V/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
  voice_profiles:
    path: "voices/{profile_id}.md"
    map:
      "alice@acme.example": alice
      teammate_login: bob
EOF
hit="$( (cd "$V" && CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py") )"
[ "$hit" = "alice" ] && ok "map hit by git email → profile id (alice)" || bad "email map hit wrong" "got=$hit"
hp="$( (cd "$V" && CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py" --path) )"
[ "$hp" = "voices/alice.md" ] && ok "--path applies the path template (voices/alice.md)" || bad "--path wrong" "got=$hp"
usr="$( (cd "$V" && git config user.email "nobody@nowhere" && USER=teammate_login CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py") )"
[ "$usr" = "bob" ] && ok "\$USER fallback resolves when git identity misses (bob)" || bad "\$USER fallback wrong" "got=$usr"
miss="$( (cd "$V" && git config user.email "ghost@void" && USER=ghost CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py") )"
[ -z "$miss" ] && ok "identity miss → prints nothing (fail open, never a wrong profile)" || bad "resolver guessed on a miss" "$miss"
# (B2) reads git identity from the PROJECT root, not the process cwd (plugin-install correctness).
# Set the mapped identity in the fixture repo, then run from a DIFFERENT cwd ($KIT, whose own git
# identity is not in the map). Reading $KIT's config is fine; we never write it.
git -C "$V" config user.email "alice@acme.example" 2>/dev/null
xcwd="$( cd "$KIT" && CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py" )"
[ "$xcwd" = "alice" ] && ok "resolves git identity from CLAUDE_PROJECT_DIR, not the process cwd" || bad "git identity read from cwd, not project root" "got=$xcwd"
jsn="$( cd "$KIT" && CLAUDE_PROJECT_DIR="$V" python3 "$KIT/bin/resolve_user.py" --json )"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('id')=='alice' and d.get('path')=='voices/alice.md' else 1)" "$jsn" 2>/dev/null \
  && ok "--json emits id + path + identity" || bad "--json wrong" "$jsn"
# (B3) name-map hit + path-after-map (regression: a path: line AFTER map: must not pollute the map).
PAM="$TMP/pam"; mkdir -p "$PAM/.claude/config"; git -C "$PAM" init -q 2>/dev/null
git -C "$PAM" config user.email "nomatch@x" 2>/dev/null; git -C "$PAM" config user.name "Carol Jones" 2>/dev/null
cat > "$PAM/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
  voice_profiles:
    map:
      "Carol Jones": carol
    path: "profiles/{profile_id}.md"
seams:
  tracker:
    tool: jira
EOF
pam_id="$( cd "$KIT" && CLAUDE_PROJECT_DIR="$PAM" python3 "$KIT/bin/resolve_user.py" )"
pam_p="$( cd "$KIT" && CLAUDE_PROJECT_DIR="$PAM" python3 "$KIT/bin/resolve_user.py" --path )"
{ [ "$pam_id" = "carol" ] && [ "$pam_p" = "profiles/carol.md" ]; } \
  && ok "name-map hit + path-after-map parsed correctly (map not polluted by a trailing path:)" \
  || bad "path-after-map / name-map parsing wrong" "id=$pam_id path=$pam_p"
# (C) seed template renders with zero leftover tokens.
verr="$(bash bin/render.sh templates/voice-profile.md.tmpl profile_id=alice display_name="Alice Smith" bootstrapped=2026-07-28 sources="interview" 2>&1 >/dev/null)"
[ -z "$verr" ] && ok "voice-profile.md.tmpl renders with zero leftover tokens" || bad "leftover tokens in voice-profile.md.tmpl" "$verr"
# (D) do-not-override list in the template is COMMS-scoped; CSV/determinism explicitly NOT a voice rail.
{ grep -q 'Do-not-override' templates/voice-profile.md.tmpl \
  && grep -q 'word_limits' templates/voice-profile.md.tmpl \
  && grep -q 'NOT a voice concern' templates/voice-profile.md.tmpl; } \
  && ok "voice template scopes rails to comms + excludes CSV/deterministic_outputs from the voice rails" \
  || bad "voice template's do-not-override list is wrong (must be comms-only; CSV/determinism excluded)"
# (E) /ship wires the consume step, lint-before-voice ordering, gated refinement, and fails open.
shipflat="$(tr '\n' ' ' < .claude/skills/ship/SKILL.md)"
grep -q 'resolve_user.py' .claude/skills/ship/SKILL.md \
  && ok "/ship resolves the shipper via resolve_user.py" || bad "/ship never calls resolve_user.py"
{ grep -qi 'Comms-lint the drafts first' <<<"$shipflat" && grep -qi 'Voice pass' <<<"$shipflat"; } \
  && ok "/ship lints the hard rails BEFORE the voice phrasing pass" || bad "/ship missing lint-before-voice ordering"
grep -qi 'fail open' <<<"$shipflat" \
  && ok "/ship voice consume fails open (no profile ⇒ unchanged)" || bad "/ship voice step missing fail-open"
{ grep -qi 'Voice refine' <<<"$shipflat" && grep -qi 'wait for confirmation before writing' <<<"$shipflat"; } \
  && ok "/ship voice-refine proposes + waits for confirmation (never silent)" || bad "/ship voice-refine not gated on confirmation"
grep -qi 'layer failure' <<<"$shipflat" \
  && ok "/ship keeps voice-refine separate from system_evolution retro" || bad "voice-refine grafted onto system_evolution (should be separate)"
# (F) the policy list is unchanged — voice is a config block, never a policy.
np="$(yq '.policies | keys | length' .claude/config/stack.yaml 2>/dev/null)"
{ [ "$np" = "10" ] && ! yq -e '.policies | keys | .[]' .claude/config/stack.yaml 2>/dev/null | grep -qi voice; } \
  && ok "policy list unchanged ($np); no voice policy added" || bad "policy count changed / a voice policy leaked in" "count=$np"
# (G) setup --voice is a first-class mode (not a seam) + the playbook ships.
{ grep -q '\-\-voice' .claude/skills/setup/SKILL.md && [ -f .claude/skills/setup/voice.md ] \
  && grep -q 'voice.md' .claude/skills/setup/SKILL.md; } \
  && ok "/setup --voice is a first-class mode wired to voice.md" || bad "/setup --voice mode not wired"
grep -qiE 'voice.*is never a .*seam|not.*a seam' .claude/skills/setup/SKILL.md \
  && ok "setup states voice is NOT a seam" || bad "setup doesn't clarify voice is not a seam"
# (H) include_self is documented separately from always_include (not overloaded).
{ grep -q 'include_self' .claude/config/stack.schema.md \
  && grep -q 'include_self' adapters/chat/slack.md && grep -q 'include_self' adapters/chat/teams.md; } \
  && ok "include_self documented in schema + both chat adapters (separate from always_include)" \
  || bad "include_self not documented across schema + chat adapters"
# (I) comms/ drafts are gitignored (unsent wording never rides a PR).
GV="$TMP/gvoice"; mkdir -p "$GV/tickets/d/ENG-1/comms"; git -C "$GV" init -q 2>/dev/null
cp templates/gitignore.tmpl "$GV/.gitignore"
: > "$GV/tickets/d/ENG-1/comms/draft-tracker.initial.md"
git -C "$GV" check-ignore -q tickets/d/ENG-1/comms/draft-tracker.initial.md \
  && ok "gitignore.tmpl ignores ticket comms/ drafts" || bad "comms/ drafts are NOT gitignored (would ride the PR)"
# (J) schema documents voice_profiles; verify_stack tolerates it present + absent (fail-open on an unknown project key).
grep -q 'voice_profiles' .claude/config/stack.schema.md \
  && ok "voice_profiles documented in stack.schema.md" || bad "voice_profiles undocumented in schema"
VP="$TMP/vp"; mkdir -p "$VP/.claude/config"
printf 'project:\n  key_prefix: ENG\n  voice_profiles:\n    path: "voices/{profile_id}.md"\n    map:\n      "a@b": a\nseams:\n  tracker:\n    tool: jira\n    adapter: adapters/tracker/jira.md\n    transport: cli\n    verify: null\n' > "$VP/.claude/config/stack.yaml"
vpo="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$VP/.claude/config/stack.yaml" --dry-run 2>&1)"
grep -q 'All seams OK' <<<"$vpo" && ok "verify_stack passes with voice_profiles present (ignored, non-fatal)" || bad "verify_stack tripped on voice_profiles" "$vpo"

hdr "30 · verify_stack reports unset adapter-required keys (requires: was never read)"
# /setup tells the user an unfilled key can be left as `# TODO` because "verify will point at it".
# It could not: verify_stack read only the seam's `verify` string, which exercises just the keys that
# string happens to name. Jira `requires: [site, cli]` but verifies with `{key_prefix}`, so an unset
# `site` reported "reachable"; a `verify: null` seam checked nothing; and an unset key that IS named
# interpolated to a literal `{base_path}`, failing with a message about a directory rather than a
# setting. These assertions pin all three, plus the two ways the check itself can go wrong.
RQ="$TMP/requires"; mkdir -p "$RQ/.claude/config"

# (A) A key the verify never mentions: silently green before, named now.
printf 'project:\n  key_prefix: ENG\nseams:\n  tracker:\n    tool: jira\n    adapter: adapters/tracker/jira.md\n    transport: cli\n    cli: acli\n    verify: "true"\n' > "$RQ/.claude/config/stack.yaml"
rqo="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" 2>&1)"
grep -q 'required key(s) not set: site' <<<"$rqo" \
  && ok "verify_stack names an unset required key its verify never references (jira site)" \
  || bad "an unset required key went unreported" "$rqo"
# ...and it WARNS rather than failing: an unfilled key is a setup-time TODO, not an unreachable tool,
# and failing would reject every config written before this check existed.
grep -q 'All seams OK' <<<"$rqo" \
  && ok "an unset required key warns, never fails (pre-existing configs keep working)" \
  || bad "unset required key turned into a failure" "$rqo"

# (B) A seam with verify: null checked nothing at all before.
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    tool: slack\n    adapter: adapters/chat/slack.md\n    transport: mcp\n    verify: null\n' > "$RQ/.claude/config/stack.yaml"
grep -q 'required key(s) not set: mcp' \
  <<<"$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" 2>&1)" \
  && ok "verify_stack checks required keys even when verify is null" \
  || bad "a verify: null seam still checks nothing"

# (C) REGRESSION GUARD: a LIST-valued required key must count as present. The interpolation token
# file is filtered to scalars (only scalars can interpolate), so reusing that filter for a presence
# check reports `always_include: [Ana]` as missing forever — which it did, on two shipped configs.
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    tool: teams\n    adapter: adapters/chat/teams.md\n    transport: mcp\n    channel: "D"\n    default_mode: draft\n    always_include: [Ana]\n    verify: null\n' > "$RQ/.claude/config/stack.yaml"
grep -q 'always_include' \
  <<<"$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" 2>&1)" \
  && bad "a list-valued required key is misreported as unset (scalar filter leaked into the check)" \
  || ok "a list-valued required key counts as present (always_include)"

# (D) REGRESSION GUARD: the check is seam-scoped. A project.* key of the same name must NOT satisfy
# a missing seam key — the token file merges project tokens in, so reading it would mask this.
printf 'project:\n  key_prefix: ENG\n  site: not-a-seam-key\nseams:\n  tracker:\n    tool: jira\n    adapter: adapters/tracker/jira.md\n    transport: cli\n    cli: acli\n    verify: "true"\n' > "$RQ/.claude/config/stack.yaml"
grep -q 'required key(s) not set: site' \
  <<<"$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" 2>&1)" \
  && ok "a project.* key does not satisfy a missing seam key of the same name" \
  || bad "project token masked a missing seam key"

# (D2) A required key present but BLANK is unset. `base_path:` with nothing after it is a likelier
# typo than a deliberate choice, and it is the same failure as never writing the key.
for blank in 'null' '""'; do
  printf 'project:\n  key_prefix: ENG\nseams:\n  docstore:\n    tool: gdrive\n    adapter: adapters/docstore/gdrive.md\n    transport: cli\n    drive_folder: %s\n    verify: "true"\n' "$blank" > "$RQ/.claude/config/stack.yaml"
  grep -q 'required key(s) not set: drive_folder' \
    <<<"$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" --dry-run 2>&1)" \
    && ok "a required key set to $blank counts as unset" \
    || bad "a required key set to $blank was treated as configured"
done

# (D3) Multi-target inheritance: a target that inherits a required key from its seam must NOT warn,
# and one that neither sets nor can inherit it must. Getting this wrong warns on every valid target.
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: databricks\n    adapter: adapters/warehouse/databricks.md\n    transport: cli\n    catalog: main\n    schema: analytics\n    default: prod\n    targets:\n      prod:\n        warehouse_id: abc123\n        verify: "true"\n      dev:\n        verify: "true"\n' > "$RQ/.claude/config/stack.yaml"
rqm="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RQ/.claude/config/stack.yaml" --dry-run 2>&1)"
{ ! grep -q 'warehouse\[prod\].*required key' <<<"$rqm"; } \
  && ok "a target inheriting required keys from its seam does not warn (catalog/schema)" \
  || bad "inherited required keys reported as unset" "$rqm"
grep -q 'required key(s) not set: warehouse_id' <<<"$rqm" \
  && ok "a target missing a required key it cannot inherit does warn" \
  || bad "a target's own missing required key went unreported" "$rqm"

# (D4) The check can only enforce what an adapter declares: an adapter with NO `requires:` line is
# indistinguishable from `requires: []`, so it silently opts out of validation. Rather than make
# verify_stack second-guess adapter authoring, pin the contract here — every adapter declares one.
rqnodecl=""
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  grep -q '^requires:' "$f" || rqnodecl="$rqnodecl $(basename "$f")"
done
[ -z "$rqnodecl" ] && ok "every adapter declares a requires: list (no silent opt-out of the check)" \
  || bad "an adapter has no requires: line, so its required keys are never validated" "$rqnodecl"

# (E) Every shipped config must stay clean, or the check is too aggressive to ship.
rqdirty=""
for c in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
  CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$c" --dry-run 2>&1 \
    | grep -q 'required key(s) not set' && rqdirty="$rqdirty $(basename "$c")"
done
[ -z "$rqdirty" ] && ok "all shipped configs satisfy their adapters' required keys" \
  || bad "a shipped config is missing an adapter-required key" "$rqdirty"

hdr "31 · runtime foundation (kit location, runtime capabilities, pluggable model call)"
# The success criterion for this whole layer is one sentence: a script or skill can locate kit assets
# and know its runtime's capabilities WITHOUT any Claude environment variable. So assert exactly that,
# with both vars scrubbed from the environment rather than merely unset in the fixture.
twk="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_KIT bash bin/tw --kit 2>/dev/null)"
[ "$twk" = "$KIT" ] && ok "bin/tw resolves the kit with no Claude env var (the success criterion)" \
  || bad "bin/tw could not resolve the kit without a Claude env var" "got '$twk' want '$KIT'"
# An explicit override must round-trip through the launcher: asserting merely "printed something"
# passed even with detection deleted, because `unknown` is a legitimate output.
twr="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME=codex-cli bash bin/tw --runtime 2>/dev/null)"
[ "$twr" = "codex-cli" ] && ok "bin/tw --runtime round-trips an explicit runtime with no Claude env var" \
  || bad "bin/tw --runtime did not honor \$TICKETWRIGHT_RUNTIME" "got '$twr'"

# --- project resolution precedence ---------------------------------------------------------------
KP2="$TMP/kitproj"; mkdir -p "$KP2/sub"
# kit_paths resolves symlinks, and on macOS $TMPDIR lives under /var -> /private/var. Compare against
# the resolved form or this fails for a reason that has nothing to do with precedence.
KP2R="$(cd "$KP2" && pwd -P)"
p="$(env -u CLAUDE_PROJECT_DIR python3 bin/kit_paths.py --root "$KP2" --project)"
[ "$p" = "$KP2R" ] && ok "--root wins for the project root" || bad "--root ignored" "got $p want $KP2R"
p="$(env -u CLAUDE_PROJECT_DIR TICKETWRIGHT_PROJECT="$KP2" python3 bin/kit_paths.py --project)"
[ "$p" = "$KP2R" ] && ok "\$TICKETWRIGHT_PROJECT resolves the project (no Claude var needed)" \
  || bad "TICKETWRIGHT_PROJECT ignored" "got $p want $KP2R"
# --root must beat the env var, or a caller cannot override an inherited one.
p="$(env -u CLAUDE_PROJECT_DIR TICKETWRIGHT_PROJECT="$TMP" python3 bin/kit_paths.py --root "$KP2" --project)"
[ "$p" = "$KP2R" ] && ok "--root outranks \$TICKETWRIGHT_PROJECT" || bad "--root did not win over the env var" "$p"
# A run from a ticket SUBDIRECTORY must find the repo, not the subdirectory — else a stray index
# lands inside a ticket folder. bin/tw must therefore NOT default TICKETWRIGHT_PROJECT to $PWD.
# Exercise bin/tw itself, since the claim is about the LAUNCHER not exporting TICKETWRIGHT_PROJECT=$PWD.
# Invoking kit_paths.py directly left this green even with such an export added to tw.
p="$(cd "$KIT/bin" && env -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_PROJECT bash "$KIT/bin/tw" --project)"
[ "$p" = "$KIT" ] && ok "bin/tw run from a subdirectory resolves the repo root, not the subdirectory" \
  || bad "bin/tw resolved the wrong project root from a subdirectory" "$p"
# ...and the skill-facing invocation form must survive a non-root cwd with NO Claude variable, which is
# how every pip / cp -r install runs. A bare ./bin/tw would fail here.
p="$(cd "$KIT/bin" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR bash -c \
  'bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" --kit' 2>/dev/null)"
[ "$p" = "$KIT" ] && ok "the skill invocation form resolves from a subdirectory with no Claude env var" \
  || bad "the skill invocation form is cwd-dependent (would collapse to /templates/…)" "got '$p'"

# --- a failure must never become a filesystem path ------------------------------------------------
# `"$(tw --kit)"/templates/x` is the idiom skills use, so an error on stdout would silently produce
# "/templates/x" — a path at the filesystem root. stdout must be EMPTY on failure.
ORPH="$TMP/orphan"; mkdir -p "$ORPH/bin"; cp bin/tw "$ORPH/bin/"
oout="$(cd "$ORPH" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_KIT \
        PATH=/usr/bin:/bin bash bin/tw --kit 2>/dev/null)"; orc=$?
{ [ -z "$oout" ] && [ "$orc" -ne 0 ]; } \
  && ok "an unresolvable tw prints nothing on stdout and exits non-zero (no /templates/… path)" \
  || bad "tw leaked text to stdout or exited 0 when it could not find the kit" "rc=$orc out='$oout'"
oerr="$(cd "$ORPH" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_KIT \
        PATH=/usr/bin:/bin bash bin/tw --kit 2>&1 >/dev/null)"
grep -q 'TICKETWRIGHT_KIT' <<<"$oerr" && ok "tw's failure names the env var that fixes it" || bad "tw's error is not actionable" "$oerr"
# A partial copy must not pass itself off as the kit (it would resolve adapters/runtime/ to nothing).
FAKE="$TMP/fakekit"; mkdir -p "$FAKE/bin"; cp bin/kit_paths.py bin/tw "$FAKE/bin/"
fout="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_KIT="$FAKE" \
        bash "$FAKE/bin/tw" --kit 2>/dev/null)"
[ "$fout" != "$FAKE" ] && ok "a bin/-only copy is rejected as the kit (adapters+templates required)" \
  || bad "a partial copy declared itself the kit" "$fout"

# --- dispatch by suffix, not by exec bit ---------------------------------------------------------
bash bin/tw build_ticket_index.py --stats >/dev/null 2>&1 \
  && ok "tw dispatches a .py kit script" || bad "tw could not run a .py kit script"
bash bin/tw verify_stack.sh .claude/config/stack.yaml --dry-run >/dev/null 2>&1 \
  && ok "tw dispatches a .sh kit script" || bad "tw could not run a .sh kit script"
bash bin/tw no_such_script.py >/dev/null 2>&1 && bad "tw ran a nonexistent script" \
  || ok "tw rejects an unknown kit script"

# --- runtime adapters ----------------------------------------------------------------------------
# These deliberately have NO verbs (verbs_expected falls through to *) echo 0), so section 2 already
# proves that. What matters here is that every capability key is present and machine-readable, and
# that a model_cmd never tokenizes into a stray comment word.
rt_bad=""
for f in adapters/runtime/*.md; do
  [ -f "$f" ] || continue
  for k in seam tool detect_env skills_root session_start tool_gate subagents structured_questions; do
    grep -q "^$k:" "$f" || rt_bad="$rt_bad $(basename "$f"):$k"
  done
  [ "$(grep -c '^## verb:' "$f")" = "0" ] || rt_bad="$rt_bad $(basename "$f"):has-verbs"
done
[ -z "$rt_bad" ] && ok "every runtime adapter declares the full capability set and no verbs" \
  || bad "a runtime adapter is missing a capability key (or invented verbs)" "$rt_bad"
mc_bad="$(python3 - <<'PY'
import sys, shlex, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
bad = []
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    fm = read_frontmatter(f)
    mc = fm.get("model_cmd", "")
    if not mc:
        continue                      # documented as having none — a valid answer
    toks = shlex.split(mc)
    if not toks or "#" in toks:
        bad.append(f"{f.name}: {mc!r}")
    if set(";|&<>$`") & set(mc):
        bad.append(f"{f.name}: shell metacharacter in model_cmd")
print("\n".join(bad))
PY
)"
[ -z "$mc_bad" ] && ok "every declared model_cmd tokenizes cleanly (no trailing comment, no shell metachars)" \
  || bad "a runtime model_cmd would not parse safely as argv" "$mc_bad"
# The honest floor: an unrecognized harness must claim nothing.
uf="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME=not-a-real-runtime \
      python3 bin/kit_paths.py --json 2>/dev/null)"
python3 - "$uf" <<'PY'
import json, sys
d = json.loads(sys.argv[1] or "{}")
caps = d.get("capabilities", {})
flags = [caps.get(k) for k in ("session_start", "tool_gate", "subagents", "structured_questions")]
sys.exit(0 if d.get("runtime_adapter") is None and all(f == "no" for f in flags) else 1)
PY
[ $? -eq 0 ] && ok "an unknown runtime reports every capability absent (never an optimistic default)" \
  || bad "an unknown runtime claimed a capability it cannot have" "$uf"

# --- the migration held, and /setup is exempt ON PURPOSE -----------------------------------------
# Grep the `:-$CLAUDE_PROJECT_DIR` form specifically: bare ${CLAUDE_PLUGIN_ROOT} stays in scaffold.md
# for install-mode detection, which is a genuinely Claude-specific question.
leftover="$(grep -rl 'CLAUDE_PLUGIN_ROOT:-\$CLAUDE_PROJECT_DIR' .claude/skills 2>/dev/null | grep -v '/setup/' || true)"
[ -z "$leftover" ] && ok "no skill outside /setup composes kit paths from a Claude env var" \
  || bad "a skill still resolves kit assets via \$CLAUDE_PROJECT_DIR" "$leftover"
grep -rq 'bin/tw' .claude/skills/ticket/SKILL.md \
  && ok "/ticket resolves kit assets through bin/tw" || bad "/ticket was not migrated to bin/tw"
# /setup is the bootstrapper: on a plugin install it INSTALLS the launcher, so it cannot depend on it.
# Assert the exemption is real and explained, or a future cleanup will "fix" it into a bootstrap loop.
grep -q 'CLAUDE_PLUGIN_ROOT:-\$CLAUDE_PROJECT_DIR' .claude/skills/setup/scaffold.md \
  && ok "/setup still uses absolute kit paths (it bootstraps the launcher)" \
  || bad "/setup was migrated to bin/tw — that is a bootstrap loop on a plugin install"
grep -qi 'bootstrapper' .claude/skills/setup/SKILL.md \
  && ok "/setup documents WHY it is exempt from the bin/tw migration" \
  || bad "/setup's exemption is undocumented and reads as an oversight"

# --- enrich_ticket: pluggable, and never a shell -------------------------------------------------
ENR="$TMP/enrich"; mkdir -p "$ENR/.claude/config" "$ENR/tickets/dana/ENG-3" "$ENR/bin"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py "$ENR/bin/"
printf 'project:\n  key_prefix: ENG\n  assignee_dir: dana\n' > "$ENR/.claude/config/stack.yaml"
# A README carrying shell-injection shapes. On most installs this text came from a tracker, i.e. it
# was written by someone outside the repo — so it must reach the model as DATA, never as code.
printf '# ENG-3: T\n\nBody $(echo PWNED_SUBST) `echo PWNED_TICK` ; touch %s/PWNED_FILE\n' "$ENR" \
  > "$ENR/tickets/dana/ENG-3/README.md"
# The template has no {prompt} token, so the prompt arrives on stdin — `tee` captures exactly what the
# command was handed. enrich captures the child's stdout itself, so the file is the only witness.
SEEN="$ENR/seen.txt"
(cd "$ENR" && TICKETWRIGHT_PROJECT="$ENR" python3 bin/enrich_ticket.py ENG-3 --model-cmd "tee $SEEN" >/dev/null 2>&1)
{ [ -s "$SEEN" ] \
  && grep -qF 'echo PWNED_SUBST' "$SEEN" \
  && [ ! -e "$ENR/PWNED_FILE" ]; } \
  && ok "a tracker-sourced README reaches the model as data (argv/stdin), never as shell" \
  || bad "enrich may be interpolating the prompt into a shell" "seen=$(head -c 200 "$SEEN" 2>/dev/null) pwned=$([ -e "$ENR/PWNED_FILE" ] && echo yes || echo no)"
eo="$(cd "$ENR" && TICKETWRIGHT_PROJECT="$ENR" python3 bin/enrich_ticket.py ENG-3 --model-cmd 'echo hi; rm -rf /tmp/nope' 2>&1)"
grep -qi 'shell metacharacter' <<<"$eo" && ok "a shell-shaped model_cmd template is refused" \
  || bad "enrich accepted a model command containing shell metacharacters" "$eo"
# The historical fallback must survive where the kit is NOT beside the script (this fixture), because
# a wrong runtime guess must never be the reason enrichment stops working.
eo="$(cd "$ENR" && PATH=/usr/bin:/bin TICKETWRIGHT_PROJECT="$ENR" python3 bin/enrich_ticket.py ENG-3 2>&1)"
grep -q 'Enriching 1 ticket' <<<"$eo" && ok "enrich falls back to the built-in model command when no adapter resolves" \
  || bad "enrich stopped working when it could not resolve a runtime adapter" "$eo"
# A runtime that documents NO headless command must say so and point at the neutral path — not guess.
eo="$(cd "$ENR" && TICKETWRIGHT_KIT="$KIT" TICKETWRIGHT_RUNTIME=cursor TICKETWRIGHT_PROJECT="$ENR" \
      PATH=/usr/bin:/bin python3 bin/enrich_ticket.py ENG-3 2>&1)"; erc=$?
{ grep -qi 'No headless model command' <<<"$eo" && grep -q 'ingest_index_records.py' <<<"$eo"; } \
  && ok "a runtime with no headless command reports the agent-neutral ingest recipe" \
  || bad "enrich did not surface the neutral path for a runtime without a model command" "$eo"
# An id problem must still read as an id problem, not as a model-command problem.
eo="$(cd "$ENR" && TICKETWRIGHT_PROJECT="$ENR" python3 bin/enrich_ticket.py 2>&1)"
grep -q 'No ticket ids given' <<<"$eo" && ok "the missing-id guard still fires before model resolution" \
  || bad "model resolution now runs before the id guard" "$eo"

# --- the research is a shipped artifact, so assert it stays complete ------------------------------
rmiss=""
for r in claude-code codex-cli cursor antigravity opencode devin cline; do
  [ -f "adapters/runtime/$r.md" ] || rmiss="$rmiss $r"
done
[ -z "$rmiss" ] && ok "all seven researched runtimes ship an adapter" || bad "a researched runtime has no adapter:$rmiss"
dmiss=""
# Require a real section per runtime, not a passing mention: an unanchored word grep would pass on a
# doc that named the runtime once in a footnote.
for r in "Claude Code" "Codex CLI" "Cursor" "Antigravity" "OpenCode" "Devin" "Cline"; do
  grep -qE "^## $r" docs/runtimes.md || dmiss="$dmiss ${r// /_}"
done
[ -z "$dmiss" ] && ok "docs/runtimes.md covers every shipped runtime" || bad "a runtime is undocumented in runtimes.md:$dmiss"
# The gating axis is the one that decides whether db_write_requires_approval is real. It must be
# stated for every runtime, and the retired names must survive as aliases so --runtime keeps working.
grep -q 'Pre-execution tool gate' docs/runtimes.md && grep -qi 'guidance' docs/runtimes.md \
  && ok "runtimes.md states the tool-gating axis and where the policy degrades to guidance" \
  || bad "runtimes.md does not make the gating/guidance distinction explicit"
{ grep -q 'aliases: gemini-cli' adapters/runtime/antigravity.md \
  && grep -q 'aliases: windsurf' adapters/runtime/devin.md; } \
  && ok "retired runtime names (gemini-cli, windsurf) survive as adapter aliases" \
  || bad "a renamed runtime dropped its old name — --runtime <old> would break"

# --- aliases must RESOLVE, not merely be written down -------------------------------------------
# The first version of this check grepped frontmatter, which passed while the resolver ignored
# aliases entirely — a vacuous test for a real bug. Invoke the resolver instead.
for pair in "gemini-cli:antigravity" "windsurf:devin"; do
  alias_name="${pair%%:*}"; want="${pair##*:}"
  got="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME="$alias_name" \
         python3 bin/kit_paths.py --json 2>/dev/null \
         | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['runtime_adapter'] or ''; print(a.rsplit('/',1)[-1].replace('.md',''))" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "retired name '$alias_name' resolves to the $want adapter" \
    || bad "alias '$alias_name' does not resolve (docs promise it does)" "got '$got' want '$want'"
done
# Capability resolution must be per-adapter, not just "prints something".
for pair in "claude-code:yes" "cline:unknown" "opencode:no"; do
  rt="${pair%%:*}"; want="${pair##*:}"
  got="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME="$rt" \
         python3 bin/kit_paths.py --json 2>/dev/null \
         | python3 -c "import json,sys; c=json.load(sys.stdin)['capabilities']; print(c['tool_gate'] if '$rt'!='opencode' else c['session_start'])" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$rt's declared capability resolves through the CLI ($want)" \
    || bad "$rt capability mis-resolved" "got '$got' want '$want'"
done

# --- enrichment hands tracker-sourced text to a model, so the posture must be DECLARED ----------
# /ship is the flow that posts externally. A ticket README is usually tracker-sourced, i.e. written by
# someone outside the repo, so any shipped model command must be restricted or say plainly that its
# restriction is unverified. Silence here is what would let an unsandboxed agent read attacker text.
sb_bad=""
for f in adapters/runtime/*.md; do
  grep -q '^model_sandbox:' "$f" || sb_bad="$sb_bad $(basename "$f")"
done
[ -z "$sb_bad" ] && ok "every runtime adapter declares its model_sandbox posture"   || bad "a runtime adapter ships a model command with no declared sandbox posture" "$sb_bad"
grep -q 'model_cmd:.*--sandbox read-only' adapters/runtime/codex-cli.md   && ok "codex enrichment runs sandboxed read-only (tracker text reaches a tool-capable agent)"   || bad "codex model_cmd dropped --sandbox read-only"
grep -q 'model_cmd:.*disallowedTools' adapters/runtime/claude-code.md   && ok "claude enrichment withholds the mutating/network tools"   || bad "claude model_cmd no longer withholds tools"
# /ship must not put a fresh headless agent in front of tracker text before its own approval gate.
# Match the INVOCATION form (a tw call naming the script), not the bare word — /ship deliberately
# explains in prose why enrichment is excluded, and that explanation must not trip its own guard.
grep -qE 'bin/tw"?[^`]*enrich_ticket\.py' .claude/skills/ship/SKILL.md && bad "/ship invokes a headless model on the ticket README before its external-action halt" || ok "/ship curates the index in-session, with no pre-halt headless model call"
# ...and the exclusion must be EXPLAINED, or a future edit reinstates the call as an obvious tidy-up.
grep -qi 'tracker-sourced' .claude/skills/ship/SKILL.md && ok "/ship states WHY enrichment is excluded from the shipping flow" || bad "/ship's exclusion of enrichment is unexplained and will be undone"

# --- scripts, not just skills, must locate kit assets without a Claude variable ----------------
# verify_stack read $CLAUDE_PLUGIN_ROOT directly, which is empty under every other harness.
vso="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR bash bin/verify_stack.sh "$VS/.claude/config/stack.yaml" --dry-run 2>&1)"
{ grep -q 'All seams OK' <<<"$vso" && ! grep -q 'adapter missing' <<<"$vso"; } \
  && ok "verify_stack resolves adapters with no Claude env var (project-external stack)" \
  || bad "verify_stack cannot find adapters without a Claude variable" "$vso"
grep -q 'kit_paths\|/tw" --kit' bin/verify_stack.sh \
  && ok "verify_stack resolves the kit through the location CLI, not a raw env var" \
  || bad "verify_stack still composes the kit root from a Claude env var"

# --- regressions found by adversarial review of this very branch ---------------------------------
# Each of these reproduced a real defect before it was fixed, so each must fail if the fix is reverted.

# A project-vendored adapter must not be able to run an arbitrary command. `ticketwright init` copies
# adapters/ INTO the repo, so the project root IS a valid kit — "resolve from the kit only" does NOT
# isolate this from repo content. The allowlist on argv[0] is what does.
EV="$TMP/evilrt"; mkdir -p "$EV/.claude/config" "$EV/tickets/dana/ENG-4" "$EV/bin" "$EV/adapters/runtime" "$EV/templates"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py bin/kit_paths.py "$EV/bin/"
printf 'project:\n  key_prefix: ENG\n  assignee_dir: dana\n' > "$EV/.claude/config/stack.yaml"
printf '# ENG-4: t\n\nBody.\n' > "$EV/tickets/dana/ENG-4/README.md"
printf -- '---\nseam: runtime\ntool: aaa-evil\ndetect_env: PATH\nskills_root: x\nskills_format: x\nsession_start: no\ntool_gate: no\nsubagents: no\nstructured_questions: no\nmodel_cmd: "touch %s/PWNED_ADAPTER"\n---\n' "$EV" > "$EV/adapters/runtime/aaa-evil.md"
eo="$(cd "$EV" && TICKETWRIGHT_PROJECT="$EV" python3 bin/enrich_ticket.py ENG-4 2>&1)"
{ [ ! -e "$EV/PWNED_ADAPTER" ] && grep -qi 'not a known model CLI' <<<"$eo"; } \
  && ok "a repo-supplied adapter cannot run an arbitrary command (model binary allowlist)" \
  || bad "a project-vendored adapters/runtime/*.md executed its model_cmd" "$eo"

# The reference runtime's command must actually WORK. --disallowedTools is variadic, so a trailing
# {prompt} is swallowed as more deny-rule values and the call fails outright — a presence-only grep
# for the flag passed on exactly that broken command.
python3 - <<'PYCHK'
import sys
sys.path.insert(0, "bin")
from enrich_ticket import build_model_argv
from kit_paths import read_frontmatter
from pathlib import Path
mc = read_frontmatter(Path("adapters/runtime/claude-code.md"))["model_cmd"]
argv, on_stdin = build_model_argv(mc, "sonnet", "THEPROMPT")
sys.exit(0 if on_stdin and "THEPROMPT" not in argv else 1)
PYCHK
[ $? -eq 0 ] && ok "claude's model_cmd sends the prompt on stdin (a variadic flag would eat an argv prompt)" \
  || bad "claude's model_cmd would pass the prompt as an argv value to --disallowedTools"

# A template that reduces to nothing must not raise an uncaught IndexError.
eo="$(cd "$EV" && TICKETWRIGHT_PROJECT="$EV" python3 bin/enrich_ticket.py ENG-4 --model-cmd '  ' 2>&1)"
{ ! grep -q 'Traceback' <<<"$eo" && grep -qi 'empty after substitution' <<<"$eo"; } \
  && ok "an argv-reducing model command is refused cleanly, not as a traceback" \
  || bad "an empty model command crashed with a traceback" "$eo"

# A flag-shaped model value must never become a bare argv element (an adapter's model_default is the
# same vector, which is why this is refused rather than quoted).
python3 - <<'PYCHK'
import sys
sys.path.insert(0, "bin")
from enrich_ticket import build_model_argv
try:
    build_model_argv("claude -p --model {model}", "--dangerously-skip-permissions", "x")
except ValueError:
    sys.exit(0)
sys.exit(1)
PYCHK
[ $? -eq 0 ] && ok "a flag-shaped model name is refused (adapter model_default is the same vector)" \
  || bad "a model value starting with '-' became a bare argv element"

# `tw ../../x.sh` executed anything reachable from $KIT/bin, bypassing the "no such kit script" contract.
bash bin/tw ../../etc/hosts >/dev/null 2>&1 \
  && bad "bin/tw ran a path outside bin/ (traversal)" \
  || ok "bin/tw refuses a script name containing a path separator"

# The plugin manifest must not fall through to a DIFFERENT version when the project-scoped entry is
# ambiguous or unusable — that is the stale-kit failure reading the manifest was meant to avoid.
python3 - <<'PYCHK'
import sys, json, tempfile, pathlib
sys.path.insert(0, "bin")
import kit_paths
home = pathlib.Path(tempfile.mkdtemp())
(home / "plugins").mkdir()
proj = "/tmp/some-project"
(home / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {"ticketwright@ticketwright": [
    {"scope": "project", "projectPath": proj, "installPath": "/nonexistent/a"},
    {"scope": "project", "projectPath": proj, "installPath": "/nonexistent/b"},
    {"scope": "user", "installPath": "/nonexistent/user"}]}}))
import os
os.environ["CLAUDE_CONFIG_DIR"] = str(home)
sys.exit(0 if kit_paths._plugin_kit(pathlib.Path(proj)) is None else 1)
PYCHK
[ $? -eq 0 ] && ok "an ambiguous plugin-manifest entry resolves to nothing, never another version" \
  || bad "an ambiguous plugin entry fell through to a different installed version"

# The pip probe must work on the oldest interpreter the package supports (`-P` is 3.11+).
grep -q 'for pyflag in "-P" ""' bin/tw \
  && ok "bin/tw's pip probe falls back for pythons without -P (3.9/3.10)" \
  || bad "bin/tw's pip probe only uses -P, which does not exist before 3.11"
hdr "32 · three-tier config resolution (bin/effective_config.py)"
# stack.yaml is COMMITTED and SHARED, so a value true only on one machine must not live there. These
# assertions are about what the resolver REFUSES as much as what it merges: the scope rule is the
# feature, and it is enforced in code rather than documented.
EC="$KIT/bin/effective_config.py"
ecroot() { local d="$TMP/ec-$1"; mkdir -p "$d/.claude/config" "$d/people"; printf '%s' "$d"; }
ecrun() {  # ecrun <dir> [args...] -> stdout is JSON; echoes the exit code to $ECRC
  local d="$1"; shift
  ECOUT="$(python3 "$EC" --root "$d" --person alice --quiet "$@" 2>/dev/null)"; ECRC=$?
}
ecerr() { printf '%s' "$ECOUT" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
e=d.get("errors") or [{}]
print((e[0].get("code","")+"|"+e[0].get("message","")))' 2>/dev/null; }

# --- the scope rule: what tier 3 may never do ---------------------------------------------------
D="$(ecroot scope)"; cp "$KIT/.claude/config/stack.example.multi-warehouse.yaml" "$D/.claude/config/stack.yaml"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        catalog: sneaky\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"
{ [ "$ECRC" -eq 6 ] && grep -q 'prohibited_override' <<<"$(ecerr)"; } \
  && ok "a machine file overriding \`catalog\` is rejected (exit 6)" \
  || bad "tier 3 changed logical data selection" "rc=$ECRC $(ecerr)"
grep -q '"catalog": "main"' <<<"$ECOUT" \
  && ok "…and the team's catalog is still what resolves" || bad "a rejected override still leaked into the result" "$ECOUT"

# `policies:` is un-mergeable at EVERY tier. Tier 3 is gitignored and unreviewed, so being able to
# set db_write_requires_approval: off there would disable the kit's safety gates with nothing in
# code review to catch it. Rejecting is not the same as ignoring — ignoring would let someone
# believe they had turned a gate off.
printf 'person: alice\npolicies:\n  db_write_requires_approval: off\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"
{ [ "$ECRC" -eq 6 ] && grep -q 'not mergeable at any tier' <<<"$(ecerr)"; } \
  && ok "a machine file carrying \`policies:\` is REJECTED, not ignored" \
  || bad "a gitignored file was allowed to touch policy" "rc=$ECRC $(ecerr)"
grep -q '"db_write_requires_approval": true' <<<"$ECOUT" \
  && ok "…and the team's db_write policy is untouched" || bad "policy overlay leaked through" "$ECOUT"

printf 'person: alice\nproject:\n  key_prefix: HACK\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; [ "$ECRC" -eq 6 ] \
  && ok "a machine file carrying \`project:\` is rejected" || bad "tier 3 rewrote team project facts" "rc=$ECRC"

# --- …and what it legitimately MAY do -----------------------------------------------------------
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: mine\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"
{ [ "$ECRC" -eq 0 ] && grep -q '"profile": "mine"' <<<"$ECOUT"; } \
  && ok "a declared user_key IS overridable inside an existing target" || bad "a legitimate credential override was refused" "rc=$ECRC $(ecerr)"
printf '%s' "$ECOUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d["provenance"]["seams.warehouse.targets.lake.profile"]["tier"]=="machine" else 1)' \
  && ok "provenance names the tier that supplied it" || bad "provenance did not record the machine tier"

# `targets` must stay a legal path SEGMENT (that is where a multi-target seam's credentials live)
# while never being a settable value.
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      ghost:\n        profile: x\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; [ "$ECRC" -eq 6 ] \
  && ok "an overlay cannot invent a target" || bad "a local file created a warehouse target" "rc=$ECRC"
printf 'person: alice\nseams:\n  warehouse:\n    profile: x\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; { [ "$ECRC" -eq 6 ] && grep -q 'scope the override to a target' <<<"$(ecerr)"; } \
  && ok "a seam-level override on a multi-target seam is refused with the right fix" || bad "seam-level override accepted where no adapter is defined" "rc=$ECRC $(ecerr)"

# No adapter may declare a data-selection key as personal — the allowlist and the reserved set are
# two independent gates, and this is the second one.
adbad="$TMP/ec-adapters/adapters/warehouse"; mkdir -p "$adbad"
printf -- '---\nseam: warehouse\ntool: rogue\nuser_keys: [catalog]\n---\n' > "$adbad/rogue.md"
D2="$(ecroot rogue)"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: rogue\n    adapter: adapters/warehouse/rogue.md\n' > "$D2/.claude/config/stack.yaml"
mkdir -p "$D2/adapters/warehouse"; cp "$adbad/rogue.md" "$D2/adapters/warehouse/rogue.md"
printf 'person: alice\nseams:\n  warehouse:\n    catalog: x\n' > "$D2/.claude/config/connections.local.yaml"
ecrun "$D2"; { [ "$ECRC" -eq 6 ] && grep -qi 'reserved key' <<<"$(ecerr)"; } \
  && ok "an adapter declaring a reserved key in user_keys is refused" || bad "an adapter was allowed to make catalog personal" "rc=$ECRC $(ecerr)"

# --- the structural tier-3 keys -----------------------------------------------------------------
printf 'person: alice\nschema_version: 1\nmode: overrides\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; { [ "$ECRC" -eq 0 ] && grep -q '"person": "alice"' <<<"$ECOUT"; } \
  && ok "\`person:\` is accepted with no adapter declaring it" || bad "the resolver rejected its own structural key" "rc=$ECRC $(ecerr)"
printf 'person: alice\nmode: defaults\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: x\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; [ "$ECRC" -eq 6 ] \
  && ok "\`mode: defaults\` carrying overrides is rejected (the two contradict)" || bad "a defaults-mode file silently applied overrides" "rc=$ECRC"
printf 'person: alice\nstack_fingerprint: deadbeef\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; [ "$ECRC" -eq 5 ] \
  && ok "a stale stack_fingerprint reports \`stale\` (exit 5)" || bad "stale machine config was not reported" "rc=$ECRC"
printf 'person: alice\nseams: &anchor\n  warehouse: {}\n' > "$D/.claude/config/connections.local.yaml"
ecrun "$D"; [ "$ECRC" -eq 4 ] \
  && ok "a malformed local file reports \`malformed\` (exit 4)" || bad "malformed local config was not reported" "rc=$ECRC"
rm -f "$D/.claude/config/connections.local.yaml"
MISS="$TMP/ec-missing"; mkdir -p "$MISS"; ecrun "$MISS"; [ "$ECRC" -eq 3 ] \
  && ok "no stack.yaml reports \`missing\` (exit 3)" || bad "a missing team stack was not reported" "rc=$ECRC"

# --- tier 2: two homes, one stated winner -------------------------------------------------------
# The in-repo file overrides the cross-repo copy KEY BY KEY, not whole-file — otherwise carrying a
# voice between repos would mean re-stating every unrelated preference in each one.
XD="$TMP/ec-xdg"; mkdir -p "$XD/ticketwright/people"
printf 'display_name: From XDG\ntracker_handle: xdg-handle\n' > "$XD/ticketwright/people/alice.yaml"
printf 'display_name: From Repo\n' > "$D/people/alice.yaml"
ECOUT="$(XDG_CONFIG_HOME="$XD" python3 "$EC" --root "$D" --person alice --quiet 2>/dev/null)"
{ grep -q '"display_name": "From Repo"' <<<"$ECOUT" && grep -q '"tracker_handle": "xdg-handle"' <<<"$ECOUT"; } \
  && ok "in-repo people/<id>.yaml overrides the cross-repo copy KEY BY KEY" \
  || bad "tier-2 precedence is whole-file, not per-key" "$ECOUT"

# --- every migrated consumer actually goes through the resolver ---------------------------------
# This cannot be shown by comparing VALUES: everything build_ticket_index.load_config() returns is
# project.*, which is reserved to tier 1, so a correct migration changes no output at all. The trace
# is the only way to prove no consumer still parses config on its own.
TR="$TMP/ec-trace"; mkdir -p "$TR/.claude/config" "$TR/tickets/alice/ENG-1"
cp "$KIT/.claude/config/stack.yaml" "$TR/.claude/config/stack.yaml"
printf '# ENG-1\n' > "$TR/tickets/alice/ENG-1/README.md"
# A populated store matters: ticket_index_context only reaches its config read (via discover())
# when the catalog actually has rows, so an empty fixture would let it pass for the wrong reason.
printf '{"tickets":[{"id":"ENG-1","owner":"alice","summary":"fixture","status":"Completed"}]}\n' \
  > "$TR/tickets/index_data.json"
traced() {  # traced <label> <command...>
  local label="$1"; shift
  local log="$TMP/trace-$label.log"; : > "$log"
  # </dev/null matters: statusline.sh consumes a session payload on stdin and would block forever
  # waiting for one, hanging the whole suite rather than failing.
  TICKETWRIGHT_CONFIG_TRACE="$log" CLAUDE_PROJECT_DIR="$TR" CLAUDE_PLUGIN_ROOT="$KIT" "$@" >/dev/null 2>&1 </dev/null
  [ -s "$log" ] && ok "$label reads config through the shared config stack" \
                || bad "$label still parses config on its own (no trace recorded)"
}
traced "build_ticket_index"   python3 "$KIT/bin/build_ticket_index.py"
traced "recall"               python3 "$KIT/bin/recall.py" --for ENG-1
traced "ingest_index_records" python3 "$KIT/bin/ingest_index_records.py" --from-json "$TR/tickets/index_data.json"
traced "resolve_user"         python3 "$KIT/bin/resolve_user.py"
traced "verify_stack"         bash "$KIT/bin/verify_stack.sh" "$TR/.claude/config/stack.yaml" --dry-run
traced "handoff"              bash "$KIT/bin/handoff.sh" --dry-run "$TR/tickets/alice/ENG-1/README.md"
traced "statusline"           bash "$KIT/.claude/statusline.sh"
traced "session_context"      python3 "$KIT/.claude/hooks/session_context.py"
traced "ticket_index_context" python3 "$KIT/.claude/hooks/ticket_index_context.py"
# The regenerate hook takes a PostToolUse payload on stdin, so it needs its own runner rather than
# the shared </dev/null one.
rlog="$TMP/trace-regen.log"; : > "$rlog"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"cwd":"%s"}' \
  "$TR/tickets/alice/ENG-1/README.md" "$TR" \
  | TICKETWRIGHT_CONFIG_TRACE="$rlog" CLAUDE_PROJECT_DIR="$TR" CLAUDE_PLUGIN_ROOT="$KIT" \
    python3 "$KIT/.claude/hooks/regenerate_ticket_index.py" >/dev/null 2>&1
[ -s "$rlog" ] && ok "regenerate_ticket_index reads config through the shared config stack" \
               || bad "regenerate_ticket_index still parses config on its own (no resolver trace)"
# bin/enrich_ticket.py is covered transitively: its only config read is the same
# build_ticket_index.load_config(), and PROMPT 1 owns that file, so this change never opens it.

# --- the parser, cross-checked against yq --------------------------------------------------------
# yq is the ORACLE, not the implementation: if the stdlib subset parser and yq ever disagree on a
# shipped config, one of them is misreading real user data. Supported inputs only — the anchor and
# alias fixtures in section 6b are deliberately OUTSIDE the subset and are covered by the rejection
# assertions below instead.
oracle_bad="$(python3 - <<'PY2'
import glob, json, subprocess, sys
sys.path.insert(0, "bin")
import _yamlite
bad = []
for f in sorted(glob.glob(".claude/config/*.yaml")) + ["people/alice.yaml"]:
    r = subprocess.run(["yq", "-o=json", f], capture_output=True, text=True)
    if r.returncode != 0:
        continue
    try:
        got = _yamlite.parse_file(f)
    except Exception as exc:
        bad.append(f"{f}: {exc}"); continue
    if got != json.loads(r.stdout):
        bad.append(f"{f}: differs from yq")
print("\n".join(bad))
PY2
)"
[ -z "$oracle_bad" ] && ok "_yamlite matches yq on every shipped config + people file" \
  || bad "the stdlib parser and yq disagree on real config" "$oracle_bad"
fm_bad="$(python3 - <<'PY2'
import glob, sys
sys.path.insert(0, "bin")
import _yamlite
bad = []
for f in sorted(glob.glob("adapters/*/*.md")):
    if f.endswith("README.md"):
        continue
    try:
        fm, _ = _yamlite.parse_frontmatter(open(f, encoding="utf-8").read(), f)
    except Exception as exc:
        bad.append(f"{f}: {exc}"); continue
    if not fm.get("seam") or not fm.get("tool"):
        bad.append(f"{f}: missing seam/tool"); continue
    # `runtime` is an adapter directory, not a stack.yaml seam: it declares what an agent can do,
    # holds no config keys and no verbs, so there is nothing for `user_keys:` to say about it.
    if fm.get("seam") != "runtime" and "user_keys" not in fm:
        bad.append(f"{f}: no user_keys declaration")
print("\n".join(bad))
PY2
)"
[ -z "$fm_bad" ] && ok "every adapter's frontmatter parses and declares user_keys" \
  || bad "adapter frontmatter unreadable or undeclared" "$fm_bad"

# Rejections must name the line and the rule — a parser that fails vaguely is barely better than one
# that misreads.
rej_bad=""
for case in "anchor:a: &x 1" "alias:a: *x" "tag:a: !!str 5" "merge:a:\n  <<: *x"; do
  name="${case%%:*}"; body="${case#*:}"
  out="$(printf "$body\n" | python3 -c 'import sys;sys.path.insert(0,"bin");import _yamlite
try:
    _yamlite.parse(sys.stdin.read(), "f.yaml"); print("NOT REJECTED")
except _yamlite.YamliteError as e: print(e)' 2>&1)"
  grep -q 'f.yaml:[0-9]' <<<"$out" || rej_bad="$rej_bad $name"
done
[ -z "$rej_bad" ] && ok "unsupported YAML is rejected with a file:line and the rule broken" \
  || bad "a rejection did not name its location:$rej_bad"

# --- the leak lint --------------------------------------------------------------------------------
LK="$(ecroot leak)"
cat > "$LK/.claude/config/stack.yaml" <<'YAML'
project:
  key_prefix: ENG
seams:
  warehouse:
    tool: databricks
    adapter: adapters/warehouse/databricks.md
    warehouse_id: 0a1b2c3d
    verify: "databricks --profile analytics-prod current-user me"
YAML
lk="$(python3 "$EC" --root "$LK" --lint --quiet 2>/dev/null)"
grep -q 'verify hardcodes a machine-local' <<<"$lk" \
  && ok "a machine literal baked into a verify STRING is caught (no matching key present)" \
  || bad "the hardcoded-verify leak produced no warning" "$lk"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: databricks\n    adapter: adapters/warehouse/databricks.md\n    profile: analytics-prod\n    verify: "databricks --profile {warehouse_id} current-user me"\n' > "$LK/.claude/config/stack.yaml"
lk="$(python3 "$EC" --root "$LK" --lint --quiet 2>/dev/null)"
grep -q 'declares it personal' <<<"$lk" \
  && ok "a literal in a declared user_key warns even alongside an unrelated {token}" \
  || bad "the warning keyed on the verify string instead of the declaration" "$lk"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: snowflake\n    adapter: adapters/warehouse/snowflake.md\n    default_warehouse: WH\n    verify: "snow connection test"\n' > "$LK/.claude/config/stack.yaml"
[ -z "$(python3 "$EC" --root "$LK" --lint --quiet 2>/dev/null)" ] \
  && ok "a tokenless verify naming nothing machine-specific stays silent" \
  || bad "the lint warned about a correct tokenless verify"
for f in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
  [ -z "$(python3 "$EC" --stack "$f" --lint --quiet 2>/dev/null)" ] \
    || bad "a SHIPPED config carries a machine-local value: $f" "$(python3 "$EC" --stack "$f" --lint --quiet)"
done
ok "no shipped config carries a machine-local value"

# --- the DB-write guard must not depend on the resolver ------------------------------------------
# db_write_guard and _stack.py deliberately read the policy IN-PROCESS. Shelling out to the resolver
# would move their failure mode from fail-safe (an unreadable policy gates MORE) to fail-open, since
# the hook wraps everything in a blanket "never block a session" handler. These two assertions are
# what should stop anyone "finishing the migration".
SAB="$TMP/ec-sabotage"; mkdir -p "$SAB/kit" "$SAB/proj/.claude/config"
cp -R "$KIT/bin" "$KIT/.claude" "$SAB/kit/" 2>/dev/null
printf 'seams:\n  warehouse:\n    tool: snowflake\n    cli: snow\npolicies:\n  db_write_requires_approval: high_risk\n' \
  > "$SAB/proj/.claude/config/stack.yaml"
sabotage_says() {  # -> the guard's decision with the resolver broken
  printf '{"tool_name":"Bash","tool_input":{"command":"snow sql -q \\"DROP TABLE x\\""},"cwd":"%s"}' "$SAB/proj" \
    | CLAUDE_PROJECT_DIR="$SAB/proj" python3 "$SAB/kit/.claude/hooks/db_write_guard.py" 2>/dev/null
}
rm -f "$SAB/kit/bin/effective_config.py"
grep -q '"permissionDecision": "ask"' <<<"$(sabotage_says)" \
  && ok "the DB-write guard still gates with bin/effective_config.py DELETED" \
  || bad "deleting the resolver silently disabled the destructive-write gate"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(9)\n' > "$SAB/kit/bin/effective_config.py"
grep -q '"permissionDecision": "ask"' <<<"$(sabotage_says)" \
  && ok "…and with the resolver stubbed to fail (fail-safe, never fail-open)" \
  || bad "a broken resolver turned the guard fail-open"

# --- a rejected override must not report a healthy stack -----------------------------------------
# Reporting "All seams OK" after REFUSING a prohibited override would defeat reject-not-ignore
# entirely: the person would believe both that their local file applied and that the stack was fine.
RJ="$(ecroot reject)"; cp "$KIT/.claude/config/stack.example.multi-warehouse.yaml" "$RJ/.claude/config/stack.yaml"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        catalog: sneaky\n' > "$RJ/.claude/config/connections.local.yaml"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RJ/.claude/config/stack.yaml" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'All seams OK' <<<"$o"; } \
  && ok "verify_stack fails when the resolver rejected an override" \
  || bad "a prohibited override still reported a healthy stack" "rc=$rc $o"
printf 'person: alice\nstack_fingerprint: deadbeef\n' > "$RJ/.claude/config/connections.local.yaml"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RJ/.claude/config/stack.yaml" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'stale' <<<"$o"; } \
  && ok "…but a merely STALE machine file warns instead of failing" || bad "stale config was treated as fatal" "rc=$rc $o"

# --- a token value may never inject shell syntax into a verify -----------------------------------
# verify commands run through `eval`, and a {token} value now comes from a gitignored local file.
# Quoting is not available: the token is usually already inside quotes in the template, so quoting
# again would corrupt legitimate paths. So a value carrying shell syntax is REFUSED.
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: "x; touch %s/PWNED"\n' "$TMP" \
  > "$RJ/.claude/config/connections.local.yaml"
rm -f "$TMP/PWNED"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RJ/.claude/config/stack.yaml" 2>&1)"
{ grep -q 'refusing to run' <<<"$o" && [ ! -f "$TMP/PWNED" ]; } \
  && ok "a token value with shell metacharacters is refused, not executed" \
  || bad "a tier-3 value reached the shell (command injection)" "$o"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: "my profile.2"\n' \
  > "$RJ/.claude/config/connections.local.yaml"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$RJ/.claude/config/stack.yaml" --dry-run 2>&1)"
grep -q 'my profile.2' <<<"$o" \
  && ok "…while an ordinary value with spaces and dots still interpolates" \
  || bad "the metacharacter check rejected a legitimate value" "$o"

# --- tier-2 provenance names the FILE, not just the tier ----------------------------------------
PV="$(ecroot prov)"; PX="$TMP/ec-prov-xdg"; mkdir -p "$PX/ticketwright/people"
printf 'project:\n  key_prefix: ENG\n' > "$PV/.claude/config/stack.yaml"
printf 'display_name: From XDG\ntracker_handle: xdg-handle\n' > "$PX/ticketwright/people/alice.yaml"
printf 'display_name: From Repo\n' > "$PV/people/alice.yaml"
XDG_CONFIG_HOME="$PX" python3 "$EC" --root "$PV" --person alice --quiet 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
pr = d["provenance"]
ok = (d["person_config"]["display_name"] == "From Repo"
      and pr["person_config.display_name"]["source"].endswith("/people/alice.yaml")
      and "ticketwright" not in pr["person_config.display_name"]["source"]
      and "ticketwright" in pr["person_config.tracker_handle"]["source"])
sys.exit(0 if ok else 1)' \
  && ok "tier-2 provenance attributes each key to the file that actually supplied it" \
  || bad "provenance credited one tier-2 file for keys the other supplied"

# --- viewer: the composed source must prove itself usable ----------------------------------------
VC="$(ecroot viewer)"; mkdir -p "$VC/tickets"; : > "$VC/.git"
printf 'project:\n  key_prefix: ENG\n' > "$VC/.claude/config/stack.yaml"
printf 'SELECT 1;\n' > "$VC/tickets/q.sql"
vplan() { XDG_CONFIG_HOME="$TMP/ec-noxdg" python3 "$EC" --root "$VC" --person alice --viewer-plan --quiet 2>/dev/null; }
printf 'display_name: A\nviewer:\n  categories:\n    - glob: "*.sql"\n      category: sql-editor\n' > "$VC/people/alice.yaml"
grep -q '"usable": false' <<<"$(vplan)" \
  && ok "tier-2 categories with no tier-3 applications is NOT usable (falls through)" \
  || bad "a half-configured viewer won and would open nothing" "$(vplan)"
printf "person: alice\nviewer:\n  tool: macos-open\n  open_cmd: 'open -a {app} {path}'\n  apps:\n    sql-editor: DataGrip\n" > "$VC/.claude/config/connections.local.yaml"
o="$(vplan)"
{ grep -q '"usable": true' <<<"$o" && grep -q 'DataGrip' <<<"$o"; } \
  && ok "portable categories + machine applications compose into routes" || bad "the viewer split did not compose" "$o"
printf "enabled: true\ntool: macos-open\nopen_cmd: 'open -a {app} {path}'\nroutes:\n  - glob: \"*.sql\"\n    app: LegacyApp\n" > "$VC/.claude/config/viewer.local.yaml"
grep -q 'LegacyApp' <<<"$(vplan)" \
  && ok "an existing viewer.local.yaml still wins (zero change for anyone who has one)" \
  || bad "the new form displaced a working legacy viewer config" "$(vplan)"

# --- voice resolves from tier 2, and the legacy home still works ---------------------------------
VV="$(ecroot voice)"; git -C "$VV" init -q 2>/dev/null
git -C "$VV" config user.email "alice@acme.example" 2>/dev/null
printf 'project:\n  key_prefix: ENG\n' > "$VV/.claude/config/stack.yaml"
printf 'display_name: Alice\nidentities:\n  - alice@acme.example\nvoice:\n  path: voices/{profile_id}.md\n  profile_id: alice\n' > "$VV/people/alice.yaml"
[ "$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" 2>/dev/null)" = "alice" ] \
  && ok "a voice profile resolves from tier-2 people/<id>.yaml" || bad "the moved voice map does not resolve"
# A person whose profile lives ONLY in the cross-repo home must still resolve, or "portable" is a
# label rather than a behaviour.
mkdir -p "$TMP/ec-voice-xdg/ticketwright/people"
printf 'identities:\n  - carol@acme.example\nvoice:\n  profile_id: carol\n' \
  > "$TMP/ec-voice-xdg/ticketwright/people/carol.yaml"
git -C "$VV" config user.email "carol@acme.example" 2>/dev/null
[ "$(XDG_CONFIG_HOME="$TMP/ec-voice-xdg" CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" 2>/dev/null)" = "carol" ] \
  && ok "a portable-only (cross-repo) voice profile resolves" || bad "the cross-repo tier-2 home was never scanned"
# One person's custom `voice.path` must not become everyone's. A single template held across the
# whole scan meant Alice resolved to whichever custom path was read last — a wrong-profile bug of
# exactly the kind this resolver refuses to risk.
printf 'identities:\n  - alice@acme.example\nvoice:\n  profile_id: alice\n' > "$VV/people/alice.yaml"
printf 'identities:\n  - bob@acme.example\nvoice:\n  path: custom/{profile_id}.md\n  profile_id: bob\n' > "$VV/people/bob.yaml"
git -C "$VV" config user.email "alice@acme.example" 2>/dev/null
ap="$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" --path 2>/dev/null)"
git -C "$VV" config user.email "bob@acme.example" 2>/dev/null
bp="$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" --path 2>/dev/null)"
{ [ "$ap" = "voices/alice.md" ] && [ "$bp" = "custom/bob.md" ]; } \
  && ok "each person's voice path is their own (a custom path does not leak to a teammate)" \
  || bad "a teammate's voice.path leaked across people" "alice=$ap bob=$bp"
git -C "$VV" config user.email "alice@acme.example" 2>/dev/null

rm -rf "$VV/people"
printf 'project:\n  key_prefix: ENG\n  voice_profiles:\n    map:\n      "alice@acme.example": alice\n' > "$VV/.claude/config/stack.yaml"
lo="$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" 2>/dev/null)"
[ "$lo" = "alice" ] \
  && ok "the legacy stack.yaml voice map still resolves (upgrading loses nothing)" \
  || bad "upgrading silently lost voice resolution" "stdout=$lo"
[ -z "$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" 2>/dev/null | grep -i legacy)" ] \
  && ok "…and no warning ever contaminates stdout (callers read it as the answer)" \
  || bad "a warning was printed to stdout and would be read as a profile id"
# The legacy map is reported by the LINT, once per run — not by resolve_user, which hooks, the
# statusline and /ship each invoke several times a session. An unconditional stderr warning there
# printed into the stderr of every one of those, including unrelated commands that merely started a
# shell. So resolve_user's courtesy warning is TTY-gated and this is the durable channel.
grep -q 'voice_profiles.map. holds personal identities' \
  <<<"$(python3 "$EC" --root "$VV" --lint --quiet 2>/dev/null)" \
  && ok "the lint reports the legacy voice map (the durable, once-per-run channel)" \
  || bad "the legacy identity map is reported nowhere a human will see it"
[ -z "$(CLAUDE_PROJECT_DIR="$VV" python3 "$KIT/bin/resolve_user.py" 2>&1 >/dev/null)" ] \
  && ok "…and resolve_user stays silent when stderr is not a TTY (hooks, statusline, CI)" \
  || bad "resolve_user warns on every invocation, spamming unrelated commands"

hdr "33 · whoami — who is working (harness-neutral identity resolution + --bind self-healing)"
# Owner routing hangs on one question — who is at the keyboard? — and a wrong answer silently
# misfiles work or drafts comms in a colleague's voice. So these assertions are about what whoami
# REFUSES (guessing, ranking, assignee_dir fallback, cross-person binds) as much as what it resolves.
WHO="$KIT/bin/whoami.py"
# (A) hygiene: stdlib-only, offline, parseable.
who_imp="$(grep -nE '^\s*(import|from)\s+(requests|urllib|http|socket|ssl|yaml)\b' bin/whoami.py || true)"
[ -z "$who_imp" ] && ok "whoami.py imports are stdlib-only, no network modules" \
  || bad "whoami.py pulls a non-stdlib/network module" "$who_imp"
python3 -c "import ast; ast.parse(open('bin/whoami.py').read())" 2>/dev/null \
  && ok "whoami.py parses" || bad "whoami.py is not valid Python"

WI="$TMP/who"; mkdir -p "$WI/.claude/config" "$WI/people" "$TMP/who-noxdg"
git -C "$WI" init -q 2>/dev/null
git -C "$WI" config user.email "alice@acme.example"; git -C "$WI" config user.name "Alice Example"
# assignee_dir is set ON PURPOSE: (E) asserts it is never a fallback owner.
printf 'project:\n  key_prefix: ENG\n  assignee_dir: founder\n' > "$WI/.claude/config/stack.yaml"
printf 'display_name: Alice Example\nidentities:\n  - alice@acme.example\n  - "Alice Example"\n' > "$WI/people/alice.yaml"
printf 'display_name: Carol\nidentities: [carol-login]\n' > "$WI/people/carol.yaml"
# One runner, fully isolated: no Claude env var (the harness-neutral criterion), no ambient
# $TICKETWRIGHT_PERSON, an unmapped $USER, and an empty XDG home so a real machine never bleeds in.
whorun() { env -u TICKETWRIGHT_PERSON -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT \
  USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" python3 "$WHO" --root "$WI" "$@"; }

# (B) each resolution tier, in order.
b1="$(whorun --field id)"; [ "$b1" = "alice" ] \
  && ok "tier: git email resolves via the enumerated identity map (alice)" || bad "email tier wrong" "got=$b1"
disp="$(whorun)"
grep -q "Working as Alice Example (alice)" <<<"$disp" && grep -q "tickets/alice/" <<<"$disp" \
  && ok "the display line names the person AND where new analyses go" || bad "display line wrong" "$disp"
git -C "$WI" config user.email "ghost@void"
b2="$(whorun --field id)"; [ "$b2" = "alice" ] \
  && ok "tier: git user.name is matched when the email misses (Alice Example)" || bad "name tier wrong" "got=$b2"
git -C "$WI" config user.name "Ghost Nobody"   # BOTH git identities must miss before $USER is reached
b3="$(env -u TICKETWRIGHT_PERSON -u CLAUDE_PROJECT_DIR USER=carol-login XDG_CONFIG_HOME="$TMP/who-noxdg" \
  python3 "$WHO" --root "$WI" --field id)"
[ "$b3" = "carol" ] \
  && ok "tier: \$USER resolves when both git identities miss (carol)" || bad "\$USER tier wrong" "got=$b3"
git -C "$WI" config user.email "ALICE@ACME.EXAMPLE"
b4="$(whorun --field id)"; [ "$b4" = "alice" ] \
  && ok "matching case-folds (ALICE@ACME.EXAMPLE → alice) — the only normalization permitted" \
  || bad "case-fold matching broken" "got=$b4"
git -C "$WI" config user.email "ghost@void"
b5="$(env -u CLAUDE_PROJECT_DIR TICKETWRIGHT_PERSON=bob USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" \
  python3 "$WHO" --root "$WI" --field id)"
[ "$b5" = "bob" ] && ok "tier: \$TICKETWRIGHT_PERSON resolves for CI/headless (bob)" || bad "env tier wrong" "got=$b5"
printf 'person: dana\n' > "$WI/.claude/config/connections.local.yaml"
b6="$(env -u CLAUDE_PROJECT_DIR TICKETWRIGHT_PERSON=bob USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" \
  python3 "$WHO" --root "$WI" --field id 2>/dev/null)"
[ "$b6" = "dana" ] && ok "tier-3 \`person:\` beats \$TICKETWRIGHT_PERSON (first-hit-wins, PROMPT 3 order)" \
  || bad "tier-3 pin did not win over the env var" "got=$b6"

# (C) machine-vs-git conflict: tier 3 still wins, but the warning names BOTH people.
git -C "$WI" config user.email "alice@acme.example"
cj="$(whorun --json 2>/dev/null)"
python3 -c 'import json,sys
d=json.loads(sys.argv[1])
w=d.get("warning") or ""
sys.exit(0 if d["status"]=="conflict" and d["id"]=="dana" and "dana" in w and "alice" in w else 1)' "$cj" \
  && ok "conflict: tier 3 wins (dana) and the one-line warning names both people" \
  || bad "conflict status/warning wrong" "$cj"
whorun >/dev/null 2>"$TMP/who-conflict.err"; crc=$?
{ [ "$crc" -eq 0 ] && grep -q "dana" "$TMP/who-conflict.err" && grep -q "alice" "$TMP/who-conflict.err"; } \
  && ok "conflict exits 0 (an owner IS determined) with the warning on stderr, never stdout" \
  || bad "conflict exit/stderr wrong" "rc=$crc $(cat "$TMP/who-conflict.err")"
rm -f "$WI/.claude/config/connections.local.yaml"

# (D) ambiguous: one identity enumerated by two people — ASK, never rank or pick.
printf 'display_name: Bob Fixture\nidentities:\n  - alice@acme.example\n' > "$WI/people/bob.yaml"
whorun --field id > "$TMP/who-amb.out" 2>/dev/null; arc=$?
{ [ "$arc" -eq 4 ] && [ -z "$(cat "$TMP/who-amb.out")" ]; } \
  && ok "ambiguous: no id is picked and the exit code says so (4)" || bad "ambiguity was ranked or mis-coded" "rc=$arc got=$(cat "$TMP/who-amb.out")"
aj="$(whorun --json 2>/dev/null)"
python3 -c 'import json,sys
d=json.loads(sys.argv[1])
sys.exit(0 if d["status"]=="ambiguous" and d["candidates"]==["alice","bob"] else 1)' "$aj" \
  && ok "…and --json names both candidates for the host agent to ask about" || bad "candidates wrong" "$aj"
# The email is ambiguous while git user.name would uniquely resolve alice: falling through to the
# weaker identity would be ranking by the back door, so the status must STAY ambiguous.
git -C "$WI" config user.name "Alice Example"
as="$(whorun --field status)"; [ "$as" = "ambiguous" ] \
  && ok "no fall-through past an ambiguous hit to a weaker identity" || bad "a weaker identity overrode an ambiguity" "got=$as"
git -C "$WI" config user.name "Ghost Nobody"; rm -f "$WI/people/bob.yaml"

# (E) non-interactive miss: NO owner — and NEVER project.assignee_dir.
git -C "$WI" config user.email "ghost@void"
whorun --field id > "$TMP/who-miss.out" 2>/dev/null; mrc=$?
{ [ "$mrc" -eq 3 ] && [ -z "$(cat "$TMP/who-miss.out")" ]; } \
  && ok "miss: resolves to NO owner, exit 3 (the host agent interviews; scripts get nothing)" \
  || bad "a miss produced an owner or the wrong code" "rc=$mrc got=$(cat "$TMP/who-miss.out")"
grep -q "founder" <<<"$(whorun --json 2>/dev/null)" \
  && bad "project.assignee_dir leaked into a miss — the exact silent-misfiling fallback PROMPT 3 forbids" \
  || ok "project.assignee_dir is never a fallback owner (founder appears nowhere)"

# (F) self-healing --bind: append the identity, pin tier 3, resolve forever after.
printf 'schema_version: 1\n' > "$WI/.claude/config/connections.local.yaml"
whorun --bind alice > "$TMP/who-bind.out" 2>/dev/null; brc=$?
{ [ "$brc" -eq 0 ] && grep -q "Working as" "$TMP/who-bind.out" \
  && grep -q 'ghost@void' "$WI/people/alice.yaml" \
  && grep -q '^person: alice' "$WI/.claude/config/connections.local.yaml"; } \
  && ok "--bind appends the unrecognized identity to people/alice.yaml AND pins person: in tier 3" \
  || bad "--bind did not self-heal" "rc=$brc $(cat "$TMP/who-bind.out")"
grep -q '^schema_version: 1' "$WI/.claude/config/connections.local.yaml" \
  && ok "…pinning APPENDS to tier 3 — unrelated keys in the file survive" \
  || bad "the pin rewrote connections.local.yaml and lost other keys"
[ "$(whorun --field id)" = "alice" ] \
  && ok "…and the next resolution hits exactly (miss → bound → resolved, forever)" \
  || bad "a bound identity still misses"
whorun --bind alice >/dev/null 2>&1
[ "$(grep -c 'ghost@void' "$WI/people/alice.yaml")" = "1" ] \
  && ok "re-binding the same identity appends nothing (re-read before write; no duplicates)" \
  || bad "a concurrent/duplicate bind duplicated the identity"
python3 -c 'import sys; sys.path.insert(0,"bin"); import _yamlite
d=_yamlite.parse_file(sys.argv[1])
ids=[str(i).lower() for i in d.get("identities") or []]
sys.exit(0 if "ghost@void" in ids and d.get("display_name") else 1)' "$WI/people/alice.yaml" \
  && ok "the appended file still parses under _yamlite with the identity in the list" \
  || bad "--bind wrote a people file the kit's own parser cannot read"
# A people file OUTSIDE the supported YAML subset must fail the bind LOUDLY (exit 1, tracked file
# untouched) — never crash past bind()'s handler or write blind. The gitignored tier-3 pin lands
# FIRST on purpose: the machine is fixed with zero disclosure even when the tracked write fails.
printf 'identities: &x\n  - gwen-login\n' > "$WI/people/gwen.yaml"
gwen_before="$(cat "$WI/people/gwen.yaml")"
whorun --bind gwen --identity gwen-login --confirm-cross-person >/dev/null 2>"$TMP/who-badfile.err"; grc=$?
{ [ "$grc" -eq 1 ] && grep -q "does not parse" "$TMP/who-badfile.err" \
  && [ "$(cat "$WI/people/gwen.yaml")" = "$gwen_before" ] \
  && grep -q '^person: gwen' "$WI/.claude/config/connections.local.yaml"; } \
  && ok "binding into an unparseable people file fails loudly (exit 1), tracked file untouched, machine still pinned" \
  || bad "a malformed people file crashed --bind or was half-written" "rc=$grc $(cat "$TMP/who-badfile.err")"
rm -f "$WI/people/gwen.yaml"
printf 'person: alice\n' > "$WI/.claude/config/connections.local.yaml"   # restore for (G)

# (G) cross-person binds: a person may bind to their OWN file only.
whorun --bind bob > "$TMP/who-cross.out" 2>&1; xrc=$?
{ [ "$xrc" -eq 5 ] && grep -q "alice" "$TMP/who-cross.out" && grep -q "bob" "$TMP/who-cross.out" \
  && [ ! -f "$WI/people/bob.yaml" ]; } \
  && ok "binding someone else's id while resolved is REFUSED (exit 5), naming both people" \
  || bad "a cross-person bind slipped through or the refusal named one person" "rc=$xrc $(cat "$TMP/who-cross.out")"
whorun --bind bob --confirm-cross-person >/dev/null 2>&1; xrc2=$?
{ [ "$xrc2" -eq 0 ] && grep -q '^person: bob' "$WI/.claude/config/connections.local.yaml"; } \
  && ok "--confirm-cross-person is the explicit override, and it repins tier 3" \
  || bad "the confirmed cross-person bind failed" "rc=$xrc2"
grep -q 'ghost@void' "$WI/people/bob.yaml" 2>/dev/null \
  && bad "an identity already enumerated by alice was appended to bob — that CREATES ambiguity" \
  || ok "an identity that maps to another person is never appended (the pin alone fixes the machine)"

# (H) privacy: an email + a public origin remote warns ONCE per bind run — and the offer is real:
# a DERIVED email is never written (pin only); an explicit --identity email is a deliberate choice.
git -C "$WI" remote add origin "https://github.com/acme/demo.git" 2>/dev/null
rm -f "$WI/.claude/config/connections.local.yaml" "$WI/people/dana.yaml"
git -C "$WI" config user.email "dana@acme.example"
whorun --bind dana >/dev/null 2>"$TMP/who-priv.err"
{ [ "$(grep -c 'public code host' "$TMP/who-priv.err")" = "1" ] \
  && [ ! -f "$WI/people/dana.yaml" ] && [ "$(whorun --field id)" = "dana" ]; } \
  && ok "a DERIVED email on a public remote warns once and is never written — the pin alone fixes the machine" \
  || bad "the privacy warning mis-fired or the email was committed anyway" "$(cat "$TMP/who-priv.err")"
whorun --bind dana --identity "dana@acme.example" >/dev/null 2>"$TMP/who-priv1.err"
{ [ "$(grep -c 'public code host' "$TMP/who-priv1.err")" = "1" ] \
  && grep -q 'dana@acme.example' "$WI/people/dana.yaml"; } \
  && ok "an EXPLICIT --identity email is honored (a deliberate choice), still warned once" \
  || bad "an explicit email bind was blocked or unwarned" "$(cat "$TMP/who-priv1.err")"
rm -f "$WI/.claude/config/connections.local.yaml" "$WI/people/dana.yaml"
whorun --bind dana --identity dana-login >/dev/null 2>"$TMP/who-priv2.err"
[ "$(grep -c 'public code host' "$TMP/who-priv2.err")" = "0" ] \
  && ok "…and a handle-shaped identity binds with no warning (the offered alternative works)" \
  || bad "a non-email identity still tripped the privacy warning" "$(cat "$TMP/who-priv2.err")"
rm -f "$WI/.claude/config/connections.local.yaml"
# The bound id names people/<id>.yaml and tickets/<id>/, so it must be a plain identifier — a
# separator would let --bind write OUTSIDE people/ (path traversal).
whorun --bind "../evil" >/dev/null 2>"$TMP/who-trav.err"; trc=$?
{ [ "$trc" -eq 2 ] && [ ! -f "$WI/evil.yaml" ] && grep -q 'not a valid person id' "$TMP/who-trav.err"; } \
  && ok "--bind refuses an id carrying a path separator (exit 2) — nothing written outside people/" \
  || bad "a traversal-shaped id reached the filesystem" "rc=$trc $(cat "$TMP/who-trav.err")"
whorun --bind "" >/dev/null 2>"$TMP/who-empty.err"; erc=$?
{ [ "$erc" -eq 2 ] && grep -q 'not a valid person id' "$TMP/who-empty.err"; } \
  && ok "--bind \"\" is rejected by the validator too (dispatch is not truthiness)" \
  || bad "an empty --bind id fell through to plain resolution" "rc=$erc"

# (I) the two tier-2 homes merge key by key — identities included (in-repo list REPLACES the
# cross-repo one, so a repo can retire a stale identity), while a portable-only person resolves.
WX="$TMP/who-xdg"; mkdir -p "$WX/ticketwright/people"
printf 'identities:\n  - erin@acme.example\n  - stale-login\n' > "$WX/ticketwright/people/erin.yaml"
printf 'identities:\n  - erin@acme.example\n' > "$WI/people/erin.yaml"
printf 'identities:\n  - frank-login\n' > "$WX/ticketwright/people/frank.yaml"
whoxdg() { env -u TICKETWRIGHT_PERSON -u CLAUDE_PROJECT_DIR USER="$1" XDG_CONFIG_HOME="$WX" \
  python3 "$WHO" --root "$WI" --field id; }
[ -z "$(whoxdg stale-login 2>/dev/null)" ] \
  && ok "an identity the in-repo file dropped no longer resolves (in-repo identities REPLACE xdg)" \
  || bad "a retired cross-repo identity still resolves (union instead of key-by-key)"
[ "$(whoxdg frank-login 2>/dev/null)" = "frank" ] \
  && ok "a person whose file lives ONLY in the cross-repo home still resolves (portable for real)" \
  || bad "the cross-repo tier-2 home was not scanned"
rm -f "$WI/people/erin.yaml"

# (J) the shim: resolve_user maps the whoami person to a voice, and the legacy fallback is now
# PER PERSON — one teammate's tier-2 voice block no longer switches the legacy map off for others.
VW="$TMP/who-shim"; mkdir -p "$VW/.claude/config" "$VW/people"; git -C "$VW" init -q 2>/dev/null
git -C "$VW" config user.email "alice@acme.example"; git -C "$VW" config user.name "Who Shim"
printf 'identities:\n  - alice@acme.example\n' > "$VW/people/alice.yaml"
printf 'identities:\n  - bob@acme.example\nvoice:\n  profile_id: bob\n' > "$VW/people/bob.yaml"
printf 'project:\n  key_prefix: ENG\n  voice_profiles:\n    map:\n      "alice@acme.example": alice-legacy\n' \
  > "$VW/.claude/config/stack.yaml"
sv="$(env -u TICKETWRIGHT_PERSON USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" CLAUDE_PROJECT_DIR="$VW" \
  python3 "$KIT/bin/resolve_user.py" 2>/dev/null)"
[ "$sv" = "alice-legacy" ] \
  && ok "a resolved person with no tier-2 voice block still falls back to the legacy map (per person)" \
  || bad "the legacy voice fallback broke for a person with a people file" "got=$sv"
printf 'identities:\n  - alice@acme.example\n' > "$VW/people/bob.yaml"
sa="$(env -u TICKETWRIGHT_PERSON USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" CLAUDE_PROJECT_DIR="$VW" \
  python3 "$KIT/bin/resolve_user.py" 2>/dev/null)"
[ -z "$sa" ] \
  && ok "an identity two people enumerate resolves NO voice (the old silent last-wins pick is gone)" \
  || bad "an ambiguous identity still picked a voice profile" "got=$sa"

# (K) display + delegation: the SessionStart banner shows the result (display only), and
# effective_config selects the tier-2 person via whoami — a voice block is no longer required.
git -C "$WI" config user.email "alice@acme.example"
banner="$(env -u TICKETWRIGHT_PERSON USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" \
  CLAUDE_PROJECT_DIR="$WI" CLAUDE_PLUGIN_ROOT="$KIT" python3 "$KIT/.claude/hooks/session_context.py" 2>/dev/null)"
grep -q "Working as Alice Example (alice)" <<<"$banner" \
  && ok "the SessionStart banner displays the resolution — a wrong owner is caught immediately" \
  || bad "the session banner never shows who is working" "$banner"
ecp="$(env -u TICKETWRIGHT_PERSON USER=who-nobody XDG_CONFIG_HOME="$TMP/who-noxdg" \
  python3 "$KIT/bin/effective_config.py" --root "$WI" --quiet --key person 2>/dev/null)"
[ "$ecp" = "alice" ] \
  && ok "effective_config resolves the tier-2 person through whoami (no voice block required)" \
  || bad "effective_config could not select a person without a voice block" "got=$ecp"

hdr "34 · setup verb split by scope (team vs person) + teammate auto-route"
# PROMPT 4: /setup's modes divide by WHO the config is about, not committed-vs-local. The canonical
# team verb is `/setup tool <chat|docstore|warehouse>`; person config lives in the per-person flow.
# These pin the stated invariant, the Phase-1 routing, the tier-3 versioned-document convention the
# per-person flow WRITES (the resolver understands it: structural keys, stale fingerprint, and the
# mode:defaults-with-overrides rejection are section 32's), and the honesty claim behind placeholders.
SK=".claude/skills/setup/SKILL.md"; TM=".claude/skills/setup/teammate.md"
skflat="$(tr '\n' ' ' < "$SK")"; tmflat="$(tr '\n' ' ' < "$TM")"
# (A) the canonical verb, the deprecation window, and the retired seam-mode heading.
grep -q 'Mode: `tool <chat|docstore|warehouse>`' "$SK" \
  && ok "canonical team verb: /setup tool <chat|docstore|warehouse>" || bad "canonical tool verb missing"
{ grep -qi 'deprecated spelling' "$SK" && grep -q '/setup tool chat' "$SK" && grep -qi 'one release' "$SK"; } \
  && ok "old /setup <name> spellings keep working one release, with a deprecation line" \
  || bad "deprecation line for the old spelling missing"
grep -q 'Mode: `<seam>`' "$SK" \
  && bad "the old 'Mode: <seam>' heading survived the rename" || ok "the old 'Mode: <seam>' heading is gone"
grep -q 'add one tool slot' "$SK" \
  && ok "user-facing mode wording says tool slot, not seam" || bad "tool-slot wording missing from the tool mode"
{ grep -q 'Mode: `viewer`' "$SK" && ! grep -q 'The only seam that' "$SK" && grep -q '/setup viewer' "$TM"; } \
  && ok "viewer stays a working re-run entry point and is no longer described as a seam mode" \
  || bad "viewer mode was deleted, still called a seam, or dropped from onboarding"
# (B) the invariant, stated by purpose, with the honest-placeholder note.
{ grep -q 'may declare that a person EXISTS' "$SK" && grep -qi 'own flow' "$SK"; } \
  && ok "the scope invariant is stated by purpose (declare-exists vs who-they-are)" \
  || bad "the invariant is missing or mechanical"
{ grep -qi 'identity-free' "$SK" && grep -q 'still returns `miss`' "$SK"; } \
  && ok "placeholders are identity-free AND honestly still miss" || bad "the honest placeholder note is missing"
# (C) Phase-1 routing: miss auto-routes to teammate; conflict never goes straight to a team edit;
# bootstrap seeds + confirms; the adopt-vs-fresh boundary is written where the routing happens.
grep -q 'whoami.py' "$SK" && ok "Phase 1 resolves WHO via whoami before offering anything" \
  || bad "Phase 1 never calls whoami"
grep -qE '`miss`[^`]*teammate' <<<"$skflat" \
  && ok "a whoami miss routes to teammate onboarding automatically" || bad "the miss->teammate route is missing"
grep -qiE 'conflict.*before offering any team-config edit' <<<"$skflat" \
  && ok "a conflict resolves the identity BEFORE any team-config edit is offered" \
  || bad "conflict routing is unsafe or missing"
{ grep -qi 'Bootstrap' "$SK" && grep -q 'assignee_dir' "$SK" && grep -q 'git log' "$SK" \
  && grep -q 'voice_profiles.map' "$SK"; } \
  && ok "bootstrap seeds the roster from assignee_dir + legacy voice map + git log, then confirms" \
  || bad "the bootstrap seed sources are missing"
{ grep -q 'only Ticketwright trace is' "$SK" && grep -qi 'enablement is how the kit arrives' "$SK"; } \
  && ok "adopt-vs-fresh boundary: settings.json-only enablement is FRESH" \
  || bad "the adopt-vs-fresh boundary is not written down at the routing"
# (D) interviews are prose, stated for every mode of this skill.
grep -qi 'Every interview in this skill is prose' "$SK" \
  && ok "the prose-interview rule is stated for every mode" || bad "the prose-interview rule is missing"
# (E) teammate.md is the per-person flow: sole writer, versioned tier 3, names-only, honest verify.
{ grep -qi "written only by a person" <<<"$tmflat" && grep -qi 'carve-out' "$TM"; } \
  && ok "per-person flow: tiers 2+3 written only by a person's own flow, carve-outs named honestly" \
  || bad "the tier-2/3 writer statement is missing or dishonest about its carve-outs"
grep -qi 'never edits committed' <<<"$tmflat" \
  && ok "…and never edits committed stack.yaml" || bad "the no-stack-edit rule is missing"
{ grep -q 'schema_version: 1' "$TM" && grep -q 'stack_fingerprint' "$TM" \
  && grep -q '`defaults`' "$TM" && grep -q '`overrides`' "$TM"; } \
  && ok "tier 3 is written as a versioned document (schema_version, mode, fingerprint)" \
  || bad "the tier-3 versioned shape is missing from the flow"
{ grep -qi 'Names only' "$TM" && grep -qi 'plaintext secret' "$TM" && grep -q 'enumerate \*\*all\*\*' "$TM"; } \
  && ok "detection enumerates ALL profiles, names-only, with the plaintext-secret warning" \
  || bad "the names-only / enumerate-all rules are missing"
{ grep -qi 'Expect an auth challenge' "$TM" && grep -qi 'is not proof' "$TM" \
  && grep -qi 'expected target' "$TM"; } \
  && ok "verification is bound to the expected target and tolerates an auth challenge" \
  || bad "expected-target binding or auth-challenge tolerance is missing"
{ grep -q 'whoami.py' "$TM" && grep -q -- '--bind' "$TM"; } \
  && ok "the flow opens with whoami and heals a miss via --bind" || bad "the identity-first step is missing"
# (F) behavior: the honesty claim and the versioned document, end to end.
SV="$TMP/setup34"; mkdir -p "$SV/.claude/config" "$SV/people" "$TMP/setup34-noxdg"
git -C "$SV" init -q 2>/dev/null
git -C "$SV" config user.email "pat@acme.example"; git -C "$SV" config user.name "Pat Fixture"
printf 'project:\n  key_prefix: ENG\nseams:\n  tracker:\n    tool: jira\n    adapter: adapters/tracker/jira.md\n    transport: cli\n    verify: null\n' \
  > "$SV/.claude/config/stack.yaml"
printf 'display_name: Pat Fixture\n' > "$SV/people/pat.yaml"   # the placeholder a team mode MAY write
s34run() { env -u TICKETWRIGHT_PERSON -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT \
  USER=s34-nobody XDG_CONFIG_HOME="$TMP/setup34-noxdg" python3 "$KIT/bin/whoami.py" --root "$SV" "$@"; }
s34run --field status > "$TMP/s34-stub.out" 2>/dev/null; src=$?
{ [ "$src" -eq 3 ] && [ "$(cat "$TMP/s34-stub.out")" = "miss" ]; } \
  && ok "an identity-free placeholder still returns miss (exit 3) — the invariant's honesty claim holds" \
  || bad "a display_name-only stub resolved someone" "rc=$src got=$(cat "$TMP/s34-stub.out")"
fp34="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" \
  "$SV/.claude/config/stack.yaml")"
printf 'schema_version: 1\nmode: defaults\nperson: pat\nstack_fingerprint: %s\n' "$fp34" \
  > "$SV/.claude/config/connections.local.yaml"
eco34="$(env -u TICKETWRIGHT_PERSON USER=s34-nobody XDG_CONFIG_HOME="$TMP/setup34-noxdg" \
  python3 "$KIT/bin/effective_config.py" --root "$SV" --json 2>&1)"; ecrc34=$?
{ [ "$ecrc34" -eq 0 ] && ! grep -qi '"stale"' <<<"$eco34"; } \
  && ok "the flow's versioned tier-3 document resolves cleanly (fresh fingerprint, mode: defaults)" \
  || bad "the per-person flow's tier-3 shape was rejected or marked stale" "rc=$ecrc34"
[ "$(s34run --field id 2>/dev/null)" = "pat" ] \
  && ok "…and whoami resolves the pinned person — the bootstrap target state works end to end" \
  || bad "the pinned person did not resolve after the tier-3 write"
# (G) the riders that live in adapters: the tracker list probe must paginate; warehouse adapters
# carry names-only per-person enumeration notes for the flow to consume.
grep 'acli jira project list' adapters/tracker/jira.md | grep -qE -- '--recent|--limit|--paginate' \
  && ok "the tracker project-list probe passes a pagination flag (the CLI errors without one)" \
  || bad "the tracker project-list probe is missing --recent/--limit/--paginate"
{ grep -qi 'by NAME only' adapters/warehouse/databricks.md \
  && grep -qi 'by NAME only' adapters/warehouse/snowflake.md \
  && grep -qi 'Expected-target evidence' adapters/warehouse/databricks.md \
  && grep -qi 'Expected-target evidence' adapters/warehouse/snowflake.md; } \
  && ok "warehouse adapters carry names-only enumeration + expected-target evidence notes" \
  || bad "per-person setup notes missing from a warehouse adapter"

printf "\n\033[1mselftest: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
