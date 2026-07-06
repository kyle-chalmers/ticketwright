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
role_focus=**You are a senior engineer** doing ticket-driven work (filled from templates/roles/<role>.md).
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

printf "\n\033[1mselftest: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
