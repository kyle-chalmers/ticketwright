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
bad()  { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$1"; }

hdr "0 · tooling"
command -v yq  >/dev/null 2>&1 && ok "yq present" || bad "yq missing (brew install yq)"
command -v python3 >/dev/null 2>&1 && ok "python3 present" || bad "python3 missing"

hdr "1 · config parses + every seam resolves to an adapter (all stacks)"
for s in .claude/config/stack.yaml .claude/config/stack.example.*.yaml; do
  if yq -e '.seams|keys' "$s" >/dev/null 2>&1; then ok "parses: $s"; else bad "parse error: $s"; fi
  out="$(bash bin/verify_stack.sh "$s" --dry-run 2>&1)"
  if grep -q "All seams OK" <<<"$out" && ! grep -q "adapter missing" <<<"$out"; then
    ok "all seams resolve: $s"
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
EOF
err="$(bash bin/render.sh templates/AGENTS.md.tmpl --vars "$TMP/vars.env" 2>&1 >/dev/null)"
[ -z "$err" ] && ok "AGENTS.md renders with zero leftover tokens" || bad "unresolved tokens in AGENTS.md" "$err"
# zero KEY=VALUE pairs must not crash (bash 3.2 empty-array under set -u)
bash bin/render.sh templates/spec.md.tmpl >/dev/null 2>"$TMP/rz.err"; rc=$?
[ "$rc" -eq 0 ] && ok "render.sh with no vars doesn't crash (bash 3.2 empty array)" || bad "render.sh crashes with zero pairs" "$(cat "$TMP/rz.err")"

hdr "6 · db_write_guard hook (PreToolUse policy enforcement)"
guard() { python3 .claude/hooks/db_write_guard.py; }
# read-only inline SELECT → no decision (allow through)
out="$(echo '{"tool_name":"Bash","tool_input":{"command":"snow sql -q \"SELECT * FROM t LIMIT 5\""}}' | guard)"
[ -z "$out" ] && ok "SELECT passes through (no prompt)" || bad "SELECT wrongly gated" "$out"
# inline destructive UPDATE → ask
out="$(echo '{"tool_name":"Bash","tool_input":{"command":"snow sql -q \"UPDATE t SET x=1\""}}' | guard)"
grep -q '"permissionDecision": "ask"' <<<"$out" && grep -q UPDATE <<<"$out" && ok "inline UPDATE → ask" || bad "UPDATE not gated" "$out"
# destructive SQL inside a -f file → ask (the strengthened file scan)
echo "CREATE OR REPLACE TABLE foo AS SELECT 1;" > "$TMP/deploy.sql"
out="$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"snow sql -f $TMP/deploy.sql\"},\"cwd\":\"/\"}" | guard)"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "-f deploy.sql (CREATE OR REPLACE) → ask" || bad "file-based write not gated" "$out"
# read-only -f file → no decision
echo "SELECT count(*) FROM t;" > "$TMP/qc.sql"
out="$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"snow sql -f $TMP/qc.sql\"},\"cwd\":\"/\"}" | guard)"
[ -z "$out" ] && ok "-f qc.sql (SELECT only) passes through" || bad "read-only file wrongly gated" "$out"
# non-warehouse bash → no decision
out="$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | guard)"
[ -z "$out" ] && ok "non-warehouse bash passes through" || bad "non-warehouse wrongly gated" "$out"
# non-Bash tool → no decision
out="$(echo '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | guard)"
[ -z "$out" ] && ok "non-Bash tool passes through" || bad "non-Bash wrongly gated" "$out"
# destructive SQL via stdin redirect (psql < file.sql) → ask (the strengthened stdin scan)
echo "DELETE FROM t WHERE 1=1;" > "$TMP/wipe.sql"
out="$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"psql mydb < $TMP/wipe.sql\"},\"cwd\":\"/\"}" | guard)"
grep -q '"permissionDecision": "ask"' <<<"$out" && ok "psql < wipe.sql (stdin redirect) → ask" || bad "stdin-redirect write not gated" "$out"

hdr "7 · session_context hook (SessionStart priming)"
out="$(echo '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$KIT" python3 .claude/hooks/session_context.py 2>&1)"
grep -q "ENG" <<<"$out" && grep -qi "PIV loop" <<<"$out" && ok "emits stack + PIV summary" || bad "session context missing/empty" "$out"

hdr "8 · statusline renders"
out="$(echo '{}' | CLAUDE_PROJECT_DIR="$KIT" bash .claude/statusline.sh 2>&1)"
grep -q "ENG" <<<"$out" && ok "statusline: $out" || bad "statusline empty/broken" "$out"

hdr "9 · productize-workflow stamp smoke (SKILL.md.tmpl → 0 leftover tokens)"
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
head -6 .claude/commands/recall.md | grep -q 'allowed-tools' && ok "/recall command has frontmatter" || bad "/recall frontmatter missing"
# regression: same id under two owners — --for --owner must keep the OTHER owner's ticket as a candidate
M="$TMP/multiowner"; mkdir -p "$M/.claude/config" "$M/tickets/alice/ENG-5" "$M/tickets/bob/ENG-5"
printf 'project:\n  key_prefix: ENG\n' > "$M/.claude/config/stack.yaml"
printf '# ENG-5: alice payment recovery\n\nshared payment recovery loan tape work.\n' > "$M/tickets/alice/ENG-5/README.md"
printf '# ENG-5: bob payment recovery\n\nshared payment recovery loan tape work.\n' > "$M/tickets/bob/ENG-5/README.md"
mo="$(CLAUDE_PROJECT_DIR="$M" python3 bin/recall.py --for ENG-5 --owner alice --json 2>/dev/null | python3 -c "import json,sys; print(','.join(x['owner']+'/'+x['id'] for x in json.load(sys.stdin)))")"
grep -q 'bob/ENG-5' <<<"$mo" && ok "recall --for keeps same-id ticket under another owner" || bad "seed exclusion dropped same-id/other-owner" "$mo"
amb="$(CLAUDE_PROJECT_DIR="$M" python3 bin/recall.py --for ENG-5 2>&1 >/dev/null)"
grep -q 'multiple owners' <<<"$amb" && ok "recall errors on ambiguous seed (no --owner)" || bad "ambiguous seed not flagged" "$amb"

hdr "12 · privacy guard (no real ticket store committed to the public kit)"
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

printf "\n\033[1mselftest: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
