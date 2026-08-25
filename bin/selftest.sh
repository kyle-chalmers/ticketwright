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
# Python 3.12+ escalates invalid \-escapes in plain strings to SyntaxWarning printed on EVERY
# import — for a hook that means stderr noise on every single guard invocation (seen live on 3.14).
hookswarn=""
for hf in .claude/hooks/*.py; do
  python3 -W error::SyntaxWarning -c "compile(open('$hf').read(),'$hf','exec')" 2>/dev/null || hookswarn="$hookswarn $hf"
done
[ -z "$hookswarn" ] && ok "every hook compiles clean under -W error::SyntaxWarning (no per-invocation stderr noise)" \
  || bad "a hook raises SyntaxWarning on import — it will print on every tool call" "$hookswarn"

hdr "1 · config parses + every seam resolves to an adapter (kit example stacks)"
for s in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
  if yq -e '.seams|keys' "$s" >/dev/null 2>&1; then ok "parses: $s"; else bad "parse error: $s"; fi
  out="$(bash bin/verify_stack.sh "$s" --dry-run 2>&1)"
  if grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$out" && ! grep -q "adapter missing" <<<"$out"; then
    ok "kit example stack resolves: $s"
  else bad "seam resolution failed: $s" "$(grep -E 'missing|UNREACHABLE' <<<"$out" | head -2)"; fi
done

# The summary line must CARRY the truth, not paper over it: the kit's own Acme stack has an
# MCP-only chat seam and an unresolved docstore {base_path}, so a healthy run reports exactly
# which seams are unverified — a teammate shipped against "All seams OK." while Slack was
# completely unauthenticated, which is the failure this wording exists to prevent.
vs1="$(bash bin/verify_stack.sh .claude/config/stack.yaml --dry-run 2>&1)"; vs1rc=$?
{ [ "$vs1rc" -eq 0 ] \
  && grep -q '3 OK, 2 unverified (chat, docstore).' <<<"$vs1" \
  && grep -q 'MCP-only: not checkable from the shell' <<<"$vs1" \
  && grep -q 'skipped: unresolved {base_path}' <<<"$vs1" \
  && ! grep -q 'All seams OK' <<<"$vs1"; } \
  && ok "verify_stack summary counts unverified seams by name (never 'All seams OK.' over a warning)" \
  || bad "the verify_stack summary hides unverified seams" "rc=$vs1rc $(tail -3 <<<"$vs1")"

hdr "2 · adapter verb coverage matches the contract"
verbs_expected() {  # bash 3.2-safe (no associative arrays)
  case "$1" in
    tracker) echo 7;; warehouse) echo 3;; chat) echo 4;; docstore) echo 2;; vcs) echo 4;;
    viewer) echo 2;; meetings) echo 3;; *) echo 0;;
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
leaks="$(grep -REn -i 'acli|\bsnow \b|snow sql|mcp__slack|slack_send|\bgh pr\b|\bgh auth\b|ACCOUNT_USAGE|SHOW VIEWS|rclone (copy|sync|link|lsd|purge)' \
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
# Meetings-vendor names are the same leak: a skill naming Zoom/Fireflies/Granola/Notion silently
# scopes the tool-neutral meetings flow to one provider. Vendors live in adapters + stack.yaml only.
meetleaks="$(grep -REn -i '\bzoom\b|\bfireflies\b|\bgranola\b|\bnotion\b' \
              .claude/skills .claude/commands .claude/agents 2>/dev/null \
              | grep -v 'for c in snow acli gh' || true)"
[ -z "$meetleaks" ] && ok "no meeting-provider name appears in a skill/command/agent" \
  || bad "a skill names a specific meeting provider (scopes the meetings flow to one vendor)" "$meetleaks"

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
tracker_adapter=`adapters/tracker/jira.md`
warehouse_tool=snowflake
warehouse_adapter=`adapters/warehouse/snowflake.md`
chat_tool=slack
chat_adapter=`adapters/chat/slack.md`
docstore_tool=gdrive
docstore_adapter=`adapters/docstore/gdrive.md`
meetings_tool=zoom
meetings_adapter=`adapters/meetings/zoom.md`
vcs_tool=github
vcs_adapter=`adapters/vcs/github.md`
key_prefix=ENG
terminal_status=Done
wl_tracker_comment=100
wl_chat=100
wl_pr=200
wl_ticket=200
chat_always_include=Alice
default_branch=main
role_focus=**You are a senior engineer** doing ticket-driven work (filled from templates/roles/<role>.md).
analysis_tools=notebooks, spreadsheets
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
# MCP-issued SQL is OUTSIDE the guard's jurisdiction — the "matcher: Bash" registration plus the
# in-hook tool_name gate mean a warehouse MCP call never reaches it. That limit is documented
# (AGENTS.md.tmpl, stack.schema.md, both warehouse adapters); this pins the BEHAVIOR so the docs
# and the code cannot drift apart silently.
out="$(echo '{"tool_name":"mcp__snowflake__query","tool_input":{"statement":"DROP TABLE t"}}' | guard)"
[ -z "$out" ] && ok "mcp__* warehouse SQL is outside the guard's jurisdiction (documented limit, pinned)" \
  || bad "an mcp__* payload produced guard output — the documented Bash-only jurisdiction changed" "$out"
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
gstack nocli <<'YAML' >"$TMP/hd296.out"
seams:
  warehouse:
    tool: bigquery
    dataset: analytics
  tracker:
    tool: jira
    cli: acli
YAML
d="$(cat "$TMP/hd296.out")"
out="$(gask 'acli jira workitem create --summary x' "$d")"
[ -z "$out" ] && ok "cli-less warehouse before tracker: tracker CLI not gated" || bad "warehouse seam scan leaked into the tracker seam" "$out"

# Four-space indentation is valid YAML that yq reads; the scan must not assume two.
gstack indent4 <<'YAML' >"$TMP/hd310.out"
seams:
    warehouse:
        tool: custom
        cli: whcli
YAML
d="$(cat "$TMP/hd310.out")"
out="$(gask 'whcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "4-space-indented stack: warehouse CLI still gated" || bad "indent width narrowed CLI gating (destructive write would slip through)" "$out"

# A multi-target seam declares one CLI per target; a non-default target's CLI must be gated too.
gstack multi <<'YAML' >"$TMP/hd321.out"
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
d="$(cat "$TMP/hd321.out")"
out="$(gask 'trino --execute "UPDATE t SET x=1"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "multi-target: non-default target CLI gated" || bad "a non-default target's CLI is not gated" "$out"

# Prose inside a block scalar is not configuration — and the scan resumes after it, so a real
# `cli:` following the scalar is still harvested. Uses `|-` to cover the indicator modifiers.
#            `realcli` sits DEEPER than the `note:` header on purpose — that is what proves the
#            skip actually *ends*, rather than swallowing every remaining nested line.
gstack blockscalar <<'YAML' >"$TMP/hd341.out"
seams:
  warehouse:
    note: |-
      cli: not-a-cli
    default: prod
    targets:
      prod:
        cli: realcli
YAML
d="$(cat "$TMP/hd341.out")"
out="$(gask 'not-a-cli --do-something CREATE' "$d")"
[ -z "$out" ] && ok "block-scalar prose not harvested as a CLI" || bad "block-scalar body read as config" "$out"
out="$(gask 'realcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "scan resumes after a block scalar (deeper cli: still gated)" || bad "block-scalar skip swallowed the rest of the seam" "$out"

# A comment between `seams:` and the first seam must not hide it (comments carry no indentation).
gstack comment <<'YAML' >"$TMP/hd358.out"
seams:
    # which warehouse we point at
  warehouse:
    cli: cmtcli
YAML
d="$(cat "$TMP/hd358.out")"
out="$(gask 'cmtcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "comment before the first seam doesn't hide it" || bad "a comment's indentation hid the warehouse seam (gating narrowed)" "$out"

# Wrong-warehouse detection: right SQL, wrong target. A READ is gated too, because it returns
# plausible numbers about the wrong system rather than erroring — the failure mode this feature
# introduces. Only a CONFIRMED mismatch gates; an unknown name must never manufacture a prompt.
gstack wrongwh <<'YAML' >"$TMP/hd371.out"
seams:
  warehouse:
    default: prod
    targets:
      prod: {tool: snowflake, cli: snow}
      lake: {tool: databricks, cli: dbsqlcli}
YAML
d="$(cat "$TMP/hd371.out")"
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
gstack wrongwh1 <<'YAML' >"$TMP/hd392.out"
seams:
  warehouse:
    tool: snowflake
    cli: snow
YAML
d1="$(cat "$TMP/hd392.out")"
printf -- '-- warehouse-target: lake\nSELECT 1;\n' > "$d1/q.sql"
out="$(gask "snow sql -f $d1/q.sql" "$d1")"
! grep -q 'wrong warehouse' <<<"$out" && ok "single-warehouse repo: a stray target header changes nothing" \
  || bad "a single-mapping seam resolved an undefined target and gated" "$out"
# A quoted scalar is valid YAML. Leaving the quotes attached made every comparison mismatch, i.e. a
# false prompt on a correct command — the worst outcome for a guard, since dismissed prompts stop working.
gstack quotedcli <<'YAML' >"$TMP/hd405.out"
seams:
  warehouse:
    default: prod
    targets:
      prod: {tool: snowflake, cli: "snow"}
      lake: {tool: databricks, cli: 'dbsqlcli'}
YAML
dq="$(cat "$TMP/hd405.out")"
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
gstack wrongwh2 <<'YAML' >"$TMP/hd444.out"
seams:
  warehouse:
    default: prod
    cli: snow
    targets:
      prod: {tool: snowflake, default_warehouse: P}
      sbx:  {tool: snowflake, default_warehouse: S}
YAML
d2="$(cat "$TMP/hd444.out")"
printf -- '-- warehouse-target: sbx\nSELECT 1;\n' > "$d2/q.sql"
out="$(gask "snow sql -f $d2/q.sql" "$d2")"
! grep -q 'wrong warehouse' <<<"$out" && ok "targets inheriting one seam-level cli don't false-positive" \
  || bad "seam-level cli inheritance produced a bogus mismatch" "$out"

# A mapping key may carry a YAML anchor before its nested block; yq resolves it, so must the scan.
gstack yamlanchor <<'YAML' >"$TMP/hd460.out"
seams: &seam_map
  warehouse: &wh
    cli: anchcli
YAML
d="$(cat "$TMP/hd460.out")"
out="$(gask 'anchcli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "YAML anchor on seams:/warehouse: still gates" || bad "a YAML anchor hid the warehouse seam (gating narrowed)" "$out"

# A partial/malformed config with no `seams:` anchor is scanned whole rather than skipped —
# over-gating costs a prompt, under-gating runs an unreviewed write.
gstack noanchor <<'YAML' >"$TMP/hd471.out"
warehouse:
  cli: barecli
YAML
d="$(cat "$TMP/hd471.out")"
out="$(gask 'barecli -e "DROP TABLE x"' "$d")"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "no seams: anchor → still gates (fails safe)" || bad "config without a seams: key stopped gating entirely" "$out"

hdr "7 · session_context hook (SessionStart priming)"
# CLAUDE_CONFIG_DIR is pinned at an empty dir so this banner cannot vary with the CONTRIBUTOR'S own
# plugin install: .claude/settings.json is gitignored here, and the update-notice footer reads a real
# ~/.claude/plugins manifest when pointed at one. Section 50 exercises that footer on purpose.
out="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$KIT" \
  CLAUDE_CONFIG_DIR="$TMP/no-config" python3 .claude/hooks/session_context.py 2>&1)"
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
CLAUDE_PROJECT_DIR="$R" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 && ok "--check covers INDEX.md + OBJECTS.md (and the graph nodes — section 48)" || bad "--check failed after render"
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
  python3 - <<'PY' >"$TMP/hd590.out"
import json, re
try:
    d = json.load(open("tickets/index_data.json"))
except Exception:
    d = {}
ts = d.get("tickets", []) if isinstance(d, dict) else []
bad = [str(t.get("id", "")) for t in ts if not re.match(r"^(ENG|DEMO|TEST|SAMPLE)-", str(t.get("id", "")))]
print(" ".join(bad))
PY
  realids="$(cat "$TMP/hd590.out")"
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
python3 - <<'PY' >"$TMP/hd632.out"
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
fm_bad="$(cat "$TMP/hd632.out")"
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
# Claude Code's marketplace schema rejects a bare "." source (must start "./") and, on some
# versions, a root-level "description" (metadata.description is accepted everywhere). Both
# failures are SILENT on the declarative session-start path — a fresh clone just has no skills —
# so the shipped manifest is pinned to the shape every CC version accepts (observed live on
# 2.0.45 and 2.1.116).
python3 - <<'MKPY'
import json, sys
d = json.load(open('.claude-plugin/marketplace.json'))
p = next(p for p in d['plugins'] if p.get('name') == 'ticketwright')
ok = p.get('source','').startswith('./') and 'description' not in d and bool(d.get('metadata',{}).get('description'))
sys.exit(0 if ok else 1)
MKPY
[ $? -eq 0 ] && ok 'marketplace source starts "./" and description lives under metadata (installable on CC 2.0.x-2.1.x)' \
  || bad 'marketplace.json regressed to a shape older Claude Code rejects (source "." or root description)'
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
# Require positive success (a healthy summary: "All seams OK" or "N OK, M unverified"), not just the absence of "adapter missing" — else a
# fixture that failed to create would falsely pass (the seam here has verify:null, so success prints).
{ grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$vout" && ! grep -q 'adapter missing' <<<"$vout"; } \
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
python3 - <<'PY' >"$TMP/hd868.out"
import pathlib, re
pat = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-\d+\b")
allow = {"ENG", "DEMO", "TEST", "SAMPLE", "UTF", "SHA", "ISO", "RFC", "CVE", "PEP", "SOC"}
hits = []
for f in sorted(pathlib.Path("adapters").rglob("*.md")):
    for n, ln in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        hits += [f"{f}:{n}:{m.group(0)}" for m in pat.finditer(ln) if m.group(1) not in allow]
print("\n".join(hits))
PY
leak="$(cat "$TMP/hd868.out")"
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
# Graph nodes are owner-qualified (<owner>.<id>.md) — owner is part of ticket identity (section 35).
{ [ -f "$GX/tickets/graph/alice.ENG-1.md" ] && [ -f "$GX/tickets/graph/alice.ENG-2.md" ] && [ -f "$GX/tickets/graph/bob.ENG-3.md" ]; } \
  && ok "graph stubs generated (one per ticket, owner-qualified filename)" || bad "graph stubs missing"
{ [ -f "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md" ] && [ -f "$GX/tickets/objects/OPS.VW_CALL.md" ]; } \
  && ok "object notes generated (one per object)" || bad "object notes missing"
{ grep -q '(../graph/alice.ENG-1.md)' "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md" \
  && grep -q '(../graph/alice.ENG-2.md)' "$GX/tickets/objects/ANALYTICS.VW_ORDERS.md"; } \
  && ok "object note links the ticket stubs (VW_ORDERS -> ENG-1, ENG-2)" || bad "object note not linking stubs"
grep -q '\[ENG-1\](alice.ENG-1.md)' "$GX/tickets/graph/alice.ENG-2.md" \
  && ok "stub carries the cross-ref link, resolved within its own owner (ENG-2 -> alice's ENG-1)" || bad "stub missing cross-ref link"
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
{ [ ! -f "$GX/tickets/graph/bob.ENG-3.md" ] && [ ! -f "$GX/tickets/objects/OPS.VW_CALL.md" ]; } \
  && ok "orphan cleanup removes the stale stub + object note" || bad "orphan cleanup failed"
GO="$TMP/graphoff"; mkdir -p "$GO/.claude/config" "$GO/tickets/alice/ENG-1"
printf 'project:\n  key_prefix: ENG\n  graph_notes: false\n' > "$GO/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nx.\n' > "$GO/tickets/alice/ENG-1/README.md"
CLAUDE_PROJECT_DIR="$GO" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ ! -d "$GO/tickets/graph" ] && [ ! -d "$GO/tickets/objects" ]; } \
  && ok "graph_notes: false disables the layer" || bad "graph_notes flag not honored"
grep -q '(../objects/ANALYTICS.VW_ORDERS.md)' "$GX/tickets/graph/alice.ENG-1.md" \
  && ok "stub links its object notes (../objects/...)" || bad "stub does not link objects"
mkdir -p "$GX/tickets/alice/ENG-20"
printf '# ENG-20: hook test\n\nx.\n' > "$GX/tickets/alice/ENG-20/README.md"
printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$GX/tickets/alice/ENG-20/q.sql"
echo "{\"tool_input\":{\"file_path\":\"$GX/tickets/alice/ENG-20/README.md\"},\"cwd\":\"$GX\"}" \
  | CLAUDE_PROJECT_DIR="$GX" python3 .claude/hooks/regenerate_ticket_index.py >/dev/null 2>&1
[ -f "$GX/tickets/graph/alice.ENG-20.md" ] \
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
{ grep -q 'ENG-999' "$DR/tickets/graph/a.ENG-1.md" && ! grep -qE '\((a\.)?ENG-999\.md\)' "$DR/tickets/graph/a.ENG-1.md"; } \
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
    starting at `after`. Both guards matter: the Getting-started (Track 1) first fenced block is bash, so
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
# Getting-started Track 1 must actually PRODUCE a project-scoped install. Match the two specific command
# lines, not incidental occurrences of the flag elsewhere in the file.
{ grep -qE '^claude plugin marketplace add https://github\.com/kyle-chalmers/ticketwright\.git --scope project$' README.md \
  && grep -qE '^claude plugin install ticketwright@ticketwright --scope project$' README.md; } \
  && ok "README Track 1 installs at project scope (--scope project on both commands)" \
  || bad "README Track 1 must pass --scope project to BOTH marketplace add and plugin install (both default to user scope)"

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
{ [ "$mtrc" -eq 0 ] && grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$mtout"; } \
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
mtstack nodefault <<'YAML' >"$TMP/hd1209.out"
project: {key_prefix: ENG}
seams:
  warehouse:
    targets:
      prod: {tool: snowflake, adapter: adapters/warehouse/snowflake.md, verify: "true"}
YAML
f="$(cat "$TMP/hd1209.out")"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q "no 'default:'" <<<"$o"; } \
  && ok "targets: without default: fails closed" || bad "missing default: was accepted" "$o"
mtstack baddefault <<'YAML' >"$TMP/hd1220.out"
project: {key_prefix: ENG}
seams:
  warehouse:
    default: nope
    targets:
      prod: {tool: snowflake, adapter: adapters/warehouse/snowflake.md, verify: "true"}
YAML
f="$(cat "$TMP/hd1220.out")"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q "not one of the defined targets" <<<"$o"; } \
  && ok "default: naming an unknown target fails closed" || bad "bad default: was accepted" "$o"
# …and doesn't also emit the (meaningless) ordering warning for a name that doesn't exist.
grep -q 'is not the first target' <<<"$o" \
  && bad "bad default: also emitted a bogus ordering warning" "$o" \
  || ok "bad default: reports one clear error, not two"

# --- seam-level scalars are inherited; a target's own key wins -----------------------------------
mtstack inherit <<'YAML' >"$TMP/hd1238.out"
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
f="$(cat "$TMP/hd1238.out")"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$f" --dry-run 2>&1)"
grep -q 'echo cli=snow role=SHARED' <<<"$o" \
  && ok "seam-level scalars are inherited by a target" || bad "seam-level inheritance broken" "$o"
grep -q 'echo cli=snow role=OWN' <<<"$o" \
  && ok "a target's own key overrides the seam's" || bad "target override lost to the seam default" "$o"

# tool/adapter/verify inherit too, so two targets on one account can share all three and differ
# only in (say) default_warehouse. Keyed on absence: an explicit `verify: null` still means "skip".
mtstack opinherit <<'YAML' >"$TMP/hd1265.out"
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
f="$(cat "$TMP/hd1265.out")"
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
CLAUDE_PROJECT_DIR="$S" python3 - <<'PY' >"$TMP/hd1413.out"
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("PROSE=" + ",".join(rows["signup-funnel-lift-analysis"]["cross_refs"]))
print("REAL=" + ",".join(rows["late-shipment-audit"]["cross_refs"]))
print("TITLE=" + (rows["signup-funnel-lift-analysis"]["title"] or ""))
PY
refs="$(cat "$TMP/hd1413.out")"
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
CLAUDE_PROJECT_DIR="$S" python3 - <<'PY2' >"$TMP/hd1464.out"
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("DQ=" + ",".join(rows["data-quality"]["cross_refs"]))
PY2
refs2="$(cat "$TMP/hd1464.out")"
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
CLAUDE_PROJECT_DIR="$S" python3 - <<'PY3' >"$TMP/hd1490.out"
import os, pathlib, sys
sys.path.insert(0, "bin")
from build_ticket_index import build_rows
rows = {r["id"]: r for r in build_rows(pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"]))}
print("DQ=" + ",".join(rows["data-quality"]["cross_refs"]))
PY3
refs3="$(cat "$TMP/hd1490.out")"
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
# NOTE: this is no longer the last assertion (sections now run after it), so checks added later are
# not in PASS here — which only makes the floor comparison more conservative, never less. The floor
# is a floor: adding checks anywhere is safe and needs no bump.
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

vproj basic <<'YAML' >"$TMP/hd1862.out"
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
VP="$(cat "$TMP/hd1862.out")"
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
vproj off <<'YAML' >"$TMP/hd1921.out"
enabled: false
tool: macos-open
open_cmd: 'open -a {app} {path}'
default_cmd: 'open {path}'
routes:
  - glob: "*.sql"
    app: SqlApp
YAML
VOFF="$(cat "$TMP/hd1921.out")"
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
vproj order <<'YAML' >"$TMP/hd1955.out"
tool: macos-open
open_cmd: 'open -a {app} {path}'
default_cmd: 'open {path}'
routes:
  - glob: "*.sql"
    app: PerUserApp
YAML
VORD="$(cat "$TMP/hd1955.out")"
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
  # Word-bound the yq check: mktemp suffixes are random, and one containing "yq"
  # (e.g. tmp.6FV8DYqer5) made this assertion fail at random on an unrelated change.
  { [ "$rc" -eq 0 ] && grep -q 'would run' <<<"$o" \
      && ! grep -qiE '(^|[^A-Za-z0-9])yq([^A-Za-z0-9]|$)' <<<"$o"; } \
    && ok "handoff.sh resolves routes with yq absent from PATH entirely" \
    || bad "handoff.sh still depends on yq" "$o rc=$rc"
  o="$(PATH="$NOYQ" CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh \
        "$KIT/.claude/config/stack.yaml" --dry-run 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$o"; } \
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
grep -qiE 'voice.*is never a .*seam|not.*a tool slot|not.*a seam' .claude/skills/setup/SKILL.md \
  && ok "setup states voice is NOT a tool slot (never a seams.* entry)" \
  || bad "setup doesn't clarify voice is not a tool slot"
# (H) include_self is documented separately from always_include (not overloaded) — in the schema
# and in EVERY chat adapter. Looped over adapters/chat/*.md, never an enumerated file list: an
# assertion that names its own subjects stops covering anything new, and chat adapters added later
# (email providers among them) must not escape this gate silently.
is29=""
grep -q 'include_self' .claude/config/stack.schema.md || is29=" stack.schema.md"
for f in adapters/chat/*.md; do
  grep -q 'include_self' "$f" || is29="$is29 $(basename "$f")"
done
[ -z "$is29" ] \
  && ok "include_self documented in schema + every chat adapter (separate from always_include)" \
  || bad "include_self not documented across schema + chat adapters" "$is29"
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
grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$vpo" && ok "verify_stack passes with voice_profiles present (ignored, non-fatal)" || bad "verify_stack tripped on voice_profiles" "$vpo"

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
# and failing would reject every config written before this check existed. The seam is counted
# UNVERIFIED, not OK — "reachable" with an unset key is exactly the state the warning surfaces,
# so the summary must name it rather than absorb it into a green line.
{ ! grep -q 'need attention' <<<"$rqo" && ! grep -Eq '[0-9]+ failing \(' <<<"$rqo" \
  && grep -Eq '0 OK, 1 unverified \(tracker\)' <<<"$rqo"; } \
  && ok "an unset required key warns and counts the seam unverified, never fails" \
  || bad "unset required key failed the run, or the summary hid it" "$rqo"

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
  for k in seam tool detect_env skills_root session_start tool_gate subagents structured_questions \
           gate_ask_tier gate_fail_mode subagent_isolation reads_foreign_skills global_skills_root; do
    grep -q "^$k:" "$f" || rt_bad="$rt_bad $(basename "$f"):$k"
  done
  [ "$(grep -c '^## verb:' "$f")" = "0" ] || rt_bad="$rt_bad $(basename "$f"):has-verbs"
done
[ -z "$rt_bad" ] && ok "every runtime adapter declares the full capability set and no verbs" \
  || bad "a runtime adapter is missing a capability key (or invented verbs)" "$rt_bad"
python3 - <<'PY' >"$TMP/hd2327.out"
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
mc_bad="$(cat "$TMP/hd2327.out")"
[ -z "$mc_bad" ] && ok "every declared model_cmd tokenizes cleanly (no trailing comment, no shell metachars)" \
  || bad "a runtime model_cmd would not parse safely as argv" "$mc_bad"
# The honest floor: an unrecognized harness must claim nothing — PER KEY. A generic "no" is not a
# legal value for the enum keys, so each floors to its own never-optimistic value ("unknown"/"none"),
# and every consumer must treat those exactly as capability-absent.
uf="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME=not-a-real-runtime \
      python3 bin/kit_paths.py --json 2>/dev/null)"
python3 - "$uf" <<'PY'
import json, sys
d = json.loads(sys.argv[1] or "{}")
caps = d.get("capabilities", {})
want = {"session_start": "no", "tool_gate": "no", "subagents": "no", "structured_questions": "no",
        "gate_ask_tier": "unknown", "gate_fail_mode": "unknown", "subagent_isolation": "unknown",
        "global_skills_root": "unknown", "reads_foreign_skills": "none"}
sys.exit(0 if d.get("runtime_adapter") is None
         and all(caps.get(k) == v for k, v in want.items()) else 1)
PY
[ $? -eq 0 ] && ok "an unknown runtime reports every capability at its declared per-key floor" \
  || bad "an unknown runtime claimed a capability it cannot have (or a floor is mistyped)" "$uf"

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
{ grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$vso" && ! grep -q 'adapter missing' <<<"$vso"; } \
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
python3 - <<'PY2' >"$TMP/hd2716.out"
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
oracle_bad="$(cat "$TMP/hd2716.out")"
[ -z "$oracle_bad" ] && ok "_yamlite matches yq on every shipped config + people file" \
  || bad "the stdlib parser and yq disagree on real config" "$oracle_bad"
python3 - <<'PY2' >"$TMP/hd2736.out"
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
fm_bad="$(cat "$TMP/hd2736.out")"
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
# An --identity value matching NO local candidate (git email/name, $USER) is legitimate — it may
# belong to the person's other machine — but on THIS machine it will never resolve, and a teammate
# bound a handle on the tool's own advice and only later discovered it was inert. The bind must
# still succeed (exit 0, written), the note must go to stderr, and stdout must stay machine-readable.
whorun --bind alice --identity totally-foreign-handle >"$TMP/who-id.out" 2>"$TMP/who-id.err"; irc=$?
{ [ "$irc" -eq 0 ] && grep -q 'matches no local identity candidate' "$TMP/who-id.err" \
  && ! grep -q 'matches no local' "$TMP/who-id.out" \
  && grep -q 'totally-foreign-handle' "$WI/people/alice.yaml"; } \
  && ok "binding a foreign --identity succeeds, WARNS on stderr, and keeps stdout clean" \
  || bad "the foreign-identity bind is silent, noisy on stdout, or refused" "rc=$irc $(cat "$TMP/who-id.err")"
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
# team verb is `/setup tool <chat|docstore|warehouse|meetings>`; person config lives in the per-person flow.
# These pin the stated invariant, the Phase-1 routing, the tier-3 versioned-document convention the
# per-person flow WRITES (the resolver understands it: structural keys, stale fingerprint, and the
# mode:defaults-with-overrides rejection are section 32's), and the honesty claim behind placeholders.
SK=".claude/skills/setup/SKILL.md"; TM=".claude/skills/setup/teammate.md"
skflat="$(tr '\n' ' ' < "$SK")"; tmflat="$(tr '\n' ' ' < "$TM")"
# (A) the canonical verb, the deprecation window, and the retired seam-mode heading.
grep -q 'Mode: `tool <chat|docstore|warehouse|meetings>`' "$SK" \
  && ok "canonical team verb: /setup tool <chat|docstore|warehouse|meetings>" || bad "canonical tool verb missing"
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
hdr "35 · owner is ticket identity (locator, graph separation, ambiguity hard stops, whoami wiring)"
# Two owners, one slug — the case that used to collapse. Every engine must treat (owner, id) as the
# identity: separate graph nodes, owner-qualified backlinks, within-owner-first link resolution, and
# a HARD STOP wherever a bare id could mean two people's work. Never a guess, never "all of them".
OI="$TMP/ownerid"; mkdir -p "$OI/.claude/config" "$OI/bin" \
  "$OI/tickets/alice/chargeback-lift" "$OI/tickets/bob/chargeback-lift" \
  "$OI/tickets/alice/other-work" "$OI/tickets/carol/third-thing"
cp bin/build_ticket_index.py bin/enrich_ticket.py bin/ingest_index_records.py "$OI/bin/"
printf 'project:\n  assignee_dir: alice\n  id_mode: slug\n  ticket_path: "tickets/{assignee}/{id}"\n' > "$OI/.claude/config/stack.yaml"
printf '# chargeback-lift: Alice chargeback lift\n\nAlice body.\n' > "$OI/tickets/alice/chargeback-lift/README.md"
printf 'SELECT * FROM S.VW_SHARED;\n' > "$OI/tickets/alice/chargeback-lift/q.sql"
printf '# chargeback-lift: Two-owner chargeback lift\n\nSecond body.\n' > "$OI/tickets/bob/chargeback-lift/README.md"
printf 'SELECT * FROM S.VW_SHARED;\n' > "$OI/tickets/bob/chargeback-lift/q.sql"
printf '# other-work: Other\n\nBuilds on [[chargeback-lift]] and [[bob/chargeback-lift]].\n' > "$OI/tickets/alice/other-work/README.md"
printf '# third-thing: Third\n\nSee [[chargeback-lift]].\n' > "$OI/tickets/carol/third-thing/README.md"
# A bare-id node left from before this rename must be swept by the normal orphan cleanup (migration).
mkdir -p "$OI/tickets/graph"; printf 'old\n' > "$OI/tickets/graph/chargeback-lift.md"
warn35="$(CLAUDE_PROJECT_DIR="$OI" python3 bin/build_ticket_index.py 2>&1 >/dev/null)"

# (a) graph separation: two nodes, no merged bare node, each naming only its own owner.
{ [ -f "$OI/tickets/graph/alice.chargeback-lift.md" ] && [ -f "$OI/tickets/graph/bob.chargeback-lift.md" ] \
  && [ ! -f "$OI/tickets/graph/chargeback-lift.md" ]; } \
  && ok "same-slug tickets under two owners get two graph nodes (stale bare-id node swept)" \
  || bad "two owners' same-slug tickets merged into one node, or the bare-id node survived"
{ grep -q '`alice`' "$OI/tickets/graph/alice.chargeback-lift.md" \
  && ! grep -q 'bob' "$OI/tickets/graph/alice.chargeback-lift.md"; } \
  && ok "each node names only its own owner (no pooled-owner line)" \
  || bad "a graph node still pools owners" "$(cat "$OI/tickets/graph/alice.chargeback-lift.md")"
CLAUDE_PROJECT_DIR="$OI" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 \
  && ok "--check is clean right after the owner-keyed render (deterministic)" \
  || bad "--check stale after render — owner keying broke determinism"

# (b) object backlinks key by (owner, id): both owners listed, owner/id labels, qualified targets.
{ grep -q '\[alice/chargeback-lift\](../graph/alice.chargeback-lift.md)' "$OI/tickets/objects/S.VW_SHARED.md" \
  && grep -q '\[bob/chargeback-lift\](../graph/bob.chargeback-lift.md)' "$OI/tickets/objects/S.VW_SHARED.md"; } \
  && ok "object-note backlinks key by (owner, id) with owner/id labels" \
  || bad "object backlinks still collapse a shared id" "$(cat "$OI/tickets/objects/S.VW_SHARED.md")"
{ grep -q '\[alice/chargeback-lift\]' "$OI/tickets/OBJECTS.md" && grep -q '\[bob/chargeback-lift\]' "$OI/tickets/OBJECTS.md"; } \
  && ok "OBJECTS.md labels a shared id by its owner/id locator" \
  || bad "OBJECTS.md renders two owners' tickets as indistinguishable bare labels"

# (c) bare-link resolution order: current owner first; explicit owner honored; two foreign owners = error.
grep -q '\[chargeback-lift\](alice.chargeback-lift.md)' "$OI/tickets/graph/alice.other-work.md" \
  && ok "a bare [[wiki-link]] resolves within the CURRENT owner first" \
  || bad "within-owner resolution failed" "$(grep 'Builds on' "$OI/tickets/graph/alice.other-work.md")"
grep -q '\[bob/chargeback-lift\](bob.chargeback-lift.md)' "$OI/tickets/graph/alice.other-work.md" \
  && ok "a qualified [[owner/id]] wiki-link is honored exactly (and the bare link beside it survives)" \
  || bad "the qualified wiki-link was not honored" "$(grep 'Builds on' "$OI/tickets/graph/alice.other-work.md")"
{ grep -q 'chargeback-lift' "$OI/tickets/graph/carol.third-thing.md" \
  && ! grep -qE '\((alice|bob)\.chargeback-lift\.md\)' "$OI/tickets/graph/carol.third-thing.md"; } \
  && ok "a bare ref two foreign owners share links NEITHER (plain text, never a guess)" \
  || bad "an ambiguous bare ref was linked to a guessed owner"
{ grep -qi 'multiple owners' <<<"$warn35" && grep -q 'alice' <<<"$warn35" && grep -q 'bob' <<<"$warn35"; } \
  && ok "…and the render error names BOTH owners on stderr" \
  || bad "the two-owner match was not reported as an error naming both" "$warn35"

# (d) enrich_ticket: a bare id two owners share is a hard stop (exit 3) — enrich-every-owner is gone.
# `claude` is kept OFF PATH (section 25/26 technique): reaching "Enriching 1 ticket(s)" proves the
# locator resolved without spending a model call.
amb="$(cd "$OI" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$OI" python3 bin/enrich_ticket.py chargeback-lift 2>&1)"; arc35=$?
{ [ "$arc35" -eq 3 ] && grep -q 'alice/chargeback-lift' <<<"$amb" && grep -q 'bob/chargeback-lift' <<<"$amb" \
  && ! grep -q 'Enriching' <<<"$amb"; } \
  && ok "enrich_ticket hard-stops (exit 3) on a shared bare id, naming both owner/id spellings" \
  || bad "enrich_ticket guessed, enriched multiple owners, or mis-coded the stop" "rc=$arc35 $amb"
eq35="$(cd "$OI" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$OI" python3 bin/enrich_ticket.py alice/chargeback-lift 2>&1)"
grep -q 'Enriching 1 ticket' <<<"$eq35" \
  && ok "the owner/id locator resolves exactly one ticket" || bad "owner/id locator did not resolve" "$eq35"

# (e) branch names: bare <id> stays the rule; the collision shape <owner>-<id> resolves its pair;
# an ambiguous bare branch hard-stops instead of enriching everyone.
( cd "$OI" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git checkout -q -b bob-chargeback-lift ) 2>/dev/null
bq35="$(cd "$OI" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$OI" python3 bin/enrich_ticket.py --branch 2>&1)"
{ grep -q 'Enriching 1 ticket' <<<"$bq35" && grep -q 'bob/chargeback-lift' <<<"$bq35"; } \
  && ok "--branch resolves the collision-shape branch (<owner>-<id>) to that owner's ticket" \
  || bad "--branch could not resolve <owner>-<id>" "$bq35"
( cd "$OI" && git checkout -q -b chargeback-lift ) 2>/dev/null
bq36="$(cd "$OI" && PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$OI" python3 bin/enrich_ticket.py --branch 2>&1)"; brc35=$?
{ [ "$brc35" -eq 3 ] && grep -qi 'multiple owners' <<<"$bq36"; } \
  && ok "--branch on an ambiguous bare branch hard-stops too" \
  || bad "--branch picked an owner for an ambiguous bare branch" "rc=$brc35 $bq36"

# (f) recall: the --owner discipline holds, and the qualified locator is a first-class seed.
ra35="$(CLAUDE_PROJECT_DIR="$OI" python3 bin/recall.py --for chargeback-lift 2>&1)"; rrc35=$?
{ [ "$rrc35" -ne 0 ] && grep -qi 'multiple owners' <<<"$ra35"; } \
  && ok "recall --for a shared bare id still hard-stops (the --owner precedent)" \
  || bad "recall silently picked a seed owner" "rc=$rrc35 $ra35"
rq35="$(CLAUDE_PROJECT_DIR="$OI" python3 bin/recall.py --for alice/chargeback-lift 2>&1)"
grep -q 'Prior art for alice/chargeback-lift' <<<"$rq35" \
  && ok "recall --for owner/id resolves the qualified seed and displays the locator" \
  || bad "recall did not accept the owner/id locator" "$rq35"
# Cross-ref scoring follows the locator's resolution order: other-work's bare ref names ALICE's
# ticket (its own owner), its qualified ref names BOB's, and third-thing's bare ref from carol is
# ambiguous and names NOBODY — never a guess, in scoring exactly as in the graph.
CLAUDE_PROJECT_DIR="$OI" python3 - "$OI" <<'PY35'
import json, os, subprocess, sys
def whys(seed):
    out = subprocess.run([sys.executable, "bin/recall.py", "--for", seed, "--json"],
                         capture_output=True, text=True, env={**os.environ}).stdout
    return {f"{r['owner']}/{r['id']}": r["why"] for r in json.loads(out)}
a, b = whys("alice/chargeback-lift"), whys("bob/chargeback-lift")
assert "ref" in a.get("alice/other-work", []), ("bare ref should name its own owner's seed", a)
assert "ref" in b.get("alice/other-work", []), ("qualified ref should name bob's seed", b)
assert "ref" not in a.get("carol/third-thing", []), ("ambiguous bare ref scored a ref for alice", a)
assert "ref" not in b.get("carol/third-thing", []), ("ambiguous bare ref scored a ref for bob", b)
PY35
[ $? -eq 0 ] && ok "recall cross-ref scoring resolves bare refs within-owner-first and never guesses an ambiguous one" \
  || bad "recall cross-ref scoring disagrees with the graph's resolution order"

# (g) keyed mode separates the same way (the graph fix is not slug-only), and a qualified ref to a
# ticket with NO folder keeps its owner — keyed refs could always name folderless tickets.
KO="$TMP/ownerid-keyed"; mkdir -p "$KO/.claude/config" "$KO/tickets/alice/ENG-7" "$KO/tickets/bob/ENG-7"
printf 'project:\n  key_prefix: ENG\n' > "$KO/.claude/config/stack.yaml"
printf '# ENG-7: Alice half\n\nThe first half of the work.\n\nSee [[bob/ENG-999]] and [[graph/ENG-777]].\n' > "$KO/tickets/alice/ENG-7/README.md"
printf '# ENG-7: Second half\n\nb.\n' > "$KO/tickets/bob/ENG-7/README.md"
CLAUDE_PROJECT_DIR="$KO" python3 bin/build_ticket_index.py >/dev/null 2>&1
{ [ -f "$KO/tickets/graph/alice.ENG-7.md" ] && [ -f "$KO/tickets/graph/bob.ENG-7.md" ]; } \
  && ok "keyed mode: one tracker key under two owners still yields two nodes" \
  || bad "keyed-mode same-key tickets merged"
{ grep -q 'bob/ENG-999' "$KO/tickets/INDEX.md" && grep -q 'ENG-777' "$KO/tickets/INDEX.md" \
  && ! grep -q 'graph/ENG-777' "$KO/tickets/INDEX.md"; } \
  && ok "a qualified ref to a folderless keyed ticket keeps its owner; a path segment is never an owner" \
  || bad "keyed qualified refs lost their owner (or a path-style link became one)" \
         "$(grep 'ENG-7' "$KO/tickets/INDEX.md" 2>/dev/null)"

# (h) the whoami wiring PROMPT 3 deferred: skills resolve WHO before rendering any ticket path.
tk=".claude/skills/ticket/SKILL.md"; tflat="$(tr '\n' ' ' < "$tk")"
wline=$(grep -n 'whoami.py' "$tk" | head -1 | cut -d: -f1)
pline=$(grep -n 'ticket_path' "$tk" | head -1 | cut -d: -f1)
{ [ -n "$wline" ] && [ -n "$pline" ] && [ "$wline" -lt "$pline" ] && grep -qi 'Working as' <<<"$tflat"; } \
  && ok "/ticket calls whoami.py BEFORE rendering ticket_path and shows the display line" \
  || bad "/ticket does not resolve WHO first (whoami at line ${wline:-none}, ticket_path at ${pline:-none})"
{ grep -qi "locator's owner" <<<"$tflat" && grep -qi 'hard-stop' <<<"$tflat" && grep -q 'owner/id' <<<"$tflat"; } \
  && ok "/ticket fills {assignee} from the locator's owner and hard-stops on a shared bare id" \
  || bad "/ticket still sources {assignee} statically or guesses on ambiguity"
grep -q '<owner>-<id>' "$tk" \
  && ok "/ticket documents the branch-collision rule (bare <id>; <owner>-<id> when taken)" \
  || bad "/ticket lost the branch-collision rule"
{ grep -qi 'last resort' <<<"$tflat" && grep -c 'assignee_dir' "$tk" >/dev/null; } \
  && ok "assignee_dir survives in /ticket only as the documented no-people-map last resort" \
  || bad "/ticket's assignee_dir fallback lost its last-resort framing"
sk35miss=""
for s in ship review spec-and-build; do
  f=".claude/skills/$s/SKILL.md"
  grep -q 'whoami.py' "$f" && grep -q 'owner/id' "$f" || sk35miss="$sk35miss $s"
  grep -q 'assignee_dir' "$f" && sk35miss="$sk35miss $s(assignee_dir)"
done
[ -z "$sk35miss" ] \
  && ok "/ship, /review, /spec-and-build each resolve the locator via whoami (and never assignee_dir)" \
  || bad "a lifecycle skill misses the locator wiring or reads assignee_dir:$sk35miss"
# Locator PROPAGATION: a step's recommendation of the next step carries the qualified owner/id, so
# a bare id can never be re-resolved to a different owner's ticket between steps (e.g. /review of
# bob's ticket recommending a bare /ship that lands on the shipper's same-named one).
{ grep -q 'spec <owner>/<id>' "$tk" && grep -q '/ship <owner>/<id>' "$tk" \
  && grep -q 'refresh index <owner>/<id>' .claude/skills/ship/SKILL.md \
  && grep -q '/ship <owner>/<id>' .claude/skills/review/SKILL.md \
  && grep -q '/review <owner>/<id>' .claude/skills/spec-and-build/SKILL.md \
  && grep -q 'recall.py --for <owner>/<id>' .claude/skills/ticket/priming.md; } \
  && ok "every cross-step handoff passes the QUALIFIED locator (routing, refresh, recall, verdicts)" \
  || bad "a cross-step handoff still passes a bare id — ownership drops between skills"
oi_other="$(grep -rl 'assignee_dir' .claude/skills/ 2>/dev/null | grep -v 'skills/setup/' | grep -v 'skills/ticket/SKILL.md' || true)"
[ -z "$oi_other" ] \
  && ok "no skill outside /ticket's last resort (and setup's scaffolding) reads assignee_dir" \
  || bad "a static assignee_dir read survives outside the documented last resort" "$oi_other"

hdr "36 · absent tool slots render the enabling command (whole-path adapter tokens)"
# The template language is a flat substitution pass — no conditionals — so a tool slot the stack
# omits cannot drop its table row. Instead every adapter cell takes a WHOLE-PATH token (the
# {{warehouse_adapter}} precedent, extended to all six slots): a configured slot passes the
# adapter path, an absent one passes a note naming the enabling command. Composing
# adapters/<slot>/<tool>.md around the tool name is the bug this pins down — it rendered broken
# markdown like `adapters/chat/— *(none; /setup chat)*.md` for an absent chat slot.
S36="$TMP/s36"; mkdir -p "$S36"
composed="$(grep -nE 'adapters/(tracker|warehouse|chat|docstore|meetings|vcs)/\{\{' templates/AGENTS.md.tmpl || true)"
[ -z "$composed" ] \
  && ok "no stack-table cell composes an adapter path around a tool token" \
  || bad "AGENTS.md.tmpl still composes an adapter path from a tool token" "$composed"
# scaffold.md is the instruction source: it must name every whole-path token AND the absent case.
s36doc=""
for t in tracker_adapter warehouse_adapter chat_adapter docstore_adapter meetings_adapter vcs_adapter; do
  grep -q "$t" .claude/skills/setup/scaffold.md || s36doc="$s36doc $t"
done
grep -q 'Absent slot' .claude/skills/setup/scaffold.md || s36doc="$s36doc absent-case"
[ -z "$s36doc" ] \
  && ok "scaffold.md documents all six adapter tokens and the absent-slot values" \
  || bad "scaffold.md is missing token guidance" "$s36doc"
# (a) every slot configured → each adapter path lands in the rendered output, zero leftover tokens.
cfgout="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$TMP/vars.env" 2>"$S36/cfg.err")"
s36miss=""
for p in adapters/tracker/jira.md adapters/warehouse/snowflake.md adapters/chat/slack.md \
         adapters/docstore/gdrive.md adapters/meetings/zoom.md adapters/vcs/github.md; do
  grep -qF "$p" <<<"$cfgout" || s36miss="$s36miss $p"
done
[ -z "$s36miss" ] && [ ! -s "$S36/cfg.err" ] \
  && ok "configured slots render their adapter paths (zero leftover tokens)" \
  || bad "a configured slot lost its adapter path or left a token" "missing:$s36miss $(cat "$S36/cfg.err")"
# (b) warehouse/chat/docstore absent (the slots /setup leaves out) → the row renders the enabling
# command, never a broken path; tracker/vcs stay configured in the same render.
cat > "$S36/absent.env" <<'EOF'
repo_name=demo
domain=data
ticket_path=tickets/{assignee}/{id}
tracker_tool=jira
tracker_adapter=`adapters/tracker/jira.md`
warehouse_tool=—
warehouse_adapter=*(not configured — run `/setup tool warehouse` to add one)*
chat_tool=—
chat_adapter=*(not configured — run `/setup tool chat` to add one)*
docstore_tool=—
docstore_adapter=*(not configured — run `/setup tool docstore` to add one)*
meetings_tool=—
meetings_adapter=*(not configured — run `/setup tool meetings` to add one)*
vcs_tool=github
vcs_adapter=`adapters/vcs/github.md`
key_prefix=ENG
terminal_status=Done
wl_tracker_comment=100
wl_chat=100
wl_pr=200
wl_ticket=200
chat_always_include=Alice
default_branch=main
role_focus=x
analysis_tools=none declared (add project.analysis_tools in stack.yaml, or run /setup role)
EOF
absout="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$S36/absent.env" 2>"$S36/abs.err")"
{ grep -qF '/setup tool chat' <<<"$absout" && grep -qF '/setup tool warehouse' <<<"$absout" \
  && grep -qF '/setup tool docstore' <<<"$absout" && grep -qF '/setup tool meetings' <<<"$absout"; } \
  && ok "an absent slot renders its enabling command (/setup tool <slot>)" \
  || bad "an absent slot's enabling command is missing from the rendered AGENTS.md"
s36broken="$(grep -nE 'adapters/(warehouse|chat|docstore|meetings)/' <<<"$absout" || true)"
[ -z "$s36broken" ] && [ ! -s "$S36/abs.err" ] \
  && ok "no broken adapter path and no leftover token for an absent slot" \
  || bad "an absent slot still renders an adapter path (or left a token)" "$s36broken $(cat "$S36/abs.err")"
grep -qF 'adapters/tracker/jira.md' <<<"$absout" \
  && ok "configured slots are untouched by absent-slot rendering" \
  || bad "a configured slot's path was lost in the mixed render"
# (c) tracker/vcs go absent only in a hand-edited config (the interview always fills them; tracker
# "none" selects the local adapter) — same mechanism, plain /setup as the enabling command.
sed -e 's|^tracker_tool=.*|tracker_tool=—|' \
    -e 's|^tracker_adapter=.*|tracker_adapter=*(not configured — run `/setup`)*|' \
    -e 's|^vcs_tool=.*|vcs_tool=—|' \
    -e 's|^vcs_adapter=.*|vcs_adapter=*(not configured — run `/setup`)*|' \
    "$S36/absent.env" > "$S36/absent-all.env"
allout="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$S36/absent-all.env" 2>"$S36/all.err")"
s36tb="$(grep -nE 'adapters/(tracker|warehouse|chat|docstore|meetings|vcs)/' <<<"$allout" || true)"
{ [ -z "$s36tb" ] && [ ! -s "$S36/all.err" ] && grep -qF 'run `/setup`' <<<"$allout"; } \
  && ok "hand-edited tracker/vcs absence renders the /setup note (no path, no leftover token)" \
  || bad "tracker/vcs absence renders broken output" "$s36tb $(cat "$S36/all.err")"
# (d) the dead stub-adapter promise stays dead: no adapter carries status: frontmatter, so no
# skill may promise a warning the kit cannot emit. The first real stub adds the mechanism with itself.
stubp="$(grep -rn 'status: stub' .claude/skills/ 2>/dev/null || true)"
[ -z "$stubp" ] \
  && ok "no skill promises a status: stub warning (no adapter carries the key)" \
  || bad "a skill still promises the status: stub warning" "$stubp"

hdr "37 · resolver target selection (--seam/--target) + the /ship approval-plan feed"
# /ship's Phase B now prints a RESOLVED delivery plan — target, destination, recipients — so the
# human authorizes the plan, not the word "ship". These assertions cover the CLI that feeds that
# rendering (adapters/README.md § Selecting a target from config). The hard edge under test: an
# unresolvable NAME is exit 8 and never a fallback to another target, because once chat holds
# targets the fallback may be the external audience.
EC37="$KIT/bin/effective_config.py"
S37="$TMP/sel37"; mkdir -p "$S37/.claude/config"
cp "$KIT/.claude/config/stack.example.multi-warehouse.yaml" "$S37/.claude/config/stack.yaml"
sel() {  # sel <root> [args...] -> $SELOUT + $SELRC
  local d="$1"; shift
  SELOUT="$(python3 "$EC37" --root "$d" --person alice --quiet "$@" 2>/dev/null)"; SELRC=$?
}
jget() { printf '%s' "$SELOUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# --- selection: default vs explicit -------------------------------------------------------------
sel "$S37" --seam warehouse
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['target']")" = "prod" ] \
  && [ "$(jget "d['selected_by']")" = "default" ] && [ "$(jget "d['is_default']")" = "True" ]; } \
  && ok "--seam alone selects the seam's default: target" \
  || bad "default selection wrong" "rc=$SELRC target=$(jget "d.get('target')")"
sel "$S37" --seam warehouse --target lake
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['selected_by']")" = "explicit" ] \
  && [ "$(jget "d['tool']")" = "databricks" ] && [ "$(jget "d['values']['catalog']")" = "main" ]; } \
  && ok "--target selects explicitly, the target's own keys winning" \
  || bad "explicit selection broken" "rc=$SELRC"

# --- inheritance is keyed on ABSENCE; an explicit verify: null is a skip, not a fall-through ------
INH="$TMP/sel37-inh"; mkdir -p "$INH/.claude/config"
cat > "$INH/.claude/config/stack.yaml" <<'YAML'
project:
  key_prefix: ENG
seams:
  warehouse:
    default: prod
    cli: fixture-cli
    verify: "fixture-seam-cmd"
    targets:
      prod:
        tool: snowflake
        adapter: adapters/warehouse/snowflake.md
      lake:
        tool: databricks
        adapter: adapters/warehouse/databricks.md
        cli: lake-cli
        verify: null
YAML
sel "$INH" --seam warehouse
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['values']['cli']")" = "fixture-cli" ] \
  && [ "$(jget "d['verify']")" = "fixture-seam-cmd" ]; } \
  && ok "a target inherits the seam-level keys it does not define" \
  || bad "seam-scalar inheritance broken in selection" "rc=$SELRC cli=$(jget "d['values'].get('cli')")"
sel "$INH" --seam warehouse --target lake
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['values']['cli']")" = "lake-cli" ] \
  && [ "$(jget "d['verify']")" = "None" ] && [ "$(jget "d['values']['verify']")" = "None" ]; } \
  && ok "…and an explicit verify: null stays null — a skip, never the seam's command" \
  || bad "verify: null fell through to the seam command" "verify=$(jget "d.get('verify')")"

# --- an unresolvable name is a hard error, never a fallback ---------------------------------------
sel "$S37" --seam warehouse --target ghost
{ [ "$SELRC" -eq 8 ] && [ "$(jget "d['error']['code']")" = "no_such_target" ] \
  && [ "$(jget "'values' in d")" = "False" ] \
  && [ "$(jget "'prod' in d['error']['configured'] and 'lake' in d['error']['configured']")" = "True" ]; } \
  && ok "an unknown target is exit 8 naming the configured names — no values, no fallback" \
  || bad "an unknown target did not hard-error (the wrong-warehouse failure)" "rc=$SELRC"
NODEF="$TMP/sel37-nodef"; mkdir -p "$NODEF/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    targets:\n      prod:\n        tool: snowflake\n        adapter: adapters/warehouse/snowflake.md\n        verify: null\n' \
  > "$NODEF/.claude/config/stack.yaml"
sel "$NODEF" --seam warehouse
{ [ "$SELRC" -eq 8 ] && [ "$(jget "'values' in d")" = "False" ]; } \
  && ok "targets: with no default: is exit 8 — first-listed is a display convention, not a pick" \
  || bad "a missing default silently selected a target" "rc=$SELRC"
# A malformed default (a list is UNHASHABLE, so an unguarded targets.get() raises) must fail the
# selection cleanly, not crash — and must not block an explicit --target that names a real one.
BADDEF="$TMP/sel37-baddef"; mkdir -p "$BADDEF/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    default: [prod]\n    targets:\n      prod:\n        tool: snowflake\n        adapter: adapters/warehouse/snowflake.md\n        verify: null\n' \
  > "$BADDEF/.claude/config/stack.yaml"
sel "$BADDEF" --seam warehouse
{ [ "$SELRC" -eq 8 ] && [ "$(jget "d['error']['code']")" = "no_such_target" ]; } \
  && ok "a non-string default: is exit 8 with a clean error, never a traceback" \
  || bad "a malformed default: crashed or resolved the selection" "rc=$SELRC"
sel "$BADDEF" --seam warehouse --target prod
[ "$SELRC" -eq 0 ] \
  && ok "…and an explicit --target still resolves past the broken pointer" \
  || bad "a malformed default: blocked an explicit valid selection" "rc=$SELRC"
sel "$S37" --seam chat --target ghost
[ "$SELRC" -eq 8 ] \
  && ok "an explicit --target on a single-mapping seam is exit 8" \
  || bad "a single-mapping seam accepted a target name" "rc=$SELRC"
sel "$S37" --seam nosuch
{ [ "$SELRC" -eq 7 ] && [ "$(jget "d['error']['code']")" = "no_such_seam" ] \
  && [ "$(jget "'chat' in d['error']['configured']")" = "True" ]; } \
  && ok "an unconfigured seam is exit 7, distinct from a bad target (callers may degrade on 7 only)" \
  || bad "no_such_seam is not distinguishable from a bad target" "rc=$SELRC"
python3 "$EC37" --root "$S37" --target lake --quiet >/dev/null 2>&1
[ $? -eq 2 ] && ok "--target without --seam is a usage error (exit 2)" \
             || bad "--target without --seam was accepted"
# Presence must be is-not-None: an EMPTY name is a usage error, never a silent fall-through to the
# full-config output (where a caller would read a healthy exit 0 as a successful selection).
python3 "$EC37" --root "$S37" --seam warehouse --target "" --quiet >/dev/null 2>&1
[ $? -eq 2 ] && ok "--target '' is a usage error, not a fall-through" \
             || bad "an empty --target slipped past the usage check"
python3 "$EC37" --root "$S37" --seam "" --json --quiet >/dev/null 2>&1
[ $? -eq 2 ] && ok "--seam '' with another output mode is a usage error, not a fall-through" \
             || bad "an empty --seam slipped past the output-mode exclusivity check"
M37="$TMP/sel37-missing"; mkdir -p "$M37"
sel "$M37" --seam warehouse
[ "$SELRC" -eq 3 ] \
  && ok "a missing stack keeps exit 3 — never misreported as a missing seam" \
  || bad "selection masked a missing stack.yaml" "rc=$SELRC"
BADYAML="$TMP/sel37-badyaml"; mkdir -p "$BADYAML/.claude/config"
printf 'seams: &anchor\n  warehouse: {}\n' > "$BADYAML/.claude/config/stack.yaml"
sel "$BADYAML" --seam warehouse
[ "$SELRC" -eq 4 ] \
  && ok "a malformed stack keeps exit 4 — the load failure outranks the selection codes" \
  || bad "selection masked a malformed stack.yaml" "rc=$SELRC"
# A `targets:` key that is NOT a mapping (null, a list) must never resolve as a single mapping —
# that would bypass every named-target rule downstream, including /ship's halt.
BADTGT="$TMP/sel37-badtargets"; mkdir -p "$BADTGT/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    tool: slack\n    adapter: adapters/chat/slack.md\n    targets: null\n' \
  > "$BADTGT/.claude/config/stack.yaml"
sel "$BADTGT" --seam chat
{ [ "$SELRC" -eq 8 ] && [ "$(jget "'values' in d")" = "False" ]; } \
  && ok "targets: null is exit 8, never a quiet single mapping" \
  || bad "a malformed targets: key resolved as a single mapping (halt bypass)" "rc=$SELRC"
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    tool: slack\n    adapter: adapters/chat/slack.md\n    targets: [a, b]\n' \
  > "$BADTGT/.claude/config/stack.yaml"
sel "$BADTGT" --seam chat
[ "$SELRC" -eq 8 ] \
  && ok "targets: as a list is exit 8, never a quiet single mapping" \
  || bad "a list-valued targets: key resolved as a single mapping" "rc=$SELRC"

# --- selection sees the MERGED config, and the scope rule still binds inside it -------------------
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: my-profile\n' \
  > "$S37/.claude/config/connections.local.yaml"
sel "$S37" --seam warehouse --target lake
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['values']['profile']")" = "my-profile" ] \
  && [ "$(jget "'my-profile' in (d['verify'] or '')")" = "True" ]; } \
  && ok "a declared user_key from tier 3 reaches the selected values and the verify command" \
  || bad "selection reads raw rather than merged config" "rc=$SELRC"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        catalog: sneaky\n' \
  > "$S37/.claude/config/connections.local.yaml"
sel "$S37" --seam warehouse --target lake
{ [ "$SELRC" -eq 6 ] && [ "$(jget "d['values']['catalog']")" = "main" ] \
  && [ "$(jget "d['errors'][0]['code']")" = "prohibited_override" ]; } \
  && ok "a tier-3 override of a target's logical keys is still rejected — selection never masks exit 6" \
  || bad "selection mode let a machine file change logical data selection" "rc=$SELRC catalog=$(jget "d['values'].get('catalog')")"
printf 'person: alice\nseams:\n  warehouse:\n    targets:\n      lake:\n        profile: "x; touch %s/PWNED37"\n' "$TMP" \
  > "$S37/.claude/config/connections.local.yaml"
rm -f "$TMP/PWNED37"
sel "$S37" --seam warehouse --target lake
{ [ "$(jget "d['verify']")" = "None" ] && [ "$(jget "'profile' in d['unsafe']")" = "True" ] \
  && [ ! -f "$TMP/PWNED37" ]; } \
  && ok "a tier-3 value with shell metacharacters nulls the emitted command (the #30 refusal, inherited)" \
  || bad "an injected tier-3 value left the CLI inside a command string" "verify=$(jget "d.get('verify')")"
rm -f "$S37/.claude/config/connections.local.yaml"

# --- the values /ship's approval block renders, from a fixture config -----------------------------
# The skill itself is prose a model executes, so the mechanically testable behavior is the exact
# feed it renders from: the resolved channel, recipient list, tool and destination.
sel "$S37" --seam chat
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['selected_by']")" = "single" ] \
  && [ "$(jget "d['target']")" = "None" ] && [ "$(jget "d['tool']")" = "slack" ] \
  && [ "$(jget "d['values']['default_channel']")" = "C0XXXXXXXXX" ] \
  && [ "$(jget "d['values']['always_include']")" = "['Alice']" ] \
  && [ "$(jget "d['values']['default_mode']")" = "draft" ]; } \
  && ok "/ship's chat plan line resolves channel + recipient list + mode from config, not memory" \
  || bad "the chat approval feed is wrong" "rc=$SELRC $(jget "d.get('values',{}).get('default_channel')")"
sel "$S37" --seam docstore
{ [ "$SELRC" -eq 0 ] && [ "$(jget "d['tool']")" = "gdrive" ] \
  && [ "$(jget "d['values']['drive_folder']")" = "Shared drives/Tickets" ]; } \
  && ok "/ship's docstore plan line resolves the destination from config" \
  || bad "the docstore approval feed is wrong" "rc=$SELRC"
# PROSE WIRING PINS, not behavior: the skill is prose a model executes, so what these prove is only
# that the instructions still say what the resolver assertions above make true. The behavioral half
# of "the approval block renders resolved values" is the --seam feed tested above.
ship37="$(tr '\n' ' ' < .claude/skills/ship/SKILL.md)"
{ grep -q 'effective_config.py --seam' .claude/skills/ship/SKILL.md \
  && grep -qi 'resolved delivery plan' <<<"$ship37" && grep -qi 'recipient list' <<<"$ship37" \
  && grep -qi 'sharing scope' <<<"$ship37" && grep -q 'HARD HALT' .claude/skills/ship/SKILL.md \
  && grep -q 'stop and wait' .claude/skills/ship/SKILL.md \
  && grep -q 'disable-model-invocation: true' .claude/skills/ship/SKILL.md; } \
  && ok "/ship's prose wires the selection call and keeps the hard halt + disable-model-invocation (wiring pin)" \
  || bad "/ship's approval rendering or its safety lines regressed"
# The preview==execution rule: /ship must halt on a multi-target chat/docstore seam rather than
# render a target its own steps would not deliver to (wiring pin for the authorization-mismatch fix).
grep -qi 'authorization mismatch' .claude/skills/ship/SKILL.md \
  && ok "/ship states the halt-on-named-targets rule (preview must equal execution)" \
  || bad "/ship may render a target-aware route its execution steps do not take"
h37="$(python3 "$EC37" --help 2>&1)"
{ grep -q -- '--seam' <<<"$h37" && grep -q -- '--target' <<<"$h37" \
  && grep -q -- '--seam' adapters/README.md && grep -q 'delivery-plan.yaml' adapters/README.md \
  && grep -q 'sharing_scope' adapters/README.md; } \
  && ok "the published contract names flags the binary actually has, and the delivery-plan schema" \
  || bad "docs and binary disagree on the selection contract"
grep -q 'no others' .claude/config/stack.schema.md \
  && bad "stack.schema.md still claims the five seams are exclusive ('no others')" \
  || ok "the schema's false exclusivity claim is gone (viewer + runtime acknowledged)"

hdr "38 · the interview in rounds (cap retired; outcomes, skips, re-entry, email, obsidian)"
# PROMPT 4b. The interview is prose a model executes, so the mechanically testable behavior is
# (1) the rendered-config OUTCOME the rounds specify, driven through verify_stack.sh like every
# other config fixture, and (2) the tested-artifact contract on the instruction files themselves.
IV=".claude/skills/setup/interview.md"; SK38=".claude/skills/setup/SKILL.md"
[ -f "$IV" ] && ok "interview.md ships (Phase 2 lives in its own reference file)" \
  || bad "interview.md missing"
iflat="$(tr '\n' ' ' < "$IV")"; skflat38="$(tr '\n' ' ' < "$SK38")"
# (A) the cap is retired — SCOPED: SKILL.md's frontmatter description + its default-mode section,
# interview.md, adopt.md and README.md. Deliberately NOT scanned: SKILL.md's --voice summary and
# voice.md (the voice interview's own ≤5 cap is a KEPT feature) and CHANGELOG.md (history is never
# rewritten). The pattern tolerates the hyphenated "≤5-question" form.
capre='≤[[:space:]]*5|at most (5|five)|(5|five)[- ]question'
dm38="$TMP/s38-scope.txt"
{ grep '^description:' "$SK38"; sed -n '/^## Default mode/,$p' "$SK38"; } > "$dm38"
cap38=""
grep -EIiq "$capre" "$dm38" && cap38="$cap38 SKILL.md(description/default-mode)"
for f in "$IV" .claude/skills/setup/adopt.md README.md; do
  grep -EIiq "$capre" "$f" && cap38="$cap38 $f"
done
[ -z "$cap38" ] && ok "no question-count promise survives on the repo-interview surfaces" \
  || bad "a question-count promise survived the cap retirement" "$cap38"
grep -q '≤5' .claude/skills/setup/voice.md \
  && ok "voice.md's own ≤5 cap is KEPT (a deliberate scope limit on a style interview)" \
  || bad "voice.md's deliberate ≤5 scope limit went missing (4b keeps it)"
# (B) rendered config, not prose: the completed-interview shape (mirrors interview.md's worked
# block). Every adapter-required key is populated — jira site+cli, postgres conn, gdrive
# drive_folder, slack mcp, github default_branch — because verify_stack exits 0 even while warning
# about unset required keys, so "it passed" alone would certify a half-configured repo.
IVR="$TMP/s38-full"; mkdir -p "$IVR/.claude/config"
cat > "$IVR/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
  assignee_dir: alice
  ticket_path: "tickets/{assignee}/{id}"
  terminal_status: Done
  ticket_url_template: "https://tracker.acme.example/browse/{id}"
  intake: [tracker, email, meetings]
  role: analyst
  domain: data analysis
  analysis_tools: [notebooks, spreadsheets]
seams:
  tracker:
    tool: jira
    adapter: adapters/tracker/jira.md
    transport: cli
    site: tracker.acme.example
    cli: acli
    verify: null
  warehouse:
    tool: postgres
    adapter: adapters/warehouse/postgres.md
    transport: cli
    conn: "service=analytics"
    dev_target: analytics_dev
    verify: null
  docstore:
    tool: gdrive
    adapter: adapters/docstore/gdrive.md
    transport: cli
    drive_folder: "Shared drives/Tickets"
    verify: null
  chat:
    tool: slack
    adapter: adapters/chat/slack.md
    transport: mcp
    mcp: chatserver
    default_channel: C0XXXXXXXXX
    default_mode: draft
    always_include: [Alice]
    verify: null
  vcs:
    tool: github
    adapter: adapters/vcs/github.md
    transport: cli
    default_branch: main
    verify: null
policies:
  db_write_requires_approval: high_risk
  human_review_handoff: review
EOF
IVY="$IVR/.claude/config/stack.yaml"
ivout="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$IVY" --dry-run 2>&1)"
grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$ivout" \
  && ok "the completed-interview config verifies end to end" \
  || bad "the completed-interview config failed verify_stack" "$ivout"
grep -q 'required key(s) not set' <<<"$ivout" \
  && bad "a completed interview left an adapter-required key unset (the ask-every-requires rule regressed)" "$ivout" \
  || ok "no adapter-required key is unset — the interview asks for every requires: key"
[ "$(yq '.seams.chat.always_include | length' "$IVY" 2>/dev/null)" -ge 1 ] 2>/dev/null \
  && ok "always_include is present and non-empty in the rendered config (round 4)" \
  || bad "always_include missing or empty in the rendered config"
ivurl="$(yq '.project.ticket_url_template' "$IVY" 2>/dev/null)"
{ [ -n "$ivurl" ] && [ "$ivurl" != "null" ]; } \
  && ok "ticket_url_template is set (round 2 — a dead index link is the textbook silent-wrong)" \
  || bad "ticket_url_template unset in the completed-interview config"
yq -e '.seams.warehouse.dev_target' "$IVY" >/dev/null 2>&1 \
  && ok "dev_target is present (round 3 — dev DDL has a separate home)" \
  || bad "dev_target missing from the completed-interview config"
yq -e '.project.intake' "$IVY" >/dev/null 2>&1 \
  && ok "project.intake is written (round 4's email question fills a real key)" \
  || bad "project.intake missing — the email question would be an ignored value"
yq -e '.seams.docstore.drive_folder' "$IVY" >/dev/null 2>&1 \
  && ok "the docstore's tier-1 half (drive_folder) lands in stack.yaml" \
  || bad "drive_folder missing from the completed-interview config"
grep -q 'mount_root' "$IVY" \
  && bad "a machine mount root leaked into committed stack.yaml (a tier-3 value in tier 1)" \
  || ok "the machine mount root is ABSENT from stack.yaml (report-only; routed to the person flow)"
# (C) skip behavior: rounds 5-6 skipped ⇒ the two # TODO(setup) lines ride the config, and the
# config still verifies. The TODO forms are the exact ones interview.md specifies, so the fixture
# and the instructions cannot drift apart without one of these assertions going red.
IVS="$TMP/s38-skip"; mkdir -p "$IVS/.claude/config"
sed -e 's|^  role: analyst$|  # TODO(setup): round 5 skipped — role/domain/analysis_tools at defaults; finish with /setup role|' \
    -e '/^  domain: data analysis$/d' -e '/^  analysis_tools:/d' \
    -e 's|^  db_write_requires_approval: high_risk$|  # TODO(setup): round 6 skipped — policies at defaults; finish with /setup policies|' \
    -e '/^  human_review_handoff: review$/d' \
    "$IVY" > "$IVS/.claude/config/stack.yaml"
printf '  hard_halt_before_external_posts: true\n' >> "$IVS/.claude/config/stack.yaml"
skout="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$IVS/.claude/config/stack.yaml" --dry-run 2>&1)"
grep -Eq 'All seams OK|[0-9]+ OK, [0-9]+ unverified' <<<"$skout" \
  && ok "a config with rounds 5-6 skipped (TODO lines in place) still verifies" \
  || bad "the skipped-rounds config failed verify_stack" "$skout"
{ grep -q '# TODO(setup): round 5 skipped' "$IVS/.claude/config/stack.yaml" \
  && grep -q '# TODO(setup): round 6 skipped' "$IVS/.claude/config/stack.yaml"; } \
  && ok "each skipped round leaves an explicit # TODO(setup) line naming its re-entry command" \
  || bad "the skip TODO lines are missing from the fixture"
{ grep -q '# TODO(setup): round 5 skipped' "$IV" && grep -q '# TODO(setup): round 6 skipped' "$IV"; } \
  && ok "interview.md specifies those exact TODO forms (fixture and instructions cannot drift)" \
  || bad "interview.md no longer specifies the # TODO(setup) line forms"
{ grep -q 'Skip this and' "$IV" && grep -qi 'per-round only' "$IV"; } \
  && ok "skips are offered per round, labeled with their cost — never a global bail" \
  || bad "the per-round consequence-labeled skip rule is missing from interview.md"
{ grep -qi 'punch list' <<<"$iflat" && grep -qi 'punch list' <<<"$skflat38"; } \
  && ok "the punch list is specified in interview.md AND in the Phase-4 report step" \
  || bad "the punch-list requirement is missing from interview.md or SKILL.md's report step"
# (D) every advertised re-entry verb resolves to a defined mode — a promise with no mechanism is
# worse than no promise.
rv38=""
for v in role team policies; do
  grep -q -- "/setup $v" "$IV" || rv38="$rv38 interview.md:/setup-$v"
  grep '^## Mode' "$SK38" | grep -q "\`$v\`" || rv38="$rv38 SKILL.md-mode:$v"
done
[ -z "$rv38" ] && ok "re-entry verbs advertised (role/team/policies) all resolve to defined modes" \
  || bad "a re-entry verb is advertised without a mechanism (or defined without being advertised)" "$rv38"
# (E) the CLI-probe exemption survives VERBATIM. Section 3 exempts the setup CLI-detector line BY
# LITERAL SUBSTRING in TWO separate greps — the tool-name leak grep AND the warehouse-product
# grep (the probe also says `databricks`). Rewording, reordering or line-splitting the probe
# breaks both, with failure messages that never say "you edited the probe".
grep -q 'for c in snow acli gh glab bq databricks yq jq git rclone' "$SK38" \
  && ok "the CLI-detection probe line survives verbatim in setup/SKILL.md" \
  || bad "the CLI probe line was reworded/split — section 3's two exemptions no longer match it"
nex38="$(grep -c "grep -v 'for c in snow acli gh'" bin/selftest.sh)"
[ "$nex38" -ge 2 ] \
  && ok "both section-3 exemption greps still carry the literal probe substring ($nex38 found)" \
  || bad "a section-3 exemption grep lost the probe literal (found $nex38, need 2)"
# (F) the canonical spelling is present; every SURVIVING old spelling carries its deprecation
# line. Deliberately NOT asserted: that old spellings are gone — prompt 4 keeps them working for
# one release, so an absence assertion and that deprecation window cannot both hold.
grep -q '/setup tool chat' "$SK38" \
  && ok "the canonical /setup tool chat spelling is present" \
  || bad "the canonical /setup tool chat spelling is missing"
old38=""
for f in $(grep -rlE '/setup (chat|docstore|warehouse)' .claude/skills README.md 2>/dev/null); do
  grep -qiE 'deprecated spelling|old spelling' "$f" || old38="$old38 $f"
done
[ -z "$old38" ] && ok "every surviving old /setup <slot> spelling carries a deprecation line" \
  || bad "an old /setup <slot> spelling survives without its deprecation line" "$old38"
# (G) Obsidian: detect-and-guide, never a question. The doc exists and is linked from BOTH README
# locations; the setup report prints the GitHub URL because docs/ does not ship in the wheel.
[ -f docs/obsidian.md ] && ok "docs/obsidian.md ships" || bad "docs/obsidian.md missing"
sed -n '/^## See it as a graph/,/^## /p' README.md | grep -q 'docs/obsidian.md' \
  && ok "README's Obsidian section links docs/obsidian.md" \
  || bad "docs/obsidian.md not linked from README's Obsidian section"
sed -n '/^## Learn more/,/^## /p' README.md | grep -q 'docs/obsidian.md' \
  && ok "README's further-reading list links docs/obsidian.md" \
  || bad "docs/obsidian.md not linked from README's Learn more list"
grep -q 'github.com/kyle-chalmers/ticketwright/blob/main/docs/obsidian.md' "$SK38" \
  && ok "the setup report prints the doc's GitHub URL (docs/ is not in the PyPI package)" \
  || bad "the setup report would print a bare docs/ path that a pip install does not have"
# (H) the AskUserQuestion sweep held: interviews are prose everywhere in the skill surface —
# frontmatter allowed-tools AND body text. (Runtime capability docs under adapters/runtime/ and
# docs/ legitimately DESCRIBE the tool; they are not skills and are not scanned.)
auq38="$(grep -rn 'AskUserQuestion' .claude/skills/ 2>/dev/null || true)"
[ -z "$auq38" ] \
  && ok "no skill authors an interview as a structured tool-call (AskUserQuestion fully swept)" \
  || bad "AskUserQuestion survives in a skill" "$auq38"
# (I) round 5's two new keys are wired end to end: schema row, template token, scaffold guidance,
# and the intake consumer in /ticket's priming — a key nothing consumes is configuration theater.
{ grep -q '{{analysis_tools}}' templates/AGENTS.md.tmpl \
  && grep -q 'analysis_tools' .claude/skills/setup/scaffold.md \
  && grep -q 'analysis_tools' .claude/config/stack.schema.md \
  && grep -qi 'Not a tool slot' .claude/config/stack.schema.md; } \
  && ok "analysis_tools: schema row (not-a-slot stated), template token, scaffold guidance" \
  || bad "analysis_tools is not wired through schema + template + scaffold"
grep -i 'permissions.allow' "$IV" | grep -qi 'not' \
  && ok "interview.md forbids auto-appending analysis tooling to permissions.allow" \
  || bad "the permissions.allow prohibition is missing from round 5"
{ grep -q 'intake' .claude/config/stack.schema.md \
  && grep -q 'intake' .claude/skills/ticket/priming.md \
  && grep -q 'source_materials' .claude/skills/ticket/priming.md; } \
  && ok "project.intake has a schema row and a real consumer (/ticket priming sweeps source_materials/)" \
  || bad "project.intake lacks its schema row or its consumer"
# (J) email: on "out", the answers are RECORDED (provider, identity, audience) in a commented
# seams.chat.targets.email block, and both the interview and the report say plainly that email is
# configured but not yet ACTIVATED — so nobody believes a draft will send. (The wording moved from
# "not yet wired" when PROMPT 10 shipped the gmail/outlook adapters: the missing piece is no longer
# an adapter but the deliberate targets: conversion, and the block must point at the activated
# worked example rather than at writing a new adapter.)
{ grep -q 'gmail' "$IV" && grep -q 'outlook' "$IV" \
  && grep -qi 'sending identity' <<<"$iflat" && grep -qi 'audience' "$IV" \
  && grep -q 'seams.chat.targets.email' "$IV" \
  && grep -qi 'configured but not yet activated' <<<"$iflat" \
  && grep -q 'stack.example.multi-audience.yaml' "$IV"; } \
  && ok "email delivery records provider + identity + audience in a commented target block, honestly unactivated" \
  || bad "the email question's recorded-answers contract is incomplete in interview.md"
grep -qi 'configured but not' <<<"$skflat38" \
  && ok "the Phase-4 report states email is configured but not yet activated" \
  || bad "the report step never says email is configured-but-not-activated"

hdr "39 · runtime installer skeleton (emit_runtime.py — verify-only vs translate-on-emit)"
# The installer is the compatibility layer between the canonical .claude/skills/ source and each
# runtime's own layout: EMIT only where the runtime cannot already see the canonical copy
# (codex-cli), VERIFY-ONLY where it can (claude-code). Every run below happens in a mktemp fixture
# project with the Claude env vars scrubbed (standing constraint: no Claude variable required), and
# CLAUDE_CONFIG_DIR pinned to an empty dir so the contributor's own plugin manifest can never
# satisfy — or fail — a verify.
EMIT_NOCLAUDE="$TMP/emit-noclaude"; mkdir -p "$EMIT_NOCLAUDE"

# --- codex-cli emit: byte-for-byte against the golden fixture tree --------------------------------
EMIT_P="$TMP/emit-codex"; mkdir -p "$EMIT_P"
emit_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_KIT -u TICKETWRIGHT_PROJECT \
  CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" python3 bin/emit_runtime.py --runtime codex-cli --root "$EMIT_P" 2>&1)"; emit_rc=$?
[ "$emit_rc" -eq 0 ] && ok "codex-cli emit exits 0 in a fresh fixture project (no Claude env var)" \
  || bad "codex-cli emit failed (rc=$emit_rc)" "$(head -3 <<<"$emit_out")"
ediff="$(diff -r "$EMIT_P/.agents" tests/emit/codex-cli/.agents 2>&1 \
        && diff -r "$EMIT_P/.codex" tests/emit/codex-cli/.codex 2>&1)" \
  && ok "emitted tree (.agents + .codex) is byte-for-byte identical to tests/emit/codex-cli/" \
  || bad "emitted tree diverges from the golden fixtures (regenerate deliberately, per tests/emit/README.md)" \
        "$(head -3 <<<"$ediff")"
# U1's temporary carve-out (defer gated skills entirely) was COMPLETED by U2's metadata mapping:
# a skill whose source declares disable-model-invocation: true is now emitted, but the loss must
# ride in the ARTIFACT — a topmost warning block — and be printed, never silent. Enumerated from
# SOURCE frontmatter rather than a hardcoded list, with the SAME parser as the emitter — a literal
# grep would let a validly quoted `"true"` evade this assertion while the emitter gates it.
gated="$(python3 -c "
import sys, pathlib
sys.path.insert(0, 'bin')
import kit_paths
for f in sorted(pathlib.Path('.claude/skills').glob('*/SKILL.md')):
    if kit_paths.read_frontmatter(f).get('disable-model-invocation') == 'true':
        print(f.parent.name)
")"
[ -n "$gated" ] || bad "no source skill declares disable-model-invocation: true — the carve-out fixture premise broke"
carve_bad=""
for g in $gated; do
  gf="$EMIT_P/.agents/skills/$g/SKILL.md"
  [ -f "$gf" ] || carve_bad="$carve_bad unemitted:$g"
  grep -q 'User-invocable only' "$gf" 2>/dev/null || carve_bad="$carve_bad unwarned:$g"
  grep -q "warned    $g" <<<"$emit_out" || carve_bad="$carve_bad unprinted:$g"
done
[ -z "$carve_bad" ] && ok "every disable-model-invocation skill is emitted WITH its warning block AND the loss printed ($(echo $gated | tr ' ' ','))" \
  || bad "a user-invocable-only skill was emitted without its stated loss" "$carve_bad"
# The count guard: the completion must not quietly drop skills either way.
emitted_n="$(find "$EMIT_P/.agents/skills" -name SKILL.md | wc -l | tr -d ' ')"
total_n="$(ls .claude/skills/*/SKILL.md | wc -l | tr -d ' ')"
[ "$emitted_n" -eq "$total_n" ] && ok "every skill is emitted ($emitted_n of $total_n)" \
  || bad "emit count wrong" "emitted $emitted_n, expected $total_n"
# The provenance header is the anti-hand-copy statement, carried in the artifact itself.
prov_bad=""
for f in "$EMIT_P"/.agents/skills/*/SKILL.md; do
  grep -q 'emitted by ticketwright install v' "$f" || prov_bad="$prov_bad $(basename "$(dirname "$f")")"
done
[ -z "$prov_bad" ] && ok "the provenance header is present in every emitted file" \
  || bad "an emitted file is missing its provenance header" "$prov_bad"
grep -q 'Metadata mapping' <<<"$emit_out" && grep -q 'not expressible here' <<<"$emit_out" \
  && ok "lost control fields are named on stdout pointing at the adapter's Metadata mapping section" \
  || bad "the lost-fields statement is missing from the emit report"
# COLLISION HANDLING IS PROVENANCE-AWARE for every emitted artifact (U1's anti-clobber guarantee,
# kept and generalized). Two pre-seeded cases: a copy WE emitted earlier (provenance header
# present — overwritten with fresh content, that is what "re-run to update" means) and a
# hand-copied file (no header — never overwritten, never deleted, and the install fails loudly
# instead of silently clobbering a hand-maintained file).
ST_P="$TMP/emit-stale"; mkdir -p "$ST_P/.agents/skills/ship" "$ST_P/.agents/skills/setup"
printf -- '---\nname: ship\ndescription: stale\n---\n\n<!-- emitted by ticketwright install v0.0.0 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->\n\nstale body\n' \
  > "$ST_P/.agents/skills/ship/SKILL.md"
printf -- '---\nname: setup\ndescription: hand-copied\n---\nforeign body\n' \
  > "$ST_P/.agents/skills/setup/SKILL.md"
st_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime codex-cli --root "$ST_P" 2>&1)"; st_rc=$?
diff -q "$ST_P/.agents/skills/ship/SKILL.md" tests/emit/codex-cli/.agents/skills/ship/SKILL.md >/dev/null 2>&1 \
  && ok "re-run overwrites OUR stale emitted copy with fresh content (provenance header identifies it)" \
  || bad "a stale emitted copy survived a re-run unrefreshed" "rc=$st_rc"
{ [ "$st_rc" -ne 0 ] && grep -q 'hand-copied' "$ST_P/.agents/skills/setup/SKILL.md" \
  && grep -q 'not deleted' <<<"$st_out" && grep -q 'unsupported' <<<"$st_out"; } \
  && ok "a hand-copied file is never overwritten or deleted, and the install fails loudly" \
  || bad "a hand-copied file was clobbered, or tolerated silently" "rc=$st_rc"
[ -f "$ST_P/.agents/skills/ticket/SKILL.md" ] \
  && ok "the collision run still emits the untouched skills" \
  || bad "the collision path stopped the normal emission"

# --- claude-code: verify-only must leave the tree byte-identical -----------------------------------
# A vendored install is recognized by the kit's own markers (the launcher's is_kit test) with the
# canonical skills alongside — NOT by "some SKILL.md exists", which any project could satisfy.
VF_P="$TMP/verify-claude"; mkdir -p "$VF_P/.claude/skills/demo" "$VF_P/adapters" "$VF_P/templates" "$VF_P/bin"
cp bin/kit_paths.py "$VF_P/bin/"
printf -- '---\nname: demo\ndescription: fixture\n---\nbody\n' > "$VF_P/.claude/skills/demo/SKILL.md"
vf_before="$(cd "$VF_P" && find . -type f -exec cksum {} + | sort)"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime claude-code --root "$VF_P" >/dev/null 2>&1; vf_rc=$?
vf_after="$(cd "$VF_P" && find . -type f -exec cksum {} + | sort)"
{ [ "$vf_rc" -eq 0 ] && [ "$vf_before" = "$vf_after" ]; } \
  && ok "claude-code verify-only: exit 0 on a vendored install, tree byte-identical" \
  || bad "claude-code verify-only wrote to the tree or failed on a vendored install" "rc=$vf_rc"
EMPTY_P="$TMP/verify-empty"; mkdir -p "$EMPTY_P"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime claude-code --root "$EMPTY_P" >/dev/null 2>&1; ve_rc=$?
{ [ "$ve_rc" -ne 0 ] && [ -z "$(find "$EMPTY_P" -type f)" ]; } \
  && ok "claude-code verify-only: exit non-zero on an uninstalled project, still writes nothing" \
  || bad "verify-only on an empty project exited 0 or created files" "rc=$ve_rc"
# The false positive that must stay dead: a project with its OWN .claude/skills/ (no kit markers)
# is not a ticketwright install, and blessing it would hide a missing install behind foreign files.
FS_P="$TMP/verify-foreign"; mkdir -p "$FS_P/.claude/skills/foo"
printf -- '---\nname: foo\ndescription: not ours\n---\nbody\n' > "$FS_P/.claude/skills/foo/SKILL.md"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime claude-code --root "$FS_P" >/dev/null 2>&1 \
  && bad "verify-only blessed a foreign .claude/skills/ project as a ticketwright install" \
  || ok "verify-only rejects a foreign .claude/skills/ project (kit markers required)"
# The plugin route: a manifest entry for this kit satisfies the verify with no vendored files at all.
PLUG_HOME="$TMP/plughome"; mkdir -p "$PLUG_HOME/plugins"
printf '{"plugins": {"ticketwright@ticketwright": [{"scope": "user", "installPath": "%s"}]}}' "$KIT" \
  > "$PLUG_HOME/plugins/installed_plugins.json"
PLUG_P="$TMP/verify-plugin"; mkdir -p "$PLUG_P"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$PLUG_HOME" \
  python3 bin/emit_runtime.py --runtime claude-code --root "$PLUG_P" >/dev/null 2>&1; pl_rc=$?
{ [ "$pl_rc" -eq 0 ] && [ -z "$(find "$PLUG_P" -type f)" ]; } \
  && ok "claude-code verify-only: a plugin-manifest install verifies with nothing vendored, nothing written" \
  || bad "the plugin-manifest verify route failed or wrote files" "rc=$pl_rc"

# --- aliases resolve through kit_paths and run the CANONICAL runtime's mode ------------------------
ws_err="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime windsurf --root "$EMPTY_P" 2>&1)"; ws_rc=$?
{ [ "$ws_rc" -ne 0 ] && grep -q 'devin' <<<"$ws_err" && ! grep -q 'windsurf' <<<"$ws_err" \
  && grep -q 'ticketwright init' <<<"$ws_err"; } \
  && ok "--runtime windsurf resolves to devin: its verify fails on an empty project naming devin (never windsurf) with the vendor fix" \
  || bad "the windsurf alias did not run devin's verify mode" "rc=$ws_rc: $(head -2 <<<"$ws_err")"
[ -z "$(find "$EMPTY_P" -type f)" ] || bad "an error path wrote files into the fixture project"
un_err="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
  python3 bin/emit_runtime.py --runtime not-a-runtime --root "$EMPTY_P" 2>&1)"; un_rc=$?
{ [ "$un_rc" -ne 0 ] && grep -q 'antigravity' <<<"$un_err" && grep -q 'gemini-cli' <<<"$un_err" \
  && grep -q 'windsurf' <<<"$un_err"; } \
  && ok "an unknown runtime exits non-zero listing the seven runtimes and their aliases" \
  || bad "the unknown-runtime error does not list runtimes + aliases" "rc=$un_rc"

# --- one implementation, three routes: pip entrypoint, shell wrapper, and the packaged path --------
# `ticketwright install` must register the PYTHON entrypoint (cli.py runs every registered script
# with sys.executable — registering install.sh would exec `python install.sh`).
python3 -c "import sys; sys.path.insert(0, '.'); from ticketwright.cli import SCRIPTS; \
sys.exit(0 if SCRIPTS.get('install') == 'emit_runtime.py' else 1)" \
  && ok "ticketwright install registers the python entrypoint (emit_runtime.py, never the .sh)" \
  || bad "SCRIPTS['install'] is not emit_runtime.py"
SH_P="$TMP/emit-sh"; mkdir -p "$SH_P"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  bash bin/install.sh --runtime codex-cli --root "$SH_P" >/dev/null 2>&1 \
  && diff -r "$SH_P/.agents" tests/emit/codex-cli/.agents >/dev/null 2>&1 \
  && diff -r "$SH_P/.codex" tests/emit/codex-cli/.codex >/dev/null 2>&1 \
  && ok "bin/install.sh (the shell convenience) reaches the same implementation, same bytes" \
  || bad "bin/install.sh diverged from the python entrypoint"
# The packaged path, end to end and offline: a wheel-shaped install (the package + _kit, which is
# exactly what the force-includes produce) runs `init` into a fresh repo, `install` emits the
# fixture-identical tree from the wheel kit, and the VENDORED bin/install.sh then emits the same
# tree again — proving init's bin/KIT_VERSION marker feeds the provenance header, since a wrong or
# missing version would break the byte-for-byte diff. cwd sits outside the repo so PYTHONPATH, not
# the source tree, supplies the package (python -c puts cwd first on sys.path).
SITE="$TMP/site"; WP="$TMP/wheelproj"
mkdir -p "$SITE/ticketwright/_kit/.claude" "$WP"
cp ticketwright/__init__.py ticketwright/cli.py "$SITE/ticketwright/"
cp -R bin "$SITE/ticketwright/_kit/bin"
cp -R adapters "$SITE/ticketwright/_kit/adapters"
cp -R templates "$SITE/ticketwright/_kit/templates"
cp -R .claude/skills "$SITE/ticketwright/_kit/.claude/skills"
cp -R .claude/agents "$SITE/ticketwright/_kit/.claude/agents"
(cd "$TMP" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR PYTHONPATH="$SITE" \
  python3 -c "import sys; from ticketwright.cli import main; sys.exit(main(['init', '$WP']))" >/dev/null 2>&1) \
  && [ -s "$WP/bin/KIT_VERSION" ] && [ -f "$WP/bin/emit_runtime.py" ] \
  && ok "a wheel-shaped install scaffolds via init, writing the bin/KIT_VERSION marker" \
  || bad "the packaged init did not vendor the kit + version marker"
grep -qx "$(python3 -c "import sys; sys.path.insert(0, '.'); import ticketwright; print(ticketwright.__version__)")" \
  "$WP/bin/KIT_VERSION" 2>/dev/null \
  && ok "the vendored KIT_VERSION matches ticketwright/__init__.py (single source of truth)" \
  || bad "bin/KIT_VERSION diverges from __init__.py"
WI="$TMP/wheelinstall"; mkdir -p "$WI"
(cd "$TMP" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" PYTHONPATH="$SITE" \
  python3 -c "import sys; from ticketwright.cli import main; sys.exit(main(['install', '--runtime', 'codex-cli', '--root', '$WI']))" >/dev/null 2>&1) \
  && diff -r "$WI/.agents" tests/emit/codex-cli/.agents >/dev/null 2>&1 \
  && diff -r "$WI/.codex" tests/emit/codex-cli/.codex >/dev/null 2>&1 \
  && ok "ticketwright install from the wheel-shaped kit emits the fixture-identical tree" \
  || bad "the packaged install route diverged from the golden fixtures"
VI="$TMP/vendoredinstall"; mkdir -p "$VI"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u TICKETWRIGHT_KIT CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  bash "$WP/bin/install.sh" --runtime codex-cli --root "$VI" >/dev/null 2>&1 \
  && diff -r "$VI/.agents" tests/emit/codex-cli/.agents >/dev/null 2>&1 \
  && diff -r "$VI/.codex" tests/emit/codex-cli/.codex >/dev/null 2>&1 \
  && ok "the init-vendored bin/install.sh emits the same bytes (KIT_VERSION feeds the provenance header)" \
  || bad "the vendored install route diverged (provenance version or emit path broke off-repo)"
# tests/ is repo-only material: it must never ride into the wheel or sdist.
grep -q '"tests' pyproject.toml && bad "tests/ leaked into pyproject packaging config" \
  || ok "tests/ fixtures stay out of the wheel and sdist (pyproject untouched by them)"
hdr "40 · capability vocabulary: the 3b safety axes as data (PROMPT 7 / U5)"
# Five additive keys on every runtime adapter. The values are DECLARATIONS backed by the dated,
# cited research in docs/runtimes.md — what this section pins is declared-value consistency, so a
# drive-by edit cannot flip a safety axis silently. The truth of the declarations rests on the
# research and its live re-checks (the U6 punch list); no assertion here claims a live behavior.

# --- closed vocabulary: an enum key holding a value outside its enum is a typo, not a finding ----
python3 - <<'PY' >"$TMP/hd4140.out"
import re, sys, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
ENUMS = {
    "gate_ask_tier": {"yes", "no", "unknown"},
    "gate_fail_mode": {"open", "closed", "unknown"},
    "subagent_isolation": {"documented", "unestablished", "none"},
}
bad = []
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    if f.name == "README.md":
        continue
    fm = read_frontmatter(f)
    for k, legal in ENUMS.items():
        if fm.get(k) not in legal:
            bad.append(f"{f.name}:{k}={fm.get(k)!r}")
    # The two installer-driving keys have FORMS, not enums — and a malformed value here would send
    # the installer down the wrong emit-vs-verify or --global path, so the form is validated too:
    # reads_foreign_skills is `none` or a comma-separated list of dot-relative roots;
    # global_skills_root is `unknown` or an absolute/home-anchored path.
    rfs = fm.get("reads_foreign_skills", "")
    if rfs != "none":
        items = [i.strip() for i in rfs.split(",")]
        if not items or any(not re.match(r"^\.[A-Za-z0-9._/-]+$", i) for i in items):
            bad.append(f"{f.name}:reads_foreign_skills={rfs!r}")
    gsr = fm.get("global_skills_root", "")
    if gsr != "unknown" and not re.match(r"^(~/|/)[A-Za-z0-9._/-]+$", gsr):
        bad.append(f"{f.name}:global_skills_root={gsr!r}")
print("\n".join(bad))
PY
cv_bad="$(cat "$TMP/hd4140.out")"
[ -z "$cv_bad" ] && ok "every runtime adapter's 3b keys hold closed-vocabulary/well-formed values (parsed as consumers parse them)" \
  || bad "a runtime adapter declares an out-of-vocabulary or malformed capability value" "$cv_bad"

# --- the load-bearing rows are PINNED, so a drive-by edit cannot flip a safety axis silently -----
# gate_ask_tier is the 3b inversion: db_write_requires_approval's default (high_risk) is natively
# expressible exactly where this is `yes`, and must collapse — visibly — exactly where it is `no`.
for pair in "claude-code:yes" "cursor:yes" "antigravity:yes" "codex-cli:no" "opencode:no" "devin:no"; do
  rt="${pair%%:*}"; want="${pair##*:}"
  got="$(python3 -c "import sys; sys.path.insert(0,'bin'); from kit_paths import read_frontmatter; \
from pathlib import Path; print(read_frontmatter(Path('adapters/runtime/$rt.md')).get('gate_ask_tier'))")"
  [ "$got" = "$want" ] && ok "pinned: $rt gate_ask_tier=$want" \
    || bad "$rt's gate_ask_tier flipped — that is a safety-axis edit, not a tidy-up" "got '$got' want '$want'"
done
# gate_fail_mode records the NATIVE default (cursor open is WHY an installer must set failClosed;
# devin open is documented design; antigravity is undocumented and must stay honestly unknown).
for pair in "cursor:open" "devin:open" "antigravity:unknown"; do
  rt="${pair%%:*}"; want="${pair##*:}"
  got="$(python3 -c "import sys; sys.path.insert(0,'bin'); from kit_paths import read_frontmatter; \
from pathlib import Path; print(read_frontmatter(Path('adapters/runtime/$rt.md')).get('gate_fail_mode'))")"
  [ "$got" = "$want" ] && ok "pinned: $rt gate_fail_mode=$want" \
    || bad "$rt's gate_fail_mode changed — re-cite the vendor docs before touching this row" "got '$got' want '$want'"
done
# subagent_isolation decides whether /review --deep is an independent second context there.
for pair in "cline:none" "codex-cli:unestablished" "opencode:unestablished"; do
  rt="${pair%%:*}"; want="${pair##*:}"
  got="$(python3 -c "import sys; sys.path.insert(0,'bin'); from kit_paths import read_frontmatter; \
from pathlib import Path; print(read_frontmatter(Path('adapters/runtime/$rt.md')).get('subagent_isolation'))")"
  [ "$got" = "$want" ] && ok "pinned: $rt subagent_isolation=$want" \
    || bad "$rt's subagent_isolation was promoted without documentation" "got '$got' want '$want'"
done

# --- the CLI surfaces the new keys, each readable on its own ------------------------------------
cli40="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME=cursor \
        python3 bin/kit_paths.py --json 2>/dev/null)"
python3 - "$cli40" <<'PY'
import json, sys
c = json.loads(sys.argv[1] or "{}").get("capabilities", {})
sys.exit(0 if c.get("gate_ask_tier") == "yes" and c.get("gate_fail_mode") == "open"
         and c.get("subagent_isolation") == "documented"
         and c.get("reads_foreign_skills") == ".claude/skills, .codex/skills"
         and c.get("global_skills_root") == "~/.cursor/skills" else 1)
PY
[ $? -eq 0 ] && ok "kit_paths --json surfaces all five keys per adapter (cursor spot-check)" \
  || bad "kit_paths --json does not surface the new capability keys" "$cli40"

# --- the axes are INDEPENDENT, and the data proves it (nothing may average them into one score) --
# Antigravity: the richest gate researched, and NO session hook. Devin: a session hook, and a gate
# that fails open by documented design. Any single derived score would erase exactly this.
python3 - <<'PY' >"$TMP/hd4220.out"
import sys
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
from pathlib import Path
agy = read_frontmatter(Path("adapters/runtime/antigravity.md"))
dvn = read_frontmatter(Path("adapters/runtime/devin.md"))
probs = []
if not (agy.get("gate_ask_tier") == "yes" and agy.get("session_start") == "no"):
    probs.append("antigravity no longer shows rich-gate-without-session-hook")
if not (dvn.get("session_start") == "yes" and dvn.get("gate_fail_mode") == "open"):
    probs.append("devin no longer shows session-hook-with-fail-open-gate")
print("\n".join(probs))
PY
ind40="$(cat "$TMP/hd4220.out")"
[ -z "$ind40" ] && ok "the 3b axes genuinely diverge in the data (richer gate != session hook != fail mode)" \
  || bad "the axis-independence examples no longer hold — check what got edited" "$ind40"

# --- the 2026-08-19 matrix corrections stay corrected --------------------------------------------
# Positive pins where the fix ADDED the true claim; a negative pin only where the false claim's
# exact wording must not return (the correction prose itself never uses that wording).
{ grep -q 'PermissionRequest' adapters/runtime/devin.md && grep -q 'PermissionRequest' docs/runtimes.md; } \
  && ok "devin's approve/block schema is attributed to PermissionRequest (adapter + runtimes.md)" \
  || bad "the devin PreToolUse/PermissionRequest correction was reverted"
{ grep -qE 'PreToolUse.*(exit code 2|exit 2)' adapters/runtime/devin.md || grep -q 'only via exit code 2' adapters/runtime/devin.md; } \
  && ok "devin's PreToolUse is documented as blocking via exit 2" \
  || bad "devin's adapter no longer states the exit-2-only PreToolUse contract"
{ grep -q 'mode: "subagent"' adapters/runtime/opencode.md && grep -q 'mode: "subagent"' docs/runtimes.md; } \
  && ok 'opencode subagent marking is mode: "subagent" (adapter + runtimes.md)' \
  || bad "the opencode subagent-marking correction was reverted"
grep -q 'only researched runtime' adapters/runtime/claude-code.md \
  && bad "claude-code.md again claims to be the only runtime with a pre-tool ask (cursor + antigravity have it)" \
  || ok "claude-code.md no longer claims the pre-tool ask tier is exclusive"

# --- the human-readable matrix and the machine-readable frontmatter must agree ------------------
python3 - <<'PY' >"$TMP/hd4255.out"
import re, sys, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
DISPLAY = {"claude-code": "Claude Code", "codex-cli": "Codex CLI", "cursor": "Cursor",
           "antigravity": "Antigravity", "opencode": "OpenCode", "devin": "Devin", "cline": "Cline"}
doc = pathlib.Path("docs/runtimes.md").read_text(encoding="utf-8")
sect = doc.split("## The matrix, machine-readable", 1)
if len(sect) < 2:
    print("runtimes.md lost its machine-readable matrix section"); raise SystemExit
def norm(cell):
    cell = re.sub(u"[¹²³⁴⁵⁶⁷⁸⁹`]", "", cell)
    return re.sub(r"\s+", " ", cell).strip()
rows = {}
for line in sect[1].splitlines():
    m = re.match(r"\|\s*\*\*(.+?)\*\*\s*\|(.+)\|", line)
    if m:
        rows[m.group(1)] = [norm(c) for c in m.group(2).split("|")[:5]]
KEYS = ("gate_ask_tier", "gate_fail_mode", "subagent_isolation",
        "reads_foreign_skills", "global_skills_root")
bad = []
for tool, name in DISPLAY.items():
    fm = read_frontmatter(pathlib.Path(f"adapters/runtime/{tool}.md"))
    want = [fm.get(k) for k in KEYS]
    if rows.get(name) != want:
        bad.append(f"{name}: doc says {rows.get(name)}, frontmatter says {want}")
print("\n".join(bad))
PY
mm_bad="$(cat "$TMP/hd4255.out")"
[ -z "$mm_bad" ] && ok "runtimes.md's machine-readable table matches the adapter frontmatter (all 7 x 5 keys)" \
  || bad "runtimes.md's capability-key table drifted from the frontmatter it documents" "$mm_bad"

hdr "41 · the emission matrix: all seven runtimes, metadata mapping, agent definitions (PROMPT 7 / U2)"
# U2 extends the installer to every runtime, data-driven off adapter frontmatter: NATIVE verify
# where skills_root IS the canonical copy, VERIFY-not-emit where reads_foreign_skills includes it,
# EMIT elsewhere. What this section pins: the per-runtime fixture trees; that every
# disable-model-invocation skill is covered by a warning IN AN ARTIFACT THIS INSTALL PRODUCES
# (the emitted file's topmost block on emit runtimes, the printed verify report on verify
# runtimes), enumerated from source frontmatter, never a hardcoded list; that verify runtimes
# provably emit no duplicate skills; and that --global is driven by global_skills_root, refusing
# on unknown.
E41="$TMP/e41"; mkdir -p "$E41"

# --- structure: the two installer-driving adapter keys hold legal forms ---------------------------
python3 - <<'PY' >"$TMP/hd4299.out"
import sys, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
bad = []
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    if f.name == "README.md":
        continue
    fm = read_frontmatter(f)
    ar = fm.get("agents_root", "")
    if ar not in ("none", "unknown") and not (ar.endswith("/<name>.md") or ar.endswith("/<name>.toml")):
        bad.append(f"{f.name}:agents_root={ar!r}")
    foreign = [i.strip() for i in fm.get("reads_foreign_skills", "").split(",") if i.strip()]
    if ".claude/skills" in foreign and not fm.get("foreign_skills_caveat"):
        bad.append(f"{f.name}: verify-mode adapter with no foreign_skills_caveat to print")
print("\n".join(bad))
PY
ar_bad="$(cat "$TMP/hd4299.out")"
[ -z "$ar_bad" ] && ok "every adapter declares a legal agents_root, and every verify-mode adapter carries its printed caveat" \
  || bad "an adapter's installer-driving key is malformed or missing" "$ar_bad"
# The emit-vs-verify split is a safety-relevant declaration — pin the verify set so a drive-by
# edit to reads_foreign_skills cannot silently flip a runtime between emitting and verifying.
python3 - <<'PY' >"$TMP/hd4321.out"
import sys, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    if f.name == "README.md":
        continue
    fm = read_frontmatter(f)
    foreign = [i.strip() for i in fm.get("reads_foreign_skills", "").split(",")]
    if ".claude/skills" in foreign:
        print(fm["tool"])
PY
verify_rts="$(cat "$TMP/hd4321.out")"
[ "$(echo $verify_rts | tr ' ' ',')" = "cline,cursor,devin,opencode" ] \
  && ok "pinned: the verify-not-emit set is exactly cline, cursor, devin, opencode (from reads_foreign_skills)" \
  || bad "the emit-vs-verify split flipped for some runtime — that is a safety-axis edit" "got: $verify_rts"

# --- the metadata mapping table: all three fields x seven runtimes, closed statuses --------------
python3 - <<'PY' >"$TMP/hd4339.out"
import re, pathlib
FIELDS = ("`allowed-tools`", "`disable-model-invocation`", "`tools:`")
LEGAL = {"native", "mapped (unverified)", "lost"}
bad = []
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    if f.name == "README.md":
        continue
    text = f.read_text(encoding="utf-8")
    m = re.search(r"^## Metadata mapping$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        bad.append(f"{f.name}: no '## Metadata mapping' section")
        continue
    for field in FIELDS:
        row = next((l for l in m.group(1).splitlines() if l.startswith("| " + field)), None)
        if not row:
            bad.append(f"{f.name}: no mapping row for {field}")
            continue
        cells = [c.strip() for c in row.strip().strip("|").split("|")]
        if len(cells) < 3 or cells[1] not in LEGAL or not cells[2]:
            bad.append(f"{f.name}: {field} status must be native|mapped (unverified)|lost with a non-empty how-cell")
print("\n".join(bad))
PY
mt_bad="$(cat "$TMP/hd4339.out")"
[ -z "$mt_bad" ] && ok "every adapter's Metadata mapping table covers all three fields with closed-vocabulary statuses (losses named, never empty)" \
  || bad "a metadata mapping table is missing a field, an illegal status, or an unexplained loss" "$mt_bad"

# --- emit runtimes: antigravity shares the .agents emission, gated warnings ride topmost ----------
gated41="$(python3 -c "
import sys, pathlib
sys.path.insert(0, 'bin')
import kit_paths
for f in sorted(pathlib.Path('.claude/skills').glob('*/SKILL.md')):
    if kit_paths.read_frontmatter(f).get('disable-model-invocation') == 'true':
        print(f.parent.name)
")"
[ -n "$gated41" ] || bad "no source skill declares disable-model-invocation: true — the warning-coverage premise broke"
AG_P="$E41/agy"; mkdir -p "$AG_P"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime antigravity --root "$AG_P" >/dev/null 2>&1; ag_rc=$?
agdiff="$(diff -r "$AG_P/.agents" tests/emit/antigravity/.agents 2>&1)" && [ "$ag_rc" -eq 0 ] \
  && ok "antigravity emission is byte-for-byte identical to tests/emit/antigravity/ (skills + agent definition)" \
  || bad "antigravity emission diverged from its golden fixtures" "rc=$ag_rc $(head -3 <<<"$agdiff")"
# The warning must be the FIRST RENDERED BLOCK of every gated emitted file (the provenance line
# above it is an HTML comment): the loss rides in the artifact, not only in a report that scrolls.
pos_bad=""
for g in $gated41; do
  for tree in "$EMIT_P" "$AG_P"; do
    f="$tree/.agents/skills/$g/SKILL.md"
    first="$(awk 'NR==1{infm=1; next} infm && /^---$/{infm=0; next} infm{next} /^$/{next} /^<!--/{next} {print; exit}' "$f" 2>/dev/null)"
    case "$first" in "> **User-invocable only"*) ;; *) pos_bad="$pos_bad $f";; esac
  done
done
[ -z "$pos_bad" ] && ok "every gated skill's warning is the topmost rendered block on both emit runtimes ($(echo $gated41 | tr ' ' ','))" \
  || bad "a gated skill's warning block is missing or not topmost" "$pos_bad"
grep -q 'NOT mechanically enforced' tests/emit/codex-cli/.codex/agents/qc-reviewer.toml \
  && grep -q 'tools: Read, Bash, Glob, Grep' tests/emit/codex-cli/.codex/agents/qc-reviewer.toml \
  && ok "the codex agent TOML states its tools: loss inside the artifact (lost, but never silently)" \
  || bad "the codex agent TOML dropped the tools: restriction without stating it"
grep -q '^tools: Read, Bash, Glob, Grep' tests/emit/antigravity/.agents/agents/qc-reviewer.md \
  && ok "the antigravity agent definition carries tools: verbatim (mapped, acceptance is live-verification work)" \
  || bad "the antigravity agent definition lost the tools: line"
# One .agents/skills emission serves both runtimes: re-emitting for the other runtime refreshes
# our provenance-marked files rather than failing them as foreign.
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime antigravity --root "$EMIT_P" >/dev/null 2>&1 \
  && grep -q 'runtime antigravity' "$EMIT_P/.agents/skills/ticket/SKILL.md" \
  && ok "the shared .agents/skills root re-emits cleanly across codex-cli and antigravity (provenance identifies our files)" \
  || bad "re-emitting the shared .agents root for the sibling runtime failed"

# --- verify runtimes: canonical copy verified, NO skill copies, losses printed per skill ----------
VD_P="$E41/vend"; mkdir -p "$VD_P/adapters" "$VD_P/templates" "$VD_P/bin" "$VD_P/.claude"
cp bin/kit_paths.py "$VD_P/bin/"
cp -R .claude/skills "$VD_P/.claude/skills"
for rt in $verify_rts; do
  (cd "$VD_P" && find . -type f | sort) > "$E41/before.$rt"
  vout="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
    python3 bin/emit_runtime.py --runtime "$rt" --root "$VD_P" 2>&1)"; vrc=$?
  (cd "$VD_P" && find . -type f | sort) > "$E41/after.$rt"
  # The durable no-duplicate proof: the ONLY files a verify run may create are the agent
  # definitions its adapter's agents_root declares, PLUS (since U3) the hook wiring its
  # hook_wiring declares and the enforcement artifact its rules_root declares — all computed
  # from the same data the emitter uses, so a regression that wrote a skill copy under ANY root
  # (its own, .agents/, anywhere) shows up as an unexpected new file, not just as a miss on one
  # probed directory.
  vnew="$(comm -13 "$E41/before.$rt" "$E41/after.$rt")"
  want="$(python3 -c "import sys, pathlib; sys.path.insert(0,'bin'); from kit_paths import read_frontmatter
fm = read_frontmatter(pathlib.Path('adapters/runtime/$rt.md'))
ar = fm.get('agents_root', '')
lines = []
if ar not in ('none', 'unknown'):
    for a in sorted(pathlib.Path('.claude/agents').glob('*.md')):
        lines.append('./' + ar.replace('<name>', a.stem))
hw = fm.get('hook_wiring', 'unknown')
if hw not in ('native', 'unknown'):
    lines.append('./' + hw)
rr = fm.get('rules_root', '')
if rr:
    lines.append('./' + rr + '/ticketwright-enforcement.md')
print('\n'.join(sorted(lines)))
")"
  sroot="$(python3 -c "import sys; sys.path.insert(0,'bin'); from kit_paths import read_frontmatter; \
from pathlib import Path; print(read_frontmatter(Path('adapters/runtime/$rt.md'))['skills_root'].rsplit('/<name>/',1)[0])")"
  vbad=""
  [ "$vrc" -eq 0 ] || vbad="$vbad rc=$vrc"
  [ "$vnew" = "$want" ] || vbad="$vbad unexpected-new-files:[$(echo $vnew | tr ' ' ',')]"
  [ -e "$VD_P/$sroot" ] && vbad="$vbad emitted-skills-copy:$sroot"
  grep -q 'caveat' <<<"$vout" || vbad="$vbad no-caveat"
  for g in $gated41; do
    grep -q "warning   $g is user-invocable-only" <<<"$vout" || vbad="$vbad unwarned:$g"
  done
  grep -q 'allowed-tools restrictions' <<<"$vout" || vbad="$vbad allowed-tools-loss-unstated"
  [ -z "$vbad" ] && ok "$rt: verify-not-emit — canonical copy verified, the only new files are its declared agent definitions, every gated skill warned" \
    || bad "$rt's verify run broke its contract" "$vbad"
done
vdiff="$(diff -r "$VD_P/.cursor" tests/emit/cursor/.cursor 2>&1)" \
  && ok "cursor's emitted tree matches tests/emit/cursor/ (agent definition + hooks.json, nothing else)" \
  || bad "cursor's emission diverged" "$(head -3 <<<"$vdiff")"
vdiff="$(diff -r "$VD_P/.devin" tests/emit/devin/.devin 2>&1)" \
  && ok "devin's emitted agent definition matches tests/emit/devin/" \
  || bad "devin's agent emission diverged" "$(head -3 <<<"$vdiff")"
# U3 gave cline and opencode emitted artifacts where they previously had none: opencode gets the
# throw-to-deny plugin wrapper (its documented plugin root), cline gets the enforcement table in
# its documented rules surface. Their fixture trees pin the bytes; .cline/ stays absent (cline's
# own skills root gets no copy — the canonical .claude/skills/ is what it reads).
vdiff="$(diff -r "$VD_P/.opencode" tests/emit/opencode/.opencode 2>&1)" \
  && ok "opencode's emitted plugin wrapper matches tests/emit/opencode/ (throw-to-deny, nothing else)" \
  || bad "opencode's plugin-wrapper emission diverged" "$(head -3 <<<"$vdiff")"
vdiff="$(diff -r "$VD_P/.clinerules" tests/emit/cline/.clinerules 2>&1)" \
  && ok "cline's emitted enforcement artifact matches tests/emit/cline/ (.clinerules copy)" \
  || bad "cline's .clinerules emission diverged" "$(head -3 <<<"$vdiff")"
[ ! -e "$VD_P/.cline" ] \
  && ok "cline's own skills root stays empty (no duplicate of the canonical copy)" \
  || bad "cline wrote files its adapter does not declare a home for"
cl_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime cline --root "$VD_P" 2>&1)"
grep -q 'not user-definable' <<<"$cl_out" \
  && ok "cline's report states the qc-reviewer loss: subagents are not user-definable there" \
  || bad "cline's agent-definition loss went unstated"
oc_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime opencode --root "$VD_P" 2>&1)"
grep -q 'no definition file path' <<<"$oc_out" \
  && ok "opencode's report states why no agent is emitted (definition path not established — never guessed)" \
  || bad "opencode's agent-definition refusal went unstated"
# A plugin-cache-only install is invisible to a foreign runtime — the verify must FAIL and say why.
PC_P="$E41/plugonly"; mkdir -p "$PC_P"
pc_err="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$PLUG_HOME" \
  python3 bin/emit_runtime.py --runtime cursor --root "$PC_P" 2>&1)"; pc_rc=$?
{ [ "$pc_rc" -ne 0 ] && grep -q 'plugin cache' <<<"$pc_err" && grep -q 'ticketwright init' <<<"$pc_err" \
  && [ -z "$(find "$PC_P" -type f)" ]; } \
  && ok "a plugin-cache-only install fails a foreign runtime's verify, naming the vendor fix, writing nothing" \
  || bad "the plugin-cache-only case was blessed, silent, or wrote files" "rc=$pc_rc"
# The duplicate scan: a same-named skill in another root this runtime reads is the stale-copy risk.
mkdir -p "$VD_P/.codex/skills/ticket"
printf -- '---\nname: ticket\ndescription: planted duplicate\n---\nbody\n' > "$VD_P/.codex/skills/ticket/SKILL.md"
dup_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime cursor --root "$VD_P" 2>&1)"
grep -q "duplicates the canonical skill 'ticket'" <<<"$dup_out" \
  && ok "the verify report names a same-named copy in another readable root (the stale-copy risk, caught while cheap)" \
  || bad "a duplicate skill copy in a foreign root went unnamed"

# --- --global: driven by global_skills_root, refusing on unknown ----------------------------------
GH="$E41/home"; GP="$E41/gproj"; mkdir -p "$GH" "$GP"
g_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" HOME="$GH" \
  python3 bin/emit_runtime.py --runtime codex-cli --global --root "$GP" 2>&1)"; g_rc=$?
{ [ "$g_rc" -eq 0 ] && [ -f "$GH/.agents/skills/ticket/SKILL.md" ] \
  && grep -q 'User-invocable only' "$GH/.agents/skills/ship/SKILL.md" \
  && [ ! -e "$GH/.codex" ] && grep -q 'project-scoped' <<<"$g_out" \
  && [ -z "$(find "$GP" -type f)" ]; } \
  && ok "--global emits skills into the declared global_skills_root under \$HOME (warnings intact; agents stay project-scoped, stated)" \
  || bad "--global emission into the declared root broke its contract" "rc=$g_rc"
ga_err="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" HOME="$GH" \
  python3 bin/emit_runtime.py --runtime antigravity --global --root "$GP" 2>&1)"; ga_rc=$?
{ [ "$ga_rc" -ne 0 ] && grep -q 'global_skills_root: unknown' <<<"$ga_err" && grep -q 'refused' <<<"$ga_err"; } \
  && ok "--global REFUSES where global_skills_root is unknown, with the explanation (never a guessed path)" \
  || bad "--global on an unknown global root did not refuse with the explanation" "rc=$ga_rc"
# Every verify runtime, not just one: --global must be the same deliberate, explained no-op on
# each, with $HOME left byte-untouched (the codex-cli emission above is the only thing in it).
(cd "$GH" && find . -type f | sort) > "$E41/home.before"
gv_bad=""
for rt in $verify_rts; do
  gv_out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" HOME="$GH" \
    python3 bin/emit_runtime.py --runtime "$rt" --global --root "$GP" 2>&1)"; gv_rc=$?
  { [ "$gv_rc" -eq 0 ] && grep -q 'stale-duplicate risk' <<<"$gv_out"; } || gv_bad="$gv_bad $rt(rc=$gv_rc)"
done
(cd "$GH" && find . -type f | sort) > "$E41/home.after"
diff -q "$E41/home.before" "$E41/home.after" >/dev/null 2>&1 || gv_bad="$gv_bad home-tree-changed"
[ -z "$gv_bad" ] && ok "--global on every verify runtime is a deliberate, explained no-op, \$HOME untouched (a global copy would shadow the canonical per-project one)" \
  || bad "--global on a verify runtime emitted something or went silent" "$gv_bad"

hdr "42 · /review degrades honestly without isolated subagents (PROMPT 7 / U4)"
# A skill is prose a model executes, so this evidence is STRUCTURAL: the capability probe, the three
# branches, the verdict-record fields and the weaker-check sentence are pinned here. That an agent
# actually FOLLOWS the branch is not offline-checkable — the live degraded run is parked on the U6
# punch list (one live /review --deep on a runtime without documented isolation).
RSK42=".claude/skills/review/SKILL.md"
QCA42=".claude/agents/qc-reviewer.md"

# --- the probe: capability KEYS through the kit CLI, launcher fallback intact --------------------
grep -qE 'CLAUDE_PLUGIN_ROOT.*bin/tw" kit_paths\.py --json' "$RSK42" \
  && ok "/review probes runtime capabilities via bin/tw kit_paths.py --json (fallback intact)" \
  || bad "/review lost the capability probe (kit_paths.py --json through the launcher)"
{ grep -q '`subagents`' "$RSK42" && grep -q '`subagent_isolation`' "$RSK42"; } \
  && ok "/review reads both capability keys (subagents + subagent_isolation)" \
  || bad "/review no longer names both capability keys it branches on"

# --- all three branches present, keyed off capability VALUE COMBINATIONS (not stray tokens) -----
# Each branch is asserted as its pairing — which values lead to which behavior — so a regression
# that keeps the words but breaks the wiring (documented no longer mapping to the independent
# mode, `none` dropping out of the inline branch) cannot stay green.
b42miss=""
grep -F -A3 'subagents: yes` and `subagent_isolation: documented' "$RSK42" \
  | grep -q 'review_mode: independent-subagent' \
  || b42miss="$b42miss documented+yes->independent-subagent"
grep -F -A3 'subagents: yes` and `subagent_isolation: unestablished' "$RSK42" \
  | grep -q 'fan out' \
  || b42miss="$b42miss unestablished+yes->still-fans-out"
inl42="$(grep -B8 -A4 'review_mode: inline-same-context' "$RSK42")"
{ grep -qF 'subagent_isolation: none' <<<"$inl42" && grep -q 'unknown' <<<"$inl42" \
  && grep -q 'fails outright' <<<"$inl42"; } \
  || b42miss="$b42miss none/unknown/failed-probe->inline"
[ -z "$b42miss" ] && ok "all three branches pair their capability values with the right behavior" \
  || bad "a degradation branch lost its capability-value pairing:" "$b42miss"
# The middle branch is honest WITHOUT refusing the stronger check, and records the posture verbatim.
{ grep -q 'the stronger check is not refused' "$RSK42" \
  && grep -B2 -A3 'subagent_isolation: unestablished' "$RSK42" | grep -qi 'verbatim'; } \
  && ok "unestablished isolation still fans out, posture recorded verbatim" \
  || bad "/review's unestablished branch lost its fan-out-but-say-so shape"
# The unknown case maps to the DEGRADED branch (never-optimistic), including a failed probe.
{ grep -B8 -A4 'review_mode: inline-same-context' "$RSK42" | grep -q 'unknown' \
  && grep -q 'treated as absent, never assumed' "$RSK42"; } \
  && ok "unknown capability (and a failed probe) maps to the inline branch, never-optimistically" \
  || bad "/review no longer maps unknown to the degraded branch"

# --- the weaker-check sentence, verbatim, one line, in BOTH the skill and the record template ----
wc42='A same-context review is not the independent second pass the validation pyramid assumes'
{ grep -qF "$wc42" "$RSK42" && grep -qF "$wc42" "$QCA42"; } \
  && ok "the weaker-check sentence is pinned verbatim in /review and qc-reviewer" \
  || bad "the weaker-check sentence drifted — an inline APPROVE would read as independent again"

# --- the verdict-record template carries the fields, and the inline claim is conditioned ---------
{ grep -qF 'review_mode: independent-subagent | inline-same-context' "$QCA42" \
  && grep -q '^subagent_isolation:' "$QCA42"; } \
  && ok "qc-reviewer's record template carries review_mode (both values) + subagent_isolation" \
  || bad "qc-reviewer's output template lost the review-mode verdict fields"
{ grep -q 'fresh-context claim above does NOT hold' "$QCA42" \
  && grep -q 'independence is NOT established' "$QCA42"; } \
  && ok "qc-reviewer conditions its fresh-context claim on the posture (inline AND unestablished)" \
  || bad "qc-reviewer asserts fresh context unconditionally — false inline, overclaimed on unestablished isolation"
grep -q 'Summary · review mode' "$RSK42" \
  && ok "/review's Phase N report inventory includes the review mode" \
  || bad "/review's verdict report no longer lists the review mode"

# --- no runtime name in the skill or the agent: the branch is DATA, the names live in adapters ---
# The forbidden list is DERIVED from adapters/runtime frontmatter (tool + aliases + spelling
# variants), so a future runtime is covered without editing this check. "claude" alone is excluded:
# .claude/ paths and CLAUDE_* env vars are kit structure, not a runtime name.
python3 - <<'PY' >"$TMP/hd4596.out"
import re, sys, pathlib
sys.path.insert(0, "bin")
from kit_paths import read_frontmatter
names = set()
for f in sorted(pathlib.Path("adapters/runtime").glob("*.md")):
    if f.name == "README.md":
        continue
    fm = read_frontmatter(f)
    if fm.get("seam") != "runtime" or not fm.get("tool"):
        continue
    for n in [fm["tool"]] + [a.strip() for a in fm.get("aliases", "").split(",") if a.strip()]:
        names.add(n.lower())
        names.add(n.lower().replace("-", " "))
        head = n.lower().split("-")[0]
        if head and head != "claude":
            names.add(head)
leaks = []
targets = sorted(pathlib.Path(".claude/skills/review").rglob("*.md"))
targets.append(pathlib.Path(".claude/agents/qc-reviewer.md"))
for path in targets:
    for no, line in enumerate(path.read_text(encoding="utf-8").lower().splitlines(), 1):
        for n in sorted(names):
            if re.search(r"(?<![a-z0-9_])" + re.escape(n) + r"(?![a-z0-9_])", line):
                leaks.append(f"{path}:{no}: {n}")
print("\n".join(sorted(set(leaks))))
PY
rt42="$(cat "$TMP/hd4596.out")"
[ -z "$rt42" ] && ok "no runtime name appears in /review or qc-reviewer (list derived from adapter data)" \
  || bad "a runtime name leaked into the review path — the branch must key off capability values" "$rt42"

# --- the data path the skill relies on: an unrecognized runtime floors into the degraded branch --
cli42="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR TICKETWRIGHT_RUNTIME=fixture-unrecognized \
        python3 bin/kit_paths.py --json 2>/dev/null)"
python3 - "$cli42" <<'PY'
import json, sys
c = json.loads(sys.argv[1] or "{}").get("capabilities", {})
sys.exit(0 if c.get("subagents") == "no" and c.get("subagent_isolation") == "unknown" else 1)
PY
[ $? -eq 0 ] && ok "an unrecognized runtime probes to the degraded pair (subagents=no, isolation=unknown)" \
  || bad "the unknown-runtime floor no longer lands the probe in the degraded branch" "$cli42"

hdr "43 · hook degradation: sql_scan extraction, guard shims, the enforcement table (PROMPT 7 / U3)"
# The riskiest boundary in the kit: the DB-write guard's scanner moved to bin/sql_scan.py and the
# Claude hook became its presenter. What this section pins, in order: (1) the Claude protocol is
# byte-identical across that move (golden corpus, generated from the pre-extraction hook) and the
# scanner CLI agrees with the hook's decisions on the same corpus; (2) a BROKEN scanner gates MORE,
# never less — the one deliberate new failure mode; (3) each runtime shim speaks its exact
# documented schema, malformed input follows each runtime's DECLARED decision (never silent-allow
# where fail-closed is configured), and the devin/opencode path can exit ONLY 0 or a deliberate 2;
# (4) the one-shot escape round-trips offline; (5) the emitted wiring artifacts (failClosed: true
# on cursor, both events on antigravity, the throw-to-deny wrapper on opencode) and the install
# report's collapse statements; (6) the enforcement table in RENDERED output with no empty cell;
# (7) the Claude wiring is untouched. Live runtime honoring is deliberately NOT asserted anywhere
# here — that is the U6 punch list.

# --- (1) behavior identity across the extraction ---------------------------------------------------
python3 tests/guard/run_corpus.py --agreement >/dev/null 2>"$TMP/corpus.err" \
  && ok "the Claude hook reproduces tests/guard/golden.json byte-for-byte, and bin/sql_scan.py's verdicts agree on the same corpus" \
  || bad "the guard's Claude protocol drifted across the sql_scan extraction" "$(head -5 "$TMP/corpus.err")"

# --- (2) a broken scanner gates MORE, never less ----------------------------------------------------
BK="$TMP/broken-scan"; mkdir -p "$BK/kit" "$BK/proj/.claude/config"
cp -R bin .claude adapters templates "$BK/kit/" 2>/dev/null   # a real kit shape, so resolve_kit lands HERE
printf 'gitdir: fixture\n' > "$BK/proj/.git"
printf 'seams:\n  warehouse:\n    tool: snowflake\n    cli: snow\npolicies:\n  db_write_requires_approval: high_risk\n' \
  > "$BK/proj/.claude/config/stack.yaml"
bkguard() {  # bkguard <command> [mode] — run the sabotaged kit's hook against the fixture repo
  python3 -c 'import json,sys
p={"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}
if len(sys.argv)>3: p["permission_mode"]=sys.argv[3]
print(json.dumps(p))' "$1" "$BK/proj" ${2:+"$2"} \
    | env -u CLAUDE_PROJECT_DIR python3 "$BK/kit/.claude/hooks/db_write_guard.py" 2>/dev/null
}
rm "$BK/kit/bin/sql_scan.py"
o="$(bkguard 'snow sql -q "DROP TABLE t"')"; r1=$?
grep -q '"permissionDecision": "ask"' <<<"$o" && grep -q 'sql_scan' <<<"$o" && [ "$r1" -eq 0 ] \
  && ok "scanner DELETED: a destructive command still asks, names the broken module, exits 0" \
  || bad "a deleted scanner weakened or crashed the Claude guard" "rc=$r1 $o"
o="$(bkguard 'ls -la')"
grep -q '"permissionDecision": "ask"' <<<"$o" \
  && ok "scanner deleted: EVERY command in the configured repo is gated (nothing can be classified — more, never less)" \
  || bad "a deleted scanner let an unclassifiable command through silently" "$o"
o="$(bkguard 'snow sql -q "DROP TABLE t"' bypassPermissions)"
grep -q 'systemMessage' <<<"$o" && ! grep -q 'permissionDecision' <<<"$o" \
  && ok "scanner deleted + bypassPermissions: visible systemMessage, no prompt (the mode contract holds)" \
  || bad "the broken-scanner path ignored bypassPermissions" "$o"
printf 'seams:\n  warehouse:\n    cli: snow\npolicies:\n  db_write_requires_approval: off\n' \
  > "$BK/proj/.claude/config/stack.yaml"
o="$(bkguard 'snow sql -q "DROP TABLE t"')"
[ -z "$o" ] && ok "scanner deleted + policy off: silent (an explicit operator instruction, readable without the scanner)" \
  || bad "policy off stopped silencing the broken-scanner path" "$o"
printf 'seams:\n  warehouse:\n    cli: snow\npolicies:\n  db_write_requires_approval: high_risk\n' \
  > "$BK/proj/.claude/config/stack.yaml"
printf 'def broken(\n' > "$BK/kit/bin/sql_scan.py"   # syntax error: import fails, file present
o="$(bkguard 'snow sql -q "SELECT 1"')"
grep -q '"permissionDecision": "ask"' <<<"$o" \
  && ok "scanner CORRUPTED (syntax error): still asks — any import failure maps to gating more" \
  || bad "a corrupt scanner fell into the blanket fail-open handler" "$o"
echo 'not json' | env -u CLAUDE_PROJECT_DIR python3 "$BK/kit/.claude/hooks/db_write_guard.py" >/dev/null 2>&1 \
  && ok "scanner corrupted: malformed stdin still exits 0 silently (the Claude protocol contract survives the fault)" \
  || bad "malformed stdin exited nonzero with a broken scanner (would BLOCK the call)"
# A scanner that imports fine but CRASHES while classifying must gate too — without the local
# boundary around assess(), this landed in main()'s blanket fail-open handler (gate-2 finding).
printf 'def assess(*a, **k):\n    raise RuntimeError("selftest: scanner runtime fault")\n' \
  > "$BK/kit/bin/sql_scan.py"
o="$(bkguard 'snow sql -q "DROP TABLE t"')"; r=$?
grep -q '"permissionDecision": "ask"' <<<"$o" && grep -q 'failed while classifying' <<<"$o" && [ "$r" -eq 0 ] \
  && ok "scanner CRASHES at classify time: still asks, names the fault, exits 0 (never the blanket fail-open)" \
  || bad "a crashing scanner fell through to fail-open on Claude" "rc=$r $o"
o="$(bkguard 'snow sql -q "DROP TABLE t"' bypassPermissions)"
grep -q 'systemMessage' <<<"$o" \
  && ok "scanner crashes + bypassPermissions: visible systemMessage, no prompt" \
  || bad "the crash path ignored bypassPermissions" "$o"
# A scanner that RETURNS GARBAGE is the same fault as one that raises: the fail-safe boundary must
# cover the verdict's consumption, not just the call (adversarial-review P2-1 — decision["kind"] /
# ["detail"] reads outside the try landed a KeyError in the blanket handler: a SILENT ALLOW).
printf 'def assess(*a, **k):\n    return {}\n' > "$BK/kit/bin/sql_scan.py"
o="$(bkguard 'snow sql -q "DROP TABLE t"')"; r=$?
grep -q '"permissionDecision": "ask"' <<<"$o" && grep -q 'failed while classifying' <<<"$o" && [ "$r" -eq 0 ] \
  && ok "scanner returns an EMPTY verdict: still asks, names the fault, exits 0 (consumption is inside the boundary)" \
  || bad "an empty scanner verdict fell through to a silent allow" "rc=$r $o"
printf 'def assess(*a, **k):\n    return {"kind": "gate"}\n' > "$BK/kit/bin/sql_scan.py"
o="$(bkguard 'snow sql -q "DROP TABLE t"')"; r=$?
grep -q '"permissionDecision": "ask"' <<<"$o" && [ "$r" -eq 0 ] \
  && ok "scanner returns a gate verdict with NO detail: still asks (a malformed field never reaches the blanket handler)" \
  || bad "a field-less gate verdict fell through to a silent allow" "rc=$r $o"

# --- (3) the shims: exact schemas, per-runtime malformed decisions, exit-code discipline ------------
SH="$TMP/shimrepo"; mkdir -p "$SH/.claude/config"
printf 'gitdir: fixture\n' > "$SH/.git"
shstack() { printf 'seams:\n  warehouse:\n    tool: snowflake\n    cli: snow\npolicies:\n  db_write_requires_approval: %s\n' "$1" > "$SH/.claude/config/stack.yaml"; }
shpay() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$SH"; }
shim() { env -u CLAUDE_PROJECT_DIR python3 bin/hook_shim.py "$@"; }
shstack high_risk
o="$(shpay 'snow sql -q "DROP TABLE t"' | shim --runtime codex-cli --hook db_write_guard)"; r=$?
python3 -c '
import json,sys
d=json.loads(sys.argv[1])["hookSpecificOutput"]
assert d["hookEventName"]=="PreToolUse" and d["permissionDecision"]=="deny", d
assert "TICKETWRIGHT_APPROVE=once" in d["permissionDecisionReason"], d
' "$o" 2>/dev/null && [ "$r" -eq 0 ] \
  && ok "codex-cli: destructive SQL → permissionDecision deny in the exact documented schema, escape named, exit 0" \
  || bad "the codex-cli deny schema is wrong" "rc=$r $o"
o="$(shpay 'snow sql -q "CREATE TABLE t (a int)"' | shim --runtime codex-cli --hook db_write_guard)"; r=$?
{ [ -z "$o" ] && [ "$r" -eq 0 ]; } \
  && ok "codex-cli: additive SQL passes untouched under high_risk (the collapse never blocks additive work)" \
  || bad "additive SQL was gated on a deny-only runtime" "rc=$r $o"
o="$(echo 'not json' | shim --runtime codex-cli --hook db_write_guard --root "$SH")"; r=$?
grep -q '"permissionDecision": "deny"' <<<"$o" && [ "$r" -eq 0 ] \
  && ok "codex-cli: malformed stdin DENIES with the escape message (never a silent allow)" \
  || bad "malformed stdin did not deny on codex-cli" "rc=$r $o"
o="$(shpay 'snow sql -q "DROP TABLE t"' | shim --runtime cursor --hook db_write_guard)"; r=$?
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["permission"])' "$o" 2>/dev/null)" = "ask" ] && [ "$r" -eq 0 ] \
  && ok "cursor: destructive SQL → {\"permission\": \"ask\"} (the ask tier exists here — no collapse)" \
  || bad "the cursor ask schema is wrong" "rc=$r $o"
o="$(echo '{broken' | shim --runtime cursor --hook db_write_guard --root "$SH")"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["permission"])' "$o" 2>/dev/null)" = "ask" ] \
  && ok "cursor: malformed stdin ESCALATES to ask (failClosed wiring must never be reopened by a swallowed parse error)" \
  || bad "malformed stdin did not escalate on cursor" "$o"
o="$(shpay 'snow sql -q "DROP TABLE t"' | shim --runtime antigravity --hook db_write_guard)"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["decision"])' "$o" 2>/dev/null)" = "ask" ] \
  && ok "antigravity: destructive SQL under high_risk → decision ask" \
  || bad "the antigravity ask schema is wrong" "$o"
o="$(echo '[not,an,object' | shim --runtime antigravity --hook db_write_guard --root "$SH")"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["decision"])' "$o" 2>/dev/null)" = "ask" ] \
  && ok "antigravity: malformed stdin ESCALATES to ask (its declared decision — never a silent allow)" \
  || bad "malformed stdin did not escalate on antigravity" "$o"
shstack all
o="$(shpay 'snow sql -q "INSERT INTO t VALUES (1)"' | shim --runtime antigravity --hook db_write_guard)"
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["decision"])' "$o" 2>/dev/null)" = "force_ask" ] \
  && ok "antigravity: policy all → force_ask (ignores cached grants — the primitive the research earmarked for it)" \
  || bad "policy all did not map to force_ask on antigravity" "$o"
shstack high_risk
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1
[ $? -eq 2 ] && ok "devin: destructive SQL → exit 2 (the only documented block)" || bad "devin destructive did not exit 2"
shpay 'snow sql -q "SELECT 1"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "devin: read-only SQL → exit 0" || bad "devin read-only did not exit 0"
echo 'garbage' | shim --runtime devin --hook db_write_guard --root "$SH" >/dev/null 2>&1
[ $? -eq 2 ] && ok "devin: malformed stdin → exit 2 (denies, never a stray code)" || bad "devin malformed stdin exit was not 2"
shpay 'snow sql -q "SELECT 1"' | env -u CLAUDE_PROJECT_DIR TICKETWRIGHT_SHIM_FAULT=raise \
  python3 bin/hook_shim.py --runtime devin --hook db_write_guard >/dev/null 2>&1
[ $? -eq 2 ] && ok "devin: an injected INTERNAL error → deliberate exit 2 (any other nonzero is logged-and-ignored by documented design)" \
  || bad "an internal shim error escaped as something other than exit 2 on devin"
( cd "$BK/kit" && shpay 'snow sql -q "SELECT 1"' | env -u CLAUDE_PROJECT_DIR \
    python3 bin/hook_shim.py --runtime devin --hook db_write_guard >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "devin: a BROKEN sql_scan in the kit → deliberate exit 2 (the import fault cannot fail open)" \
  || bad "a broken scanner produced a non-2 exit on devin"
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime windsurf --hook db_write_guard >/dev/null 2>&1
[ $? -eq 2 ] && ok "the windsurf alias resolves to devin's exit-code protocol" || bad "the windsurf alias broke in the shim"
# opencode speaks the same exit-code protocol THROUGH the emitted wrapper — the wrapper itself is
# static-asserted against its fixture (executing it would need a JS runtime the suite cannot
# assume); the shim side it shells to is exercised here.
oc_msg="$(shpay 'snow sql -q "DROP TABLE t"' | shim --runtime opencode --hook db_write_guard 2>/dev/null)"; r=$?
{ [ "$r" -eq 2 ] && grep -q 'TICKETWRIGHT_APPROVE=once' <<<"$oc_msg"; } \
  && ok "opencode: destructive SQL → exit 2 with the escape message on stdout (what the wrapper throws)" \
  || bad "the opencode shim path lost its deny or escape message" "rc=$r"
shpay 'snow sql -q "INSERT INTO t VALUES (1)"' | shim --runtime opencode --hook db_write_guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "opencode: additive SQL passes under high_risk" || bad "opencode gated additive SQL"
echo '}{' | shim --runtime opencode --hook db_write_guard --root "$SH" >/dev/null 2>&1
[ $? -eq 2 ] && ok "opencode: malformed stdin → exit 2 (denies — the wrapper turns it into a thrown error)" \
  || bad "opencode malformed stdin did not deny"
printf '{"tool_name":"Read","tool_input":{"file_path":"x"},"cwd":"%s"}' "$SH" | shim --runtime devin --hook db_write_guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "a recognizably non-shell tool call passes: the guard's jurisdiction is shell commands" \
  || bad "a non-shell tool call was gated by the shim"
o="$(printf '{"tool_name":"Bash","tool_input":{},"cwd":"%s"}' "$SH" | shim --runtime devin --hook db_write_guard 2>&1)"; r=$?
[ "$r" -eq 2 ] && ok "a shell-like tool with NO extractable command is unreadable input → denied, not guessed" \
  || bad "an extractionless shell payload passed" "rc=$r"
rm -f "$SH/.claude/config/stack.yaml"
echo 'not json' | shim --runtime devin --hook db_write_guard --root "$SH" >/dev/null 2>&1
[ $? -eq 0 ] && ok "no stack.yaml → the shim is silent (repo-gated, like the Claude hook — a de-configured repo must not brick)" \
  || bad "the shim gated outside a configured repo"
shstack off
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime codex-cli --hook db_write_guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "policy off → the shim passes even destructive SQL (an explicit operator instruction)" \
  || bad "policy off did not silence the shim"
echo '{}' | shim --runtime claude-code --hook db_write_guard >/dev/null 2>&1
[ $? -eq 2 ] && ok "the shim REFUSES --runtime claude-code (the native hook's failure mode is not to be re-plumbed)" \
  || bad "the shim accepted claude-code"
echo '{}' | shim --runtime cline --hook db_write_guard >/dev/null 2>&1
[ $? -eq 2 ] && ok "the shim REFUSES cline (hook_protocol: unknown — no documented schema to speak)" \
  || bad "the shim spoke an undocumented protocol for cline"

# --- (4) the one-shot escape round-trips offline ----------------------------------------------------
shstack high_risk
shpay 'TICKETWRIGHT_APPROVE=once snow sql -q "DROP TABLE t"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1
[ $? -eq 0 ] && ok "escape: the TICKETWRIGHT_APPROVE=once command prefix approves exactly that command (visible in the transcript)" \
  || bad "the command-prefix escape did not approve"
TOK="$SH/.claude/config/approve.once"; touch "$TOK"
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1; r1=$?
tok_after=$([ -f "$TOK" ] && echo present || echo consumed)
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1; r2=$?
{ [ "$r1" -eq 0 ] && [ "$tok_after" = "consumed" ] && [ "$r2" -eq 2 ]; } \
  && ok "escape: the token approves exactly once — consumed on use, and the very next statement is denied again" \
  || bad "the approval token did not round-trip (allowed=$r1 token=$tok_after second=$r2)"
touch "$TOK"; python3 -c "import os,time,sys; p=sys.argv[1]; os.utime(p,(time.time()-3600,)*2)" "$TOK"
shpay 'snow sql -q "DROP TABLE t"' | shim --runtime devin --hook db_write_guard >/dev/null 2>&1; r=$?
{ [ "$r" -eq 2 ] && [ -f "$TOK" ]; } \
  && ok "escape: a STALE token (>15 min) is ignored — an abandoned approval never covers a later statement" \
  || bad "a stale token approved a destructive statement" "rc=$r"
rm -f "$TOK"

# --- (5) emitted wiring artifacts + the install report's collapse statements -----------------------
E43="$TMP/e43"; mkdir -p "$E43/adapters" "$E43/templates" "$E43/bin" "$E43/.claude"
cp bin/kit_paths.py "$E43/bin/"; cp -R .claude/skills "$E43/.claude/skills"
# The emitted PreToolUse wiring is `--hook shell_guards` — ONE entry covering both shell guards
# (db_write + source_material). It is deliberately not two array entries: whether a runtime
# executes every element of a hook array is undocumented, and a WIRED cell resting on that
# assumption would be an overclaim (see the enforcement table's vocabulary).
grep -q '"failClosed": true' tests/emit/cursor/.cursor/hooks.json \
  && grep -q 'hook_shim.py --runtime cursor --hook shell_guards' tests/emit/cursor/.cursor/hooks.json \
  && ok "the emitted cursor hook config contains \"failClosed\": true wired to the guard shim (required configuration, set by the installer)" \
  || bad "the cursor hooks.json lost failClosed or the shim command"
[ "$(grep -c 'beforeShellExecution' tests/emit/cursor/.cursor/hooks.json)" -eq 1 ] \
  && [ "$(grep -c '\-\-hook' tests/emit/cursor/.cursor/hooks.json)" -eq 1 ] \
  && ok "cursor's shell wiring is ONE entry (no dependence on array-execution order)" \
  || bad "cursor's hooks.json emits more than one shell hook entry"
grep -q '"PreToolUse"' tests/emit/antigravity/.agents/hooks.json \
  && grep -q 'shell_guards' tests/emit/antigravity/.agents/hooks.json \
  && [ "$(grep -c 'PreToolUse' tests/emit/antigravity/.agents/hooks.json)" -eq 1 ] \
  && grep -q '"PostToolUse"' tests/emit/antigravity/.agents/hooks.json \
  && grep -q 'regenerate_ticket_index' tests/emit/antigravity/.agents/hooks.json \
  && ok "the emitted antigravity hooks.json wires PreToolUse (guard) and PostToolUse (index regen) — its five-event surface, used where it maps" \
  || bad "the antigravity hooks.json lost an event"
grep -q 'tool.execute.before' tests/emit/opencode/.opencode/plugins/ticketwright-db-write-guard.js \
  && grep -q 'throw new Error' tests/emit/opencode/.opencode/plugins/ticketwright-db-write-guard.js \
  && grep -q 'emitted by ticketwright install v' tests/emit/opencode/.opencode/plugins/ticketwright-db-write-guard.js \
  && ok "the emitted opencode wrapper throws to deny from tool.execute.before and carries provenance" \
  || bad "the opencode plugin wrapper lost its deny path or provenance"
# provenance-aware collision handling extends to hook configs: ours refresh, foreign fail loudly
FC="$TMP/hookforeign"; mkdir -p "$FC/adapters" "$FC/templates" "$FC/bin" "$FC/.claude" "$FC/.cursor"
cp bin/kit_paths.py "$FC/bin/"; cp -R .claude/skills "$FC/.claude/skills"
printf '{"hooks": {"beforeShellExecution": []}}\n' > "$FC/.cursor/hooks.json"
fo="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime cursor --root "$FC" 2>&1)"; fr=$?
{ [ "$fr" -ne 0 ] && grep -q '"beforeShellExecution": \[\]' "$FC/.cursor/hooks.json" && grep -q 'not deleted' <<<"$fo"; } \
  && ok "a hand-written .cursor/hooks.json is never clobbered — the install fails loudly (provenance-aware, like every emitted artifact)" \
  || bad "a foreign hooks.json was overwritten or tolerated silently" "rc=$fr"
co="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime codex-cli --root "$E43" 2>&1)"
grep -q 'DENY-WITH-ESCAPE' <<<"$co" && grep -q 'NEVER collapses toward allow' <<<"$co" \
  && grep -q 'trusted BY HASH' <<<"$co" && grep -q 'not in the kit'"'"'s research' <<<"$co" \
  && ok "codex-cli install: the high_risk collapse is surfaced at install time, with trusted-by-hash and the unresearched-config-location gap stated" \
  || bad "the codex-cli install report buried a safety statement" "$(grep -E 'policy|hooks|caveat' <<<"$co" | head -4)"
do_="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime devin --root "$E43" 2>&1)"
grep -q 'DENY-WITH-ESCAPE' <<<"$do_" && grep -q 'fails open BY DOCUMENTED DESIGN' <<<"$do_" \
  && ok "devin install: deny-with-escape + the documented fail-open are stated on stdout" \
  || bad "the devin install report is missing its safety statements"
mkdir -p "$TMP/e43-agy"
ao="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime antigravity --root "$TMP/e43-agy" 2>&1)"
grep -q 'expressed as `ask`' <<<"$ao" && grep -q 'FAILING hook does here is undocumented' <<<"$ao" \
  && ok "antigravity install: high_risk-as-ask stated, hook-failure mode stated as UNKNOWN (never assumed)" \
  || bad "the antigravity install report is missing its statements"
lo="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR="$EMIT_NOCLAUDE" \
  python3 bin/emit_runtime.py --runtime cline --root "$E43" 2>&1)"
grep -q 'degrades to GUIDANCE' <<<"$lo" && grep -q 'model-judged' <<<"$lo" \
  && ok "cline install: guidance-only degradation stated (hooks unverified upstream, model-judged approvals)" \
  || bad "the cline install report is missing its degradation statement"
# the deny-with-escape set is exactly the gate_ask_tier:no set — data drives the collapse, per runtime
denyset="$(python3 -c "
import sys, pathlib
sys.path.insert(0, 'bin')
from kit_paths import read_frontmatter
for f in sorted(pathlib.Path('adapters/runtime').glob('*.md')):
    if f.name != 'README.md' and read_frontmatter(f).get('gate_ask_tier') == 'no':
        print(read_frontmatter(f)['tool'])
" | tr '\n' ',' )"
[ "$denyset" = "codex-cli,devin,opencode," ] \
  && ok "the deny-with-escape set is exactly the gate_ask_tier=no runtimes (codex-cli, devin, opencode) — the collapse is adapter data, not a hardcoded list" \
  || bad "the deny-with-escape set drifted from the 3b axis" "$denyset"

# --- (6) the enforcement table: rendered output, no empty cells, the false sentence gone -----------
bash bin/render.sh templates/AGENTS.md.tmpl --vars "$TMP/vars.env" > "$TMP/agents-rendered.md" 2>/dev/null
grep -q 'For every other agent it is guidance, not enforcement' "$TMP/agents-rendered.md" \
  && bad "the retired blanket guidance sentence survives in the rendered AGENTS.md (false once U3 landed)" \
  || ok "the false 'every other agent is guidance' sentence is gone from the rendered AGENTS.md"
python3 - "$TMP/agents-rendered.md" <<'PY' >"$TMP/hd4914.out"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- ticketwright:enforcement:begin -->(.*?)<!-- ticketwright:enforcement:end -->",
              text, re.S)
if not m:
    print("no enforcement markers in the rendered output"); raise SystemExit
block = m.group(1)
rows = {}
for line in block.splitlines():
    if line.startswith("| ") and not line.startswith("|--") and "Runtime" not in line:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows[cells[0]] = cells[1:]
WANT = ["Claude Code", "Codex CLI", "Cursor", "Antigravity", "OpenCode", "Devin", "Cline"]
bad = [f"missing row: {r}" for r in WANT if r not in rows]
for name in WANT:
    cells = rows.get(name, [])
    if len(cells) != 6:
        bad.append(f"{name}: {len(cells)} cells, want 6 (5 hooks + malformed-input)")
        continue
    for i, c in enumerate(cells[:5]):
        if not c:
            bad.append(f"{name}: empty hook cell {i}")
        elif not re.match(r"^(ENFORCEMENT|WIRED|GUIDANCE|UNKNOWN)\b", c):
            bad.append(f"{name}: hook cell {i} outside the closed vocabulary: {c[:40]!r}")
    if not cells[5]:
        bad.append(f"{name}: empty malformed-input cell")
# the malformed-input column must carry each runtime's DECLARED decision
for name, frag in [("Codex CLI", "denies"), ("OpenCode", "denies"), ("Devin", "denies"),
                   ("Cursor", "ask"), ("Antigravity", "ask"), ("Cline", "UNKNOWN")]:
    if name in rows and frag not in rows[name][5]:
        bad.append(f"{name}: malformed-input cell does not state '{frag}'")
# ENFORCEMENT is reserved for mechanisms proven in THIS repo's test contract (Claude Code);
# an emitted-but-live-unverified mechanism is WIRED, and a live confirmation on the punch list
# is what promotes it (adversarial-review ruling). Sharing Claude's word would imply a parity
# tiebreaker 6 forbids.
for name in WANT:
    if name != "Claude Code":
        for i, c in enumerate(rows.get(name, [])[:5]):
            if c.startswith("ENFORCEMENT"):
                bad.append(f"{name}: cell {i} claims ENFORCEMENT — only a live confirmation may promote WIRED")
if "Claude Code" in rows and not all(c.startswith("ENFORCEMENT") for c in rows["Claude Code"][:5]):
    bad.append("Claude Code: all five hook cells must be ENFORCEMENT (the proven native wiring)")
for name, wired in [("Cursor", ".cursor/hooks.json"), ("Antigravity", ".agents/hooks.json"),
                    ("OpenCode", ".opencode/plugins/")]:
    if name in rows and (not rows[name][0].startswith("WIRED") or wired not in rows[name][0]):
        bad.append(f"{name}: guard cell must be WIRED naming {wired}")
if "Antigravity" in rows and not rows["Antigravity"][4].startswith("WIRED"):
    bad.append("Antigravity: the regenerate cell must be WIRED (emitted PostToolUse entry)")
# The source-material guard column follows the SAME wired/unwired sets as the db-write guard:
# both are PreToolUse shell guards, so a runtime that wires one and not the other ships a gate
# with a hole in it while the table reads as protection.
for name, level in [("Cursor", "WIRED"), ("Antigravity", "WIRED"), ("OpenCode", "WIRED"),
                    ("Codex CLI", "GUIDANCE"), ("Devin", "GUIDANCE")]:
    if name in rows and not rows[name][1].startswith(level):
        bad.append(f"{name}: the source_material_guard cell must be {level} — a runtime that "
                   f"wires one shell guard and not the other has a gate with a hole in it")
for name in ["Codex CLI", "Devin"]:
    if name in rows and not rows[name][0].startswith("GUIDANCE"):
        bad.append(f"{name}: guard cell must be GUIDANCE (config location unresearched — never claim wiring that does not exist)")
if "Cline" in rows and not all(c.startswith("UNKNOWN") for c in rows["Cline"][:5]):
    bad.append("Cline: all five hook cells must be UNKNOWN (the stated case)")
if "**WIRED**" not in block:
    bad.append("the legend does not define WIRED")
print("\n".join(bad))
PY
tbl_bad="$(cat "$TMP/hd4914.out")"
[ -z "$tbl_bad" ] && ok "the rendered enforcement table: 7 runtimes x (5 hooks + malformed-input), closed vocabulary, no empty cell, wired/unwired sets pinned" \
  || bad "the enforcement table broke its contract" "$tbl_bad"
for frag in 'trusted by hash' 'failClosed: true' 'fails open by documented design' 'deny-with-escape' 'model-judged'; do
  grep -q "$frag" "$TMP/agents-rendered.md" || bad "the rendered AGENTS.md lost the caveat: $frag"
done
ok "the per-runtime caveats survive in RENDERED output (trusted-by-hash, failClosed, documented fail-open, deny-with-escape, model-judged)"
grep -q '| Cline | UNKNOWN' tests/emit/cline/.clinerules/ticketwright-enforcement.md \
  && grep -q '| Cursor | WIRED' tests/emit/cline/.clinerules/ticketwright-enforcement.md \
  && ok "the .clinerules artifact carries the same table rows (one authoring point in the template, extracted at emit time)" \
  || bad "the .clinerules enforcement copy lost the table"

# --- (7) the Claude wiring is untouched -------------------------------------------------------------
grep -q 'db_write_guard.py' .claude-plugin/plugin.json && grep -q 'db_write_guard.py' .claude/settings.json.tmpl \
  && ! grep -q 'hook_shim' .claude-plugin/plugin.json && ! grep -q 'hook_shim' .claude/settings.json.tmpl \
  && ok "Claude Code still runs the native hook directly — nothing routes it through the shim (plugin.json + settings template)" \
  || bad "the Claude hook wiring changed (plugin.json / settings.json.tmpl)"
grep -q 'sql_scan' bin/effective_config.py 2>/dev/null \
  && bad "the resolver grew a dependency on the scanner (the two must stay decoupled)" \
  || ok "bin/effective_config.py and bin/sql_scan.py stay decoupled (the policy exemption is intact)"
hp_bad="$(python3 -c "
import sys, pathlib
sys.path.insert(0, 'bin')
from kit_paths import read_frontmatter
PIN = {'claude-code': ('native', 'claude-json'), 'codex-cli': ('unknown', 'codex-json'),
       'cursor': ('.cursor/hooks.json', 'cursor-json'), 'antigravity': ('.agents/hooks.json', 'agy-json'),
       'devin': ('unknown', 'exit-code'),
       'opencode': ('.opencode/plugins/ticketwright-db-write-guard.js', 'exit-code'),
       'cline': ('unknown', 'unknown')}
bad = []
for tool, (wiring, proto) in PIN.items():
    fm = read_frontmatter(pathlib.Path(f'adapters/runtime/{tool}.md'))
    if fm.get('hook_wiring') != wiring or fm.get('hook_protocol') != proto:
        bad.append(f\"{tool}: {fm.get('hook_wiring')}/{fm.get('hook_protocol')} want {wiring}/{proto}\")
    if tool != 'claude-code' and not fm.get('hook_wiring_caveat'):
        bad.append(f'{tool}: no hook_wiring_caveat to print')
print('; '.join(bad))
")"
[ -z "$hp_bad" ] && ok "pinned: hook_wiring + hook_protocol per runtime (a drive-by edit here re-routes a safety gate)" \
  || bad "a hook wiring/protocol declaration drifted" "$hp_bad"

hdr "44 · the live-verification honesty linkage (PROMPT 7 / U6)"
# docs/live-verification.md is the parked live-runtime work, written down — one entry per claim
# only a live external runtime can prove. This section makes the honesty link MECHANICAL: every
# unknown/unverified value in adapters/runtime/*.md frontmatter, every WIRED cell in the
# enforcement table, every emitted artifact carrying an "unverified" label, and every
# "(unverified)" metadata-mapping row must be claimed on some entry's Covers: line — a future
# unverified claim without a tracked way to verify it turns this section red. Tokens are read
# from Covers: lines ONLY, never from prose, so an example cannot satisfy the link. Deliberately
# ABSENT here: any assertion that a punch-list item "passed" — the list records that verification
# is OWED, and only a human with the runtime can pay it (U6's evidence-of-done states this rule).
# The one forward-looking check: a non-Claude ENFORCEMENT cell (none exist today — section 43
# forbids them) must carry a PROMOTED ledger line, so a promotion can never be a template edit
# alone.

LV="docs/live-verification.md"
[ -s "$LV" ] && ok "docs/live-verification.md exists (the punch list the enforcement table cites)" \
  || bad "docs/live-verification.md missing — U3's enforcement table cites a punch list that does not resolve"
for sec in "## Recording a result" "promotion protocol" "## The entries" "## Promotion ledger"; do
  grep -q "$sec" "$LV" 2>/dev/null && ok "punch list carries: $sec" \
    || bad "punch list lost its section: $sec"
done
# The rendered AGENTS.md lands in user repos and docs/ does not ship in the wheel, so the legend
# must point at the punch list by GitHub URL (same precedent as the obsidian.md pointer).
grep -q 'github.com/kyle-chalmers/ticketwright/blob/main/docs/live-verification.md' templates/AGENTS.md.tmpl \
  && ok "the enforcement-table legend links the punch list by GitHub URL (docs/ does not ship in the wheel)" \
  || bad "the enforcement-table legend lost its punch-list URL"
grep -q 'docs/live-verification.md' docs/runtimes.md \
  && ok "docs/runtimes.md names the punch list" \
  || bad "docs/runtimes.md lost its punch-list reference"

python3 - <<'PY' >"$TMP/hd5051.out"
import os, pathlib, re, sys, tempfile
sys.path.insert(0, 'bin')
from kit_paths import read_frontmatter

doc_lines = pathlib.Path('docs/live-verification.md').read_text(encoding='utf-8').splitlines()
bad = []

# Covers: blocks only (from "Covers:" to the next blank line) — prose mentions never count.
covers_lines, i = [], 0
while i < len(doc_lines):
    if doc_lines[i].startswith('Covers:'):
        while i < len(doc_lines) and doc_lines[i].strip():
            covers_lines.append(doc_lines[i]); i += 1
    else:
        i += 1
covers_text = '\n'.join(covers_lines)
# Exact backticked claims, not substrings: `codex-cli.hook` must never ride on the existing
# `codex-cli.hook_wiring` token (gate-2 finding — a substring match is a false negative in
# exactly the future-unknown direction this section exists to catch).
claims = set(re.findall(r'`([^`]+)`', covers_text))
if not covers_lines:
    bad.append('no Covers: lines found — the punch list lost its entry structure')
ledger = [l.strip() for l in doc_lines if l.strip().startswith('PROMOTED ')]

def need(token, why):
    if token not in claims:
        bad.append(f'{why} — no Covers: line claims `{token}` (exact backticked token required)')

# reader canary: the unknown scan is blind if read_frontmatter stops stripping inline comments
with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as tf:
    tf.write('---\nseam: runtime\ntool: probe\nprobe_axis: unknown  # inline comment\n---\nbody\n')
canary = read_frontmatter(pathlib.Path(tf.name)).get('probe_axis')
os.unlink(tf.name)
if canary != 'unknown':
    bad.append(f'reader canary: read_frontmatter returned {canary!r} for "unknown  # comment" — the unknown scan below is blind')

# (1) every unknown/unverified frontmatter value -> `<tool>.<key>` on a Covers: line
unknown_count = 0
adapters = sorted(pathlib.Path('adapters/runtime').glob('*.md'))
for f in adapters:
    fm = read_frontmatter(f)
    tool = fm.get('tool') or f.stem
    for key in sorted(fm):
        val = fm[key]
        if isinstance(val, str) and val.strip() in ('unknown', 'unverified'):
            unknown_count += 1
            need(f'{tool}.{key}', f'{f.name}: {key}: {val.strip()}')
if unknown_count == 0:
    bad.append('sanity: zero unknown/unverified frontmatter values found; if every axis is truly '
               'resolved, retire this guard deliberately rather than letting it pass silently')

# (2) every WIRED enforcement cell -> `<tool>.wired.<hook>`; every non-Claude ENFORCEMENT cell
#     -> a PROMOTED ledger line (a promotion is never a template edit alone)
tmpl = pathlib.Path('templates/AGENTS.md.tmpl').read_text(encoding='utf-8')
m = re.search(r'<!-- ticketwright:enforcement:begin -->(.*?)<!-- ticketwright:enforcement:end -->',
              tmpl, re.S)
if not m:
    bad.append('no enforcement markers in templates/AGENTS.md.tmpl')
else:
    NAME2TOOL = {'Claude Code': 'claude-code', 'Codex CLI': 'codex-cli', 'Cursor': 'cursor',
                 'Antigravity': 'antigravity', 'OpenCode': 'opencode', 'Devin': 'devin',
                 'Cline': 'cline'}
    header_hooks = []
    for line in m.group(1).splitlines():
        if not line.startswith('| ') or line.startswith('|--'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if cells[0] == 'Runtime':
            header_hooks = [c.strip('`') for c in cells[1:5]]
            continue
        if not header_hooks:
            continue
        tool = NAME2TOOL.get(cells[0])
        if tool is None:
            bad.append(f'enforcement row {cells[0]!r} is not in section 44 runtime-name map — extend it')
            continue
        for hook, cell in zip(header_hooks, cells[1:5]):
            if cell.startswith('WIRED'):
                need(f'{tool}.wired.{hook}', f'enforcement WIRED cell {cells[0]} x {hook}')
            if cell.startswith('ENFORCEMENT') and tool != 'claude-code':
                want = f'PROMOTED {tool}.wired.{hook} '
                if not any(l.startswith(want) for l in ledger):
                    bad.append(f'{cells[0]} x {hook} claims ENFORCEMENT with no promotion-ledger '
                               f'line ({want.strip()} ...)')

# (3) every emitted fixture artifact carrying an "unverified" label -> its in-project path
emit_hits = 0
for p in sorted(pathlib.Path('tests/emit').rglob('*')):
    if p.is_file() and 'unverified' in p.read_text(encoding='utf-8', errors='ignore'):
        emit_hits += 1
        rel = p.relative_to('tests/emit')
        proj = str(pathlib.Path(*rel.parts[1:]))
        if proj not in claims:
            bad.append(f'{p} carries an unverified label — no Covers: line names `{proj}`')
if emit_hits == 0:
    bad.append('sanity: zero unverified-labeled files under tests/emit/; if every label is truly '
               'gone, retire this guard deliberately rather than letting it pass silently')

# (4) every "(unverified)" metadata-mapping row -> the emitted qc-reviewer path its agents_root
#     derives (or the fallback token where no agents_root is declared)
for f in adapters:
    lines = f.read_text(encoding='utf-8').splitlines()
    k = lines.index('---', 1) if '---' in lines[1:] else len(lines)
    body = '\n'.join(lines[k + 1:])
    if '(unverified)' not in body:
        continue
    fm = read_frontmatter(f)
    tool = fm.get('tool') or f.stem
    ar = (fm.get('agents_root') or '').strip()
    if ar and ar not in ('none', 'unknown'):
        path = ar.replace('<name>', 'qc-reviewer')
        if path not in claims and f'{tool}.metadata_mapping' not in claims:
            bad.append(f'{f.name}: "(unverified)" mapping row — no Covers: line names `{path}` '
                       f'(or the fallback `{tool}.metadata_mapping`)')
    else:
        need(f'{tool}.metadata_mapping', f'{f.name}: "(unverified)" mapping row with no agents_root to derive an artifact from')

print('\n'.join(bad))
PY
lv_bad="$(cat "$TMP/hd5051.out")"
[ -z "$lv_bad" ] && ok "every unknown/unverified frontmatter value, WIRED cell, unverified-labeled artifact, and (unverified) mapping row is claimed on a punch-list Covers: line" \
  || bad "an unverified claim exists without a tracked way to verify it" "$lv_bad"

hdr "45 · chat/docstore delivery routing: a DECLARED audience, and always_include enforced in code (PROMPT 8 / items 2-3)"
# The seam that can leak client data. Two properties are load-bearing and both are tested by
# BEHAVIOR, never by grepping for a token:
#   (1) routing reads a DECLARATION and halts when there isn't one — it never infers an audience
#       from prose/labels and never falls back to a listed target, because the fallback may be the
#       external one;
#   (2) `always_include` is ENFORCED — a config omitting it is REJECTED, and a drafted message that
#       fails to carry the routed list is REJECTED. (A presence grep for the token proves neither:
#       it passes against a config that never applies the list and against a message that omits it.)
DP="$KIT/bin/delivery_plan.py"
D45="$TMP/route45"; mkdir -p "$D45/.claude/config" "$D45/tk"
cp "$KIT/.claude/config/stack.example.multi-audience.yaml" "$D45/.claude/config/stack.yaml"
PLAN45="$D45/tk/delivery-plan.yaml"
route() { ROUT="$(python3 "$DP" --root "$D45" --plan "$PLAN45" --quiet "$@" 2>/dev/null)"; RRC=$?; }
rget()  { printf '%s' "$ROUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# --- (A) a declared audience routes, and carries THAT target's own recipients -------------------
printf 'schema_version: 1\naudience: client\nclassification: client_delivery\n' > "$PLAN45"
route --seam chat
{ [ "$RRC" -eq 0 ] && [ "$(rget "d['target']")" = "client" ] && [ "$(rget "d['tool']")" = "teams" ] \
  && [ "$(rget "d['selected_by']")" = "declared" ] && [ "$(rget "d['recipients']")" = "['Dana']" ]; } \
  && ok "a declared audience routes to that target, with the target's OWN recipient list" \
  || bad "declared-audience routing wrong" "rc=$RRC target=$(rget "d.get('target')") to=$(rget "d.get('recipients')")"
printf 'schema_version: 1\naudience: internal\nclassification: internal_archive\n' > "$PLAN45"
route --seam chat
{ [ "$(rget "d['target']")" = "internal" ] && [ "$(rget "d['recipients']")" = "['Alice']" ] \
  && [ "$(rget "d['destination']")" = "C0XXXXXXXXX" ] && [ "$(rget "d['destination_key']")" = "default_channel" ]; } \
  && ok "the other audience routes to the other target — different tool, different key, different list" \
  || bad "second audience routed wrong" "target=$(rget "d.get('target')") to=$(rget "d.get('recipients')")"
route --seam docstore
{ [ "$(rget "d['target']")" = "archive" ] && [ "$(rget "d['sharing_scope']")" = "team" ]; } \
  && ok "a declared classification routes the docstore and reports its declared sharing scope" \
  || bad "docstore classification routing wrong" "target=$(rget "d.get('target')")"

# --- (B) every failure is a HALT with no target and no destination in the output -----------------
# The output shape matters as much as the exit code: a caller that ignores the code must still not
# be able to lift a usable destination out of a failed routing.
printf 'schema_version: 1\n' > "$PLAN45"
route --seam chat
{ [ "$RRC" -eq 9 ] && [ "$(rget "d['target']")" = "None" ] && [ "$(rget "d['destination']")" = "None" ]; } \
  && ok "no declaration = exit 9, and neither a target nor a destination is emitted" \
  || bad "an undeclared audience did not halt cleanly" "rc=$RRC target=$(rget "d.get('target')")"
printf '%s' "$ROUT" | grep -q "delivery-plan.yaml\|audience" \
  && ok "the halt names what is missing (the plan's audience declaration)" \
  || bad "the no-declaration halt does not say what to declare"
{ printf '%s' "$ROUT" | grep -q "internal" && printf '%s' "$ROUT" | grep -q "client"; } \
  && ok "the halt lists the configured audiences instead of picking one" \
  || bad "the no-declaration halt does not list the configured audiences"
printf 'schema_version: 1\naudience: externl\n' > "$PLAN45"
route --seam chat
{ [ "$RRC" -eq 8 ] && [ "$(rget "d['target']")" = "None" ]; } \
  && ok "a declared audience matching no target = exit 8, never a fallback" \
  || bad "an unmatched audience did not halt" "rc=$RRC target=$(rget "d.get('target')")"
# Exact match, deliberately: a near-miss is a typo, and fuzzy-matching an audience is how a message
# reaches the wrong room. `Client` is not `client`.
printf 'schema_version: 1\naudience: Client\n' > "$PLAN45"
route --seam chat
[ "$RRC" -eq 8 ] && ok "audience matching is exact — a case variant halts rather than resolving" \
  || bad "audience matching normalized a near-miss" "rc=$RRC target=$(rget "d.get('target')")"
rm -f "$PLAN45"
route --seam chat
{ [ "$RRC" -eq 3 ] && [ "$(rget "d['target']")" = "None" ]; } \
  && ok "a missing delivery plan on a multi-target slot = exit 3, no target" \
  || bad "a missing plan did not halt" "rc=$RRC"
printf 'schema_version: 2\naudience: internal\n' > "$PLAN45"
route --seam chat
[ "$RRC" -eq 4 ] && ok "a plan written to another schema_version is malformed, not read anyway" \
  || bad "an unsupported plan schema_version was read" "rc=$RRC"

# --- (C) the explicit override, and its honesty about not being recorded ------------------------
printf 'schema_version: 1\naudience: client\n' > "$PLAN45"
route --seam chat --override internal
{ [ "$RRC" -eq 0 ] && [ "$(rget "d['target']")" = "internal" ] \
  && [ "$(rget "d['selected_by']")" = "override" ] && [ "$(rget "d['recipients']")" = "['Alice']" ]; } \
  && ok "--override selects a target explicitly and swaps in ITS recipient list" \
  || bad "override routing wrong" "rc=$RRC target=$(rget "d.get('target')")"
route --seam chat --override ghost
{ [ "$RRC" -eq 8 ] && [ "$(rget "d['target']")" = "None" ]; } \
  && ok "an unknown --override is exit 8, never a fallback to the declaration" \
  || bad "an unknown override did not halt" "rc=$RRC"
printf 'schema_version: 1\n' > "$PLAN45"
route --seam chat --override client
{ [ "$RRC" -eq 0 ] && printf '%s' "$ROUT" | grep -q "not recorded"; } \
  && ok "an override with nothing declared routes but SAYS the routing isn't recorded with the ticket" \
  || bad "an unrecorded override did not report itself"

# --- (D) a rendered draft provably carries the routed list --------------------------------------
# This is the half a presence grep cannot do: the check reads the DRAFT and reports the names it
# fails to carry, so a message written for one audience cannot pass for the other.
printf 'schema_version: 1\naudience: client\nclassification: client_delivery\n' > "$PLAN45"
printf 'ENG-1234 shipped. Summary in the linked deck. cc Dana\n' > "$D45/tk/good.md"
printf 'ENG-1234 shipped. Summary in the linked deck. cc Alice\n' > "$D45/tk/wrong.md"
route --seam chat --check-draft "$D45/tk/good.md"
[ "$RRC" -eq 0 ] && ok "a draft naming every routed recipient passes the comms rail" \
  || bad "a correct draft was rejected" "rc=$RRC missing=$(rget "d.get('missing_recipients')")"
route --seam chat --check-draft "$D45/tk/wrong.md"
{ [ "$RRC" -ne 0 ] && [ "$(rget "d['missing_recipients']")" = "['Dana']" ]; } \
  && ok "a draft carrying the WRONG audience's stakeholder is rejected, naming who is missing" \
  || bad "a draft missing its routed recipient was accepted" "rc=$RRC missing=$(rget "d.get('missing_recipients')")"

# --- (E) always_include (and the rest) ENFORCED by bin/verify_stack.sh --------------------------
# The gate is the verify run's EXIT CODE, not a message: this list had zero mechanical enforcement
# before — it was prose in an adapter — and a new prose rule replacing an unenforced prose rule
# would change nothing. Fixtures are built by these two helpers rather than by string substitution:
# `[Alice]` inside a bash ${var/pat/rep} pattern is a CHARACTER CLASS, so an edit like that silently
# does nothing and the test then proves the wrong thing.
V45="$TMP/vrfy45"; mkdir -p "$V45/.claude/config"
vcfg() { printf '%s' "$1" > "$V45/.claude/config/stack.yaml"
         VOUT="$(bash "$KIT/bin/verify_stack.sh" "$V45/.claude/config/stack.yaml" --dry-run 2>&1)"; VRC=$?; }
chat_cfg() {  # chat_cfg <internal target body> <client target body> [extra slot-level line]
  printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    default: internal\n    default_mode: draft\n%s    targets:\n      internal: {%s}\n      client: {%s}\n' \
    "${3:-}" "$1" "$2"
}
SLACK_T='audience: internal, tool: slack, adapter: adapters/chat/slack.md, default_channel: C1, always_include: [Alice], verify: null'
TEAMS_T='audience: client, tool: teams, adapter: adapters/chat/teams.md, channel: X9, always_include: [Dana], verify: null'

vcfg "$(chat_cfg "$SLACK_T" "$TEAMS_T")"
[ "$VRC" -eq 0 ] && ok "a well-formed two-target chat slot verifies clean" \
  || bad "a valid multi-target chat config was rejected" "$(printf '%s' "$VOUT" | grep '✗' | head -2)"
vcfg "$(chat_cfg "$SLACK_T" 'audience: client, tool: teams, adapter: adapters/chat/teams.md, channel: X9, verify: null')"
{ [ "$VRC" -ne 0 ] && printf '%s' "$VOUT" | grep -q 'always_include'; } \
  && ok "a chat target with NO always_include is REJECTED (non-zero exit), naming the key" \
  || bad "always_include is not actually enforced" "rc=$VRC"
vcfg "$(chat_cfg "$SLACK_T" 'audience: client, tool: teams, adapter: adapters/chat/teams.md, channel: X9, always_include: [], verify: null')"
[ "$VRC" -ne 0 ] && ok "an EMPTY always_include is rejected too (worse than absent — it reads as a decision)" \
  || bad "an empty always_include was accepted"
vcfg "$(chat_cfg 'tool: slack, adapter: adapters/chat/slack.md, default_channel: C1, always_include: [Alice], verify: null' "$TEAMS_T")"
[ "$VRC" -ne 0 ] && ok "a chat target with no declared audience is rejected (it would be unroutable)" \
  || bad "a target with no audience was accepted"
vcfg "$(chat_cfg "$SLACK_T" 'audience: internal, tool: teams, adapter: adapters/chat/teams.md, channel: X9, always_include: [Dana], verify: null')"
[ "$VRC" -ne 0 ] && ok "two targets declaring the SAME audience are rejected (ambiguous routing)" \
  || bad "duplicate audiences were accepted"
vcfg "$(chat_cfg "$SLACK_T" "$TEAMS_T" '    audience: internal
')"
[ "$VRC" -ne 0 ] && ok "a slot-level audience is rejected — a routing key must never be inherited" \
  || bad "a slot-level audience was accepted"
# Two targets that both fall back to one inherited channel are a separation that does not exist.
vcfg "$(chat_cfg 'audience: internal, tool: slack, adapter: adapters/chat/slack.md, always_include: [Alice], verify: null' 'audience: client, tool: slack, adapter: adapters/chat/slack.md, always_include: [Dana], verify: null' '    default_channel: CSHARED
')"
{ [ "$VRC" -ne 0 ] && printf '%s' "$VOUT" | grep -q 'inherited'; } \
  && ok "targets relying on an INHERITED channel are rejected — inheritance is never a destination" \
  || bad "two targets shared one inherited channel" "rc=$VRC"
vcfg "$(chat_cfg "$SLACK_T" 'audience: client, tool: slack, adapter: adapters/chat/slack.md, default_channel: C1, always_include: [Dana], verify: null')"
[ "$VRC" -ne 0 ] && ok "two targets resolving to the same tool+destination are rejected" \
  || bad "colliding destinations were accepted"
vcfg "$(chat_cfg "$SLACK_T" 'audience: client, tool: teams, adapter: adapters/chat/teams.md, channel: X9, always_include: ["D$(id)"], verify: null')"
{ [ "$VRC" -ne 0 ] && printf '%s' "$VOUT" | grep -q 'metacharacters'; } \
  && ok "a recipient carrying shell metacharacters is refused (the tier-3 injection rule, inherited)" \
  || bad "a recipient with shell metacharacters was accepted" "rc=$VRC"
# THE REGRESSION GUARD. The non-empty rule binds only under `targets:` — a single-mapping chat slot
# that omits always_include must keep validating, or every shipped example config breaks.
vcfg 'project:
  key_prefix: ENG
seams:
  chat:
    tool: slack
    adapter: adapters/chat/slack.md
    transport: mcp
    mcp: slack
    default_channel: C0XXXXXXXXX
    default_mode: draft
    verify: null
'
[ "$VRC" -eq 0 ] && ok "a SINGLE-mapping chat slot with no always_include still verifies (the rule is targets-scoped)" \
  || bad "the new rule broke single-target chat configs" "$(printf '%s' "$VOUT" | grep '✗' | head -2)"

ds_cfg() {  # ds_cfg <archive target body> <client target body>
  printf 'project:\n  key_prefix: ENG\nseams:\n  docstore:\n    default: archive\n    targets:\n      archive: {%s}\n      client_delivery: {%s}\n' "$1" "$2"
}
DS_A='classification: internal_archive, sharing_scope: team, tool: gdrive, adapter: adapters/docstore/gdrive.md, drive_folder: "A", verify: null'
DS_C='classification: client_delivery, sharing_scope: external, tool: sharepoint, adapter: adapters/docstore/sharepoint.md, drive_folder: "B", verify: null'
vcfg "$(ds_cfg "$DS_A" "$DS_C")"
[ "$VRC" -eq 0 ] && ok "a well-formed two-target docstore slot verifies clean" \
  || bad "a valid multi-target docstore config was rejected" "$(printf '%s' "$VOUT" | grep '✗' | head -2)"
vcfg "$(ds_cfg "$DS_A" 'classification: client_delivery, tool: sharepoint, adapter: adapters/docstore/sharepoint.md, drive_folder: "B", verify: null')"
[ "$VRC" -ne 0 ] && ok "a docstore target with no declared sharing_scope is rejected" \
  || bad "an undeclared sharing_scope was accepted"
vcfg "$(ds_cfg 'classification: internal_archive, sharing_scope: everyone, tool: gdrive, adapter: adapters/docstore/gdrive.md, drive_folder: "A", verify: null' "$DS_C")"
[ "$VRC" -ne 0 ] && ok "a sharing_scope outside team|org|external is rejected" \
  || bad "an unknown sharing_scope was accepted"
vcfg "$(ds_cfg "$DS_A" 'classification: internal_archive, sharing_scope: external, tool: sharepoint, adapter: adapters/docstore/sharepoint.md, drive_folder: "B", verify: null')"
[ "$VRC" -ne 0 ] && ok "two docstore targets sharing one classification are rejected" \
  || bad "duplicate classifications were accepted"
# The shipped worked example must satisfy its own audit (section 1 proves it RESOLVES; this proves
# it obeys the routing rules).
python3 "$DP" --stack "$KIT/.claude/config/stack.example.multi-audience.yaml" --audit --quiet >/dev/null 2>&1 \
  && ok "the shipped multi-audience example satisfies every routing rule" \
  || bad "the shipped multi-audience example fails its own audit"

# --- (E2) the same rules bind AT ROUTE TIME, not only in the audit ------------------------------
# The audit runs when someone runs verify_stack.sh; routing runs when a message is about to be sent.
# If enforcement lived only in the audit, an unverified config would still deliver — so routing
# re-checks and REFUSES. "They should have run verify first" is not a safety property.
R2="$TMP/route45b"; mkdir -p "$R2/.claude/config" "$R2/tk"
printf 'schema_version: 1\naudience: client\n' > "$R2/tk/delivery-plan.yaml"
printf '%s' "$(chat_cfg "$SLACK_T" 'audience: client, tool: teams, adapter: adapters/chat/teams.md, channel: X9, verify: null')" \
  > "$R2/.claude/config/stack.yaml"
python3 "$DP" --root "$R2" --plan "$R2/tk/delivery-plan.yaml" --seam chat --quiet > "$TMP/r2.json" 2>/dev/null
R2RC=$?
R2T="$(python3 -c "import json;print(json.load(open('$TMP/r2.json'))['target'])" 2>/dev/null)"
{ [ "$R2RC" -ne 0 ] && [ "$R2T" = "None" ]; } \
  && ok "routing REFUSES a target with no always_include, even on a config nobody verified" \
  || bad "routing delivered to a target with no stakeholder list" "rc=$R2RC target=$R2T"
printf '%s' "$(chat_cfg 'audience: internal, tool: slack, adapter: adapters/chat/slack.md, always_include: [Alice], verify: null' 'audience: client, tool: slack, adapter: adapters/chat/slack.md, always_include: [Dana], verify: null' '    default_channel: CSHARED
')" > "$R2/.claude/config/stack.yaml"
python3 "$DP" --root "$R2" --plan "$R2/tk/delivery-plan.yaml" --seam chat --quiet > "$TMP/r2.json" 2>/dev/null
R2RC=$?
R2D="$(python3 -c "import json;print(json.load(open('$TMP/r2.json'))['destination'])" 2>/dev/null)"
{ [ "$R2RC" -ne 0 ] && [ "$R2D" = "None" ]; } \
  && ok "routing REFUSES an inherited destination — a routed target never delivers to a shared channel" \
  || bad "routing delivered to an inherited channel" "rc=$R2RC dest=$R2D"

# --- (E3) the gate-2 hardening: chat-only override, an approved plan is binding, per-deliverable -
printf 'schema_version: 1\naudience: internal\nclassification: internal_archive\ndeliverables:\n  - file: final_deliverables/summary.pdf\n    classification: client_delivery\n' > "$PLAN45"
route --seam docstore
[ "$(rget "d['target']")" = "archive" ] \
  && ok "the plan-level classification routes the ticket's deliverables by default" \
  || bad "plan-level classification routing wrong" "target=$(rget "d.get('target')")"
route --seam docstore --file final_deliverables/summary.pdf
{ [ "$(rget "d['target']")" = "client_delivery" ] && [ "$(rget "d['sharing_scope']")" = "external" ]; } \
  && ok "a deliverable declaring its OWN classification routes to its own store (per-deliverable)" \
  || bad "per-deliverable classification ignored" "target=$(rget "d.get('target')")"
route --seam docstore --override archive
[ "$RRC" -eq 2 ] \
  && ok "--override is refused for docstore — a store is DECLARED per deliverable, never flagged" \
  || bad "a docstore override was accepted" "rc=$RRC"
# An approved plan is binding: the human authorized ONE target, and a plan edited afterwards must
# stop the delivery rather than redirect it.
route --seam chat --expect-target internal
[ "$RRC" -eq 0 ] && ok "--expect-target passes while routing still agrees with the approved plan" \
  || bad "expect-target rejected a matching target" "rc=$RRC"
printf 'schema_version: 1\naudience: client\n' > "$PLAN45"
route --seam chat --expect-target internal
{ [ "$RRC" -ne 0 ] && [ "$(rget "d['target']")" = "None" ]; } \
  && ok "a plan edited AFTER approval refuses to route (preview==execution, mechanically)" \
  || bad "an edited plan delivered to a target nobody approved" "rc=$RRC target=$(rget "d.get('target')")"
route --seam chat --override internal
printf '%s' "$ROUT" | grep -qi 'contradicts' \
  && ok "an override contradicting the ticket's declaration says so on the plan line" \
  || bad "a contradicting override was silent"
# /ship renders `target: single` for a single mapping; passing that plan line back must MATCH, or
# the approval pin would misfire on every single-target repo.
SG="$TMP/single45"; mkdir -p "$SG/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    tool: slack\n    adapter: adapters/chat/slack.md\n    transport: mcp\n    mcp: slack\n    default_channel: C0X\n    default_mode: draft\n    always_include: [Alice]\n    verify: null\n' > "$SG/.claude/config/stack.yaml"
printf 'schema_version: 1\n' > "$SG/dp.yaml"
python3 "$DP" --root "$SG" --plan "$SG/dp.yaml" --seam chat --expect-target single --quiet >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "--expect-target single matches a single mapping's null target (the rendering sentinel)" \
  || bad "the approval pin misfires on a single-target repo"
python3 "$DP" --root "$SG" --plan "$SG/dp.yaml" --seam chat --expect-target client --quiet >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "a single mapping still refuses an approval pinned to a named target" \
  || bad "a single mapping accepted a foreign expect-target"

# --- (E4) adversarial-review hardening: rows honored-or-reported, the pin binds the RESOLUTION ---
# The P1 from the adversarial review: a deliverables row someone wrote to keep a file INTERNAL was
# silently overridden by the plan-level classification whenever its value wasn't a non-empty string
# — `classification: null`, `[]`, `""`, a misspelled key, or the chat key `audience:` by mix-up all
# routed the file to the client store with rc=0. Every shape now halts (exit 4), no target emitted.
row_case() {  # row_case <label> <deliverables block yaml> <--file arg>
  printf 'schema_version: 1\nclassification: client_delivery\n%s' "$2" > "$PLAN45"
  python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --file "$3" --quiet > "$TMP/e4.json" 2>/dev/null
  E4RC=$?; E4T="$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])" 2>/dev/null)"
  { [ "$E4RC" -eq 4 ] && [ "$E4T" = "None" ]; } \
    && ok "a deliverables row with $1 is exit 4 with no target — never a fallthrough to plan level" \
    || bad "a row with $1 fell through to the plan-level classification" "rc=$E4RC target=$E4T"
}
row_case "classification: null" 'deliverables:\n  - file: qc_queries/scratch.sql\n    classification: null\n' qc_queries/scratch.sql
row_case "classification: []"   'deliverables:\n  - file: qc_queries/scratch.sql\n    classification: []\n' qc_queries/scratch.sql
row_case "classification: \"\"" 'deliverables:\n  - file: qc_queries/scratch.sql\n    classification: ""\n' qc_queries/scratch.sql
row_case "the chat key audience: (mix-up)" 'deliverables:\n  - file: a.csv\n    audience: internal\n' a.csv
row_case "a misspelled key" 'deliverables:\n  - file: a.csv\n    clasification: internal_archive\n' a.csv
row_case "a non-mapping row" 'deliverables:\n  - just a string\n' a.csv
printf 'schema_version: 1\nclassification: client_delivery\ndeliverables: not a list\n' > "$PLAN45"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --quiet > "$TMP/e4.json" 2>/dev/null
E4RC=$?; E4T="$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])" 2>/dev/null)"
{ [ "$E4RC" -eq 4 ] && [ "$E4T" = "None" ]; } \
  && ok "a deliverables: block that is not a list of rows is exit 4 with no target" \
  || bad "a malformed deliverables block was silently iterated into nothing" "rc=$E4RC target=$E4T"
# The mix-up error must TEACH: it names the right key.
printf 'schema_version: 1\nclassification: client_delivery\ndeliverables:\n  - file: a.csv\n    audience: internal\n' > "$PLAN45"
E4MSG="$(python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --file a.csv 2>&1)" || true
grep -q 'did you mean' <<<"$E4MSG" \
  && ok "the audience-key mix-up error names classification: as the fix" \
  || bad "the mix-up error does not say what was meant"
# Path normalization: a ./-prefixed row must MATCH its bare --file (the same fallthrough in a wig).
printf 'schema_version: 1\nclassification: client_delivery\ndeliverables:\n  - file: ./qc_queries/scratch.sql\n    classification: internal_archive\n' > "$PLAN45"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --file qc_queries/scratch.sql --quiet > "$TMP/e4.json" 2>/dev/null
{ [ "$?" -eq 0 ] && [ "$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])")" = "archive" ]; } \
  && ok "a ./-prefixed row path matches its bare --file (normalized) and keeps the file internal" \
  || bad "a ./-prefixed row silently missed its file and fell through to the client store"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --file qc_queries//scratch.sql --quiet > "$TMP/e4.json" 2>/dev/null
{ [ "$?" -eq 0 ] && [ "$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])")" = "archive" ]; } \
  && ok "a doubled-slash --file matches the row too (both sides normalized)" \
  || bad "a doubled slash in the path degraded to the plan-level fallthrough"
# Two rows naming one file (after normalization) is ambiguity, and ambiguity never picks.
printf 'schema_version: 1\nclassification: internal_archive\ndeliverables:\n  - file: a.csv\n    classification: internal_archive\n  - file: ./a.csv\n    classification: client_delivery\n' > "$PLAN45"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --file a.csv --quiet >/dev/null 2>&1
[ "$?" -eq 4 ] && ok "duplicate rows for one file are exit 4 — first-match-wins never silently routes" \
  || bad "duplicate deliverables rows were resolved by picking one"

# P2-1: the pin binds the RESOLUTION, not the name. Same target name, edited channel → refuse.
printf 'schema_version: 1\naudience: client\nclassification: client_delivery\n' > "$PLAN45"
route --seam chat
E4FP="$(rget "d['resolution_fingerprint']")"
[ -n "$E4FP" ] && [ "$E4FP" != "None" ] \
  && ok "a routed plan line carries a resolution_fingerprint" \
  || bad "no resolution_fingerprint emitted" "$E4FP"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam chat --expect-fingerprint "$E4FP" --quiet >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "--expect-fingerprint passes while the resolution is unchanged" \
  || bad "a matching fingerprint was refused"
sed 's/19:shared-client-channel@thread.tacv2/19:some-other-room@thread.tacv2/' \
  "$D45/.claude/config/stack.yaml" > "$TMP/e4-edited.yaml"
python3 "$DP" --stack "$TMP/e4-edited.yaml" --plan "$PLAN45" --seam chat --expect-target client --quiet >/dev/null 2>&1 \
  && E4NAME=pass || E4NAME=refuse
python3 "$DP" --stack "$TMP/e4-edited.yaml" --plan "$PLAN45" --seam chat \
  --expect-target client --expect-fingerprint "$E4FP" --quiet > "$TMP/e4.json" 2>/dev/null
E4RC=$?; E4T="$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])" 2>/dev/null)"
{ [ "$E4NAME" = "pass" ] && [ "$E4RC" -eq 8 ] && [ "$E4T" = "None" ]; } \
  && ok "an edited channel passes the NAME pin but the FINGERPRINT refuses (exit 8, no target) — the pin binds the resolution" \
  || bad "a same-name resolution change slipped past the approval pin" "name=$E4NAME rc=$E4RC target=$E4T"
# The basis covers facts that do not change the folded recipient list: toggling include_self alone
# must move the fingerprint, or a stale pin matches a materially different delivery.
sed 's/always_include: \[Alice\]/always_include: [Alice], include_self: true/' \
  "$D45/.claude/config/stack.yaml" > "$TMP/e4-selfed.yaml"
printf 'schema_version: 1\naudience: internal\n' > "$PLAN45"
FPA="$(python3 "$DP" --root "$D45" --plan "$PLAN45" --seam chat --quiet 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["resolution_fingerprint"])')"
FPB="$(python3 "$DP" --stack "$TMP/e4-selfed.yaml" --plan "$PLAN45" --seam chat --quiet 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["resolution_fingerprint"])')"
{ [ -n "$FPA" ] && [ -n "$FPB" ] && [ "$FPA" != "$FPB" ]; } \
  && ok "toggling include_self alone moves the fingerprint (the basis is wider than the visible list)" \
  || bad "an include_self toggle left the fingerprint unchanged" "$FPA vs $FPB"

# P2-2: a routed docstore target with no sharing_scope refuses AT ROUTE TIME (audit bypassed).
NS="$TMP/e4-noscope"; mkdir -p "$NS/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  docstore:\n    default: archive\n    targets:\n      archive: {classification: internal_archive, tool: gdrive, adapter: adapters/docstore/gdrive.md, drive_folder: "A", verify: null}\n      client_delivery: {classification: client_delivery, sharing_scope: external, tool: sharepoint, adapter: adapters/docstore/sharepoint.md, drive_folder: "B", verify: null}\n' > "$NS/.claude/config/stack.yaml"
printf 'schema_version: 1\nclassification: internal_archive\n' > "$NS/dp.yaml"
python3 "$DP" --root "$NS" --plan "$NS/dp.yaml" --seam docstore --quiet > "$TMP/e4.json" 2>/dev/null
E4RC=$?; E4T="$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['target'])" 2>/dev/null)"
{ [ "$E4RC" -eq 4 ] && [ "$E4T" = "None" ]; } \
  && ok "a routed docstore target with no sharing_scope refuses at route time (exit 4, parity with the audit)" \
  || bad "a scope-less docstore target routed rc=0" "rc=$E4RC target=$E4T"
# A junk-typed base_path may never REPLACE the type-checked drive_folder as the destination.
printf 'project:\n  key_prefix: ENG\nseams:\n  docstore:\n    default: archive\n    targets:\n      archive: {classification: internal_archive, sharing_scope: team, tool: gdrive, adapter: adapters/docstore/gdrive.md, drive_folder: "A", base_path: {x: 1}, verify: null}\n      client_delivery: {classification: client_delivery, sharing_scope: external, tool: sharepoint, adapter: adapters/docstore/sharepoint.md, drive_folder: "B", verify: null}\n' > "$NS/.claude/config/stack.yaml"
printf 'schema_version: 1\nclassification: internal_archive\n' > "$NS/dp.yaml"
E4D="$(python3 "$DP" --root "$NS" --plan "$NS/dp.yaml" --seam docstore --quiet 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["destination"])' 2>/dev/null)"
[ "$E4D" = "A" ] && ok "a junk-typed base_path cannot replace the checked destination (the string stays)" \
  || bad "an unchecked base_path was emitted as the destination" "dest=$E4D"
# A plan that EXISTS but is malformed reports on a SINGLE-mapping slot too; only an ABSENT plan is excused.
SM="$TMP/e4-single"; mkdir -p "$SM/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  docstore:\n    tool: gdrive\n    adapter: adapters/docstore/gdrive.md\n    transport: cli\n    drive_folder: "A"\n    verify: null\n' > "$SM/.claude/config/stack.yaml"
printf 'schema_version: 1\ndeliverables: junk\n' > "$SM/dp.yaml"
python3 "$DP" --root "$SM" --plan "$SM/dp.yaml" --seam docstore --quiet >/dev/null 2>&1
[ "$?" -eq 4 ] && ok "a malformed plan reports exit 4 even on a single-mapping slot (broken record, not excused)" \
  || bad "a malformed plan exited 0 on a single-mapping slot"
python3 "$DP" --root "$SM" --plan "$SM/absent.yaml" --seam docstore --quiet >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "an ABSENT plan on a single-mapping slot still routes (the regression guard holds)" \
  || bad "the malformed-plan tightening broke plan-less single-mapping repos"

# P2-3: junk-typed destinations are refused in BOTH the audit and the route.
printf '%s' "$(chat_cfg 'audience: internal, tool: slack, adapter: adapters/chat/slack.md, default_channel: [], always_include: [Alice], verify: null' "$TEAMS_T")" > "$NS/.claude/config/stack.yaml"
VOUT="$(bash "$KIT/bin/verify_stack.sh" "$NS/.claude/config/stack.yaml" --dry-run 2>&1)"; VRC=$?
{ [ "$VRC" -ne 0 ] && printf '%s' "$VOUT" | grep -q 'non-empty string'; } \
  && ok "the audit rejects a non-string destination (channel: []) naming the type rule" \
  || bad "junk-typed destination passed the audit" "rc=$VRC"
printf 'schema_version: 1\naudience: internal\n' > "$NS/dp.yaml"
python3 "$DP" --root "$NS" --plan "$NS/dp.yaml" --seam chat --quiet > "$TMP/e4.json" 2>/dev/null
E4RC=$?; E4D="$(python3 -c "import json;print(json.load(open('$TMP/e4.json'))['destination'])" 2>/dev/null)"
{ [ "$E4RC" -eq 4 ] && [ "$E4D" = "None" ]; } \
  && ok "routing refuses a junk-typed destination rather than emitting the raw value" \
  || bad "routing emitted junk as a destination" "rc=$E4RC dest=$E4D"

# P3a: an absent router is a FAILURE on configs that need it, and only on those.
NK="$TMP/e4-nokit"; rm -rf "$NK"; mkdir -p "$NK/bin"
cp "$KIT/bin/verify_stack.sh" "$KIT/bin/effective_config.py" "$KIT/bin/_yamlite.py" "$NK/bin/"
cp -R "$KIT/adapters" "$NK/adapters"
CLAUDE_PLUGIN_ROOT= bash "$NK/bin/verify_stack.sh" "$KIT/.claude/config/stack.example.multi-audience.yaml" --dry-run > "$TMP/e4nk.txt" 2>&1
{ [ "$?" -eq 1 ] && grep -q 'delivery-routing checker is missing' "$TMP/e4nk.txt" \
    && grep -q 'delivery_plan.py' "$TMP/e4nk.txt"; } \
  && ok "a kit missing delivery_plan.py FAILS verify on a targets config, naming the missing FILE" \
  || bad "the routing enforcement silently vanished with its file" "$(tail -2 "$TMP/e4nk.txt")"
# A targets: block holding ONLY non-mapping entries emits no unit rows — it must still fail (the
# resolver now reports each junk entry as a seam_error instead of skipping it invisibly).
printf 'project:\n  key_prefix: ENG\nseams:\n  chat:\n    default: internal\n    targets:\n      internal: junk string\n' > "$TMP/e4-junk.yaml"
CLAUDE_PLUGIN_ROOT= bash "$NK/bin/verify_stack.sh" "$TMP/e4-junk.yaml" --dry-run > "$TMP/e4nk2.txt" 2>&1
{ [ "$?" -eq 1 ] && grep -q 'not a mapping' "$TMP/e4nk2.txt"; } \
  && ok "a targets: block of non-mapping entries fails verify even without the router (no invisible skip)" \
  || bad "junk-only targets bypassed both the unit rows and the missing-router failure" "$(tail -2 "$TMP/e4nk2.txt")"
CLAUDE_PLUGIN_ROOT= bash "$NK/bin/verify_stack.sh" "$KIT/.claude/config/stack.yaml" --dry-run >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "the same kit still passes a single-mapping config (the failure is scoped to targets)" \
  || bad "the missing-router failure fires on configs that never needed the router"

# --- (F) the delivered row binds link_for to the store backup actually used ----------------------
printf 'schema_version: 1\naudience: client\nclassification: client_delivery\n' > "$PLAN45"
route --seam docstore
BACKUP_T="$(rget "d['target']")"
python3 "$DP" --root "$D45" --plan "$PLAN45" --seam docstore --quiet \
  --record-delivered "final_deliverables/out_12rows.csv" --url "https://example.invalid/d/x1" >/dev/null 2>&1
python3 - "$PLAN45" "$KIT/bin" <<'PY' >"$TMP/hd5570.out"
import sys, pathlib
sys.path.insert(0, sys.argv[2])
from _yamlite import parse_file
rows = parse_file(pathlib.Path(sys.argv[1])).get("delivered") or []
print(rows[-1].get("docstore_target") if rows else "")
PY
REC_T="$(cat "$TMP/hd5570.out")"
{ [ -n "$BACKUP_T" ] && [ "$REC_T" = "$BACKUP_T" ]; } \
  && ok "a delivered row records the docstore target actually routed, so link_for hits that same store" \
  || bad "the delivered row does not match the routed target" "routed=$BACKUP_T recorded=$REC_T"

# --- (G) tier 3 can never move an audience ------------------------------------------------------
# A gitignored, unreviewed per-machine file that could re-point `audience` would be a routing
# override with nothing in code review to catch it. REJECTED (exit 6), never ignored.
T3="$TMP/tier3-45"; mkdir -p "$T3/.claude/config"
cp "$KIT/.claude/config/stack.example.multi-audience.yaml" "$T3/.claude/config/stack.yaml"
printf 'person: alice\nseams:\n  chat:\n    targets:\n      internal:\n        audience: client\n' \
  > "$T3/.claude/config/connections.local.yaml"
python3 "$KIT/bin/effective_config.py" --root "$T3" --json --quiet >/dev/null 2>&1
[ "$?" -eq 6 ] && ok "a tier-3 file re-pointing a target's audience is REJECTED, not ignored" \
  || bad "tier 3 was allowed to change an audience declaration"

# --- (H) /ship: routes before drafting, previews what it executes, and still halts on tracker/vcs -
# PROSE WIRING PINS, not behavior — the same convention section 37 uses. A skill is prose an
# agent executes, so these prove the instructions still SAY what the CLI assertions above make
# true; they cannot prove an agent passed --expect-target at execution time. That honesty gap
# is stated in adapters/README.md (§ What is MECHANICAL here, and what is instruction) rather
# than papered over with a grep that would look like proof.
SH45=".claude/skills/ship/SKILL.md"
grep -q 'disable-model-invocation: true' "$SH45" \
  && ok "/ship keeps disable-model-invocation (routing added no model surface)" \
  || bad "/ship lost disable-model-invocation"
grep -q 'claude -p' "$SH45" && bad "/ship reintroduced a headless model call" \
  || ok "/ship still makes no headless model call"
{ grep -q 'delivery_plan.py' "$SH45" && grep -q 'check-draft' "$SH45"; } \
  && ok "/ship resolves routing and the draft rail through the delivery-plan CLI" \
  || bad "/ship does not call the delivery-plan CLI"
grep -q 'Route the delivery FIRST' "$SH45" \
  && ok "/ship routes BEFORE drafting (the draft must carry the routed list)" \
  || bad "/ship still drafts before it routes"
grep -qi 'never infer the audience' "$SH45" \
  && ok "/ship forbids inferring an audience in so many words" \
  || bad "/ship does not forbid inferring the audience"
grep -q 'tracker and vcs' "$SH45" \
  && ok "/ship still halts on named targets for the two DEFERRED slots (tracker, vcs)" \
  || bad "/ship dropped the tracker/vcs named-target halt"

hdr "46 · email is a chat target: gmail/outlook adapters + sender-pinned stakeholder routing (PROMPT 10)"
# Email is the delivery path where a wrong audience is LEAST recoverable — a sent mail cannot be
# unsent and cannot be scoped after the fact. Everything here is prompt 8's machinery INHERITED by
# two new adapters, so the tests drive the same CLI the same way section 45 does and assert that
# nothing about email relaxed a rule: routing still reads a declaration and halts without one, the
# target's own always_include still binds, the fingerprint still pins the resolution — now
# including the SENDER, the one fact email has that a channel does not.

# --- (A) the four chat verbs by NAME, across every chat adapter ----------------------------------
# Section 2 proves each chat adapter has the RIGHT NUMBER of verb headings, not the RIGHT ONES —
# four typo'd verbs count four and pass. The email adapters are the first chat adapters added after
# the contract settled, so the whole seam gets the name check (the rank_projects_by_activity
# precedent).
for v in draft send lookup_user lookup_channel; do
  cvmiss=""
  for f in adapters/chat/*.md; do
    grep -qE "^## verb: $v( |$)" "$f" || cvmiss="$cvmiss $(basename "$f")"
  done
  [ -z "$cvmiss" ] && ok "every chat adapter names verb $v exactly" \
    || bad "chat adapter(s) miss or misspell verb $v" "$cvmiss"
done

# --- (B) the honesty frontmatter both email adapters must carry ---------------------------------
# The rough edges are load-bearing documentation: a future reader must not infer Slack parity that
# does not exist. Pinned as literals because each one was a deliberate prompt-10 requirement.
for f in adapters/chat/gmail.md adapters/chat/outlook.md; do
  n="$(basename "$f")"
  grep -q '^channel_key: to' "$f" \
    && ok "$n declares channel_key: to (routing reads the adapter's own destination key)" \
    || bad "$n does not declare channel_key: to"
  grep -q '^sender_key: identity' "$f" \
    && ok "$n declares sender_key: identity (the sender is part of the resolution)" \
    || bad "$n does not declare sender_key: identity"
  grep -q 'STRETCH' "$f" \
    && ok "$n states the lookup_channel → distribution-list mapping is a STRETCH" \
    || bad "$n does not admit the distribution-list stretch"
  grep -qi 'no bcc\|NO bcc mapping' "$f" \
    && ok "$n states there is deliberately no bcc mapping (no invisible audience widening)" \
    || bad "$n does not state the no-bcc rule"
  grep -q 'never falls back' "$f" \
    && ok "$n states a routing failure never falls back to another chat target" \
    || bad "$n does not state the never-fall-back rule"
done

# --- (C) the shipped worked examples: explicit draft-first, and both route ----------------------
# `default_mode: draft` must be EXPLICIT on every email target: an unset default_mode is NOT
# documented as meaning draft, and the gap between a draft a human clicks and a message already
# gone is the whole safety margin here.
for ex in .claude/config/stack.example.multi-audience.yaml .claude/config/stack.example.azure.yaml; do
  [ "$(yq '.seams.chat.targets.email.default_mode' "$ex" 2>/dev/null)" = "draft" ] \
    && ok "$(basename "$ex"): default_mode: draft is EXPLICIT on the email target" \
    || bad "$(basename "$ex"): the email target does not set default_mode: draft explicitly"
done
DP46="$KIT/bin/delivery_plan.py"
D46="$TMP/route46"; mkdir -p "$D46/.claude/config" "$D46/tk"
cp "$KIT/.claude/config/stack.example.multi-audience.yaml" "$D46/.claude/config/stack.yaml"
P46="$D46/tk/delivery-plan.yaml"
r46() { R46="$(python3 "$DP46" --root "$D46" --plan "$P46" --quiet "$@" 2>/dev/null)"; R46RC=$?; }
g46() { printf '%s' "$R46" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
printf 'schema_version: 1\naudience: stakeholders\n' > "$P46"
r46 --seam chat
{ [ "$R46RC" -eq 0 ] && [ "$(g46 "d['target']")" = "email" ] && [ "$(g46 "d['tool']")" = "gmail" ] \
  && [ "$(g46 "d['destination_key']")" = "to" ] \
  && [ "$(g46 "d['destination']")" = "stakeholder-updates@acme.example" ] \
  && [ "$(g46 "d['recipients']")" = "['pm@acme.example']" ] \
  && [ "$(g46 "d['mode']")" = "draft" ] && [ "$(g46 "d['selected_by']")" = "declared" ]; } \
  && ok "a declared stakeholders audience routes to the email target — gmail, key 'to', its OWN Cc list, draft mode" \
  || bad "stakeholder email routing wrong" "rc=$R46RC target=$(g46 "d.get('target')") to=$(g46 "d.get('recipients')")"
{ [ "$(g46 "d['sender']")" = "reports@acme.example" ] && [ "$(g46 "d['sender_key']")" = "identity" ]; } \
  && ok "the routed plan carries the SENDER (who the mail goes out as is part of what the human authorizes)" \
  || bad "the routed email plan has no sender" "sender=$(g46 "d.get('sender')")"
AZ46="$TMP/route46-az"; mkdir -p "$AZ46/.claude/config" "$AZ46/tk"
cp "$KIT/.claude/config/stack.example.azure.yaml" "$AZ46/.claude/config/stack.yaml"
printf 'schema_version: 1\naudience: stakeholders\n' > "$AZ46/tk/delivery-plan.yaml"
AZOUT="$(python3 "$DP46" --root "$AZ46" --plan "$AZ46/tk/delivery-plan.yaml" --seam chat --quiet 2>/dev/null)"
{ [ "$(printf '%s' "$AZOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tool"])' 2>/dev/null)" = "outlook" ] \
  && [ "$(printf '%s' "$AZOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sender"])' 2>/dev/null)" = "platform-reports@acme-corp.example" ] \
  && [ "$(printf '%s' "$AZOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mode"])' 2>/dev/null)" = "draft" ]; } \
  && ok "the azure example's outlook target routes the same way (the second worked activation)" \
  || bad "azure outlook routing wrong" "$AZOUT"

# --- (D) email inherits the halts: no declaration, no near-miss, no fallback --------------------
printf 'schema_version: 1\n' > "$P46"
r46 --seam chat
{ [ "$R46RC" -eq 9 ] && [ "$(g46 "d['target']")" = "None" ] && [ "$(g46 "d['destination']")" = "None" ]; } \
  && ok "no declared audience = exit 9 with target and destination null — email added no inference path" \
  || bad "an undeclared audience did not halt with email configured" "rc=$R46RC"
printf '%s' "$R46" | grep -q "stakeholders" \
  && ok "the halt lists the email audience among the configured values instead of picking one" \
  || bad "the no-declaration halt does not list the email audience"
printf 'schema_version: 1\naudience: stakeholder\n' > "$P46"
r46 --seam chat
{ [ "$R46RC" -eq 8 ] && [ "$(g46 "d['target']")" = "None" ]; } \
  && ok "a near-miss audience (stakeholder vs stakeholders) = exit 8, never a fallback to another target" \
  || bad "a near-miss audience resolved" "rc=$R46RC target=$(g46 "d.get('target')")"

# --- (E) the target's OWN always_include binds for email too (audit + route time) ---------------
NAI="$TMP/e46-noai"; mkdir -p "$NAI/.claude/config" "$NAI/tk"
cat > "$NAI/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
seams:
  chat:
    default: internal
    targets:
      internal:
        audience: internal
        tool: slack
        adapter: adapters/chat/slack.md
        default_channel: C1
        always_include: [Alice]
        verify: null
      email:
        audience: stakeholders
        tool: gmail
        adapter: adapters/chat/gmail.md
        to: list@acme.example
        identity: reports@acme.example
        default_mode: draft
        verify: null
EOF
VOUT46="$(bash "$KIT/bin/verify_stack.sh" "$NAI/.claude/config/stack.yaml" --dry-run 2>&1)"; VRC46=$?
{ [ "$VRC46" -ne 0 ] && printf '%s' "$VOUT46" | grep -q 'always_include'; } \
  && ok "an email target with no always_include is REJECTED by verify (the never-solo rule reaches email)" \
  || bad "an email target without always_include verified clean" "rc=$VRC46"
printf 'schema_version: 1\naudience: stakeholders\n' > "$NAI/tk/delivery-plan.yaml"
python3 "$DP46" --root "$NAI" --plan "$NAI/tk/delivery-plan.yaml" --seam chat --quiet > "$TMP/e46.json" 2>/dev/null
E46RC=$?; E46T="$(python3 -c "import json;print(json.load(open('$TMP/e46.json'))['target'])" 2>/dev/null)"
{ [ "$E46RC" -eq 4 ] && [ "$E46T" = "None" ]; } \
  && ok "…and refused at ROUTE time too (exit 4, no target) — enforcement does not require running verify" \
  || bad "a list-less email target routed" "rc=$E46RC target=$E46T"

# --- (F) the sender is enforced and pinned -------------------------------------------------------
# A named email target with NO identity would send as whoever the transport is authenticated as —
# a silent wrong-sender. Refused at audit and at route; a shell-unsafe identity is refused the
# same way; and an identity EDIT after approval trips the fingerprint even though the target name
# still matches.
NID="$TMP/e46-noid"; mkdir -p "$NID/.claude/config" "$NID/tk"
sed '/identity: reports@acme.example/d' "$NAI/.claude/config/stack.yaml" > "$NID/.claude/config/stack.yaml.tmp"
sed 's/^        default_mode: draft$/        always_include: [pm@acme.example]\n        default_mode: draft/' \
  "$NID/.claude/config/stack.yaml.tmp" > "$NID/.claude/config/stack.yaml"
python3 "$DP46" --root "$NID" --audit --quiet > "$TMP/e46-audit.txt" 2>&1; ARC46=$?
{ [ "$ARC46" -ne 0 ] && grep -q 'sender_key' "$TMP/e46-audit.txt"; } \
  && ok "the audit rejects a named email target whose identity is unset, naming sender_key" \
  || bad "an identity-less email target passed the audit" "rc=$ARC46 $(head -1 "$TMP/e46-audit.txt")"
printf 'schema_version: 1\naudience: stakeholders\n' > "$NID/tk/delivery-plan.yaml"
python3 "$DP46" --root "$NID" --plan "$NID/tk/delivery-plan.yaml" --seam chat --quiet > "$TMP/e46.json" 2>/dev/null
E46RC=$?; E46S="$(python3 -c "import json;print(json.load(open('$TMP/e46.json'))['sender'])" 2>/dev/null)"
E46T="$(python3 -c "import json;print(json.load(open('$TMP/e46.json'))['target'])" 2>/dev/null)"
{ [ "$E46RC" -eq 4 ] && [ "$E46T" = "None" ] && [ "$E46S" = "None" ]; } \
  && ok "…and refused at route time (exit 4): mail never goes out as whoever happens to be authenticated" \
  || bad "an identity-less email target routed" "rc=$E46RC target=$E46T"
BID="$TMP/e46-badid"; mkdir -p "$BID/.claude/config" "$BID/tk"
sed 's/identity: reports@acme.example/identity: "x$(id)@acme.example"/' \
  "$NAI/.claude/config/stack.yaml" > "$BID/.claude/config/stack.yaml.tmp"
sed 's/^        default_mode: draft$/        always_include: [pm@acme.example]\n        default_mode: draft/' \
  "$BID/.claude/config/stack.yaml.tmp" > "$BID/.claude/config/stack.yaml"
printf 'schema_version: 1\naudience: stakeholders\n' > "$BID/tk/delivery-plan.yaml"
python3 "$DP46" --root "$BID" --plan "$BID/tk/delivery-plan.yaml" --seam chat --quiet > "$TMP/e46.json" 2>/dev/null
E46RC=$?
E46U="$(python3 -c "import json;print(json.load(open('$TMP/e46.json'))['unsafe'])" 2>/dev/null)"
{ [ "$E46RC" -eq 4 ] && [ "$E46U" = "['identity']" ]; } \
  && ok "a shell-unsafe identity is refused as a sender (the tier-3 injection rule, inherited)" \
  || bad "a shell-unsafe identity was emitted as a sender" "rc=$E46RC unsafe=$E46U"
printf 'schema_version: 1\naudience: stakeholders\n' > "$P46"
r46 --seam chat
FP46="$(g46 "d['resolution_fingerprint']")"
sed 's/identity: reports@acme.example/identity: other-mailbox@acme.example/' \
  "$D46/.claude/config/stack.yaml" > "$TMP/e46-ident.yaml"
python3 "$DP46" --stack "$TMP/e46-ident.yaml" --plan "$P46" --seam chat --expect-target email --quiet >/dev/null 2>&1 \
  && NP46=pass || NP46=refuse
python3 "$DP46" --stack "$TMP/e46-ident.yaml" --plan "$P46" --seam chat \
  --expect-target email --expect-fingerprint "$FP46" --quiet > "$TMP/e46.json" 2>/dev/null
E46RC=$?; E46T="$(python3 -c "import json;print(json.load(open('$TMP/e46.json'))['target'])" 2>/dev/null)"
{ [ "$NP46" = "pass" ] && [ "$E46RC" -eq 8 ] && [ "$E46T" = "None" ]; } \
  && ok "an identity edit passes the NAME pin but the FINGERPRINT refuses — the sender is part of what was approved" \
  || bad "a post-approval identity swap slipped past the pin" "name=$NP46 rc=$E46RC target=$E46T"
# Adapters WITHOUT sender_key are untouched: the slack target still routes, sender stays null.
printf 'schema_version: 1\naudience: internal\n' > "$P46"
r46 --seam chat
{ [ "$R46RC" -eq 0 ] && [ "$(g46 "d['sender']")" = "None" ] && [ "$(g46 "d['sender_key']")" = "None" ]; } \
  && ok "adapters without sender_key are unaffected (slack routes, sender null) — no new required key" \
  || bad "the sender rule leaked onto a non-email adapter" "rc=$R46RC sender=$(g46 "d.get('sender')")"

# --- (G) the draft rail reads ADDRESSES the same way it reads names ------------------------------
printf 'schema_version: 1\naudience: stakeholders\n' > "$P46"
printf 'ENG-1234 shipped. Summary linked. cc pm@acme.example\n' > "$D46/tk/good.md"
printf 'ENG-1234 shipped. Summary linked. cc Alice\n' > "$D46/tk/wrong.md"
r46 --seam chat --check-draft "$D46/tk/good.md"
[ "$R46RC" -eq 0 ] && ok "a draft naming the routed address passes the comms rail" \
  || bad "a correct email draft was rejected" "rc=$R46RC"
r46 --seam chat --check-draft "$D46/tk/wrong.md"
{ [ "$R46RC" -ne 0 ] && [ "$(g46 "d['missing_recipients']")" = "['pm@acme.example']" ]; } \
  && ok "a draft missing the routed address is rejected, naming it — a wrong-audience mail is caught before send" \
  || bad "a draft missing its routed address was accepted" "rc=$R46RC missing=$(g46 "d.get('missing_recipients')")"

# --- (H) include_self on email: the shipper is ADDED, never substituted --------------------------
IS46="$TMP/e46-self"; mkdir -p "$IS46/.claude/config" "$IS46/tk"
sed 's/^        default_mode: draft$/        always_include: [pm@acme.example]\n        include_self: true\n        default_mode: draft/' \
  "$NAI/.claude/config/stack.yaml" > "$IS46/.claude/config/stack.yaml"
printf 'schema_version: 1\naudience: stakeholders\n' > "$IS46/tk/delivery-plan.yaml"
ISOUT="$(python3 "$DP46" --root "$IS46" --plan "$IS46/tk/delivery-plan.yaml" --seam chat --self "alice@acme.example" --quiet 2>/dev/null)"
[ "$(printf '%s' "$ISOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["recipients"])' 2>/dev/null)" = "['pm@acme.example', 'alice@acme.example']" ] \
  && ok "include_self Cc's the shipper IN ADDITION to the stakeholder list, never instead" \
  || bad "include_self did not add the shipper alongside the list" "$ISOUT"

# --- (I) the ONE sanctioned exception stays visible ----------------------------------------------
# Prompt 8's --chat override is explicit, human-invoked, and warned-as-unrecorded. It is inherited
# for email UNCHANGED — pinning it here keeps it a documented exception rather than a quiet hole:
# an override with nothing declared routes AND says the routing is not recorded with the ticket.
printf 'schema_version: 1\n' > "$P46"
r46 --seam chat --override email
{ [ "$R46RC" -eq 0 ] && [ "$(g46 "d['target']")" = "email" ] \
  && printf '%s' "$R46" | grep -q "not recorded"; } \
  && ok "--override email (the one escape hatch) routes and SAYS the routing isn't recorded — visible, not quiet" \
  || bad "the override exception changed shape for email" "rc=$R46RC"

# --- (J) a written `bcc:` is warned about, never silently ignored --------------------------------
# The kit deliberately maps no hidden recipients — but a key someone WROTE reads as a considered
# choice, and honoring it with silence is how config becomes theater (the slot-level
# always_include principle, from the adversarial review of this PR). A WARN, never an error:
# narrowing-only, so existing configs keep validating and routing is unchanged.
BCC46="$TMP/e46-bcc"; mkdir -p "$BCC46/.claude/config" "$BCC46/tk"
cat > "$BCC46/.claude/config/stack.yaml" <<'EOF'
project:
  key_prefix: ENG
seams:
  chat:
    default: internal
    targets:
      internal:
        audience: internal
        tool: slack
        adapter: adapters/chat/slack.md
        default_channel: C1
        always_include: [Alice]
        verify: null
      email:
        audience: stakeholders
        tool: gmail
        adapter: adapters/chat/gmail.md
        to: list@acme.example
        identity: reports@acme.example
        always_include: [pm@acme.example]
        bcc: [hidden@acme.example]
        default_mode: draft
        verify: null
EOF
python3 "$DP46" --root "$BCC46" --audit --quiet > "$TMP/e46-bcc.txt" 2>&1; BRC46=$?
{ [ "$BRC46" -eq 0 ] && grep -q 'warn' "$TMP/e46-bcc.txt" && grep -q 'bcc' "$TMP/e46-bcc.txt"; } \
  && ok "a chat target carrying bcc: audits clean (exit 0) WITH a warn row naming the ignored key" \
  || bad "a written bcc: was silently ignored (or wrongly escalated to an error)" "rc=$BRC46 $(head -1 "$TMP/e46-bcc.txt")"
printf 'schema_version: 1\naudience: stakeholders\n' > "$BCC46/tk/delivery-plan.yaml"
BOUT46="$(python3 "$DP46" --root "$BCC46" --plan "$BCC46/tk/delivery-plan.yaml" --seam chat --quiet 2>/dev/null)"; BRC46=$?
{ [ "$BRC46" -eq 0 ] \
  && [ "$(printf '%s' "$BOUT46" | python3 -c 'import json,sys;print(json.load(sys.stdin)["recipients"])' 2>/dev/null)" = "['pm@acme.example']" ]; } \
  && ok "…and routing is unchanged: exit 0, the bcc value never joins the recipients" \
  || bad "the bcc warn changed routing behavior" "rc=$BRC46"

hdr "47 · docs lead with the team brain + lifecycle (PROMPT 9)"
# The mission and vision sentences are FIXED TEXT: the docs arrange them, never rewrite them.
grep -qF "Ticketwright empowers a team to do a high volume of analysis without letting quality slide, on whatever tools they already use." README.md \
  && ok "README carries the mission sentence verbatim" || bad "mission sentence missing or reworded in README"
grep -qF "Any new or experienced member can pick up any analysis and be productive the same day, because the team's past work is written down and organized, and AI can trace it." README.md \
  && ok "README carries the vision sentence verbatim" || bad "vision sentence missing or reworded in README"
# The lifecycle is the primary map: phases precede the tool-slot list, in both restructured docs.
rl_life="$(grep -n '^## The lifecycle is the map' README.md | head -1 | cut -d: -f1)"
rl_slots="$(grep -n '^| Tool slot | Works with |' README.md | head -1 | cut -d: -f1)"
{ [ -n "$rl_life" ] && [ -n "$rl_slots" ] && [ "$rl_life" -lt "$rl_slots" ]; } \
  && ok "README: the lifecycle section precedes the tool-slot table" \
  || bad "README: lifecycle section missing or placed after the tool-slot table" "life=$rl_life slots=$rl_slots"
al_life="$(grep -n '^## The lifecycle is the primary map' docs/architecture.md | head -1 | cut -d: -f1)"
al_slots="$(grep -n '^## Tool slots, adapters, and the verb contract' docs/architecture.md | head -1 | cut -d: -f1)"
{ [ -n "$al_life" ] && [ -n "$al_slots" ] && [ "$al_life" -lt "$al_slots" ]; } \
  && ok "architecture.md: the lifecycle section precedes the tool-slot section" \
  || bad "architecture.md: lifecycle section missing or placed after the slots section" "life=$al_life slots=$al_slots"
rl_brain="$(grep -n '^## What it builds: a team brain' README.md | head -1 | cut -d: -f1)"
{ [ -n "$rl_brain" ] && [ -n "$rl_life" ] && [ "$rl_brain" -lt "$rl_life" ]; } \
  && ok "README: the team-brain section precedes the lifecycle section" \
  || bad "README: team-brain section missing or placed after the lifecycle section" "brain=$rl_brain life=$rl_life"
# Phase 3's precision marker: quality checking has NO SLOT OF ITS OWN (never "calls no external
# tool" — it borrows the warehouse to re-verify). Both restructured docs must state it.
grep -q 'no slot of its own' README.md && grep -q 'no slot of its own' docs/architecture.md \
  && ok "phase 3's 'no slot of its own' statement present in README and architecture.md" \
  || bad "phase 3 lost its 'no slot of its own' statement (PROMPT 9 precision requirement)"
# The slot-to-phase matrix names all five phases, in both files.
pmiss=""
for ph in "Open the work" "Do the work" "Quality-check" "Deliver" "Announce"; do
  grep -q "$ph" README.md || pmiss="$pmiss README:${ph// /_}"
  grep -q "$ph" docs/architecture.md || pmiss="$pmiss architecture:${ph// /_}"
done
[ -z "$pmiss" ] && ok "all five lifecycle phases are named in README and architecture.md" \
  || bad "a lifecycle phase is missing from the slot-to-phase matrix" "$pmiss"
# Voice audit: marketing filler stays out of user-facing docs. Scope is README + docs/ prose;
# docs/PROMPT-*.md are planning documents and exempt (PLANNED-CHANGES.md, the original planning
# doc, is retired — its exemption became the PROMPT- prefix). 'empower' is allowed only inside the
# verbatim mission sentence (pinned above); the technical noun "agent harness" is not filler and
# is deliberately NOT grepped.
filler="$(grep -rniEw 'robust|comprehensive|seamless|streamline[sd]?|streamlining|unlock(s|ed|ing)?|leverag(e[sd]?|ing)|moreover|furthermore|worth noting' README.md docs/ --include='*.md' | grep -v '^docs/PROMPT-' || true)"
[ -z "$filler" ] && ok "no marketing filler in README + docs/ user-facing prose" \
  || bad "marketing filler in user-facing docs (voice audit, PROMPT 9 rider 1)" "$filler"
emp="$(grep -rni 'empower' README.md docs/ --include='*.md' | grep -v '^docs/PROMPT-' | grep -v 'empowers a team to do a high volume' || true)"
[ -z "$emp" ] && ok "'empower' appears only inside the verbatim mission sentence" \
  || bad "'empower' used outside the mission sentence" "$emp"

hdr "48 · the index commit includes the graph layer (/ship stages what --check gates)"
# The graph layer is generated by the same render pass as the catalog, ignored by nothing, and
# gated by --check just like INDEX.md — so a ship that stages only the three catalog files leaves
# the person-facing rendering behind and reddens the next contributor's CI. Two kinds of check
# below: one MECHANICAL (the gate the instructions lean on really does cover the nodes) and the
# rest PROSE WIRING PINS, the same convention sections 37/45 use — a skill is prose an agent
# executes, so what is testable is that the instruction still SAYS it.

# --- (A) --check gates the graph nodes, and its clean line names what it compared ---------------
G48="$TMP/graph48"; mkdir -p "$G48/.claude/config" "$G48/tickets/alice/ENG-1"
printf 'project:\n  key_prefix: ENG\n' > "$G48/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nx.\n' > "$G48/tickets/alice/ENG-1/README.md"
printf 'SELECT * FROM ANALYTICS.VW_ORDERS;\n' > "$G48/tickets/alice/ENG-1/q.sql"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py >/dev/null 2>&1
# BOTH directories, separately: /ship stages tickets/graph/ AND tickets/objects/, so a gate that
# only covered the ticket stubs would leave half the staged claim unproven.
rm -f "$G48/tickets/graph/alice.ENG-1.md"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 \
  && bad "--check passes with a ticket node missing (the staging instruction rests on this gate)" \
  || ok "--check gates tickets/graph/, so a stub left unstaged is CI drift"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py >/dev/null 2>&1
rm -f "$G48/tickets/objects/ANALYTICS.VW_ORDERS.md"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 \
  && bad "--check passes with an object node missing (half the staged graph layer is ungated)" \
  || ok "--check gates tickets/objects/ too, so an object note left unstaged is CI drift"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py >/dev/null 2>&1
c48="$(CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py --check 2>&1)"
grep -q 'graph layer' <<<"$c48" \
  && ok "--check's clean line names the graph layer it compared" \
  || bad "--check reports only the catalog after comparing the graph nodes too" "$c48"
# ...and stays honest the other way: with the layer off there is no graph to claim.
printf 'project:\n  key_prefix: ENG\n  graph_notes: false\n' > "$G48/.claude/config/stack.yaml"
CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py >/dev/null 2>&1
c48off="$(CLAUDE_PROJECT_DIR="$G48" python3 bin/build_ticket_index.py --check 2>&1)"
grep -q 'graph layer' <<<"$c48off" \
  && bad "--check names a graph layer that graph_notes disabled" "$c48off" \
  || ok "--check omits the graph layer when graph_notes is off"

# --- (B) every instruction that names the index commit names the whole index ---------------------
# Enumerated, not grepped repo-wide: these are the sites that tell a human or an agent WHICH files
# to stage — the two skills, the reference doc, and enrich_ticket.py, whose docstring and completion
# line are the ONE such instruction a person meets without going through a skill at all (it
# re-renders, so it moves the graph layer too). CHANGELOG.md is deliberately absent — history is
# never rewritten (section 38).
IDX48=".claude/skills/ship/SKILL.md .claude/skills/refresh/SKILL.md \
       .claude/skills/refresh/index.md docs/ticket-index.md bin/enrich_ticket.py"
for f in $IDX48; do
  { grep -q 'tickets/graph/' "$f" && grep -q 'tickets/objects/' "$f" \
    && grep -q 'graph_notes' "$f"; } \
    && ok "$f stages the graph layer with the catalog, gated on graph_notes" \
    || bad "$f names only the catalog files in the index commit"
done
u48=""
for f in $IDX48; do
  grep -qiE 'all three' "$f" && u48="$u48 $f"
done
[ -z "$u48" ] && ok "no index-commit instruction still counts the staged set as three" \
  || bad "an index-commit instruction still says 'all three'" "$u48"
# The gate's SCOPE is the easy thing to overstate once the staged list grows: index_data.json is
# the curated INPUT to the render, never in the `fresh` map, so no instruction may promise --check
# covers it. Proven from the code, not from the prose, then required of the prose.
gj48="$TMP/gate48"; mkdir -p "$gj48/.claude/config" "$gj48/tickets/alice/ENG-1"
printf 'project:\n  key_prefix: ENG\n' > "$gj48/.claude/config/stack.yaml"
printf '# ENG-1: x\n\nx.\n' > "$gj48/tickets/alice/ENG-1/README.md"
CLAUDE_PROJECT_DIR="$gj48" python3 bin/build_ticket_index.py >/dev/null 2>&1
# A WELL-FORMED record (load_data keeps only records carrying both owner and id as strings — an
# ownerless one is dropped, which would make this a no-op change and prove nothing). ENG-404 has no
# folder, so it never enters `rows` and the rendering is unchanged: what is left on the table is
# purely the store file's own bytes, which is exactly the thing --check must not be gating.
printf '{"schema_version": 1, "tickets": [{"owner": "alice", "id": "ENG-404", "summary": "no folder on disk"}]}\n' \
  > "$gj48/tickets/index_data.json"
CLAUDE_PROJECT_DIR="$gj48" python3 bin/build_ticket_index.py --check >/dev/null 2>&1 \
  && ok "--check leaves the curated store alone (it is the render's input, not a rendering)" \
  || bad "--check now gates index_data.json — the staging prose says it does not"
{ grep -q 'rendered' .claude/skills/ship/SKILL.md \
  && ! grep -qE '\-\-check.*gates every one of them' .claude/skills/ship/SKILL.md; } \
  && ok "/ship scopes the --check promise to the rendered files" \
  || bad "/ship claims --check covers the curated store too"
# Staging a repo-wide rendering can carry another ticket's row or node: the step must say so.
grep -q 'repo-wide' .claude/skills/ship/SKILL.md \
  && ok "/ship states that the index render is repo-wide before it stages the directories" \
  || bad "/ship stages whole rendered directories without naming the unrelated-diff risk"

# --- (C) the retired asymmetry does not creep back into the docs --------------------------------
a48="$(grep -niE 'staging asymmetry|asymmetry to know' README.md docs/architecture.md || true)"
[ -z "$a48" ] && ok "README + architecture.md no longer document /ship skipping the graph layer" \
  || bad "a doc still describes the retired staging asymmetry" "$a48"
{ grep -q 'tickets/graph/' README.md && grep -q 'tickets/graph/' docs/architecture.md; } \
  && ok "both docs still name the graph paths (the asymmetry was fixed, not deleted)" \
  || bad "the graph paths vanished from README or docs/architecture.md"
hdr "49 · meetings intake + the source-material guard (PROMPT: meetings-intake)"
# The pre-existing intake assertion (section 38 I) greps that files MENTION the words. That is not
# the bar here: this section drives real binaries against fixture trees, because the policy it
# covers — raw meeting transcripts stay out of git and out of a docstore backup — is worth exactly
# what its mechanism is worth. Cases A-E are behavioral; F-H are labeled structural pins and are
# not dressed up as more than that.
S48="$TMP/s48"; mkdir -p "$S48"
SCAN="bin/scan_source_materials.py"
FIX="tests/source_materials/fixtures"

# --- (A) the gitignore policy, executed by git itself ------------------------------------------
# Same harness as section 19: real `git init`, real patterns, real matching semantics. The three
# outcomes below are the whole policy — self-declaring names out, private/ out, curated form IN.
GI48="$S48/gitignore"; mkdir -p "$GI48/tickets/a/ENG-1/source_materials/private"
cp templates/gitignore.tmpl "$GI48/.gitignore"
( cd "$GI48" && git init -q . ) 2>/dev/null
for f in weekly-sync-transcript.md 2026-08-20-pricing-review-meeting.md notes.md; do
  : > "$GI48/tickets/a/ENG-1/source_materials/$f"
done
: > "$GI48/tickets/a/ENG-1/source_materials/private/raw.md"
gi_raw=0;  git -C "$GI48" check-ignore -q tickets/a/ENG-1/source_materials/weekly-sync-transcript.md && gi_raw=1
gi_priv=0; git -C "$GI48" check-ignore -q tickets/a/ENG-1/source_materials/private/raw.md && gi_priv=1
gi_cur=0;  git -C "$GI48" check-ignore -q tickets/a/ENG-1/source_materials/2026-08-20-pricing-review-meeting.md && gi_cur=1
{ [ "$gi_raw" -eq 1 ] && [ "$gi_priv" -eq 1 ] && [ "$gi_cur" -eq 0 ]; } \
  && ok "gitignore: *transcript* and private/ are ignored, the curated *-meeting.md commits" \
  || bad "the source-material gitignore policy is wrong" \
         "transcript=$gi_raw private=$gi_priv curated_ignored=$gi_cur"
# The shape-only transcript is deliberately NOT covered by any pattern — that gap is the whole
# reason the guard exists, and asserting it keeps the two mechanisms honest about their division.
gi_shape=0; git -C "$GI48" check-ignore -q tickets/a/ENG-1/source_materials/notes.md && gi_shape=1
[ "$gi_shape" -eq 0 ] \
  && ok "a shape-only transcript (notes.md) is NOT gitignored — the guard's job, not a pattern's" \
  || bad "notes.md is gitignored, so the guard's stated reason for existing is wrong"

# --- (B) classification against the golden corpus ----------------------------------------------
# The corpus carries the two cases that decide whether the heuristic is real: a curated-NAMED file
# whose body is a transcript (content must beat filename) and ordinary timestamped notes (must not
# trip). tests/source_materials/README.md explains each fixture.
python3 - <<'EOF' >"$TMP/hd6051.out" 2>&1
import json, sys
sys.path.insert(0, "bin")
import scan_source_materials as s
golden = json.load(open("tests/source_materials/golden.json"))
from pathlib import Path
bad = []
for name, want in golden.items():
    got = s.classify_path(Path("tests/source_materials/fixtures") / name)
    if got["kind"] != want["kind"]:
        bad.append(f"{name}: want {want['kind']}, got {got['kind']}")
print("; ".join(bad))
EOF
c48="$(cat "$TMP/hd6051.out")"
[ -z "$c48" ] && ok "classifier matches the golden corpus on every fixture" \
  || bad "classifier drifted from tests/source_materials/golden.json" "$c48"
k48() { python3 -c "
import sys; sys.path.insert(0,'bin')
import scan_source_materials as s
from pathlib import Path
print(s.classify_path(Path('$FIX/$1'))['kind'])"; }
[ "$(k48 2026-08-20-roadmap-sync-meeting.md)" = "raw_suspect" ] \
  && ok "COLLISION: a curated-NAMED full transcript is raw_suspect (content beats filename)" \
  || bad "a transcript defeats the gate by adopting the curated filename"
[ "$(k48 notes.md)" = "raw_suspect" ] \
  && ok "SHAPE: a transcript with an innocuous filename is caught by content" \
  || bad "a transcript named notes.md passes — the gate is filename-only"
# The caption formats. VTT is what the major meeting platforms export by default, and its
# timestamp and speaker sit on DIFFERENT lines — every same-line speaker pattern misses it. Both
# spellings are pinned: named .vtt (extension rule) and stripped-and-renamed (cue-count rule).
[ "$(k48 weekly-sync.vtt)" = "raw_suspect" ] \
  && ok "CAPTION: a .vtt export is raw_suspect (the platforms' default download)" \
  || bad "a WebVTT transcript passes the gate"
[ "$(k48 recording-export.txt)" = "raw_suspect" ] \
  && ok "CAPTION: a headerless VTT renamed .txt is caught by cue-line count alone" \
  || bad "a renamed caption file passes — the cue rule is not working"
[ "$(k48 standup-notes.md)" = "other" ] \
  && ok "FALSE POSITIVE: ordinary timestamped meeting notes are NOT flagged" \
  || bad "ordinary meeting notes trip the shape test — the gate cries wolf"
[ "$(k48 2026-08-20-pricing-review-meeting.md)" = "curated" ] \
  && ok "a curated summary that QUOTES a transcript briefly stays curated" \
  || bad "a curated excerpt is flagged — the policy's committed form would be blocked"

# --- (C) the exit-code contract (what /ship branches on) ---------------------------------------
EX48="$S48/exit/source_materials"; mkdir -p "$EX48"
cp "$FIX/standup-notes.md" "$EX48/"
python3 "$SCAN" --root "$S48/exit" >/dev/null 2>&1 \
  && ok "clean source material exits 0" || bad "a clean ticket exits non-zero"
cp "$FIX/notes.md" "$EX48/"
python3 "$SCAN" --root "$S48/exit" >/dev/null 2>&1 \
  && bad "a raw_suspect present and the scanner still exits 0 — nothing can gate on it" \
  || ok "a raw_suspect exits non-zero (the signal /ship halts on)"
python3 "$SCAN" --root "$S48/exit" --intake >/dev/null 2>&1 \
  && ok "--intake REPORTS rather than gates (exit 0 even with a raw_suspect present)" \
  || bad "--intake gates, so priming could be failed by material it merely declined to read"

# --- (D) the priming path, end to end ----------------------------------------------------------
# The prompt requires this one by name: drive a fixture ticket carrying a *-meeting.md through the
# priming path and prove the file is picked up. `--intake` is that path's executable consumer, so
# the naming convention is enforced by code rather than approximated from prose.
PR48="$S48/prime/tickets/alice/ENG-7/source_materials"; mkdir -p "$PR48"
cp "$FIX/2026-08-20-pricing-review-meeting.md" "$FIX/notes.md" "$FIX/forwarded-thread.md" "$PR48/"
pj="$(python3 "$SCAN" --root "$S48/prime" --ticket tickets/alice/ENG-7 --intake --json)"
grep -q '2026-08-20-pricing-review-meeting.md' <<<"$pj" \
  && ok "priming picks up the curated *-meeting.md from a fixture ticket's source_materials/" \
  || bad "the required behavioral priming case fails: the meeting file is not enumerated" "$pj"
grep -q 'forwarded-thread.md' <<<"$pj" \
  && ok "priming still picks up non-meeting intake (the email/chat channels keep working)" \
  || bad "widening intake to meetings dropped the other channels"
python3 -c "
import json,sys
d = json.load(open('$S48/prime.json')) if False else json.loads(sys.stdin.read())
names = [f['name'] for f in d['files']]
sys.exit(0 if 'notes.md' not in names else 1)" <<<"$pj" \
  && ok "priming OMITS a raw transcript — a full transcript never enters context by default" \
  || bad "priming would read a raw transcript into context"
# The consumer must actually be wired into the skill, or the CLI is a test-only artifact.
{ grep -q 'scan_source_materials.py' .claude/skills/ticket/priming.md \
  && grep -q 'meetings' .claude/skills/ticket/priming.md; } \
  && ok "priming.md calls the enumerator and names the meetings channel" \
  || bad "priming.md does not consume the meetings intake channel"

# --- (E) the guard, via its real stdin -> stdout protocol --------------------------------------
# This is the case that proves the gate is a gate rather than a paragraph. A configured fixture
# repo, real payloads, and the two bypasses the design exists to close.
GD48="$S48/guard"; mkdir -p "$GD48/.claude/config" "$GD48/tickets/a/ENG-1/source_materials"
printf 'project:\n  key_prefix: ENG\npolicies:\n  db_write_requires_approval: high_risk\n' \
  > "$GD48/.claude/config/stack.yaml"
( cd "$GD48" && git init -q . ) 2>/dev/null
cp "$FIX/notes.md" "$GD48/tickets/a/ENG-1/source_materials/"
guard48() { printf '%s' "$1" | python3 .claude/hooks/source_material_guard.py 2>/dev/null; }
g_add="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$GD48\"}")"
grep -q '"permissionDecision": "ask"' <<<"$g_add" \
  && ok 'guard ASKS on a git add when a shape-only transcript is staged (bypass 1 closed)' \
  || bad "git add of a raw transcript is not gated" "$g_add"
g_cp="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -r $GD48/tickets/a/ENG-1 /d/x\"},\"cwd\":\"$GD48\"}")"
grep -q '"permissionDecision": "ask"' <<<"$g_cp" \
  && ok 'guard ASKS on the docstore cp -r (bypass 2 — the productized path — closed)' \
  || bad "a folder-wide docstore backup of a raw transcript is not gated" "$g_cp"
# Path narrowing must never turn into a silent pass: when the parsed paths land OUTSIDE the repo
# (an unexpanded ~, a variable, a glob, with a destination that happens to exist), the guard falls
# back to every flagged file rather than filtering them all away.
g_cpv="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -r \$TICKET $TMP\"},\"cwd\":\"$GD48\"}")"
grep -q '"permissionDecision": "ask"' <<<"$g_cpv" \
  && ok "an unparsed copy source with an existing destination still gates (no silent pass)" \
  || bad "path narrowing filtered every finding away — a copy passes in silence" "$g_cpv"
grep -q 'private/' <<<"$g_cp" && grep -qi 'does not apply to' <<<"$g_cp" \
  && ok "the copy prompt says private/ does NOT protect a cp -r (the remedies are not the same)" \
  || bad "the copy prompt offers the git remedy for a docstore exposure"
# The guard must NOT assume the repo's .gitignore matches the kit's shipped template: an install
# predating those patterns would stage a self-declaring transcript in silence. A plain `git add`
# (no -f) over a *transcript*-named file must still ask.
cp "$FIX/weekly-sync-transcript.md" "$GD48/tickets/a/ENG-1/source_materials/"
g_ign="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$GD48\"}")"
grep -q 'weekly-sync-transcript.md' <<<"$g_ign" \
  && ok "a *transcript* file is asked about on a PLAIN git add (no shipped-gitignore assumption)" \
  || bad "the guard assumes the repo's gitignore — a migrating install stages it silently" "$g_ign"
rm "$GD48/tickets/a/ENG-1/source_materials/weekly-sync-transcript.md"
# Jurisdiction evasion: a flags-only alternation missed `git -C <path> add` and `git stage`,
# both of which stage exactly the same way. Each spelling is pinned, because the failure mode of
# a too-narrow pattern is a SILENT pass — the transcript goes in and nothing says so.
for spell in "git -C $GD48 add -A" "git stage ." "git -C $GD48 commit -am x" "git commit -a -m x"; do
  g_ev="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$spell\"},\"cwd\":\"$GD48\"}")"
  grep -q '"permissionDecision": "ask"' <<<"$g_ev" \
    && ok "guard catches the staging spelling: $spell" \
    || bad "a staging spelling evades the guard: $spell" "$g_ev"
done
# ...and read-only git commands are still none of its business — INCLUDING ones whose option
# VALUES contain a staging word. A broad substring match fires on all four of these, and on a
# deny-only runtime that turns `git log` into a blocked command. The subcommand is parsed, so the
# only thing that counts is the subcommand.
for ro in "git log --oneline" "git log --grep=commit" "git show --format=commit HEAD" \
          "git config --get user.commit" "git diff HEAD -- add.py" "git status"; do
  g_ro="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$ro\"},\"cwd\":\"$GD48\"}")"
  [ -z "$g_ro" ] && ok "guard ignores a read-only git command: $ro" \
    || bad "guard fires on a read-only git command: $ro" "$g_ro"
done
rm "$GD48/tickets/a/ENG-1/source_materials/notes.md"
cp "$FIX/standup-notes.md" "$GD48/tickets/a/ENG-1/source_materials/"
g_clean="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$GD48\"}")"
[ -z "$g_clean" ] && ok "guard is SILENT on a clean ticket (no false prompt)" \
  || bad "guard prompts on ordinary meeting notes" "$g_clean"
g_ls="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"$GD48\"}")"
[ -z "$g_ls" ] && ok "guard is silent outside its jurisdiction (a non-staging, non-copy command)" \
  || bad "guard fires on an unrelated command" "$g_ls"
g_out="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$TMP\"}")"
[ -z "$g_out" ] && ok "guard is repo-gated: no output outside a configured repo" \
  || bad "guard fires outside a ticketwright repo" "$g_out"
printf 'not json' | python3 .claude/hooks/source_material_guard.py >"$S48/mal.out" 2>/dev/null
mal_rc=$?
{ [ "$mal_rc" -eq 0 ] && [ ! -s "$S48/mal.out" ]; } \
  && ok "guard FAILS OPEN on malformed input (exit 0, no output — never blocks a session)" \
  || bad "guard does not fail open" "rc=$mal_rc out=$(cat "$S48/mal.out")"
# `off` is an explicit operator instruction and must be readable without the classifier.
printf 'project:\n  key_prefix: ENG\npolicies:\n  source_material_guard: off\n' \
  > "$GD48/.claude/config/stack.yaml"
cp "$FIX/notes.md" "$GD48/tickets/a/ENG-1/source_materials/"
g_off="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$GD48\"}")"
[ -z "$g_off" ] && ok "policies.source_material_guard: off silences the guard" \
  || bad "the off switch does not work" "$g_off"
# ...but an UNPARSEABLE value must gate MORE, never less (the db_write_requires_approval asymmetry).
printf 'project:\n  key_prefix: ENG\npolicies:\n  source_material_guard: banana\n' \
  > "$GD48/.claude/config/stack.yaml"
g_junk="$(guard48 "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"$GD48\"}")"
grep -q '"permissionDecision": "ask"' <<<"$g_junk" \
  && ok "an unrecognized policy value resolves to ON — parse failure gates MORE" \
  || bad "an unparseable policy value silences the guard (the asymmetry runs the wrong way)"

# --- (E2) an INCOMPLETE scan gates: coverage that ran out never reads as clean -----------------
# The bound exists for the hook budget, but a truncated scan that reports `other` is
# indistinguishable from a clean one — the exact silent pass this guard exists to prevent. A tree
# larger than the cap must gate on its OWN account, with no raw_suspect present at all.
LIM48="$TMP/s48-limit"; LS48="$LIM48/tickets/a/ENG-1/source_materials/deep"
mkdir -p "$LIM48/.claude/config" "$LS48"
printf 'project:\n  key_prefix: ENG\n' > "$LIM48/.claude/config/stack.yaml"
python3 -c "
from pathlib import Path
import sys
sys.path.insert(0, 'bin')
import scan_source_materials as s
d = Path('$LS48')
for i in range(s.MAX_FILES + 100):
    (d / f'pad-{i:05d}.txt').write_text('x')
"
lim_out="$(python3 "$SCAN" --root "$LIM48" 2>&1)"
grep -q '^incomplete' <<<"$lim_out" \
  && ok "a tree past the scan cap reports INCOMPLETE (not silently 'other')" \
  || bad "an over-cap scan does not report incomplete coverage"
[ "$(grep -c 'raw_suspect' <<<"$lim_out")" -eq 0 ] \
  && ok "the limit fixture holds no raw_suspect — incomplete gates on its own account" \
  || bad "the limit fixture is contaminated; it cannot prove incomplete gates alone"
python3 "$SCAN" --root "$LIM48" >/dev/null 2>&1 \
  && bad "an INCOMPLETE scan exits 0 — /ship would treat 'not looked at' as 'nothing there'" \
  || ok "an INCOMPLETE scan exits non-zero (it does not certify the tree)"
g_lim="$(printf '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"cwd\":\"%s\"}' "$LIM48" \
  | python3 .claude/hooks/source_material_guard.py 2>/dev/null)"
grep -q '\"permissionDecision\": \"ask\"' <<<"$g_lim" && grep -qi 'did NOT cover' <<<"$g_lim" \
  && ok "the guard ASKS on incomplete coverage, naming it as coverage rather than a finding" \
  || bad "incomplete coverage passes the guard silently" "$g_lim"

# --- (F) structural pin: the callers exist where the hook cannot reach --------------------------
{ grep -q 'scan_source_materials.py' .claude/skills/ship/SKILL.md \
  && grep -q 'scan_source_materials.py' templates/productized-skill/SKILL.md.tmpl; } \
  && ok "pin: /ship and the productized template both call the scanner" \
  || bad "a workflow that backs up + commits does not call the scanner"
ship48="$(grep -c 'scan_source_materials.py' .claude/skills/ship/SKILL.md || true)"
[ "${ship48:-0}" -ge 2 ] \
  && ok "pin: /ship scans at BOTH risk points (before the backup and before staging)" \
  || bad "/ship scans at only one risk point (found $ship48)"

# --- (G) structural pin: one intake question, not two ------------------------------------------
IV48=".claude/skills/setup/interview.md"
{ grep -q 'meetings' "$IV48" && grep -qi 'never a new one' "$IV48"; } \
  && ok "pin: the meetings option rides round 4's existing intake question" \
  || bad "the meetings option is not stated as an addition to the existing question"
[ "$(grep -c '^14\. \*\*Email' "$IV48")" -eq 1 ] \
  && ok "pin: round 4 still has exactly one intake/delivery question" \
  || bad "round 4's single intake question was split"

# --- (H) structural pin: the enforcement table carries the new column ---------------------------
enf48=""
for r in "Claude Code" "Codex CLI" "Cursor" "Antigravity" "OpenCode" "Devin" "Cline"; do
  line="$(grep "^| $r |" templates/AGENTS.md.tmpl || true)"
  [ "$(awk -F'|' '{print NF}' <<<"$line")" -eq 9 ] || enf48="$enf48 ${r// /_}"
done
[ -z "$enf48" ] \
  && ok "pin: every runtime row carries a source_material_guard cell" \
  || bad "a runtime row is missing the new enforcement column" "$enf48"
# Read the block as one flowed string: the honesty sentence wraps across lines, and a
# line-oriented grep would pass or fail on where the author happened to break it.
enf_flat="$(tr '\n' ' ' < templates/AGENTS.md.tmpl)"
{ # A runtime whose wiring must be done BY HAND still has to be told to wire both guards; an
# instruction naming only db_write_guard leaves source-material staging silent for that user.
mw48="$(grep -n 'hook_shim.py --runtime .* --hook db_write_guard' templates/AGENTS.md.tmpl || true)"
[ -z "$mw48" ] \
  && ok "the manual-wiring lines name --hook shell_guards (both guards), not just the DB guard" \
  || bad "a manual-wiring instruction wires only db_write_guard" "$mw48"
grep -q 'source_material_guard' templates/AGENTS.md.tmpl \
  && grep -qi 'it sees \*\*Bash\*\*' <<<"$enf_flat" \
  && grep -qi 'document shape, never *\*\*meaning\*\*' <<<"$enf_flat"; } \
  && ok "pin: the table states the guard's jurisdiction limit (Bash; shape, not meaning)" \
  || bad "the enforcement table omits the guard or its honest limits"
# The DB guard has the SAME limit and, until now, no pin — which is exactly how README prose grew
# an "inspects every warehouse command" overclaim while the hook gated Bash payloads only. Pin the
# sentence AND its honest consequence, mirroring the source_material_guard pin above.
{ grep -qi 'db_write_guard[^ ]* has the same jurisdiction limit' <<<"$enf_flat" \
  && grep -qi 'guidance the agent follows, not a gate the runtime enforces' <<<"$enf_flat"; } \
  && ok "pin: the table states db_write_guard's jurisdiction (Bash only; MCP SQL never reaches it)" \
  || bad "the enforcement table omits db_write_guard's Bash-only jurisdiction"
# Pre-install honesty: the hooks ship WITH the plugin, so the rendered doc must name the install
# command and say the table is guidance until it runs — the first, uninstalled session is exactly
# the one where a newcomer pokes at the warehouse.
{ grep -q 'claude plugin install ticketwright@ticketwright' templates/AGENTS.md.tmpl \
  && grep -q '/ticketwright:ticket' templates/AGENTS.md.tmpl; } \
  && ok "pin: the template names the plugin-install command and the namespaced skill form" \
  || bad "the template lost the pre-install note or the /ticketwright: namespacing line"
# Both shell guards must be wired wherever ONE of them is — a runtime with half the gate is worse
# than one with none, because the table would read as protection.
# The emitters must wire ONE entry covering both guards (`--hook shell_guards`), never two array
# entries. Whether a runtime executes every element of a hook array is undocumented, and a WIRED
# cell resting on that assumption would be an overclaim — one entry removes the assumption.
for f in bin/emit_runtime.py bin/opencode_tool_gate.js; do
  grep -q 'shell_guards' "$f" \
    && ok "$f wires both shell guards through one hook entry (no array-ordering assumption)" \
    || bad "$f does not use the combined shell_guards hook"
  grep -q '"source_material_guard", tool' "$f" \
    && bad "$f still emits a SECOND array entry — the WIRED cells would rest on an assumption" \
    || ok "$f emits no separate source_material_guard array entry"
done
# Set this check's OWN state rather than inheriting whatever the policy tests above left behind.
SG48="$TMP/s48-combined"; mkdir -p "$SG48/.claude/config" "$SG48/tickets/a/ENG-1/source_materials"
printf 'project:\n  key_prefix: ENG\n' > "$SG48/.claude/config/stack.yaml"
cp "$FIX/notes.md" "$SG48/tickets/a/ENG-1/source_materials/"
sg48="$(printf '{"tool_name":"Bash","tool_input":{"command":"git add -A"},"cwd":"%s"}' "$SG48" \
  | python3 bin/hook_shim.py --runtime cursor --hook shell_guards 2>/dev/null || true)"
grep -q '"permission": "ask"' <<<"$sg48" \
  && ok "the combined shell_guards hook surfaces a source-material verdict (not just SQL)" \
  || bad "shell_guards does not reach the source-material guard" "$sg48"


hdr "50 · docstore without a mount: the rclone adapter + drive-mount guidance"
# A docstore that needs a desktop sync agent is unavailable to anyone who cannot run one (Linux has
# no Drive for Desktop client at all). rclone fills the slot with no mount — which moves the tier-3
# hole from "where is it mounted" to "which ACCOUNT does this alias reach", a redirect that ships a
# client deliverable somewhere nobody approved. Everything here is the existing machinery inherited
# by one new adapter: the destination is still composed from a team half + a machine half, still
# metachar-refused, still fingerprinted.
RC="adapters/docstore/rclone.md"

# --- (A) frontmatter: the tier split is declared, not implied ------------------------------------
python3 - <<'PY' >"$TMP/hd6327.out"
import sys
sys.path.insert(0, "bin")
import _yamlite
f = "adapters/docstore/rclone.md"
try:
    fm, _ = _yamlite.parse_frontmatter(open(f, encoding="utf-8").read(), f)
except Exception as exc:
    print(f"unparseable: {exc}"); raise SystemExit
bad = []
if fm.get("seam") != "docstore": bad.append("seam")
if fm.get("tool") != "rclone": bad.append("tool")
if fm.get("destination_key") != "remote_path": bad.append("destination_key")
if fm.get("user_keys") != ["remote"]: bad.append(f"user_keys={fm.get('user_keys')!r}")
for k in ("remote_path", "target_sentinel"):
    if k not in (fm.get("requires") or []): bad.append(f"requires:{k}")
print(" ".join(bad))
PY
rc_fm="$(cat "$TMP/hd6327.out")"
[ -z "$rc_fm" ] \
  && ok "rclone.md declares destination_key: remote_path (team) + user_keys: [remote] (machine)" \
  || bad "rclone.md frontmatter wrong — the tier split is what keeps a destination reviewable" "$rc_fm"

# --- (B) both docstore verbs BY NAME, across every docstore adapter ------------------------------
# Section 2 proves each adapter has the right NUMBER of verb headings, not the right ONES — two
# typo'd verbs count two and pass. (the chat-seam precedent, section 46A)
for v in backup link_for; do
  dvmiss=""
  for f in adapters/docstore/*.md; do
    grep -qE "^## verb: $v( |$)" "$f" || dvmiss="$dvmiss $(basename "$f")"
  done
  [ -z "$dvmiss" ] && ok "every docstore adapter names verb $v exactly" \
    || bad "docstore adapter(s) miss or misspell verb $v" "$dvmiss"
done

# --- (C) copy never deletes, and every destination comes from {base_path} ----------------------
# Asserted on TOKENIZED runnable commands, not on prose and not on the raw string. Three traps this
# avoids: grepping the whole verb section lets the PROSE that bans `sync` satisfy the check that
# bans it; a line-anchored match misses `rclone --progress sync`; and shell quoting (`rclone
# "sync"`) or an escape (`s\ync`) slips past any bare pattern. So parse the fences and shlex them.
python3 - <<'PYC' >"$TMP/hd6367.out"
import json, re, shlex
t = open("adapters/docstore/rclone.md", encoding="utf-8").read()
DESTRUCTIVE = {"sync", "move", "moveto", "delete", "deletefile", "rmdir", "rmdirs", "purge"}
rep = {"cmds": [], "destructive": [], "delete_flags": [], "dest_missing": [], "handbuilt": []}
for verb in ("backup", "link_for"):
    if f"## verb: {verb}" not in t:
        rep["dest_missing"].append(f"{verb}:section-missing"); continue
    body = re.split(r"^## ", t.split(f"## verb: {verb}", 1)[1], flags=re.M)[0]
    mine = []
    # fenced blocks: ``` or ~~~, tolerating up to 3 leading spaces and a blockquote marker
    for i, chunk in enumerate(re.split(r"^[ ]{0,3}>?[ ]*(?:```|~~~).*$", body, flags=re.M)):
        if i % 2 == 0:
            continue
        for raw in chunk.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            mine.append(line); rep["cmds"].append(f"{verb}: {line}")
            try:
                toks = shlex.split(line)          # resolves quotes AND backslash escapes
            except ValueError:
                toks = line.split()
            for j, tok in enumerate(toks):
                if tok.rsplit("/", 1)[-1] != "rclone":
                    continue
                rest = [x for x in toks[j+1:] if not x.startswith("-")]
                if rest and rest[0] in DESTRUCTIVE:
                    rep["destructive"].append(f"{verb}: {line}")
            for tok in toks:
                if re.match(r"^--delete(-during|-before|-after|-excluded)?(=.*)?$", tok):
                    rep["delete_flags"].append(f"{verb}: {tok}")
            if "{remote}:{remote_path}" in line:
                rep["handbuilt"].append(f"{verb}: {line}")
    if "{base_path}" not in " ".join(mine):
        rep["dest_missing"].append(verb)
print(json.dumps(rep))
PYC
rc_verbs="$(cat "$TMP/hd6367.out")"
rcq() { printf '%s' "$rc_verbs" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))" "$1"; }
grep -q '"backup: rclone' <<<"$rc_verbs" && grep -q 'copy' <<<"$rc_verbs" \
  && ok "the backup verb's runnable command is \`rclone copy\`" \
  || bad "no runnable \`rclone copy\` in the backup verb" "$(rcq cmds)"
[ "$(rcq destructive)" = "[]" ] \
  && ok "no destructive rclone verb (sync/move/delete/rmdir/purge) is runnable in EITHER verb" \
  || bad "a runnable command can delete remote content that predates the backup" "$(rcq destructive)"
[ "$(rcq delete_flags)" = "[]" ] \
  && ok "…and no --delete* flag appears, in space or = form" \
  || bad "a delete-capable flag is runnable in a verb" "$(rcq delete_flags)"
grep -q 'dry-run' <<<"$rc_verbs" \
  && ok "backup dry-runs first, as a real command (the plan shows its output)" \
  || bad "the backup verb has no runnable --dry-run preview" "$(rcq cmds)"
# EVERY destination-bearing verb reads the composed value: that identity is what keeps the executed
# target equal to the fingerprinted one, including when a team pins base_path literally.
[ "$(rcq dest_missing)" = "[]" ] \
  && ok "both backup and link_for take their destination from {base_path}" \
  || bad "a verb builds its own destination instead of the composed {base_path}" "$(rcq dest_missing)"
[ "$(rcq handbuilt)" = "[]" ] \
  && ok "…and no runnable command hand-builds {remote}:{remote_path}, which would bypass the fingerprint" \
  || bad "a runnable command hand-builds the remote prefix" "$(rcq handbuilt)"
grep -qi 'non-deleting, not non-destructive' "$RC" \
  && ok "rclone.md states copy is non-deleting, NOT non-destructive (it overwrites same-name files)" \
  || bad "rclone.md overclaims copy's safety — it must say same-name files are overwritten"

# --- (D) a poisoned tier-3 remote is refused AT VERIFY -------------------------------------------
# `remote` is the one value a gitignored file supplies, so it is the injection surface. It reaches
# the verify template, so unsafe_tokens must refuse it and verify_stack must run nothing.
RCP50="$TMP/rclone-poison"; mkdir -p "$RCP50/.claude/config" "$RCP50/tk"
cat > "$RCP50/.claude/config/stack.yaml" <<'YAML'
schema_version: 1
project:
  key_prefix: ENG
seams:
  docstore:
    default: archive
    targets:
      archive:
        classification: internal_archive
        sharing_scope: team
        tool: rclone
        adapter: adapters/docstore/rclone.md
        transport: cli
        remote_path: "eng-archive"
        target_sentinel: "eng-sentinel-01"
        verify: "test \"$(rclone cat \"{base_path}/.ticketwright-target\")\" = \"{target_sentinel}\""
YAML
printf 'schema_version: 1\nclassification: internal_archive\n' > "$RCP50/tk/delivery-plan.yaml"
# Tie the fixture to the SHIPPED adapter: its auth block documents the verify command, and if that
# drifts from what these tests exercise, the tests stop proving anything about the real adapter.
# Compare the WHOLE command on both sides, parsed rather than grep-fragmented: a substring match
# would stay green while text before or after the fragment drifted.
python3 - "$RCP50/.claude/config/stack.yaml" <<'PYV' >"$TMP/hd6458.out"
import re, sys
sys.path.insert(0, "bin")
import _yamlite
fm, _ = _yamlite.parse_frontmatter(open("adapters/docstore/rclone.md", encoding="utf-8").read(),
                                   "rclone.md")
m = re.search(r"^\s*Verify:\s*`(.+?)`\.?\s*$", fm.get("auth") or "", re.M)
documented = m.group(1).strip() if m else ""
cfg = _yamlite.parse_file(sys.argv[1])
node = cfg["seams"]["docstore"]
node = node["targets"][sorted(node["targets"])[0]] if "targets" in node else node
fixture = (node.get("verify") or "").strip()
print("MATCH" if documented and documented == fixture
      else f"DRIFT documented=[{documented}] fixture=[{fixture}]")
PYV
vfy_cmp="$(cat "$TMP/hd6458.out")"
[ "$vfy_cmp" = "MATCH" ] \
  && ok "the fixture's verify is the COMPLETE command rclone.md documents (no test/ship drift)" \
  || bad "the rclone fixture and the adapter's documented verify have diverged" "$vfy_cmp"
rc_local() { printf 'person: alice\nseams:\n  docstore:\n    targets:\n      archive:\n        remote: %s\n' "$1" \
               > "$RCP50/.claude/config/connections.local.yaml"; }
PWNED="$TMP/RCLONE_PWNED"
rc_local "\"x; touch $PWNED\""
rcv="$(CLAUDE_PLUGIN_ROOT="$KIT" python3 "$KIT/bin/effective_config.py" --root "$RCP50" --seam docstore 2>/dev/null)"
{ printf '%s' "$rcv" | python3 -c 'import json,sys; d=json.load(sys.stdin); u=d.get("unsafe") or []; raise SystemExit(0 if d.get("verify") is None and ("remote" in u or "base_path" in u) else 1)'; } \
  && ok "a tier-3 remote carrying shell metacharacters is refused at verify (verify nulled, flagged unsafe)" \
  || bad "a poisoned tier-3 remote survived verify resolution" "$rcv"
o="$(CLAUDE_PLUGIN_ROOT="$KIT" bash "$KIT/bin/verify_stack.sh" "$RCP50/.claude/config/stack.yaml" --dry-run 2>&1)"
grep -q 'refusing to run' <<<"$o" \
  && ok "verify_stack refuses to execute the poisoned rclone verify" \
  || bad "verify_stack did not refuse the poisoned rclone verify" "$o"
[ ! -e "$PWNED" ] && ok "…and nothing executed: the injection artifact was never created" \
  || bad "INJECTION EXECUTED — the poisoned remote ran a command"

# --- (E) …and the same value cannot reach a ROUTED backup ---------------------------------------
DP50="$KIT/bin/delivery_plan.py"
r50="$(python3 "$DP50" --root "$RCP50" --plan "$RCP50/tk/delivery-plan.yaml" --seam docstore --quiet 2>/dev/null)"; rc50=$?
{ [ "$rc50" -eq 4 ] \
  && printf '%s' "$r50" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("resolution_fingerprint") is None and d.get("destination") is None and d.get("unsafe") else 1)'; } \
  && ok "a poisoned remote is unroutable too: exit 4, no destination, no fingerprint" \
  || bad "a poisoned remote reached routing" "rc=$rc50 $r50"

# --- (F) a tier-3 REDIRECT moves the fingerprint ------------------------------------------------
# The whole point. A remote name is a personal alias, so re-pointing it after an approval is a
# silent redirect UNLESS the resolved destination (which carries the remote) is fingerprinted.
fp50() {
  rc_local "$1"
  python3 "$DP50" --root "$RCP50" --plan "$RCP50/tk/delivery-plan.yaml" --seam docstore --quiet 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("resolution_fingerprint"),d.get("destination"))'
}
f_team="$(fp50 teamdrive)"; f_other="$(fp50 attacker-drive)"
{ [ -n "${f_team%% *}" ] && [ "$f_team" != "$f_other" ]; } \
  && ok "re-pointing the tier-3 remote changes the routed destination AND the fingerprint" \
  || bad "a tier-3 remote swap left the fingerprint unchanged — a redirect would go undetected" \
         "team=$f_team other=$f_other"
grep -q 'teamdrive:eng-archive' <<<"$f_team" \
  && ok "the routed destination is the composed \`{remote}:{remote_path}\`, not the bare path" \
  || bad "the routed rclone destination does not carry the remote" "$f_team"
rc_local teamdrive
approved="$(python3 "$DP50" --root "$RCP50" --plan "$RCP50/tk/delivery-plan.yaml" --seam docstore --quiet 2>/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin)["resolution_fingerprint"])')"
rc_local attacker-drive
python3 "$DP50" --root "$RCP50" --plan "$RCP50/tk/delivery-plan.yaml" --seam docstore \
        --expect-fingerprint "$approved" --quiet >/dev/null 2>&1
[ "$?" -eq 8 ] && ok "--expect-fingerprint REFUSES after the remote is re-pointed (exit 8)" \
  || bad "--expect-fingerprint accepted a redirected remote"

# --- (F2) what is fingerprinted is what EXECUTES ------------------------------------------------
# The hole this pins: `_compose_paths` skips when `base_path` is set literally in team config. If
# the adapter's commands built `{remote}:{remote_path}` by hand, routing would fingerprint the
# static base_path while the upload went to the tier-3 remote — so re-pointing the alias after an
# approval would pass `--expect-fingerprint`. The adapter interpolating {base_path} everywhere is
# what closes it, and block C pins that; this asserts the config-level consequence.
LITP="$TMP/rclone-literal"; mkdir -p "$LITP/.claude/config" "$LITP/tk"
sed 's|remote_path: "eng-archive"|remote_path: "eng-archive"\n        base_path: "pinned:by-team"|' \
  "$RCP50/.claude/config/stack.yaml" > "$LITP/.claude/config/stack.yaml"
cp "$RCP50/tk/delivery-plan.yaml" "$LITP/tk/delivery-plan.yaml"
litfp() {
  printf 'person: alice\nseams:\n  docstore:\n    targets:\n      archive:\n        remote: %s\n' "$1" \
    > "$LITP/.claude/config/connections.local.yaml"
  python3 "$DP50" --root "$LITP" --plan "$LITP/tk/delivery-plan.yaml" --seam docstore --quiet 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("destination"))'
}
# A team-committed base_path is a TEAM decision and reviewable in git, so it legitimately wins the
# destination. What must hold is that the adapter cannot then execute somewhere else: every runnable
# command reads {base_path}, so the executed target and the fingerprinted one are the same string.
[ "$(litfp teamdrive)" = "pinned:by-team" ] && [ "$(litfp attacker-drive)" = "pinned:by-team" ] \
  && ok "a team-pinned base_path is the destination for BOTH aliases — and the commands execute it, not the alias" \
  || bad "a literal base_path and the executed destination disagree" "$(litfp teamdrive) / $(litfp attacker-drive)"
# …and the tier split is not silently lost: the lint says so (block J2 proves the message).
python3 "$KIT/bin/effective_config.py" --root "$LITP" --lint 2>&1 | grep -q 'mixes a team decision' \
  && ok "…and hardcoding base_path is LINTED, so the lost tier split is visible rather than silent" \
  || bad "a hardcoded base_path silently replaced the tier split with no warning"

# --- (G) reachability is not identity: the sentinel is the proof --------------------------------
# `rclone lsd` succeeds against any account holding the same path, and on an object store an absent
# prefix lists empty and exits 0. So the shipped verify compares a team-pinned token's CONTENTS.
grep -q 'Expected-target evidence' "$RC" \
  && ok "rclone.md carries an Expected-target evidence section (the databricks/snowflake precedent)" \
  || bad "rclone.md has no Expected-target evidence section"
grep -q 'rclone cat' "$RC" && grep -q 'target_sentinel' "$RC" \
  && ok "…and the proof is a team-pinned sentinel read back by \`rclone cat\`" \
  || bad "rclone.md's expected-target check is not a sentinel comparison"
grep -qi 'lsd' "$RC" && grep -qiE 'not identity|exits 0|different account' "$RC" \
  && ok "…and rclone.md says plainly that lsd/about prove reachability, not identity" \
  || bad "rclone.md presents a reachability probe as identity proof"
# Prove the check with a stubbed rclone: right token passes, wrong token fails. No network, no creds.
RCBIN="$TMP/rc-bin"; mkdir -p "$RCBIN"
for c in bash sh env printf awk sed grep tr cut basename dirname realpath python3 mktemp rm cat \
         head tail sort uniq wc xargs cp mv mkdir touch chmod ln date id git test; do
  src="$(command -v "$c" 2>/dev/null)" && ln -sf "$src" "$RCBIN/$c"
done
cat > "$RCBIN/rclone" <<'STUB'
#!/bin/sh
# Fixture stub. Serves ONE purpose: `rclone cat <remote>:<path>/.ticketwright-target` echoes the
# token recorded for that remote in $RC_STUB_DIR. Offline, read-only, no credentials.
if [ "$1" = "cat" ]; then
  remote="${2%%:*}"
  [ -f "$RC_STUB_DIR/$remote.token" ] && cat "$RC_STUB_DIR/$remote.token"
  exit 0
fi
exit 0
STUB
chmod +x "$RCBIN/rclone"
if ! ( PATH="$RCBIN"; command -v rclone >/dev/null 2>&1 ) \
   || [ "$( PATH="$RCBIN"; command -v rclone )" != "$RCBIN/rclone" ]; then
  bad "rclone stub setup is broken: the stub does not resolve on PATH, so this branch never ran"
else
  ok "rclone stub resolves on the fixture PATH (precondition asserted, not assumed)"
  export RC_STUB_DIR="$TMP/rc-stub"; mkdir -p "$RC_STUB_DIR"
  printf 'eng-sentinel-01' > "$RC_STUB_DIR/teamdrive.token"      # the team's real destination
  printf 'someone-elses-bucket' > "$RC_STUB_DIR/attacker-drive.token"
  rc_local teamdrive
  o="$(PATH="$RCBIN" RC_STUB_DIR="$RC_STUB_DIR" CLAUDE_PLUGIN_ROOT="$KIT" \
        bash "$KIT/bin/verify_stack.sh" "$RCP50/.claude/config/stack.yaml" 2>&1)"
  grep -q 'All seams OK' <<<"$o" \
    && ok "a remote whose sentinel matches the team token VERIFIES (no mount anywhere in the path)" \
    || bad "the correct rclone remote failed verification" "$o"
  rc_local attacker-drive
  o="$(PATH="$RCBIN" RC_STUB_DIR="$RC_STUB_DIR" CLAUDE_PLUGIN_ROOT="$KIT" \
        bash "$KIT/bin/verify_stack.sh" "$RCP50/.claude/config/stack.yaml" 2>&1)"; rc=$?
  { [ "$rc" -ne 0 ] && grep -q 'UNREACHABLE' <<<"$o"; } \
    && ok "…and a remote pointed at a DIFFERENT account fails it — the redirect lsd would have missed" \
    || bad "the sentinel check passed a redirected remote" "$o rc=$rc"
  rc_local teamdrive
fi

# --- (G2) the sharing warning PRECEDES the runnable link command -------------------------------
# Ordering is the whole mitigation here. `rclone link` mints an accountless public URL and has no
# read-only form, so a caveat printed below the command is a caveat read after the link exists.
python3 - <<'PYL' && ok "link_for's public-sharing warning appears BEFORE its runnable command" \
  || bad "the link_for command is printed before its sharing warning — the caveat arrives too late"
import sys
t = open("adapters/docstore/rclone.md", encoding="utf-8").read()
body = t.split("## verb: link_for", 1)[1].split("## gotchas", 1)[0]
warn = min((i for i in (body.find("READ BEFORE RUNNING"), body.find("⛔")) if i >= 0), default=-1)
fence = body.find("```")
sys.exit(0 if 0 <= warn < fence else 1)
PYL

# --- (H) the guide ships and is reachable from all five sites ------------------------------------
# docs/ is NOT in the wheel, so anything installed code PRINTS must be the GitHub URL (the
# obsidian.md precedent, section 38G); README links stay relative.
[ -f docs/drive-mount.md ] && ok "docs/drive-mount.md ships" || bad "docs/drive-mount.md missing"
sed -n '/^## The lifecycle is the map/,/^## /p' README.md | grep -q 'docs/drive-mount.md' \
  && ok "README's lifecycle section links docs/drive-mount.md" \
  || bad "docs/drive-mount.md not linked from README's lifecycle section"
sed -n '/^## Learn more/,/^## /p' README.md | grep -q 'docs/drive-mount.md' \
  && ok "README's further-reading list links docs/drive-mount.md" \
  || bad "docs/drive-mount.md not linked from README's Learn more list"
DMURL='github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md'
dmiss50=""
for f in adapters/docstore/gdrive.md adapters/docstore/sharepoint.md \
         .claude/skills/setup/SKILL.md .claude/skills/setup/teammate.md \
         .claude/skills/setup/interview.md; do
  grep -q "$DMURL" "$f" || dmiss50="$dmiss50 $f"
done
[ -z "$dmiss50" ] \
  && ok "the mount guide is pointed at by both adapters' auth notes and all three setup surfaces, by GitHub URL" \
  || bad "a missing-mount failure would name a docs/ path a pip install does not have" "$dmiss50"
# The operative line lives in SKILL.md, not only a sub-file: emit_runtime.py globs */SKILL.md, so
# guidance parked in teammate.md/interview.md never reaches codex-cli or antigravity (issue #55).
grep -q "$DMURL" .claude/skills/setup/SKILL.md \
  && ok "…including setup/SKILL.md, which is the file the runtime installers actually emit" \
  || bad "the guide is only in un-emitted sub-files, so two runtimes would never print it"

# --- (I) an adapter can never make its OWN destination personal ---------------------------------
# Derived, not listed: the static reserved set can only name today's destination keys. A future
# adapter declaring `destination_key: x` and then `user_keys: [x]` would leave its destination
# tier-3 overridable, which is the redirect this whole section is about.
RCA50="$TMP/rc-adapter"; mkdir -p "$RCA50/adapters/docstore" "$RCA50/.claude/config"
cat > "$RCA50/adapters/docstore/selfdest.md" <<'YAML'
---
seam: docstore
tool: selfdest
transport: cli
requires: [box_path]
destination_key: box_path
user_keys: [box_path]
---
## verb: backup
## verb: link_for
YAML
cat > "$RCA50/.claude/config/stack.yaml" <<'YAML'
schema_version: 1
seams:
  docstore:
    tool: selfdest
    adapter: adapters/docstore/selfdest.md
    transport: cli
    box_path: "team-archive"
YAML
printf 'person: alice\nseams:\n  docstore:\n    box_path: "somewhere-else"\n' \
  > "$RCA50/.claude/config/connections.local.yaml"
o="$(python3 "$KIT/bin/effective_config.py" --root "$RCA50" 2>&1)"; rc=$?
{ [ "$rc" -eq 6 ] || grep -q 'prohibited_override' <<<"$o"; } \
  && ok "an adapter declaring its OWN destination_key in user_keys is rejected, not honored" \
  || bad "an adapter left its destination tier-3 overridable" "rc=$rc $o"
grep -q 'somewhere-else' <<<"$o" \
  && bad "the rejected tier-3 destination override still landed in the resolved config" \
  || ok "…and the rejected override never reaches the resolved destination"

# --- (J) copy semantics, BOTH halves -------------------------------------------------------------
# The safe half alone is a misleading test: assert what survives AND what is meant to change.
python3 - <<'PY' && ok "copy semantics documented both ways: destination-only files survive, same-name files update" \
  || bad "rclone.md documents only half of copy's behavior"
import re, sys
t = open("adapters/docstore/rclone.md", encoding="utf-8").read()
body = t.split("## verb: backup", 1)[1].split("## verb: link_for", 1)[0]
survives = re.search(r"[Dd]oesn't delete files from the destination|never.*deleting destination-only|losing destination-only", body)
updates = re.search(r"overwrites a same-name file|should\*\* update it|overwrites same-name", body)
sys.exit(0 if survives and updates else 1)
PY

# --- (J2) the tier-split lint knows BOTH machine halves -----------------------------------------
# The lint that catches a hardcoded `base_path` named only `mount_root`, so an rclone slot could
# commit a machine path and lose the tier split without a word — a silent honesty gap, not a crash.
LINT50="$TMP/lint50"; mkdir -p "$LINT50/.claude/config"
lint50() {  # lint50 <tool> <adapter> <team-half-key> <team-half-value>
  cat > "$LINT50/.claude/config/stack.yaml" <<YAML
schema_version: 1
seams:
  docstore:
    tool: $1
    adapter: $2
    transport: cli
    $3: "$4"
    base_path: "/machine/specific/path"
    verify: "test -d \"{base_path}\""
YAML
  python3 "$KIT/bin/effective_config.py" --root "$LINT50" --lint 2>&1
}
o="$(lint50 rclone adapters/docstore/rclone.md remote_path eng-archive)"
{ grep -q 'mixes a team decision' <<<"$o" && grep -q 'remote_path' <<<"$o" && grep -q 'connections.local.yaml' <<<"$o"; } \
  && ok "a hardcoded base_path on an UNMOUNTED docstore is linted, naming remote_path + remote" \
  || bad "the tier-split lint is silent for rclone — a committed machine path would pass unnoticed" "$o"
o="$(lint50 gdrive adapters/docstore/gdrive.md drive_folder "Shared drives/Tickets")"
{ grep -q 'mixes a team decision' <<<"$o" && grep -q 'drive_folder' <<<"$o" && grep -q 'mount_root' <<<"$o"; } \
  && ok "…and the mounted case still names drive_folder + mount_root (no regression)" \
  || bad "generalizing the lint broke the mounted docstore message" "$o"

# --- (K) credential hygiene: the obvious command is the unsafe one ------------------------------
# `rclone config show` prints the DECRYPTED config. A probe that pretty-prints it is one paste away
# from publishing a token, which is why the adapter names it as forbidden rather than staying silent.
# "Invoked" means it appears in a RUNNABLE fenced block, not in the prose that BANS it — a
# line-oriented grep cannot tell those apart, and the ban wraps across lines and matched itself.
python3 - <<'PY50' >"$TMP/hd6724.out"
import pathlib, re
# `config dump` prints the whole config too, and a runnable line can hide in a ~~~ fence or a
# 4-space indented block as easily as in a ``` one. Cover all three, or the check is decorative.
hits = []
pat = re.compile(r"rclone(?:\s+-{1,2}\S+)*\s+config\s+(?:show|dump)"
                 r"|rclone(?:\s+-{1,2}\S+)*\s+listremotes[^\n`]*--json"
                 r"|rclone\.conf")
for root in ("adapters", ".claude"):
    for f in pathlib.Path(root).rglob("*.md"):
        text = f.read_text(encoding="utf-8", errors="replace")
        runnable = []
        # even-indexed chunks are outside fences, odd-indexed are inside one (``` or ~~~)
        # tolerate up to 3 leading spaces and a blockquote marker before the fence
        for i, chunk in enumerate(re.split(r"^[ ]{0,3}>?[ ]*(?:```|~~~).*$", text, flags=re.M)):
            if i % 2 == 1:
                runnable.append(chunk)
        # an indented line inside a list is still a command someone can paste — four spaces OR
        # MORE, any tab depth, optionally behind a blockquote marker
        runnable += ["\n".join(re.findall(r"^(?:>[ ]*)?(?: {4,}|\t+)\S.*$", text, flags=re.M))]
        for chunk in runnable:
            m = pat.search(chunk)
            if m:
                hits.append(f"{f}: {m.group(0)}")
print(" ".join(hits))
PY50
ch50="$(cat "$TMP/hd6724.out")"
[ -z "$ch50" ] \
  && ok "no runnable block invokes \`rclone config show\`/\`listremotes --json\` or reads rclone.conf" \
  || bad "a credential-bearing rclone command is invoked rather than warned about" "$ch50"
grep -q 'rclone listremotes' "$RC" && grep -qi 'decrypted' "$RC" \
  && ok "rclone.md enumerates remotes by NAME only and says why config show is banned" \
  || bad "rclone.md does not state the names-only enumeration rule"

# --- (L2) the unmounted backup is inside the source-material guard's jurisdiction ---------------
# A new copy verb that the privacy guard cannot see is a BYPASS of a shipped gate, not a new
# feature: `rclone copy` carries a ticket folder out of the repo with no `cp` anywhere in the
# command. Safety gates get more visible, never more convenient.
SMG50=".claude/hooks/source_material_guard.py"
# Assert the REGEX's behavior, not that the file contains the string "rclone": a static word
# match would stay green against a pattern that no real command form hits.
python3 - <<'PYS' >"$TMP/hd6765.out"
import re, sys
src = open(".claude/hooks/source_material_guard.py", encoding="utf-8").read()
def grab(name):
    seg = src[src.index(name):]; depth = 0; out = []
    for ch in seg:
        out.append(ch)
        if ch == "(": depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0: break
    return "".join(out)
ns = {"re": re}
exec(grab("_COPY_RE = "), ns); exec(grab("_COPY_RECURSIVE_RE = "), ns)
cov = lambda c: bool(ns["_COPY_RE"].search(c)) and bool(ns["_COPY_RECURSIVE_RE"].search(c))
# Each of these bypassed an earlier draft of the pattern. They are the regression list.
must = ["rclone copy tk remote:p", "rclone -vv copy tk remote:p",
        "rclone --config /p/rclone.conf copy tk remote:p",
        "rclone --config=/p/rclone.conf copy tk remote:p",
        "rclone --progress sync tk remote:p", "rclone --checkers 4 --transfers 8 copy tk remote:p",
        "/usr/local/bin/rclone copy tk remote:p", "env RCLONE_CONFIG=/x.conf rclone copy tk remote:p",
        "'rclone' copy tk remote:p", '"rclone" copy tk remote:p',
        "rclone copy -- tk remote:p", "cp -r tk /d", "'cp' -r tk /d", "rsync -a tk /d"]
must_not = ["rclone lsd remote:p --max-depth 1", "rclone cat remote:p/.ticketwright-target",
            "rclone about remote:", "rclone listremotes", "cp tk /d"]
bad = [c for c in must if not cov(c)] + [f"FP:{c}" for c in must_not if cov(c)]
print(" | ".join(bad))
PYS
smgcov="$(cat "$TMP/hd6765.out")"
[ -z "$smgcov" ] \
  && ok "the guard's copy detection covers every rclone directory form (flags, absolute path) and no read-only one" \
  || bad "rclone copy escapes the source-material guard — the unmounted backup would bypass it" "$smgcov"
SMG_T="$TMP/smg-rclone"; mkdir -p "$SMG_T/.claude/config" "$SMG_T/tickets/alice/ENG-1/source_materials"
cp "$KIT/.claude/config/stack.yaml" "$SMG_T/.claude/config/stack.yaml"
{ i=1; while [ "$i" -le 90 ]; do printf '[00:%02d:00] Speaker 1: line %d\n' "$i" "$i"; i=$((i+1)); done; } \
  > "$SMG_T/tickets/alice/ENG-1/source_materials/transcript-full.txt"
smg50() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$SMG_T" "$1" \
            | python3 "$KIT/$SMG50" 2>/dev/null; }
o="$(smg50 'rclone copy tickets/alice/ENG-1 teamdrive:archive/ENG-1')"
grep -q '"permissionDecision": "ask"' <<<"$o" \
  && ok "…and an rclone backup of a ticket holding raw transcript material ASKS first" \
  || bad "an unmounted backup carried raw transcript material out with no prompt" "$o"
o="$(smg50 'rclone lsd teamdrive:archive --max-depth 1')"
[ -z "$o" ] \
  && ok "…while read-only rclone verbs stay outside the guard entirely (no prompt fatigue)" \
  || bad "a read-only rclone command triggered the privacy guard" "$o"

# --- (L) the new tool is DETECTED, never chosen by a skill ---------------------------------------
# Adding a tool must not teach a skill that tool's name beyond the sanctioned detection probe.
grep -q 'for c in snow acli gh glab bq databricks yq jq git rclone' .claude/skills/setup/SKILL.md \
  && ok "rclone joined the CLI-detection probe (appended, so section 3's exemptions still match)" \
  || bad "the CLI probe does not detect rclone"
rcleak50="$(grep -rn 'rclone' .claude/skills .claude/commands .claude/agents 2>/dev/null \
           | grep -v 'for c in snow acli gh' | grep -v 'drive-mount.md' \
           | grep -v 'adapter fills this slot' || true)"
[ -z "$rcleak50" ] \
  && ok "no skill INVOKES rclone — tool choice stays in stack.yaml + the adapter" \
  || bad "rclone leaked into skill orchestration (the golden rule)" "$rcleak50"
hdr "51 · update notice: a pending release is VISIBLE, and every other case is silence (PROMPT: update-notice)"
# The gap this exists for: `autoUpdate: true` refreshes the marketplace CATALOG, but Claude Code does
# not re-install a project-scoped plugin from it — so a release lands on the machine and is silently
# not running. Everything below asserts OUTPUT AND EXIT CODE, because "prints nothing" and "prints
# nothing because it crashed" are the two states this CLI must never confuse.
UN="$TMP/unotice"

# --- fixture builders ----------------------------------------------------------------------------
un_repo() { mkdir -p "$1/.claude"; printf '%s' "$2" > "$1/.claude/settings.json"; }
# The default eligible repo: marketplace `acmehub` with autoUpdate, plugin `acme` enabled.
un_settings() {
  cat <<JSON
{"extraKnownMarketplaces":{"acmehub":{"source":{"source":"git","url":"https://acme.example/acme.git"},"autoUpdate":${1:-true}}},
 "enabledPlugins":{"acme@acmehub":${2:-true}}}
JSON
}
# `un_catalog <config-root> <version>` — what the cached marketplace advertises.
un_catalog() {
  mkdir -p "$1/plugins/marketplaces/acmehub/.claude-plugin"
  printf '{"name":"acme","version":"%s"}' "$2" \
    > "$1/plugins/marketplaces/acmehub/.claude-plugin/plugin.json"
}
# `un_manifest <config-root> <repo> <version>` — one project-scoped record for <repo>, plus a
# FOREIGN repo's record. That foreign path is the privacy fixture: it is real data in the real file,
# and it must never reach the output.
UN_FOREIGN="/Users/someone-else/Development/private-repo"
un_manifest() {
  mkdir -p "$1/plugins"
  cat > "$1/plugins/installed_plugins.json" <<JSON
{"version":1,"plugins":{"acme@acmehub":[
  {"scope":"project","projectPath":"$UN_FOREIGN","installPath":"$UN_FOREIGN/cache","version":"9.9.9"},
  {"scope":"project","projectPath":"$2","installPath":"$2/cache","version":"$3"}
]}}
JSON
}
# `un_json <path> <json>` writes a fixture through json.dump, and `un_parses <path> <label>` proves
# it parsed. Both matter more than they look: a printf-escaped "\n" lands as a LITERAL newline inside
# a JSON string, which makes the document malformed — and then a test named "the regex refused this
# name" actually measures the JSON parser refusing the file. DEFINED HERE, with the other builders,
# because a shell function is only callable after its definition is reached: these once lived
# further down the section and the earlier caller silently did nothing.
un_json() { python3 -c 'import json,sys; json.dump(json.loads(sys.argv[2]), open(sys.argv[1],"w"))' "$1" "$2"; }
un_parses() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null \
    && ok "fixture is VALID JSON, so the next silence is the check and not a parse error: $2" \
    || bad "fixture is malformed JSON — the next assertion would be vacuous: $2"
}
# `un_run <config-root> <repo>` — sets UN_OUT, UN_ERR and UN_RC IN THE CALLING SHELL.
# NEVER wrap a call in command substitution: `$( … )` runs the function in a subshell, the variable
# assignments die with that subshell, and un_clean then reads the initialized 0/"" forever — which
# is exactly how every exit-code and stderr assertion in this section became a silent no-op once
# already. The harness-capture check below is what keeps that from coming back.
UN_SCRIPT="bin/update_notice.py"
UN_OUT=""; UN_ERR=""; UN_RC=0
un_run() {
  python3 "$UN_SCRIPT" --root "$2" --config-root "$1" >"$TMP/un.out" 2>"$TMP/un.err"
  UN_RC=$?
  UN_OUT="$(cat "$TMP/un.out")"; UN_ERR="$(cat "$TMP/un.err")"
}
# Every case must exit 0 with an empty stderr — asserted once, here, so no case can pass by crashing.
un_clean() {
  { [ "$UN_RC" -eq 0 ] && [ -z "$UN_ERR" ]; } && return 0
  bad "$1: exit=$UN_RC stderr=$UN_ERR"; return 1
}
# Silence is judged on the RAW FILE, never on "$UN_OUT": command substitution strips trailing
# newlines, so a regression that printed nothing but "\n" would read as empty and pass every case
# below. -s is the byte-exact question.
un_quiet() { [ ! -s "$TMP/un.out" ]; }
# …and "exactly one line" is asked of the RAW BYTES for the same reason: "$UN_OUT" came through
# command substitution, which strips every trailing newline, so `notice\n\n` would count as one line.
un_one_line() {
  python3 -c '
import sys
b = open(sys.argv[1], "rb").read()
sys.exit(0 if b.endswith(b"\n") and b.count(b"\n") == 1 and len(b) > 1 else 1)
' "$TMP/un.out"
}
# THE HARNESS MUST BE ABLE TO FAIL. Point it at a script that exits nonzero and writes to stderr; if
# the capture works, both land in the parent shell. If this ever regresses to a subshell, it is this
# assertion that breaks first rather than everything below passing quietly.
printf 'import sys\nsys.stderr.write("boom\\n")\nraise SystemExit(7)\n' > "$TMP/un-fail.py"
UN_SCRIPT="$TMP/un-fail.py"; un_run "$TMP" "$TMP"
{ [ "$UN_RC" -eq 7 ] && [ "$UN_ERR" = "boom" ]; } \
  && ok "the harness captures exit code + stderr in the PARENT shell (no subshell swallow)" \
  || bad "un_run's capture is lost — every exit-code assertion below would be vacuous" \
        "rc=$UN_RC err=$UN_ERR"
UN_SCRIPT="bin/update_notice.py"

# --- the firing condition: catalog newer than installed -------------------------------------------
UR="$UN/repo"; UC="$UN/cfg"
un_repo "$UR" "$(un_settings)"; un_catalog "$UC" 3.6.1; un_manifest "$UC" "$UR" 3.5.0
un_run "$UC" "$UR"; out="$UN_OUT"
if un_clean "newer"; then
  { un_one_line && grep -q '3\.6\.1' <<<"$out" && grep -q '3\.5\.0' <<<"$out" \
    && grep -q 'claude plugin uninstall acme@acmehub --scope project' <<<"$out" \
    && grep -q 'claude plugin install acme@acmehub --scope project' <<<"$out"; } \
    && ok "a newer catalog prints ONE line carrying both versions and the uninstall+install pair" \
    || bad "the notice line is wrong" "$out"
  # The names come from the repo's own settings, never a hardcoded 'ticketwright' — this is what
  # keeps a fork or a rename working.
  grep -q 'ticketwright' <<<"$out" \
    && bad "the notice hardcodes ticketwright instead of reading the repo's configured names" \
    || ok "plugin + marketplace names are read from the repo settings (fork-safe)"
  # PRIVACY: installed_plugins.json lists other repos' paths. None may ever be printed.
  { grep -qF "$UN_FOREIGN" <<<"$out" || grep -qF "$UR" <<<"$out" || grep -qF "$UC" <<<"$out"; } \
    && bad "the notice leaked a filesystem path from installed_plugins.json" "$out" \
    || ok "no filesystem path from installed_plugins.json reaches the output"
fi

# --- everything else is silence -------------------------------------------------------------------
# Each case MUTATES ONE THING from the firing fixture above, so a pass can never be vacuous: the same
# fixture demonstrably fires, and the single mutation is what silences it.
un_silent() {  # un_silent <label> <config-root> <repo>
  local label="$1"; shift
  un_run "$1" "$2"; out="$UN_OUT"
  un_clean "$label" || return 0
  un_quiet && ok "silent: $label" \
    || bad "silent: $label — wrote $(wc -c < "$TMP/un.out") bytes to stdout" "$out"
}
mkver() { C2="$UN/cfg-$1"; rm -rf "$C2"; un_catalog "$C2" "$2"; un_manifest "$C2" "$UR" "$3"; }

mkver equal   3.6.1     3.6.1 ; un_silent "versions equal"                          "$C2" "$UR"
mkver older   3.5.0     3.6.1 ; un_silent "catalog OLDER (never a downgrade)"        "$C2" "$UR"
mkver pad     3.6       3.6.0 ; un_silent "3.6 == 3.6.0 (shorter tuple zero-padded)" "$C2" "$UR"
mkver prerel  3.7.0-rc1 3.6.1 ; un_silent "a non-integer segment (prerelease)"       "$C2" "$UR"
mkver blank   3..1     3.6.1 ; un_silent "an EMPTY version segment"                  "$C2" "$UR"
# str.isdigit() is True for fullwidth and superscript digits, which int() then rejects — a crash
# where the contract says silence. The parser takes ASCII digits only.
mkver wide    "3.6.１" 3.6.1 ; un_silent "a fullwidth digit in the version (isdigit lies)" "$C2" "$UR"
mkver sup     "3.6.³"  3.6.1 ; un_silent "a superscript digit in the version"          "$C2" "$UR"
mkver empty   3.6.1     ""    ; un_silent "the installed record has an empty version" "$C2" "$UR"
# The padding case must not pass merely because the parser rejected something: prove the same
# fixture DOES fire when the catalog is genuinely ahead by that trailing segment.
mkver padfire 3.6.1 3.6 ; un_run "$C2" "$UR"; out="$UN_OUT"; un_clean "padfire" || true
grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "control: 3.6 vs 3.6.1 DOES fire (so the zero-padding silence is not vacuous)" \
  || bad "3.6 vs 3.6.1 did not fire — the padding assertion above is vacuous" "$out"

# Manifest shapes.
mkver shape 3.6.1 3.5.0
printf '{"version":1}' > "$C2/plugins/installed_plugins.json"
un_silent "the manifest has no top-level plugins mapping" "$C2" "$UR"
printf '{"plugins":{"acme@acmehub":{"scope":"project"}}}' > "$C2/plugins/installed_plugins.json"
un_silent "the plugin entry is a mapping, not a list" "$C2" "$UR"
printf '{"plugins":{"acme@acmehub":[{"scope":"project","projectPath":"%s"' "$UR" \
  > "$C2/plugins/installed_plugins.json"
un_silent "the manifest JSON is truncated" "$C2" "$UR"
cat > "$C2/plugins/installed_plugins.json" <<JSON
{"plugins":{"acme@acmehub":[{"scope":"user","installPath":"/x","version":"3.5.0"}]}}
JSON
un_silent "only a USER-scope record exists (project scope is what the notice is about)" "$C2" "$UR"
cat > "$C2/plugins/installed_plugins.json" <<JSON
{"plugins":{"acme@acmehub":[{"scope":"project","projectPath":"$UN_FOREIGN","version":"3.5.0"}]}}
JSON
un_silent "no record whose projectPath is this repo" "$C2" "$UR"
# THE AMBIGUITY RULE, exercised rather than asserted: two project records for the SAME repo at
# DIFFERENT versions. Guessing between them is how a notice tells someone to downgrade.
cat > "$C2/plugins/installed_plugins.json" <<JSON
{"plugins":{"acme@acmehub":[
  {"scope":"project","projectPath":"$UR","version":"3.5.0"},
  {"scope":"project","projectPath":"$UR","version":"3.6.0"}]}}
JSON
un_silent "TWO project records match this repo (ambiguous — never guess a version)" "$C2" "$UR"
# The SAME ambiguity wearing a disguise: one record spells the canonical path, the other a symlink
# to it. Counting only the textual match would pick a version and call it the answer.
mkver dual 3.6.1 3.5.0
ln -snf "$UR" "$UN/repo-alias"
un_json "$C2/plugins/installed_plugins.json" "{\"plugins\":{\"acme@acmehub\":[{\"scope\":\"project\",\"projectPath\":\"$UR\",\"version\":\"3.5.0\"},{\"scope\":\"project\",\"projectPath\":\"$UN/repo-alias\",\"version\":\"3.6.0\"}]}}"
un_silent "one CANONICAL record plus one SYMLINKED record for this repo (still ambiguous)" "$C2" "$UR"
# The lexical trap a normpath shortcut would fall into: `<root>/aliasdir/..` COLLAPSES to `<root>`
# on paper, but aliasdir is a symlink, so the path really names somewhere else. Matching it would be
# a false positive — this repo told a version it does not run.
mkver lex 3.6.1 3.5.0
mkdir -p "$UN/elsewhere"; ln -snf "$UN/elsewhere" "$UR/aliasdir"
un_json "$C2/plugins/installed_plugins.json" "{\"plugins\":{\"acme@acmehub\":[{\"scope\":\"project\",\"projectPath\":\"$UR/aliasdir/..\",\"version\":\"3.5.0\"}]}}"
un_silent "a record spelled <root>/<symlink>/.. — collapses textually, resolves elsewhere" "$C2" "$UR"
rm -f "$UR/aliasdir"
# resolve() defaults to strict=False, which collapses `..` LEXICALLY when a component is missing:
# `<root>/missing/..` comes back as `<root>` and would match a repo it does not name.
mkver strictres 3.6.1 3.5.0
un_json "$C2/plugins/installed_plugins.json" "{\"plugins\":{\"acme@acmehub\":[{\"scope\":\"project\",\"projectPath\":\"$UR/missing/..\",\"version\":\"3.5.0\"}]}}"
un_silent "a record naming a NONEXISTENT component (<root>/missing/..) — strict resolution refuses it" "$C2" "$UR"
# A relative record resolves against THIS PROCESS'S cwd, so a child launched inside the repo would
# match a record that names no repo at all.
mkver relrec 3.6.1 3.5.0
un_json "$C2/plugins/installed_plugins.json" '{"plugins":{"acme@acmehub":[{"scope":"project","projectPath":".","version":"3.5.0"}]}}'
( cd "$UR" && python3 "$KIT/bin/update_notice.py" --root "$UR" --config-root "$C2" > "$TMP/un.out" 2>&1 )
un_quiet && ok "silent: a RELATIVE projectPath ('.') never matches, even run from inside the repo" \
  || bad "a relative projectPath matched against the process cwd" "$(cat "$TMP/un.out")"
rm -f "$C2/plugins/installed_plugins.json"
un_silent "installed_plugins.json is missing entirely" "$C2" "$UR"
# A NON-CANONICAL --root must still match the manifest's projectPath. Claude Code writes a resolved
# path; a person (or a worktree) hands over a symlink or a trailing slash, and a textual compare
# would report "not installed here" for a repo that plainly is.
mkver link 3.6.1 3.5.0
ln -snf "$UR" "$UN/repo-link"
un_run "$C2" "$UN/repo-link"; out="$UN_OUT"; un_clean "symlinked root" || true
grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "a symlinked --root still matches the manifest's projectPath" \
  || bad "a symlinked --root missed its own install record" "$out"
un_run "$C2" "$UR/"; out="$UN_OUT"; un_clean "trailing slash" || true
grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "a trailing slash on --root still matches" || bad "a trailing slash broke the match" "$out"

# Catalog shapes. The catalog version comes from the cached marketplace's own plugin.json — a
# marketplace laid out any other way is SILENCE, never a second guess at where the version lives.
mkver cat 3.6.1 3.5.0
CATP="$C2/plugins/marketplaces/acmehub/.claude-plugin/plugin.json"
rm -f "$CATP"
un_silent "the cached marketplace plugin.json is missing" "$C2" "$UR"
printf '{"name":"other","version":"9.9.9"}' > "$CATP"
un_silent "the catalog manifest names a DIFFERENT plugin" "$C2" "$UR"
printf '{"name":"acme"}' > "$CATP"
un_silent "the catalog manifest has no version" "$C2" "$UR"
printf '{"name":"acme","version":361}' > "$CATP"
un_silent "the catalog version is a number, not a string" "$C2" "$UR"
printf '{"name":"acme","version":"3.6.1"' > "$CATP"
un_silent "the catalog JSON is truncated" "$C2" "$UR"
printf '["acme","3.6.1"]' > "$CATP"
un_silent "the catalog manifest is a list, not a mapping" "$C2" "$UR"

# EVERY settings case below runs against $UCX, a config root that holds an install record FOR THAT
# REPO. Without that they were vacuous: a repo with no record is silent whatever its settings say, so
# "silent because autoUpdate is false" and "silent because this repo has no install" were the same
# observation. un_register adds the record AND proves the fixture fires with GOOD settings, so the
# only thing left that can silence the paired case is the settings check it names.
UCX="$UN/cfg-settings"; un_catalog "$UCX" 3.6.1
mkdir -p "$UCX/plugins"; printf '{"plugins":{"acme@acmehub":[]}}' > "$UCX/plugins/installed_plugins.json"
un_register() {  # un_register <repo> <label>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["plugins"]["acme@acmehub"].append(
    {"scope": "project", "projectPath": sys.argv[2], "version": "3.5.0"})
json.dump(d, open(sys.argv[1], "w"))
' "$UCX/plugins/installed_plugins.json" "$1"
  un_repo "$1" "$(un_settings)"
  un_run "$UCX" "$1"
  { [ "$UN_RC" -eq 0 ] && grep -q '3\.6\.1 is available' <<<"$UN_OUT"; } \
    && ok "control: the fixture FIRES with good settings — $2" \
    || bad "control did not fire; the paired silence would be vacuous — $2" "$UN_OUT"
}

# Repo-settings shapes that are MALFORMED rather than opted out — also silence, never a traceback.
RJ="$UN/repo-badjson"; un_register "$RJ" "truncated settings.json"
printf '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true}},' > "$RJ/.claude/settings.json"
un_silent "the repo settings.json is truncated" "$UCX" "$RJ"
RL="$UN/repo-list"; un_register "$RL" "extraKnownMarketplaces as a list"
un_repo "$RL" '{"extraKnownMarketplaces":[],"enabledPlugins":{"acme@acmehub":true}}'
un_silent "extraKnownMarketplaces is a list, not a mapping" "$UCX" "$RL"
RE2="$UN/repo-enablist"; un_register "$RE2" "enabledPlugins as a list"
un_repo "$RE2" '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true}},"enabledPlugins":["acme@acmehub"]}'
un_silent "enabledPlugins is a list, not a mapping" "$UCX" "$RE2"
RTR="$UN/repo-truthy"; un_register "$RTR" "autoUpdate as a truthy string"
un_repo "$RTR" '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":"yes"}},"enabledPlugins":{"acme@acmehub":true}}'
un_silent "autoUpdate is a truthy STRING, not true (never guess at intent)" "$UCX" "$RTR"
RNP="$UN/repo-nopair"; un_register "$RNP" "an enabledPlugins key with no @ half"
un_repo "$RNP" '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true}},"enabledPlugins":{"acme":true}}'
un_silent "an enabledPlugins key with no @marketplace half" "$UCX" "$RNP"
# The names are interpolated into a shell command the notice invites a person to PASTE. A name that
# is not an ordinary identifier does not fire — otherwise the reader is handed a line that does
# something other than what it looks like, and the "one line" contract breaks on a newline.
for hostile in 'acme; rm -rf ~@acmehub' 'acme$(id)@acmehub' 'acme@acmehub"' 'ac me@acmehub'; do
  RX="$UN/repo-hostile"
  [ -f "$RX/.claude/settings.json" ] || un_register "$RX" "hostile plugin names"
  python3 - "$RX/.claude/settings.json" "$hostile" <<'UNPY'
import json, sys
json.dump({"extraKnownMarketplaces": {"acmehub": {"autoUpdate": True}},
           "enabledPlugins": {sys.argv[2]: True}}, open(sys.argv[1], "w"))
UNPY
  un_silent "a plugin name carrying shell metacharacters (${hostile}) never reaches the command" "$UCX" "$RX"
done
# A newline inside the name would split the notice into two lines — the same rule catches it.
RNL="$UN/repo-newline"; un_register "$RNL" "a newline inside the plugin name"
printf '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true}},"enabledPlugins":{"ac\nme@acmehub":true}}' \
  > "$RNL/.claude/settings.json"
un_silent "a newline inside the plugin name (the one-line contract cannot be split)" "$UCX" "$RNL"

# Repo-settings shapes — the deliberate opt-outs /setup already honors.
RO="$UN/repo-off"; un_register "$RO" "autoUpdate: false"
un_repo "$RO" "$(un_settings false true)"
un_silent "autoUpdate is explicitly false (a deliberate opt-out)" "$UCX" "$RO"
RD="$UN/repo-dis"; un_register "$RD" "the plugin disabled in enabledPlugins"
un_repo "$RD" "$(un_settings true false)"
un_silent "the plugin is explicitly disabled in enabledPlugins" "$UCX" "$RD"
RN="$UN/repo-nomk"; un_register "$RN" "no extraKnownMarketplaces block"
un_repo "$RN" '{"enabledPlugins":{"acme@acmehub":true}}'
un_silent "no extraKnownMarketplaces block in the repo settings" "$UCX" "$RN"
RB="$UN/repo-bare"; un_register "$RB" "no .claude/settings.json at all"
rm -f "$RB/.claude/settings.json"
un_silent "the repo has no .claude/settings.json at all (a vendored or pip install)" "$UCX" "$RB"
RT="$UN/repo-two"; un_register "$RT" "two eligible plugin@marketplace pairs"
un_repo "$RT" '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true},"bhub":{"autoUpdate":true}},"enabledPlugins":{"acme@acmehub":true,"bee@bhub":true}}'
un_silent "TWO eligible plugin@marketplace pairs (ambiguous — never name the wrong one)" "$UCX" "$RT"
# The marketplace name is used as a PATH COMPONENT under plugins/marketplaces/. `.` and `..` clear
# the identifier check but would read a manifest from the wrong directory entirely.
#
# THE FIXTURE IS BUILT SO THAT REMOVING THE GUARD WOULD FIRE. Asserting silence against a config
# root that has no record for the traversed pair proves nothing — it would be silent either way.
# So each case gets its own config root carrying (a) an install record under the traversed key
# `acme@..`, and (b) a catalog manifest at exactly the path the traversal would reach:
# marketplaces/../.claude-plugin -> plugins/.claude-plugin. With the guard, silence. Without it, a
# notice sourced from a directory nobody named.
for trav in ".." "."; do
  RV="$UN/repo-trav-$(printf '%s' "$trav" | tr -d '.')x"; mkdir -p "$RV/.claude"
  CV="$UN/cfg-trav-$(printf '%s' "$trav" | tr -d '.')x"
  mkdir -p "$CV/plugins/marketplaces"
  TRAVDIR="$(cd "$CV/plugins/marketplaces" && cd "$trav" && pwd)/.claude-plugin"
  mkdir -p "$TRAVDIR"
  printf '{"name":"acme","version":"3.6.1"}' > "$TRAVDIR/plugin.json"
  un_json "$CV/plugins/installed_plugins.json" "{\"plugins\":{\"acme@$trav\":[{\"scope\":\"project\",\"projectPath\":\"$RV\",\"version\":\"3.5.0\"}]}}"
  un_json "$RV/.claude/settings.json" "{\"extraKnownMarketplaces\":{\"$trav\":{\"autoUpdate\":true}},\"enabledPlugins\":{\"acme@$trav\":true}}"
  # Prove the fixture is loaded: the same config root fires for an ordinary marketplace name.
  RVOK="$RV-ok"; mkdir -p "$RVOK/.claude"
  un_catalog "$CV" 3.6.1
  un_json "$CV/plugins/installed_plugins.json" "{\"plugins\":{\"acme@$trav\":[{\"scope\":\"project\",\"projectPath\":\"$RV\",\"version\":\"3.5.0\"}],\"acme@acmehub\":[{\"scope\":\"project\",\"projectPath\":\"$RVOK\",\"version\":\"3.5.0\"}]}}"
  un_repo "$RVOK" "$(un_settings)"
  un_run "$CV" "$RVOK"
  grep -q '3\.6\.1 is available' <<<"$UN_OUT" \
    && ok "control: this config root FIRES for an ordinary marketplace name (trav='$trav')" \
    || bad "traversal control did not fire; the paired silence would be vacuous (trav='$trav')" "$UN_OUT"
  un_silent "a marketplace named '$trav' — a path component, with a catalog planted where it would land" "$CV" "$RV"
done
# …and the guard itself, asserted directly, with an ordinary name as the control.
python3 - "$KIT/bin/update_notice.py" <<'UNPY' && ok "eligible_pair() refuses '.' and '..' for either name, and accepts an ordinary one" || bad "eligible_pair() does not refuse the traversal names"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("un", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def settings(plugin, marketplace):
    return {"extraKnownMarketplaces": {marketplace: {"autoUpdate": True}},
            "enabledPlugins": {f"{plugin}@{marketplace}": True}}

if m.eligible_pair(settings("acme", "acmehub")) != ("acme", "acmehub"):
    print("control: an ordinary pair was refused", file=sys.stderr); sys.exit(1)
for plugin, marketplace in (("acme", ".."), ("acme", "."), ("..", "acmehub"), (".", "acmehub")):
    if m.eligible_pair(settings(plugin, marketplace)) is not None:
        print("accepted %r@%r" % (plugin, marketplace), file=sys.stderr); sys.exit(1)
UNPY

# A TRAILING newline is the case a `^…$` anchor silently accepts (`$` matches before a final
# newline), so each of the four strings the notice interpolates is pinned separately. These fixtures
# go through json.dump ON PURPOSE: a printf-escaped "\n" lands as a LITERAL newline inside the JSON
# string, which makes the document malformed — and then every one of these tests passes for the
# wrong reason, the parser rejecting the file rather than the regex rejecting the name. Each fixture
# is proven parseable first, so "silent" can only mean the name/version check refused it.
RTN="$UN/repo-trailnl"; un_register "$RTN" "a trailing newline on the plugin name"
un_json "$RTN/.claude/settings.json" '{"extraKnownMarketplaces":{"acmehub":{"autoUpdate":true}},"enabledPlugins":{"acme\n@acmehub":true}}'
un_parses "$RTN/.claude/settings.json" "trailing newline on the plugin name"
un_silent "a TRAILING newline on the plugin name" "$UCX" "$RTN"
RTM="$UN/repo-trailmk"; un_register "$RTM" "a trailing newline on the marketplace name"
un_json "$RTM/.claude/settings.json" '{"extraKnownMarketplaces":{"acmehub\n":{"autoUpdate":true}},"enabledPlugins":{"acme@acmehub\n":true}}'
un_parses "$RTM/.claude/settings.json" "trailing newline on the marketplace name"
un_silent "a TRAILING newline on the marketplace name" "$UCX" "$RTM"
mkver catnl 3.6.1 3.5.0
CATNL="$C2/plugins/marketplaces/acmehub/.claude-plugin/plugin.json"
un_json "$CATNL" '{"name":"acme","version":"3.6.1\n"}'
un_parses "$CATNL" "trailing newline on the catalog version"
un_silent "a TRAILING newline on the CATALOG version" "$C2" "$UR"
mkver insnl 3.6.1 3.5.0
INSNL="$C2/plugins/installed_plugins.json"
un_json "$INSNL" '{"plugins":{"acme@acmehub":[{"scope":"project","projectPath":"'"$UR"'","version":"3.5.0\n"}]}}'
un_parses "$INSNL" "trailing newline on the installed version"
un_silent "a TRAILING newline on the INSTALLED version" "$C2" "$UR"

# Bounded input: this runs as a child inside a SessionStart budget, so it must not agree to parse an
# arbitrarily large file, and it must not be BLOCKABLE by a non-regular one.
mkver big 3.6.1 3.5.0
python3 -c "
import json,sys
recs=[{'scope':'project','projectPath':'/x/%d'%i,'version':'1.0.0'} for i in range(80000)]
recs.append({'scope':'project','projectPath':sys.argv[2],'version':'3.5.0'})
open(sys.argv[1],'w').write(json.dumps({'plugins':{'acme@acmehub':recs}}))
" "$C2/plugins/installed_plugins.json" "$UR"
[ "$(wc -c < "$C2/plugins/installed_plugins.json")" -gt 4194304 ] \
  && ok "oversize fixture is genuinely over the 4MiB cap ($(wc -c < "$C2/plugins/installed_plugins.json") bytes)" \
  || bad "oversize fixture is not actually oversize — the next assertion would be vacuous"
un_silent "an installed_plugins.json past the size cap" "$C2" "$UR"
# A symlink is judged by its TARGET: open() follows the link and the fstat is of the descriptor, so
# a link to an oversize file is refused too.
mkver bigln 3.6.1 3.5.0
BIGSRC="$C2/plugins/installed_plugins.json.big"
mv "$UN/cfg-big/plugins/installed_plugins.json" "$BIGSRC"
ln -snf "$BIGSRC" "$C2/plugins/installed_plugins.json"
un_silent "a SYMLINK to an oversize manifest (open follows the link, fstat judges the fd)" "$C2" "$UR"
# The BOUNDARY, both sides — a cap nobody tests at the edge is a cap that drifts. JSON tolerates
# leading whitespace, so the same document is padded to exactly the cap and to exactly one over it.
un_pad() {  # un_pad <path> <exact-byte-size> <repo>
  python3 -c '
import json, sys
doc = json.dumps({"plugins": {"acme@acmehub": [
    {"scope": "project", "projectPath": sys.argv[3], "version": "3.5.0"}]}})
size = int(sys.argv[2])
open(sys.argv[1], "w").write(" " * (size - len(doc)) + doc)
' "$1" "$2" "$3"
  [ "$(wc -c < "$1")" -eq "$2" ] || bad "padding produced $(wc -c < "$1") bytes, wanted $2"
}
mkver cap 3.6.1 3.5.0
un_pad "$C2/plugins/installed_plugins.json" 4194304 "$UR"
un_run "$C2" "$UR"; out="$UN_OUT"
un_clean "at the cap" && { grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "a manifest of exactly MAX_BYTES is accepted (the cap is inclusive)" \
  || bad "a manifest at exactly the cap was refused — the boundary is off by one" "$out"; }
un_pad "$C2/plugins/installed_plugins.json" 4194305 "$UR"
un_silent "a manifest of exactly MAX_BYTES + 1 (one byte over)" "$C2" "$UR"
mkver fifo 3.6.1 3.5.0
rm -f "$C2/plugins/installed_plugins.json"
if mkfifo "$C2/plugins/installed_plugins.json" 2>/dev/null; then
  t0=$(date +%s); un_run "$C2" "$UR"; out="$UN_OUT"; t1=$(date +%s)
  { un_quiet && [ "$UN_RC" -eq 0 ] && [ -z "$UN_ERR" ] && [ $((t1 - t0)) -lt 5 ]; } \
    && ok "a FIFO where the manifest should be is silence, not a hang ($((t1 - t0))s)" \
    || bad "a FIFO manifest hung or produced output ($((t1 - t0))s)" "$out"
  rm -f "$C2/plugins/installed_plugins.json"
else
  ok "mkfifo unavailable — non-regular-file case skipped on this host"
fi

# --- the hook is a PRESENTER, and it fails open ---------------------------------------------------
# A fixture kit: the hook resolves bin/ from CLAUDE_PLUGIN_ROOT, so a stand-in update_notice.py here
# proves the failure paths without touching the real one.
UK="$UN/kit"; mkdir -p "$UK/bin" "$UK/adapters" "$UK/templates" "$UK/.claude/hooks"
cp bin/kit_paths.py bin/effective_config.py bin/_yamlite.py bin/whoami.py "$UK/bin/"
cp .claude/hooks/session_context.py .claude/hooks/_stack.py "$UK/.claude/hooks/"
HR="$UN/hookrepo"; mkdir -p "$HR/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: duckdb\n' > "$HR/.claude/config/stack.yaml"
un_repo "$HR" "$(un_settings)"
HC="$UN/hookcfg"; un_catalog "$HC" 3.6.1; un_manifest "$HC" "$HR" 3.5.0
HN="$UN/hookcfg-none"; mkdir -p "$HN"        # an empty config root: eligible repo, nothing installed
# Writes the banner to $TMP/banner.out and echoes it. Comparisons use the FILE (`cmp`), because
# "$(hook_banner …)" strips trailing newlines — so an extra blank final line would compare equal to
# the baseline and "byte-identical" would be a claim the test never checked.
hook_banner() {  # hook_banner <config-root> [outfile]
  echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$HR" CLAUDE_PLUGIN_ROOT="$UK" \
    CLAUDE_CONFIG_DIR="$1" python3 "$UK/.claude/hooks/session_context.py" 2>/dev/null \
    > "${2:-$TMP/banner.out}"
  cat "${2:-$TMP/banner.out}"
}
# `un_same_banner <label>` — run against the pending-release config root and require the bytes to
# match the recorded baseline exactly.
un_same_banner() {
  hook_banner "$HC" "$TMP/banner.cmp" >/dev/null
  cmp -s "$TMP/banner.cmp" "$TMP/banner.base" && ok "$1" || bad "$1 — banner bytes differ"
}
cp bin/update_notice.py "$UK/bin/"
withnotice="$(hook_banner "$HC")"
{ [ "$(grep -c 'is available' <<<"$withnotice")" -eq 1 ] \
  && grep -q '3\.6\.1 is available' <<<"$withnotice"; } \
  && ok "the SessionStart banner gains EXACTLY ONE notice line when a release is pending" \
  || bad "the banner did not pick up exactly one notice" "$withnotice"
baseline="$(hook_banner "$HN" "$TMP/banner.base")"
{ [ -s "$TMP/banner.base" ] && ! grep -q 'is available' "$TMP/banner.base"; } \
  && ok "baseline banner renders in full with no notice line" || bad "baseline banner wrong" "$baseline"
# (1) a BROKEN CLI must leave the banner byte-identical to the baseline.
printf 'import sys\nsys.stderr.write("boom\\n")\nraise SystemExit(3)\n' > "$UK/bin/update_notice.py"
un_same_banner "fail-open: a broken update_notice.py leaves the banner byte-identical"
# (2) a CHATTY CLI — multi-line output, or a line alongside stderr noise — is not a notice either.
printf 'print("line one")\nprint("line two")\n' > "$UK/bin/update_notice.py"
un_same_banner "fail-open: multi-line CLI output is rejected, banner byte-identical"
printf 'import sys\nprint("looks like a notice")\nsys.stderr.write("warn\\n")\n' > "$UK/bin/update_notice.py"
un_same_banner "fail-open: output alongside stderr noise is rejected, banner byte-identical"
# Stderr holding ONLY a newline: `proc.stderr.strip()` reads that as empty, so this is the fixture
# that fails if the check ever softens back to a stripped comparison.
printf 'import sys\nprint("looks like a notice")\nsys.stderr.write("\\n")\n' > "$UK/bin/update_notice.py"
un_same_banner "fail-open: stderr holding only a newline still rejects the line"
# (3) a HANGING CLI must time out inside the hook budget and change nothing.
printf 'import time\ntime.sleep(60)\n' > "$UK/bin/update_notice.py"
t0=$(date +%s); hook_banner "$HC" "$TMP/banner.cmp" >/dev/null; t1=$(date +%s)
{ cmp -s "$TMP/banner.cmp" "$TMP/banner.base" && [ $((t1 - t0)) -lt 10 ]; } \
  && ok "fail-open: a hanging CLI times out inside the 10s hook budget, banner byte-identical" \
  || bad "a hanging update_notice.py blocked or changed the banner ($((t1 - t0))s)"
# (4) an EMPTY-output CLI is the ordinary no-notice case and must also change nothing.
printf 'pass\n' > "$UK/bin/update_notice.py"
un_same_banner "a silent CLI leaves the banner byte-identical (the ordinary no-notice case)"
# (5) whitespace-only output is not a notice either.
printf 'print("   ")\n' > "$UK/bin/update_notice.py"
un_same_banner "whitespace-only CLI output is rejected, banner byte-identical"
# U+2028 LINE SEPARATOR renders as a second line in plenty of viewers and contains no "\n" at all,
# so a `"\n" in out` check would wave it through. str.splitlines() is the check that catches it.
printf 'print("notice\\u2028SECOND LINE")\n' > "$UK/bin/update_notice.py"
un_same_banner "a Unicode line separator (U+2028) in CLI output is rejected, banner byte-identical"
# TRAILING separators are the ones a strip()-first gate waves through: str.strip() treats U+2028 as
# whitespace, and it collapses a doubled final newline. The gate validates the RAW stdout, so both
# are refused — "exactly one line" has to mean exactly, or the claim is decoration.
printf 'import sys\nsys.stdout.write("notice\\u2028")\n' > "$UK/bin/update_notice.py"
un_same_banner "a TRAILING U+2028 is rejected (strip() would have called it whitespace)"
printf 'import sys\nsys.stdout.write("notice\\n\\n")\n' > "$UK/bin/update_notice.py"
un_same_banner "a DOUBLED final newline is rejected (only one trailing newline is normalized)"
# …and the well-behaved single trailing newline a plain print() emits still fires, so the two
# assertions above are strictness, not breakage.
printf 'print("acme 9.9.9 is available - control line")\n' > "$UK/bin/update_notice.py"
grep -q 'control line' <<<"$(hook_banner "$HC")" \
  && ok "control: one line with a single trailing newline IS admitted" \
  || bad "the presenter rejects ordinary print() output — the gate is too strict"
# A carriage return could redraw the banner lines above it — one line by newline count, not by what
# a terminal would show.
printf 'print("notice\\rOVERWRITE")\n' > "$UK/bin/update_notice.py"
un_same_banner "a control character (CR) in CLI output is rejected, banner byte-identical"
# (6) no CLI at all — a partially vendored kit.
rm -f "$UK/bin/update_notice.py"
un_same_banner "fail-open: a missing update_notice.py leaves the banner byte-identical"

# The child timeout is a share of the hook's budget, not the whole of it: prove the banner the
# session actually depends on still renders well inside 10s on the HAPPY path, so the hung-CLI
# assertion above is measuring headroom rather than luck.
cp bin/update_notice.py "$UK/bin/"
t0=$(date +%s); hook_banner "$HC" >/dev/null; t1=$(date +%s)
[ $((t1 - t0)) -lt 5 ] \
  && ok "the happy-path banner renders in $((t1 - t0))s, well inside the 10s hook budget" \
  || bad "the banner took $((t1 - t0))s — the child timeout leaves the parent no headroom"

# --- the harness-neutral route --------------------------------------------------------------------
# A usage error must not be able to write argparse's diagnostic into a hook's stderr check.
out="$(python3 bin/update_notice.py --not-a-flag 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && ok "a usage error is silence with exit 0 (argparse can never surface a diagnostic)" \
  || bad "a bad flag produced output or a nonzero exit" "rc=$rc $out"
# `--help` is the ONE documented exception to "silence or one line" — a harness-neutral CLI needs
# discoverable help. It is only safe because the presenter refuses multi-line output, so assert BOTH
# halves: help exists, and it could never reach a banner.
help_out="$(python3 bin/update_notice.py --help 2>/dev/null)"; help_rc=$?
{ [ "$help_rc" -eq 0 ] && grep -q '^usage: ' <<<"$help_out" \
  && grep -q '\-\-root' <<<"$help_out" && grep -q '\-\-config-root' <<<"$help_out"; } \
  && ok "--help prints REAL usage naming both flags and exits 0 (the documented exception)" \
  || bad "--help output is not recognizable usage text" "rc=$help_rc $help_out"
# Contract 1 (exit 0, ALWAYS) has NO exceptions — including the one path that deliberately writes.
# `--help` renders BEFORE argparse exits, so a closed stdout raises from the act of printing help.
for flags in "--help" "--root $UR --config-root $UC"; do
  # shellcheck disable=SC2086
  python3 bin/update_notice.py $flags >&- 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "exit 0 with stdout CLOSED ($flags)" \
    || bad "a closed stdout produced exit $rc ($flags)"
done
grep -q 'ONE deliberate exception is `--help`' bin/update_notice.py \
  && ok "the docstring STATES the --help exception rather than overclaiming absolute silence" \
  || bad "update_notice.py claims absolute silence while --help prints usage"
cp bin/update_notice.py "$UK/bin/"
printf 'import sys\nsys.argv=["x","--help"]\nexec(open(%s).read())\n' "\"$KIT/bin/update_notice.py\"" \
  > "$UK/bin/update_notice.py"
un_same_banner "even --help output cannot reach the banner (the presenter rejects multi-line)"
cp bin/update_notice.py "$UK/bin/"
out="$(bash bin/tw update_notice.py --root "$UR" --config-root "$UC" 2>&1)"
grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "reachable through the bin/tw launcher (every runtime, not just Claude Code)" \
  || bad "bin/tw could not run update_notice.py" "$out"
grep -q 'update_notice.py --root' docs/runtimes.md \
  && ok "docs/runtimes.md names the launcher form for runtimes without a session-start hook" \
  || bad "docs/runtimes.md does not name the update_notice launcher form"
# No CLAUDE_* variable is REQUIRED: the CLI must work from its flags alone.
out="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR \
  python3 bin/update_notice.py --root "$UR" --config-root "$UC" 2>&1)"
grep -q '3\.6\.1 is available' <<<"$out" \
  && ok "no Claude environment variable required (harness-neutral)" \
  || bad "update_notice.py needs a CLAUDE_* variable" "$out"
# It NAMES the remediation; it must never RUN it. A kit that silently swaps its own running code has
# a worse property than a stale version, so the only subprocess here is git rev-parse.
python3 - "$KIT/bin/update_notice.py" <<'UNPY' && ok "the notice only NAMES the remediation; it never executes a plugin command" || bad "update_notice.py appears to execute a plugin command"
import re, sys
src = open(sys.argv[1]).read()
calls = re.findall(r"subprocess\.\w+\(\s*\[([^\]]*)\]", src, re.S)
sys.exit(1 if any("claude" in c or "plugin" in c for c in calls) else 0)
UNPY


hdr "51b · MCP permission posture — adapter sections, probe hygiene, the posture table (PROMPT: mcp-permission-posture)"
# On the MCP transport the shell hooks cannot see the traffic, so a policy's enforcement moves into
# the TOOL's own permission controls — and the kit's job is to say where that control lives, what
# to set, and how to CHECK it read-only. This section pins the adapter contract (D1), the
# template's NATIVE (tool-side) vocabulary (D3), and the honesty asymmetry at the heart of the
# design: NATIVE is claimable ONLY where a read-only, in-session privilege introspection exists
# (today: the warehouse seam); chat/tracker connector grants cannot be introspected in-session, so
# those posture records cap at `unverified` and every surface must say so plainly.

p51_fence() {  # the fenced code-block lines inside a file's "### Read-only probe" subsection
  awk '
    /^### Read-only probe$/ {insec=1; next}
    insec && /^## /  {insec=0}
    insec && /^### / {insec=0}
    insec && /^```/  {infence = !infence; next}
    insec && infence {print}
  ' "$1"
}
p51_transport() {  # frontmatter transport — the same sed shape bin/verify_stack.sh uses
  sed -n '2,/^---$/p' "$1" 2>/dev/null | sed -n 's/^transport:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -n 1
}

# --- (A) structure pin: every mcp/both adapter carries the 3-part section; nothing else does ----
p51_miss=""; p51_extra=""; p51_count=0
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  case "$(p51_transport "$f")" in
    mcp|both)
      p51_count=$((p51_count + 1))
      { grep -q '^## Permission posture (MCP)$' "$f" \
        && grep -q '^### Native control$' "$f" \
        && grep -q '^### Recommended setting (by policy)$' "$f" \
        && grep -q '^### Read-only probe$' "$f"; } || p51_miss="$p51_miss $f"
      ;;
    *)
      grep -q '^## Permission posture (MCP)$' "$f" && p51_extra="$p51_extra $f"
      ;;
  esac
done
[ "$p51_count" -eq 10 ] \
  && ok "exactly 10 adapters declare transport mcp/both (the posture contract's whole scope)" \
  || bad "the mcp/both adapter census moved (found $p51_count, expected 10) — extend the posture contract with it" "$p51_count"
[ -z "$p51_miss" ] \
  && ok "every mcp/both adapter carries '## Permission posture (MCP)' + all three '###' parts" \
  || bad "an MCP-capable adapter misses the posture section (or one of its three parts)" "$p51_miss"
[ -z "$p51_extra" ] \
  && ok "no cli/native adapter carries a posture section (the advisory keys off transport)" \
  || bad "a non-MCP adapter grew a posture section" "$p51_extra"

# --- (B) probe SYNTAX HYGIENE — fence-scoped, so grant-vocabulary PROSE stays legal --------------
# The lint reads ONLY the fenced code inside "### Read-only probe": the comparison-rule prose
# legitimately enumerates write-class privileges (INSERT, UPDATE, DELETE, …) and the tracker
# sections talk about "create/comment grants" — scoping to the fence exempts all of it by
# construction. Denylist = bin/sql_scan.py's high-risk vocabulary + non-ADD ALTER +
# statement-leading INSERT/CREATE. GRANT is statement-anchored (`^\s*GRANT `), NOT a word grep —
# the warehouse probes legitimately run `SHOW GRANTS …` introspection and must never trip it.
p51_dirty=""
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  case "$(p51_transport "$f")" in mcp|both) : ;; *) continue ;; esac
  fence="$(p51_fence "$f")"
  [ -n "$fence" ] || { p51_dirty="$p51_dirty $f(no-fence)"; continue; }
  grep -Eiqw 'CREATE[[:space:]]+OR[[:space:]]+REPLACE|DROP|TRUNCATE|DELETE|UPDATE|MERGE|REPLACE[[:space:]]+INTO|INSERT[[:space:]]+OVERWRITE|REVOKE|CALL|EXECUTE[[:space:]]+IMMEDIATE|EXECUTE[[:space:]]+TASK|COPY[[:space:]]+INTO|PUT|REMOVE|UNSET' <<<"$fence" \
    && p51_dirty="$p51_dirty $f(mutation-verb)"
  grep -Eiq '^[[:space:]]*GRANT[[:space:]]' <<<"$fence" && p51_dirty="$p51_dirty $f(grant-statement)"
  alt51="$(grep -Eiw 'ALTER' <<<"$fence" | grep -Eiv 'ALTER[[:space:]]+[A-Za-z_]+[[:space:]]+[^[:space:]]+[[:space:]]+ADD' || true)"
  [ -z "$alt51" ] || p51_dirty="$p51_dirty $f(non-add-alter)"
  grep -Eiq '^[[:space:]]*(INSERT|CREATE)([^A-Za-z_]|$)' <<<"$fence" && p51_dirty="$p51_dirty $f(leading-ddl)"
done
[ -z "$p51_dirty" ] \
  && ok "probe fence: syntax hygiene (denylist, not proof of read-only) — SHOW GRANTS introspection passes" \
  || bad "a posture probe fence carries mutation syntax (or has no fence at all)" "$p51_dirty"

# --- (C) per-adapter probe anchors, fence-scoped --------------------------------------------------
# Warehouse probes must DISCOVER the connection's actual principal/role (never assert a name —
# bring-your-own-role stands) and then INTROSPECT its grants; chat/tracker probes must be the read
# call the adapter's own auth: verify names. The discovery anchor accepts current[-_]user: Spark
# SQL spells the function current_user(), the CLI spells it current-user — both are the discovery.
p51_anchor=""
for f in adapters/*/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  case "$(p51_transport "$f")" in mcp|both) : ;; *) continue ;; esac
  fence="$(p51_fence "$f")"
  case "$f" in
    adapters/warehouse/*)
      { grep -Eiq 'CURRENT_ROLE|CURRENT_AVAILABLE_ROLES|current[-_]user' <<<"$fence" \
        && grep -Eiq 'SHOW GRANTS|information_schema' <<<"$fence"; } || p51_anchor="$p51_anchor $f" ;;
    */slack.md)   grep -q 'slack_search_channels' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */teams.md)   grep -Eq 'list-channels|list-teams' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */gmail.md)   grep -q 'search_threads' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */outlook.md) grep -q 'list_mail_folders' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */jira.md)    grep -Eq 'searchJiraIssuesUsingJql|workitem search' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */asana.md)   grep -Eq 'list-workspaces|typeahead' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */linear.md)  grep -Eq 'list-teams|list-issues' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    */monday.md)  grep -q 'list-boards' <<<"$fence" || p51_anchor="$p51_anchor $f" ;;
    *) p51_anchor="$p51_anchor $f(unmapped — extend this case)" ;;
  esac
done
[ -z "$p51_anchor" ] \
  && ok "probe anchors: warehouse fences discover-then-introspect; chat/tracker fences use their auth: read call" \
  || bad "a posture probe fence lost its read anchor" "$p51_anchor"

# --- (D) the posture table: 3 honest rows, NATIVE only where introspection exists ----------------
python3 - <<'PY' >"$TMP/p51_table.out"
import re, pathlib, sys
t = pathlib.Path('templates/AGENTS.md.tmpl').read_text(encoding='utf-8')
bad = []
m = re.search(r'<!-- ticketwright:posture:begin -->(.*?)<!-- ticketwright:posture:end -->', t, re.S)
if not m:
    print('no posture markers in templates/AGENTS.md.tmpl'); sys.exit()
rows = []
for line in m.group(1).splitlines():
    if not line.startswith('| '):
        continue
    cells = [c.strip() for c in line.strip().strip('|').split('|')]
    if cells[0] in ('Policy',) or set(''.join(cells)) <= set('- '):
        continue
    rows.append(cells)
if len(rows) != 3:
    bad.append(f'expected 3 policy rows, found {len(rows)}')
first = [r[0].strip('`') for r in rows]
for want in ('db_write_requires_approval', 'chat_default_draft', 'hard_halt_before_external_posts'):
    if want not in first:
        bad.append(f'missing policy row: {want}')
for r in rows:
    name, rest = r[0].strip('`'), ' '.join(r[1:])
    if 'NATIVE' in rest:
        if name != 'db_write_requires_approval':
            bad.append(f'NATIVE claimed on a seam with no introspection: {name}')
        if not ('once' in rest and 'comparison rule' in rest and 'posture.local.yaml' in rest):
            bad.append('the NATIVE cell lost its conditional (once … comparison rule … posture.local.yaml)')
    if name == 'chat_default_draft' and 'unverified' not in rest:
        bad.append('the chat row lost its `unverified` cap — the asymmetry must stay stated')
# the ENFORCEMENT block stays a closed world: section 44 parses its rows, so NATIVE never appears in one
e = re.search(r'<!-- ticketwright:enforcement:begin -->(.*?)<!-- ticketwright:enforcement:end -->', t, re.S)
if e is None:
    bad.append('no enforcement markers')
else:
    for line in e.group(1).splitlines():
        if line.startswith('| ') and 'NATIVE' in line:
            bad.append(f'NATIVE leaked into an enforcement-table row: {line[:70]}')
print(' ;; '.join(bad))
PY
p51_tbl="$(cat "$TMP/p51_table.out")"
[ -z "$p51_tbl" ] \
  && ok "posture table: 3 policy rows; NATIVE only on the DB row, conditional stated; chat capped unverified; enforcement rows NATIVE-free" \
  || bad "the posture table breaks its honesty contract" "$p51_tbl"

# --- (E) template pins (§49H style — flowed, so a rewrap can't fake a failure) --------------------
p51_flat="$(tr '\n' ' ' < templates/AGENTS.md.tmpl)"
{ grep -q 'NATIVE (tool-side)' <<<"$p51_flat" \
  && grep -q 'Permission posture (MCP)' <<<"$p51_flat" \
  && grep -q 'posture.local.yaml' <<<"$p51_flat" \
  && grep -q 'claimable only where a read-only privilege introspection exists' <<<"$p51_flat"; } \
  && ok "legend: NATIVE (tool-side) is defined with the introspection-only qualifier + the record file" \
  || bad "the template's NATIVE legend is missing or lost its qualifier"
{ grep -qi 'db_write_guard[^ ]* has the same jurisdiction limit' <<<"$p51_flat" \
  && grep -qi 'guidance the agent follows, not a gate the runtime enforces' <<<"$p51_flat"; } \
  && ok "both §49H jurisdiction phrases survive the posture edit verbatim" \
  || bad "a pinned jurisdiction phrase was reworded — extend around it, never rewrite it"
{ grep -q 'ticketwright:posture:begin' bin/emit_runtime.py && grep -q 'ticketwright:posture:end' bin/emit_runtime.py; } \
  && ok "bin/emit_runtime.py extracts the posture block (the cline artifact carries it too)" \
  || bad "bin/emit_runtime.py does not know the posture markers — cline users would never see the table"

# --- (F) wiring pins: setup surfaces, the record file, the contract doc --------------------------
p51_wire=""
for f in .claude/skills/setup/SKILL.md .claude/skills/setup/teammate.md .claude/skills/setup/interview.md; do
  grep -q 'Permission posture (MCP)' "$f" || p51_wire="$p51_wire $f"
done
[ -z "$p51_wire" ] \
  && ok "all three setup surfaces point at the adapters' posture sections by name" \
  || bad "a setup surface never surfaces the posture section" "$p51_wire"
TM51=".claude/skills/setup/teammate.md"
{ grep -q '`matches`' "$TM51" && grep -q '`exceeds-policy`' "$TM51" && grep -q '`unverified`' "$TM51" \
  && grep -q 'posture.local.yaml' "$TM51" && grep -qi 'comparison rule' "$TM51"; } \
  && ok "teammate.md defines the three outcome words + the record file + the comparison-rule reference" \
  || bad "teammate.md lost the posture-record vocabulary (matches / exceeds-policy / unverified + posture.local.yaml)"
grep -q 'posture.local.yaml' .claude/skills/setup/SKILL.md \
  && ok "the record file is named in setup/SKILL.md — the file the runtime installers actually emit" \
  || bad "the posture record is only in un-emitted sub-files, so two runtimes would never write it"
{ grep -q 'Permission posture (MCP)' adapters/README.md && grep -qi 'comparison rule' adapters/README.md \
  && grep -q 'unverified' adapters/README.md; } \
  && ok "adapters/README.md documents the posture contract (3-part section, probe, NATIVE needs a comparison rule)" \
  || bad "the posture contract is not documented for adapter authors"
# The FULL rule vocabulary, pinned per adapter — the read-class allowlist, the write-class
# trigger, AND the `unverified` fallback. A comparison rule missing any of the three legs can
# claim `matches` on partial visibility, which is exactly the false-NATIVE this feature forbids.
SF51="adapters/warehouse/snowflake.md"; sf51_flat="$(tr '\n' ' ' < "$SF51")"
{ grep -q 'USAGE, SELECT, REFERENCES, MONITOR, READ' <<<"$sf51_flat" \
  && grep -q 'OWNERSHIP' <<<"$sf51_flat" && grep -q '`status: exceeds-policy`' <<<"$sf51_flat" \
  && grep -q '`status: unverified`' <<<"$sf51_flat" && grep -q '`status: matches`' <<<"$sf51_flat"; } \
  && ok "snowflake rule carries all three legs (read-class allowlist, write-class trigger, unverified fallback)" \
  || bad "snowflake's comparison rule lost a leg — partial visibility could claim matches"
DB51="adapters/warehouse/databricks.md"; db51_flat="$(tr '\n' ' ' < "$DB51")"
# Databricks is CAP-BIASED by design: Unity Catalog privileges inherit and group grants apply,
# while SHOW GRANTS / information_schema list DIRECT grants only — so `matches` is writable ONLY
# from an effective-permission surface, and unobservable effective privileges yield `unverified`.
{ grep -q 'USE CATALOG, USE SCHEMA, BROWSE' <<<"$db51_flat" \
  && grep -q 'ALL PRIVILEGES' <<<"$db51_flat" && grep -q '`status: exceeds-policy`' <<<"$db51_flat" \
  && grep -q '`status: unverified`' <<<"$db51_flat" \
  && grep -qi 'inherit' <<<"$db51_flat" && grep -q 'EFFECTIVE-permission' <<<"$db51_flat" \
  && grep -Eq 'direct.grant listing can never prove' <<<"$db51_flat"; } \
  && ok "databricks rule is cap-biased: matches needs an effective-permission surface; direct grants alone cap at unverified" \
  || bad "databricks' comparison rule could claim matches from direct-grant views under UC inheritance"
# The record is DISPLAY-ONLY — never resolver-merged, never read by verify_stack beyond naming its
# path. Prove it: resolution (the verify plan) and verify_stack output are byte-identical with and
# without a populated record file in the fixture repo.
ISO51="$TMP/posture-iso"; mkdir -p "$ISO51/.claude/config"
cp .claude/config/stack.yaml "$ISO51/.claude/config/stack.yaml"
python3 bin/effective_config.py --stack "$ISO51/.claude/config/stack.yaml" --verify-plan \
  > "$TMP/iso51-res.a" 2>&1
CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$ISO51/.claude/config/stack.yaml" --dry-run \
  > "$TMP/iso51-vs.a" 2>&1
printf 'schema_version: 1\nchecked:\n  warehouse:\n    control: role discovered via the MCP connection\n    status: exceeds-policy\n    checked: 2026-08-25\n' \
  > "$ISO51/.claude/config/posture.local.yaml"
python3 bin/effective_config.py --stack "$ISO51/.claude/config/stack.yaml" --verify-plan \
  > "$TMP/iso51-res.b" 2>&1
CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$ISO51/.claude/config/stack.yaml" --dry-run \
  > "$TMP/iso51-vs.b" 2>&1
{ cmp -s "$TMP/iso51-res.a" "$TMP/iso51-res.b" && cmp -s "$TMP/iso51-vs.a" "$TMP/iso51-vs.b"; } \
  && ok "a populated posture.local.yaml is INERT: resolver plan + verify_stack output byte-identical" \
  || bad "posture.local.yaml leaked into resolution or verify output — it must stay display-only"
# The record is per-machine display state — it must be gitignored by the pattern the scaffold ships.
GIP51="$TMP/gi51"; mkdir -p "$GIP51/.claude/config"
git -C "$GIP51" init -q 2>/dev/null
cp templates/gitignore.tmpl "$GIP51/.gitignore"
: > "$GIP51/.claude/config/posture.local.yaml"
git -C "$GIP51" check-ignore -q .claude/config/posture.local.yaml 2>/dev/null \
  && ok "posture.local.yaml is gitignored by the scaffold (the *.local.yaml pattern)" \
  || bad "the posture record would be COMMITTED — the scaffold gitignore misses it"


hdr "51c · the posture advisory is BEHAVIORAL — verify_stack terminal states + the session banner"
# The advisory keys off the CONFIGURED unit's resolved transport (config wins, adapter frontmatter
# is the fallback), prints AFTER the row's terminal status (the unit line opens with a no-newline
# printf, so an early echo would splice into it), and never touches a counter or an exit code.
# ADJACENCY is the contract, not co-presence: the advisory must be the very next line after its
# row's terminal status — two independent greps would pass even if flush spliced into an open row.
p51adj() {  # in file $1, the line immediately after the one containing $2 must contain $3
  awk -v t="$2" -v n="$3" 'p { if (index($0, n)) ok=1; p=0 } index($0, t) { p=1 } END { exit ok?0:1 }' "$1"
}

# --- (A) dry-run over a both/mcp/cli mix: prod yes, tracker yes, chat yes, lake NO ----------------
mw51="$(bash bin/verify_stack.sh .claude/config/stack.example.multi-warehouse.yaml --dry-run 2>&1)"
printf '%s\n' "$mw51" > "$TMP/mw51.out"
{ grep -qF 'posture[warehouse[prod]*]: transport=both' <<<"$mw51" \
  && grep -qF 'adapters/warehouse/snowflake.md § Permission posture (MCP)' <<<"$mw51" \
  && grep -qF 'posture[tracker]: transport=both' <<<"$mw51" \
  && grep -qF 'adapters/tracker/jira.md § Permission posture (MCP)' <<<"$mw51" \
  && grep -qF 'posture[chat]: transport=mcp' <<<"$mw51"; } \
  && ok "multi-warehouse dry-run: posture advisories for prod(both) + tracker(both) + chat(mcp), each naming its adapter" \
  || bad "a resolved-transport advisory is missing from the multi-warehouse dry-run" "$mw51"
grep -qF 'posture[warehouse[lake]]' <<<"$mw51" \
  && bad "warehouse[lake] got a posture line — configured transport=cli must beat the adapter's both" \
  || ok "warehouse[lake] stays silent: configured cli wins over the adapter's both frontmatter"
grep -qF 'skipped: unresolved {profile}' <<<"$mw51" \
  && ok "…and [lake]'s unresolved-{profile} terminal branch coexists untouched in the same run" \
  || bad "the unresolved-token branch changed shape" "$mw51"
{ p51adj "$TMP/mw51.out" '→ would run: snow connection test' 'posture[warehouse[prod]*]: transport=both' \
  && p51adj "$TMP/mw51.out" '→ would run: acli jira workitem search' 'posture[tracker]: transport=both'; } \
  && ok "ADJACENT: each dry-run advisory is the very next line after its row's terminal status" \
  || bad "an advisory is not adjacent to its terminal status — flush spliced or drifted" "$mw51"

# --- (B) mcp-only seams both advise -----------------------------------------------------------------
ab51="$(bash bin/verify_stack.sh .claude/config/stack.example.asana-bq.yaml --dry-run 2>&1)"
{ grep -qF 'posture[tracker]: transport=mcp' <<<"$ab51" \
  && grep -qF 'adapters/tracker/asana.md § Permission posture (MCP)' <<<"$ab51" \
  && grep -qF 'posture[chat]: transport=mcp' <<<"$ab51" \
  && grep -qF 'adapters/chat/teams.md § Permission posture (MCP)' <<<"$ab51" \
  && ! grep -qF 'posture[warehouse]' <<<"$ab51"; } \
  && ok "asana-bq dry-run: tracker + chat advise (mcp); the cli warehouse stays silent" \
  || bad "mcp-only advisory wrong on the asana-bq stack" "$ab51"

# --- (C) the null-verify branch + the byte-exact §1 summary pin -----------------------------------
rs51="$(bash bin/verify_stack.sh .claude/config/stack.yaml --dry-run 2>&1)"; rs51rc=$?
printf '%s\n' "$rs51" > "$TMP/rs51.out"
{ [ "$rs51rc" -eq 0 ] \
  && grep -qF 'posture[chat]: transport=mcp' <<<"$rs51" \
  && grep -q 'MCP-only: not checkable from the shell' <<<"$rs51"; } \
  && ok "root stack: the chat advisory coexists with the null-verify MCP-only warning (both print, in order)" \
  || bad "the chat posture advisory broke the null-verify terminal branch" "rc=$rs51rc $(tail -5 <<<"$rs51")"
p51adj "$TMP/rs51.out" 'MCP-only: not checkable from the shell' 'posture[chat]: transport=mcp' \
  && ok "ADJACENT: the chat advisory is the very next line after the null-verify warning" \
  || bad "the chat advisory drifted from its null-verify terminal status" "$rs51"
{ grep -q 'skipped: unresolved {base_path}' <<<"$rs51" && ! grep -qF 'posture[docstore]' <<<"$rs51"; } \
  && ok "the cli docstore row keeps its unresolved warning and gains NO posture line" \
  || bad "the docstore row changed" "$rs51"
grep -qF '3 OK, 2 unverified (chat, docstore).' <<<"$rs51" \
  && ok "the §1 summary pin holds byte-for-byte — the advisory never touches a counter" \
  || bad "the advisory changed the summary line" "$(tail -3 <<<"$rs51")"

# --- (D) failed verify: the advisory still prints after ✗ UNREACHABLE, exit stays 1 ---------------
FV51="$TMP/fv51"; mkdir -p "$FV51"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: snowflake\n    adapter: adapters/warehouse/snowflake.md\n    transport: both\n    cli: snow\n    verify: "false"\n' > "$FV51/stack.yaml"
fv51="$(bash bin/verify_stack.sh "$FV51/stack.yaml" 2>&1)"; fv51rc=$?
printf '%s\n' "$fv51" > "$TMP/fv51.out"
{ [ "$fv51rc" -eq 1 ] && grep -q 'UNREACHABLE' <<<"$fv51" \
  && grep -qF 'posture[warehouse]: transport=both' <<<"$fv51"; } \
  && ok "an UNREACHABLE seam still gets its posture advisory, and the run still exits 1" \
  || bad "the advisory is lost (or the exit code moved) on the failed-verify branch" "rc=$fv51rc $fv51"
p51adj "$TMP/fv51.out" '✗ UNREACHABLE → false' 'posture[warehouse]: transport=both' \
  && ok "ADJACENT: the advisory is the very next line after ✗ UNREACHABLE" \
  || bad "the advisory drifted from the UNREACHABLE terminal status" "$fv51"

# --- (D2) the unsafe-token terminal branch: refused value, advisory still adjacent, exit 1 --------
UV51="$TMP/uv51"; mkdir -p "$UV51/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: databricks\n    adapter: adapters/warehouse/databricks.md\n    transport: both\n    warehouse_id: X\n    catalog: c\n    schema: s\n    verify: "databricks --profile {profile} current-user me"\n' > "$UV51/.claude/config/stack.yaml"
printf 'person: alice\nseams:\n  warehouse:\n    profile: "x; touch %s/PWNED51"\n' "$TMP" > "$UV51/.claude/config/connections.local.yaml"
rm -f "$TMP/PWNED51"
uv51="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh "$UV51/.claude/config/stack.yaml" 2>&1)"; uv51rc=$?
printf '%s\n' "$uv51" > "$TMP/uv51.out"
{ [ "$uv51rc" -eq 1 ] && grep -q 'refusing to run' <<<"$uv51" && [ ! -f "$TMP/PWNED51" ] \
  && grep -qF 'posture[warehouse]: transport=both' <<<"$uv51"; } \
  && ok "a metachar-refused token still gets its posture advisory (refused, never executed, exit 1)" \
  || bad "the unsafe-token terminal branch lost its advisory (or executed the value)" "rc=$uv51rc $uv51"
p51adj "$TMP/uv51.out" 'refusing to run: value for {profile}' 'posture[warehouse]: transport=both' \
  && ok "ADJACENT: the advisory is the very next line after the refusal" \
  || bad "the advisory drifted from the unsafe-token terminal status" "$uv51"

# --- (E) cli-only stacks are advisory-free ---------------------------------------------------------
nw51="$(bash bin/verify_stack.sh .claude/config/stack.example.no-warehouse.yaml --dry-run 2>&1)"
grep -qF 'posture[' <<<"$nw51" \
  && bad "a cli-only stack printed a posture advisory" "$nw51" \
  || ok "no-warehouse (all-cli) stack prints zero posture advisories"
az51="$(bash bin/verify_stack.sh .claude/config/stack.example.azure.yaml --dry-run 2>&1)"
{ ! grep -qF 'posture[tracker]' <<<"$az51" && ! grep -qF 'posture[warehouse' <<<"$az51" \
  && ! grep -qF 'posture[docstore]' <<<"$az51" && ! grep -qF 'posture[vcs]' <<<"$az51" \
  && grep -qF 'posture[chat[internal]*]: transport=mcp' <<<"$az51" \
  && grep -qF 'posture[chat[email]]: transport=mcp' <<<"$az51"; } \
  && ok "azure stack: cli seams silent; both mcp chat TARGETS advise under their own unit labels" \
  || bad "per-target advisory wrong on the azure stack" "$az51"

# --- (F) the session banner: five cases, keyed by resolved warehouse transport + policy mode ------
b51() {  # $1 = project dir → the SessionStart banner
  echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$1" \
    CLAUDE_CONFIG_DIR="$TMP/no-config" python3 .claude/hooks/session_context.py 2>&1
}
# (i) the kit's own stack: warehouse transport both + high_risk ⇒ the MCP wording.
bi51="$(b51 "$KIT")"
grep -qF 'DB writes: policy high_risk — Bash path hook-gated; MCP path advisory (tool-side controls, posture recorded at setup).' <<<"$bi51" \
  && ok "banner (kit stack): the DB-writes line names both paths — Bash hook-gated, MCP advisory" \
  || bad "the MCP-aware DB-writes banner line is missing" "$bi51"
# (ii) configured cli ⇒ plain jurisdiction wording, and no MCP claim anywhere in that line.
BP51="$TMP/b51-cli"; mkdir -p "$BP51/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: postgres\n    adapter: adapters/warehouse/postgres.md\n    transport: cli\n    cli: psql\npolicies:\n  db_write_requires_approval: high_risk\n' > "$BP51/.claude/config/stack.yaml"
bii51="$(b51 "$BP51")"
if grep -qF 'DB writes: policy high_risk — hook-gated (Bash jurisdiction).' <<<"$bii51"; then
  if grep 'DB writes: policy' <<<"$bii51" | grep -q 'MCP'; then
    bad "a cli-only warehouse banner line claims MCP" "$bii51"
  else
    ok "banner (cli warehouse): plain jurisdiction wording, no MCP substring in the DB-writes line"
  fi
else
  bad "the cli-warehouse DB-writes banner line is missing" "$bii51"
fi
# (iii) unknown transport (no transport key, adapter unreadable) ⇒ NEVER claims MCP.
BU51="$TMP/b51-unknown"; mkdir -p "$BU51/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: mystery\n    adapter: adapters/warehouse/does-not-exist.md\npolicies:\n  db_write_requires_approval: high_risk\n' > "$BU51/.claude/config/stack.yaml"
biii51="$(b51 "$BU51")"
grep -qF 'DB writes: policy high_risk — hook-gated (Bash jurisdiction).' <<<"$biii51" \
  && ok "banner (unknown transport): falls to the plain wording — unknown never claims MCP" \
  || bad "an unknown transport produced the wrong DB-writes line" "$biii51"
# (iv) policy off ⇒ no advisory line at all (the policy summary already says NOT gated).
BO51="$TMP/b51-off"; mkdir -p "$BO51/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  warehouse:\n    tool: snowflake\n    adapter: adapters/warehouse/snowflake.md\n    transport: both\n    cli: snow\npolicies:\n  db_write_requires_approval: off\n' > "$BO51/.claude/config/stack.yaml"
biv51="$(b51 "$BO51")"
grep -qF 'DB writes: policy' <<<"$biv51" \
  && bad "policy off still printed a DB-writes advisory line" "$biv51" \
  || ok "banner (policy off): no DB-writes advisory line"
# (v) no warehouse seam ⇒ no line.
BN51="$TMP/b51-none"; mkdir -p "$BN51/.claude/config"
printf 'project:\n  key_prefix: ENG\nseams:\n  tracker:\n    tool: local\n    adapter: adapters/tracker/local.md\n    transport: cli\npolicies:\n  db_write_requires_approval: high_risk\n' > "$BN51/.claude/config/stack.yaml"
bv51="$(b51 "$BN51")"
grep -qF 'DB writes: policy' <<<"$bv51" \
  && bad "a warehouse-less repo printed a DB-writes advisory line" "$bv51" \
  || ok "banner (no warehouse): no DB-writes advisory line"
hdr "51d · the meetings tool slot (PROMPT: meetings-intake, stage 2)"
# The sixth tool slot, shipped after the bar judgment recorded in ROADMAP.md. Cases A-E are
# behavioral and each names what it executes; the pins at the end are labeled structural (the
# section-49 F-H convention). Regression note: section 49 (meetings INTAKE + the source-material
# guard) runs unmodified in this same suite — stage 2 adds no new mechanical enforcement there;
# the one new mechanical piece is bin/meeting_refs.py's parse-time credential refusal. Honest
# limit: the skill orchestration itself (fetch → curate in-context) is prose no selftest executes.
S51D="$TMP/s51d"; mkdir -p "$S51D"
MRFIX="tests/meeting_refs/fixtures"

# --- (A) config resolution — executes: bin/effective_config.py ----------------------------------
mkdir -p "$S51D/cfg/.claude/config"
cp .claude/config/stack.example.multi-audience.yaml "$S51D/cfg/.claude/config/stack.yaml"
a51="$(python3 bin/effective_config.py --root "$S51D/cfg" --seam meetings 2>/dev/null)"; a51rc=$?
{ [ "$a51rc" -eq 0 ] && grep -q '"tool": "zoom"' <<<"$a51" \
  && grep -q 'adapters/meetings/zoom.md' <<<"$a51"; } \
  && ok "effective_config resolves seams.meetings (exit 0, tool + adapter populated)" \
  || bad "the meetings seam does not resolve through the config resolver" "rc=$a51rc $(head -3 <<<"$a51")"
mkdir -p "$S51D/solo/.claude/config"
cp .claude/config/stack.example.solo.yaml "$S51D/solo/.claude/config/stack.yaml"
python3 bin/effective_config.py --root "$S51D/solo" --seam meetings >/dev/null 2>&1; a51n=$?
[ "$a51n" -eq 7 ] \
  && ok "an absent meetings seam exits 7 (no_such_seam — the one code a caller may degrade on)" \
  || bad "absent meetings seam should exit 7, got $a51n"

# --- (B) seam discovery — executes: bin/verify_stack.sh -----------------------------------------
b51="$(CLAUDE_PLUGIN_ROOT="$KIT" bash bin/verify_stack.sh .claude/config/stack.example.multi-audience.yaml --dry-run 2>&1)"
{ grep -q 'meetings' <<<"$b51" && ! grep -q 'adapter missing' <<<"$b51"; } \
  && ok "verify_stack --dry-run resolves the meetings seam to its adapter (seam-generic)" \
  || bad "verify_stack does not resolve the meetings seam" "$(grep -i 'meetings\|missing' <<<"$b51" | head -3)"

# --- (C) the banner — executes: .claude/hooks/session_context.py --------------------------------
c51="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$S51D/cfg" python3 .claude/hooks/session_context.py 2>&1)"
grep -q 'meetings=zoom' <<<"$c51" \
  && ok "session banner names the configured meetings tool (meetings=zoom)" \
  || bad "banner hides a configured meetings slot" "$(grep 'Stack' <<<"$c51")"
c51n="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$S51D/solo" python3 .claude/hooks/session_context.py 2>&1)"
grep -q 'meetings=—' <<<"$c51n" \
  && ok "session banner ALWAYS prints the meetings slot (meetings=— when absent)" \
  || bad "banner omits the meetings slot when absent (it must print meetings=—)" "$(grep 'Stack' <<<"$c51n")"

# --- (D) render round-trip — executes: bin/render.sh (the section-36 fixtures carry the
#         absent-slot half: /setup tool meetings renders when the slot is omitted) ---------------
d51="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$TMP/vars.env" 2>"$S51D/d.err")"
{ grep -q 'Meetings' <<<"$d51" && grep -qF 'adapters/meetings/zoom.md' <<<"$d51" \
  && [ ! -s "$S51D/d.err" ]; } \
  && ok "the stack table renders a Meetings row from whole-path tokens (zero leftover tokens)" \
  || bad "the Meetings row is missing or left a token" "$(cat "$S51D/d.err")"

# --- (E) the reference parser — executes: bin/meeting_refs.py ------------------------------------
# E1 valid ref → JSON exit 0 (with the optional meeting_date carried through).
mkdir -p "$S51D/t1/source_materials"
cp "$MRFIX/2026-08-18-kickoff-meeting.md" "$S51D/t1/source_materials/"
e1="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t1 --json 2>&1)"; e1rc=$?
{ [ "$e1rc" -eq 0 ] && grep -q '"provider": "acmemeet"' <<<"$e1" \
  && grep -q '"id": "mtg-0042/rec-7"' <<<"$e1" && grep -q '"meeting_date": "2026-08-18"' <<<"$e1"; } \
  && ok "E1: a valid meeting_ref parses to JSON, exit 0" \
  || bad "E1: valid ref failed" "rc=$e1rc $e1"
# E2 multiple refs, filename-ordered (the date prefix gives chronology); a no-ref stub is skipped.
mkdir -p "$S51D/t2/source_materials"
cp "$MRFIX/2026-08-20-pricing-review-meeting.md" "$MRFIX/2026-08-18-kickoff-meeting.md" \
   "$MRFIX/no-ref-notes.md" "$S51D/t2/source_materials/"
e2="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t2 --json 2>&1)"; e2rc=$?
e2first="$(grep -o '"file": "[^"]*"' <<<"$e2" | head -1)"
{ [ "$e2rc" -eq 0 ] && [ "$(grep -c '"provider"' <<<"$e2")" -eq 2 ] \
  && grep -q '2026-08-18-kickoff-meeting.md' <<<"$e2first" \
  && grep -q '"id": "Q3~review=2026+final"' <<<"$e2"; } \
  && ok "E2: multiple stubs return filename-ordered refs (quoted opaque id unquoted + validated)" \
  || bad "E2: ordering or quoted-id handling wrong" "rc=$e2rc $e2first"
# E3 invalid grammar → exit 4 with the offending file NAMED (never silence).
mkdir -p "$S51D/t3/source_materials"
cp "$MRFIX/2026-08-21-invalid-grammar-meeting.md" "$S51D/t3/source_materials/"
e3="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t3 --json 2>&1)"; e3rc=$?
{ [ "$e3rc" -eq 4 ] && grep -q 'invalid-grammar-meeting.md' <<<"$e3" \
  && grep -q '"reason": "invalid-grammar"' <<<"$e3"; } \
  && ok "E3: an invalid ref is a NAMED error, exit 4 — never silence" \
  || bad "E3: invalid grammar not surfaced as a named error" "rc=$e3rc $e3"
# E4 no ref at all → refs: [] exit 0 — the no-speculative-fetch silence, proven mechanically.
mkdir -p "$S51D/t4/source_materials"
cp "$MRFIX/no-ref-notes.md" "$S51D/t4/source_materials/"
e4="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t4 --json 2>&1)"; e4rc=$?
{ [ "$e4rc" -eq 0 ] && grep -q '"refs": \[\]' <<<"$e4"; } \
  && ok "E4: no reference ⇒ refs: [] exit 0 (silence is mechanical, never a guess)" \
  || bad "E4: the no-ref case is not silent-with-exit-0" "rc=$e4rc $e4"
# E5 credential-bearing value → exit 4, reason refused-credential (distinct from grammar errors).
mkdir -p "$S51D/t5/source_materials"
cp "$MRFIX/2026-08-22-credential-url-meeting.md" "$S51D/t5/source_materials/"
e5="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t5 --json 2>&1)"; e5rc=$?
{ [ "$e5rc" -eq 4 ] && grep -q '"reason": "refused-credential"' <<<"$e5"; } \
  && ok "E5: a credential-bearing ref is refused at parse time (exit 4, reason refused-credential)" \
  || bad "E5: credential refusal missing or mislabeled" "rc=$e5rc $e5"
# E5c a ref OUTSIDE the canonical *-meeting.md stub is refused (misplaced-ref), never honored OR
# silently ignored — including in a nested directory and a non-.md file ("any other filename is
# refused" is the schema's contract). Body-prose mentions of the key must NOT trip the sweep.
mkdir -p "$S51D/t7/source_materials/archive"
cp "$MRFIX/misplaced-ref-notes.md" "$S51D/t7/source_materials/"
cp "$MRFIX/misplaced-ref-notes.md" "$S51D/t7/source_materials/archive/nested-notes.md"
printf -- '---\nmeeting_ref: acmemeet:mtg-77\n---\nbody\n' > "$S51D/t7/source_materials/export.txt"
printf 'prose mentioning meeting_ref: syntax in the BODY only\n' > "$S51D/t7/source_materials/2026-08-19-clean-meeting.md"
e5c="$(python3 bin/meeting_refs.py --root "$S51D" --ticket t7 --json 2>&1)"; e5crc=$?
{ [ "$e5crc" -eq 4 ] && [ "$(grep -c '"reason": "misplaced-ref"' <<<"$e5c")" -eq 3 ] \
  && grep -q 'misplaced-ref-notes.md' <<<"$e5c" \
  && grep -q 'archive/nested-notes.md' <<<"$e5c" \
  && grep -q 'export.txt' <<<"$e5c" \
  && ! grep -q '2026-08-19-clean-meeting.md' <<<"$e5c" \
  && grep -q '"refs": \[\]' <<<"$e5c"; } \
  && ok "E5c: misplaced refs are refused by name (top-level .md, nested .md, non-.md) — body prose is not swept" \
  || bad "E5c: a misplaced meeting_ref was honored, dropped silently, or prose false-tripped" "rc=$e5crc $e5c"
# E5b a YAML list is invalid — one meeting per stub is the contract.
mkdir -p "$S51D/t6/source_materials"
cp "$MRFIX/2026-08-23-list-refs-meeting.md" "$S51D/t6/source_materials/"
python3 bin/meeting_refs.py --root "$S51D" --ticket t6 --json >"$S51D/e5b.out" 2>&1; e5brc=$?
{ [ "$e5brc" -eq 4 ] && grep -q '"reason": "list-not-allowed"' "$S51D/e5b.out"; } \
  && ok "E5b: a meeting_ref list is invalid (exactly one ref per stub)" \
  || bad "E5b: a list of refs was not refused" "rc=$e5brc"
# The exit family is the contract callers branch on: 0 ok · 2 usage · 4 malformed-or-refused.
python3 bin/meeting_refs.py --root "$S51D" --ticket does-not-exist >/dev/null 2>&1; e5urc=$?
[ "$e5urc" -eq 2 ] && ok "usage errors exit 2 (missing ticket dir)" \
  || bad "usage error should exit 2, got $e5urc"
# Config-free by design: matching the ref's provider against seams.meetings.tool is skill-side.
# (The docstring may NAME stack.yaml/effective_config while stating it never reads them, so this
# pins the imports, not the prose.)
mrcfg="$(grep -nE '^(import|from)[[:space:]].*(_yamlite|effective_config)' bin/meeting_refs.py || true)"
[ -z "$mrcfg" ] \
  && ok "meeting_refs.py is config-free (no config-reader import; provider match is skill-side)" \
  || bad "meeting_refs.py imports a config reader — it must stay purely syntactic" "$mrcfg"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
  python3 bin/meeting_refs.py --root "$S51D" --ticket t1 --json >/dev/null 2>&1 \
  && ok "meeting_refs.py needs no Claude environment variable (harness-neutral)" \
  || bad "meeting_refs.py depends on a CLAUDE_* variable"

# --- structural pins, labeled as such (the section-49 F-H convention) ----------------------------
# Pin: every meetings adapter carries the exact 3 contract verbs BY NAME (section 2 counts them;
# this catches a typo'd verb that still counts).
mv51=""
for f in adapters/meetings/*.md; do
  for v in fetch_transcript search_meetings fetch_action_items; do
    grep -q "^## verb: $v" "$f" || mv51="$mv51 $(basename "$f"):$v"
  done
done
[ -z "$mv51" ] && ok "pin: every meetings adapter names all 3 contract verbs exactly" \
  || bad "a meetings adapter misses or misspells a contract verb" "$mv51"
# Pin: the transcript-privacy rule VERBATIM in every fetch_transcript section, with the honesty
# sentence naming the mechanical gates' limit (shape, never meaning). Prose pins, labeled as such.
pv51=""
for f in adapters/meetings/*.md; do
  # Flatten the section (the section-49 enf_flat convention): the verbatim sentence wraps across
  # lines, and a line-oriented grep would pass or fail on where the author happened to break it.
  sec="$(sed -n '/^## verb: fetch_transcript$/,/^## /p' "$f" | tr '\n' ' ')"
  grep -qF 'Curated excerpts and action items are committed; raw full transcripts are not, by default.' <<<"$sec" \
    || pv51="$pv51 $(basename "$f"):rule"
  grep -q 'filenames and document shape, never meaning' <<<"$sec" \
    || pv51="$pv51 $(basename "$f"):honesty"
done
[ -z "$pv51" ] && ok "pin: the verbatim privacy rule + honesty sentence sit in every fetch_transcript" \
  || bad "a meetings adapter's fetch_transcript lacks the verbatim rule or the honesty sentence" "$pv51"
# Pin: the typed fetch_action_items contract is documented in the contract table, all three statuses.
{ grep -q 'status: ok | empty | no_native_export' adapters/README.md \
  && grep -q 'never a runtime probe' adapters/README.md; } \
  && ok "pin: the typed ok/empty/no_native_export contract is documented (static declaration stated)" \
  || bad "adapters/README.md lost the typed fetch_action_items contract"
# Pin: ticket/SKILL.md carries the COMPLETE operative rule (not a pointer): the full portable
# launcher invocation, the silence rule, and never-write-raw.
TK51=".claude/skills/ticket/SKILL.md"
grep -qF 'bin/tw" meeting_refs.py --ticket' "$TK51" \
  && ok "pin: ticket/SKILL.md enumerates refs via the full portable launcher invocation" \
  || bad "ticket/SKILL.md lacks the full bin/tw meeting_refs.py invocation"
tk51flat="$(tr '\n' ' ' < "$TK51")"
{ grep -qi 'never fetch speculatively' <<<"$tk51flat" && grep -q 'no_native_export' <<<"$tk51flat" \
  && grep -qi 'never write the raw transcript' <<<"$tk51flat"; } \
  && ok "pin: the complete rule states silence, the typed statuses, and never-save-raw" \
  || bad "ticket/SKILL.md's meetings rule is a pointer, not the complete rule"


hdr "52 · selftest itself parses under stock macOS bash 3.2 (self-lint)"
# bash 3.2 — /bin/bash on every Mac — mis-scans a heredoc nested inside $( ): backticks,
# apostrophes, or parens in the BODY desync the parser, hundreds of sections print ✓, and the run
# dies mid-file with a syntax error (observed live by three teammates, three releases in a row:
# 6 sites in v3.6.1 grew to 9 by v3.7.0+). Every such site is written heredoc-first instead:
#   python3 - <<'TAG' >"$TMP/out"  …  TAG   then   var="$(cat "$TMP/out")"
# This lint keeps the forbidden shape out of the file on EVERY platform, so a Linux CI run or a
# Homebrew-bash Mac still catches what only a stock Mac would hit at runtime.
# The regex is best-effort static coverage (same-line `$(` + `<<`, comments excluded); the
# AUTHORITATIVE enforcement is the /bin/bash -n proof below plus CI's macOS job running the full
# suite under 3.2 — a multi-line `$( )` split across lines can only be caught by a real parser.
hd52="$(grep -nE '\$\(.*<<-?['"'"'\"]?[A-Za-z]' bin/selftest.sh | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v '52 ·' | grep -v 'hd52=' || true)"
[ -z "$hd52" ] && ok "no same-line heredoc inside \$( ) in selftest (static lint; the -n proof below is authoritative)" \
  || bad "a heredoc inside \$( ) crept back in — stock macOS bash 3.2 cannot parse it; capture via a temp file instead" "$hd52"
# And when a bash 3.2 actually exists on this machine, prove the promise directly.
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null; then
  /bin/bash -n bin/selftest.sh 2>"$TMP/hd52.err" \
    && ok "/bin/bash (3.2) parses selftest end to end" \
    || bad "/bin/bash (3.2) cannot parse selftest" "$(head -2 "$TMP/hd52.err")"
fi


printf "\n\033[1mselftest: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
