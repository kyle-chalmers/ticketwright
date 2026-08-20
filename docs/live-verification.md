# Live verification — the punch list

This kit's test contract is read-only, offline, and credential-free. Wave F2 (PROMPT 7, U1–U5)
shipped everything that contract can prove: the installer emits the right artifacts byte-for-byte,
the shims speak each runtime's documented protocol, the safety collapses are stated in files users
read, and the Claude Code path is unchanged. What that contract can **never** witness is a live
runtime loading, trusting, or honoring any of it. This page is that residue, written down: one
entry per parked claim, each naming the runtime, the preconditions, the exact steps a human with
that runtime must run, the observation that counts as PASS, and the mechanical edits a PASS
triggers.

Three rules govern this list:

- **No selftest assertion may claim an entry passed.** The suite (`bin/selftest.sh` section 44)
  checks that verification is *owed and tracked* — only a human with the runtime can pay it.
- **The honesty linkage is mechanical.** Every `unknown` or `unverified` value in
  `adapters/runtime/*.md` frontmatter, every WIRED cell in the enforcement table
  (`templates/AGENTS.md.tmpl`), every emitted artifact carrying an "unverified" label, and every
  adapter metadata-mapping row marked "(unverified)" must be claimed on some entry's `Covers:`
  line here, or the suite goes red. An unverified claim cannot exist in this kit without a
  tracked way to verify it.
- **The linkage is one-directional.** When an entry passes, its `Covers:` tokens stay (the entry
  becomes the record of the verification); the frontmatter value it covered flips to a real value,
  so the forward requirement simply disappears. Checking an entry off never breaks the suite.

**Token grammar** (what section 44 reads — exact backticked spans on `Covers:` lines only, never
prose and never substrings, so a token mentioned in an example cannot satisfy the linkage and
`codex-cli.hook_wiring` can never accidentally cover a future `codex-cli.hook`): a frontmatter
unknown is covered by the literal token `` `<tool>.<key>` `` (e.g. `` `antigravity.gate_fail_mode` ``); a WIRED
enforcement-table cell by `` `<tool>.wired.<hook>` `` (e.g. `` `cursor.wired.db_write_guard` ``);
an unverified-labeled emitted artifact by its project-relative path (e.g. `` `.cursor/hooks.json` ``);
a "(unverified)" metadata-mapping row by the emitted qc-reviewer path its adapter's `agents_root`
declares — or, where no `agents_root` is declared, by the fallback token
`` `<tool>.metadata_mapping` ``. A `Covers:` line runs from `Covers:` to the next blank line.

**Status convention**: every entry starts `Status: OPEN`. On pass, it becomes
`Status: VERIFIED <YYYY-MM-DD> — <runtime name + version> — <observer>`, and an `Evidence:`
paragraph is appended to the entry stating what was actually observed (payloads, exit codes,
version strings — enough for the next person to re-run it). A partial pass **splits the entry**
rather than half-checking it: several entries below bundle multiple axes for reading convenience,
and any axis a session does not establish moves to its own OPEN entry with its tokens. A FAIL is
recorded too: keep `Status: OPEN`, append a dated `Observed:` line with what actually happened,
and correct `docs/runtimes.md` if the failure contradicts a cited claim — a documented failure is
a finding, not a gap.

---

## Recording a result — the general protocol

Every PASS lands as one commit containing all of:

1. **The adapter flip.** The covered `adapters/runtime/<tool>.md` frontmatter key changes from
   `unknown`/`unverified` to the observed value, with the access date in its inline comment
   (the vocabulary is closed — see `bin/selftest.sh` section 40's `ENUMS`).
2. **The pins that move.** Selftest pins exist precisely so a drive-by edit cannot flip a safety
   axis silently — a *live-verified* flip moves the pin deliberately, in the same commit:
   - `gate_ask_tier` / `gate_fail_mode` / `subagent_isolation` value flips → the matching pin
     loop in section 40 (e.g. `antigravity:unknown` for `gate_fail_mode`).
   - `hook_wiring` / `hook_protocol` flips → the `PIN` dict at the tail of section 43.
   - Enforcement-table cell changes → the promotion protocol below.
3. **The research re-date.** The matching bullet in `docs/runtimes.md` is updated with the
   observation and its date (that page's header demands dated findings, never undated edits).
4. **The entry check-off.** This page's `Status:` line flips and the `Evidence:` paragraph lands;
   `Covers:` tokens stay.
5. **The gate.** `bash bin/selftest.sh` prints `0 failed` after the pin moves — if it does not,
   a pin you did not expect to move is telling you the flip has a consumer you missed.

## The WIRED → ENFORCEMENT promotion protocol

The enforcement table in `templates/AGENTS.md.tmpl` reserves **ENFORCEMENT** for mechanisms proven
inside this repo's own test contract (today: the Claude Code row). An emitted-but-live-unverified
mechanism is **WIRED**, and a live confirmation here is the *only* thing that promotes it
(adversarial-review ruling on #46). **Promotion is per cell, never per entry** — entry 4 covers
two independently promotable Antigravity cells, and observing one must not promote the other.
The promotion is mechanical — one commit containing:

1. **The ledger line.** Add to the Promotion ledger at the bottom of this page:
   `PROMOTED <tool>.wired.<hook> <YYYY-MM-DD> — <runtime + version> — <observer>`. Selftest
   section 44 requires every non-Claude ENFORCEMENT cell in the template to have this line — a
   cell cannot reach ENFORCEMENT by editing the template and its pins alone.
2. **The cell.** In `templates/AGENTS.md.tmpl`, the promoted cell's `WIRED (…)` becomes
   `ENFORCEMENT (…)`, keeping the artifact name and adding the verification date.
3. **The section 43 pins** (`bin/selftest.sh`), three of them:
   - the "only a live confirmation may promote WIRED" loop must exempt the promoted
     (runtime, cell) pair — keep the loop, add the explicit exemption naming this page;
   - the WIRED-set pin for that cell (`guard cell must be WIRED naming <artifact>`, or the
     Antigravity regenerate-cell pin) flips to expect `ENFORCEMENT` with the same artifact name;
   - the `.clinerules` fixture greps (`| Cursor | WIRED` …) update if the promoted row is one
     they read.
4. **The fixture.** `tests/emit/cline/.clinerules/ticketwright-enforcement.md` is extracted from
   the template's markers at emit time and diffed byte-for-byte — regenerate it per
   `tests/emit/README.md` in the same commit.
5. **The adapter.** The tool's `hook_wiring_caveat` drops its "live-unverified" clause and gains
   the dated observation. Any axis the same session resolved (e.g. Antigravity's
   `gate_fail_mode`) follows the general protocol above.
6. **The docs.** `docs/runtimes.md` re-dated; this entry checked off.
7. `bash bin/selftest.sh` → `0 failed`.

What the pins can and cannot certify, stated plainly: moving them proves the promotion was
*deliberate and complete*, not that the observation *happened* — no offline suite can witness a
live runtime. The evidence binding is the ledger line plus the entry's `Evidence:` paragraph
(date, runtime version, observer, what was seen), and a promotion commit without them does not
pass review.

**GUIDANCE → WIRED is a code change, not a doc edit.** Codex CLI and Devin sit at GUIDANCE because
their hooks-CONFIG file locations are unresearched — the installer refuses to guess a path. When
entry 1 or entry 5 establishes the location live, wiring it is a follow-up implementation:
`emit_hooks` in `bin/emit_runtime.py` grows that runtime, the adapter's `hook_wiring` flips from
`unknown` to the real path (moving section 43's `PIN` dict), section 43's "guard cell must be
GUIDANCE" pin for that runtime moves, and `tests/emit/<runtime>/` grows the new artifact. The new
cell enters as WIRED — honoring it live is a *further* observation before ENFORCEMENT.

---

## The entries

### 1. Codex CLI — the success criterion (two stages, by design)

Status: OPEN (both stages)
Covers: `codex-cli.hook_wiring` `codex-cli.gate_fail_mode`

**Claim to verify.** PROMPT 7's own success criterion: a Codex CLI user installs, runs setup,
opens an analysis, reviews it, and ships it **without hand-editing a single file**. Until a human
checks this off, prompt 7's criterion is OPEN — U1–U5 proved only that the artifacts are emitted
correctly.

**Why two stages.** The criterion cannot pass in one visit today, and pretending otherwise would
be the dishonesty this list exists to prevent: the installer deliberately emits **no** Codex hook
config — the hooks-CONFIG file location is not in the kit's research, so it prints a manual
wiring line instead of guessing a path. A run that hand-wires the hook has, by definition,
hand-edited a file. So: Stage A establishes the facts (hand-wiring allowed); a follow-up code
change teaches the emitter the now-known location (the GUIDANCE → WIRED change named in the
promotion protocol); Stage B then runs the criterion proper against the improved installer. The
criterion is met only when Stage B passes.

**Preconditions.** An authenticated Codex CLI install (`command -v codex`); a fresh git repo with
a warehouse the tracker-less demo flow can use (fixture data is fine); ticketwright installed as
a package or checked out.

**Stage A — establish the facts (hand-wiring allowed).**
1. `ticketwright init` (or copy the kit), then `ticketwright install --runtime codex-cli`.
   Expect: skills emitted under `.agents/skills/` with provenance headers, user-invocable-only
   skills carrying their topmost warning block, `.codex/agents/qc-reviewer.toml`, and the printed
   manual hook-wiring line — no hook config file is emitted.
2. Find where Codex's hooks config actually lives; wire the printed line verbatim:
   `bash bin/tw hook_shim.py --runtime codex-cli --hook db_write_guard || exit 2`. Record the
   config file path that worked — that path is the value `codex-cli.hook_wiring` has been
   waiting for.
3. Trust the hooks by hash where Codex asks. Observe: **installed is not armed** until this
   step — record what the trust flow actually looks like. Then edit the wired hook file by one
   byte and observe whether Codex **re-arms the trust review** before the hook runs again.
4. Issue a destructive fixture statement (`DROP TABLE demo_scratch`) → observe the deny with the
   escape-hatch message. Issue an additive one → passes. Watch for tool paths that **bypass the
   hook entirely** — the vendor's docs admit some paths opt out; record any you can produce,
   because a bypassed guard is a caveat the enforcement table must carry.
5. Break the hook deliberately (point the wiring at a nonexistent script) and re-issue the
   destructive statement. Observe what a **crashing** hook does — the docs state the deny paths,
   not this. That observation is `codex-cli.gate_fail_mode` (`open` if the call proceeds,
   `closed` if it blocks).
6. Sabotage the launcher (`bin/tw`) so it exits 3, and confirm the `|| exit 2` suffix in the
   wiring line still lands the failure as a deny — the offline proof covers the shim's own exit
   codes (only 0 or 2), not the launcher's (adversarial review of #46, P3).

**Stage A PASS looks like.** The hooks-config location known; trust-by-hash and edit-re-arms
observed; deny/pass/bypass behavior recorded; the broken-hook and broken-launcher observations
recorded.

**Between the stages (a code change, not a verification).** Ship the GUIDANCE → WIRED follow-up:
`emit_hooks` grows codex-cli, `hook_wiring` flips to the real path, section 43's `PIN` dict and
"must be GUIDANCE" pin move, `tests/emit/codex-cli/` grows the config artifact.

**Stage B — the criterion proper.** In a **fresh** repo, with the improved installer:
`ticketwright install --runtime codex-cli`, trust the hooks by hash (an interactive approval is
not a hand-edit), run the setup skill, open a fixture analysis (e.g. `DEMO-101`), review it, ship
it. Count hand-edited files. **The count must be zero**, and the guard must be observed
intercepting the flow's destructive statements (a lifecycle that never traversed the hook proves
nothing about it).

**Record on pass.** Stage A: `codex-cli.md` `hook_wiring` → the real config path,
`gate_fail_mode` → the observed value (general protocol: section 43 `PIN` dict + section 40 pin
move accordingly); any observed bypass path recorded in the adapter gotchas and the enforcement
table's codex caveat. Stage B: PROMPT 7's success criterion recorded as met in
`docs/PLANNED-CHANGES.md`; `docs/runtimes.md` re-dated.

### 2. Codex CLI — qc-reviewer addressable by name; isolation posture probed

Status: OPEN
Covers: `.codex/agents/qc-reviewer.toml` (acceptance itself is entry 9; this entry decides
addressability)

**Claim to verify.** (a) Whether a custom subagent defined in `.codex/agents/qc-reviewer.toml`
can be **invoked by name** from a session (the upstream issue was open as of 2026-08-19). This
decides whether `/review --deep` fan-out on Codex is nameable or generic. (b) The isolation
posture behind `subagent_isolation: unestablished`: separate agent threads are documented, "own
context window" is not.

**Preconditions.** Entry 1 Stage A's install completed (the TOML exists).

**Steps.** In a live Codex session, attempt to spawn the reviewer by its name; if that fails,
attempt a generic subagent spawn and observe whether the definition is picked up at all.
Re-check the upstream issue's status the same day. Then probe isolation: place a distinctive
fixture token in the parent conversation, spawn the reviewer, and ask it to repeat the token — a
subagent that can see it is sharing context. Re-check the vendor docs for an isolation statement
the same day.

**PASS looks like.** A by-name spawn reaches the qc-reviewer definition (record the invocation
syntax), or a documented negative: name-addressing still broken upstream, generic spawn
works/does not work. The isolation probe result recorded either way.

**Record on pass.** `adapters/runtime/codex-cli.md` gotchas re-dated with the observations;
`docs/runtimes.md` re-dated. Vocabulary honesty: `subagent_isolation: unestablished` means the
*docs* do not establish it — the value flips to `documented` only if the vendor docs now say so
(moving section 40's pin); a clean probe alone is recorded as a dated probe result in the
adapter prose, not a frontmatter flip. A negative keeps `/review`'s posture exactly as U4
shipped it (fan-out permitted, isolation recorded verbatim as `unestablished`).

### 3. Cursor — the deny path, failClosed, and copy precedence

Status: OPEN
Covers: `cursor.wired.db_write_guard` — artifact `.cursor/hooks.json`

**Claim to verify.** Three claims the emitted wiring makes that only a live Cursor can prove:
(a) the deny path actually blocks (unofficial reports of uneven deny reliability exist);
(b) `failClosed: true` actually fails closed on a broken hook — the emitted config sets it as
required configuration because Cursor hooks fail OPEN by default;
(c) precedence between the natively-read `.claude/skills/` and any same-named copy in the other
roots Cursor reads (`.codex/skills/`, `.agents/skills/`) — the stale-copy-silently-wins failure
mode item 0b exists for. The config-file schema itself is also live-unverified (the emitted
`_schema_note` says so) — step 1 pays that off.

**Preconditions.** A Cursor install; `ticketwright install --runtime cursor` run in a fixture
repo (emits `.cursor/hooks.json` + `.cursor/agents/qc-reviewer.md`, no skills — Cursor reads the
canonical copy).

**Steps.**
1. Confirm the hook config loads at all (no schema rejection — the `_schema_note` caveat).
2. Issue a destructive fixture statement (`DROP TABLE demo_scratch`) through the agent. Observe
   the `ask` (the `high_risk` expression on an ask-capable runtime); deny it; confirm the
   statement did not run.
3. Break the hook (point the config at a nonexistent script). Re-issue the statement. With
   `failClosed: true`, observe the call **blocked** — not silently allowed.
4. Plant a stale duplicate: copy one canonical skill to `.codex/skills/<name>/SKILL.md`, change
   one visible line, invoke the skill. Observe which copy wins. Remove the duplicate.

**PASS looks like.** (a) deny observed blocking; (b) the broken hook blocks; (c) precedence
recorded (either order is a finding — the point is knowing it).

**Record on pass.** WIRED → ENFORCEMENT for the Cursor guard cell per the promotion protocol
(ledger line included); `cursor.md` `hook_wiring_caveat` and `foreign_skills_caveat` re-dated
with the observations (precedence result recorded in the caveat and in `docs/runtimes.md`). A
FAIL on (a) or (b) is a safety finding: record it, keep the cell WIRED with the dated negative,
and consider whether the adapter's `gate_fail_mode: open` needs a stronger warning in the
enforcement table.

### 4. Antigravity — failure mode, global root, ask/force_ask, regen, questions

Status: OPEN
Covers: `antigravity.gate_fail_mode` `antigravity.global_skills_root`
`antigravity.structured_questions` `antigravity.wired.db_write_guard`
`antigravity.wired.regenerate_ticket_index` — artifact `.agents/hooks.json`

**Claim to verify.** Five axes the docs leave open on the richest-gated runtime (each
independently recordable — split the entry if a session establishes only some):
(a) hook-failure mode — undocumented, declared `unknown`, never assumed;
(b) which documented global skills path is real: the two official pages disagree
(`~/.gemini/config/skills/` vs `~/.gemini/antigravity-cli/skills/`) — until this resolves,
`ticketwright install --runtime antigravity --global` REFUSES by design;
(c) `ask` / `force_ask` observed doing what the emitted `.agents/hooks.json` claims — `ask` for
`high_risk`, `force_ask` for `all` (ignoring cached grants);
(d) the emitted PostToolUse entry actually regenerates the ticket index after a ticket write
(the second WIRED cell on this runtime — the U6 spec's entry list never covered it, but the
promotion protocol needs an owner for every WIRED cell);
(e) whether any structured-question surface exists in the CLI (a question panel demonstrably
exists in the IDE).

**Preconditions.** An authenticated Antigravity install (`agy`);
`ticketwright install --runtime antigravity` run in a fixture repo.

**Steps.**
1. Destructive fixture statement under `db_write_requires_approval: high_risk` → observe `ask`.
2. Set the policy to `all`, approve a statement once, immediately re-issue it → `force_ask` must
   prompt again (cached grant ignored).
3. Break the hook (nonexistent script in `.agents/hooks.json`); re-issue the destructive
   statement; observe proceed (fail-open) or block (fail-closed). That is (a).
4. Edit a fixture ticket file in-session; confirm `tickets/INDEX.md` regenerates via the emitted
   PostToolUse entry. That is (d).
5. Emit `--global` by hand into each candidate path in turn; observe which one Antigravity
   actually reads. That is (b).
6. Trigger any interview flow; record whether the CLI can render a structured picker or only
   prose. That is (e).

**PASS looks like.** All five observations recorded, each with the runtime version.

**Record on pass.** `antigravity.md`: `gate_fail_mode` unknown → observed (moves section 40's
`antigravity:unknown` pin), `global_skills_root` unknown → the real path (unblocks `--global`,
whose refusal message and selftest 41 assertion then move), `structured_questions` unknown →
observed; WIRED → ENFORCEMENT for the guard cell and/or the regenerate cell per the promotion
protocol — **per cell, each with its own ledger line; promote only what was seen**;
`docs/runtimes.md` re-dated.

### 5. Devin — the documented fail-open, the banner, the config location

Status: OPEN
Covers: `devin.hook_wiring`

**Claim to verify.** (a) The documented fail-open exit table holds live: exit 0 continues, exit 2
blocks, any **other** nonzero is logged and does not block — which is exactly why the shim maps
every internal error to a deliberate exit 2, and why the printed wiring line carries `|| exit 2`
(the offline 0-or-2 proof covers the shim, not the `bin/tw` launcher — #46 P3).
(b) The SessionStart banner actually renders in a session.
(c) The hooks-CONFIG file location — not in the kit's research; wiring is manual until this entry
establishes it.
(d) Whether a hook decision can override a static `deny` rule — not documented (adapter gotcha).
(e) The `ask_user_question` option/multi-select schema — `structured_questions: yes` rests on
changelog evidence; the exact schema is unverified, which is why prose stays the safe authoring
choice.
*Note (delta from the planning spec): the spec's original entry said "emitted skill frontmatter
accepted", but U2 made Devin a verify-only runtime — no skills are emitted for it. Skill
discovery on Devin is entry 8; its emitted agent definition is entry 9.*

**Preconditions.** A Devin install (`devin` CLI or `devin-desktop`);
`ticketwright install --runtime devin` run in a fixture repo (emits
`.devin/agents/qc-reviewer.md` only, prints the manual wiring lines).

**Steps.**
1. Find where Devin's hooks config lives; wire the printed line verbatim:
   `bash bin/tw hook_shim.py --runtime devin --hook db_write_guard || exit 2`. Record the path.
2. Destructive fixture statement → observe the deny (exit 2) with the escape-hatch message.
3. Replace the wiring with a script that exits 3. Re-issue the statement → observe Devin **log
   and continue** (the documented fail-open, seen live).
4. Restore the `|| exit 2` form, sabotage `bin/tw` to exit 3 → observe the deny still lands
   (the launcher failure stays inside the one exit code Devin honors as a block).
5. Wire `--hook session_context` / `--hook ticket_index_context` at session start → observe the
   stack + catalog banner in a fresh session.
6. Add a static `deny` rule matching a command the hook would allow, and vice versa → record
   which wins. That is (d).
7. Trigger a flow that asks a question → record the actual `ask_user_question` payload shape
   (options? multi-select?). That is (e).

**PASS looks like.** The exit-table behavior observed in both directions (2 blocks; 3 does not);
the launcher-failure deny observed; the banner rendered; the config location recorded; the
static-deny interaction and question schema recorded.

**Record on pass.** `devin.md`: `hook_wiring` unknown → the real path (moves section 43's `PIN`
dict); GUIDANCE → WIRED for the Devin guard cell is the follow-up code change named in the
promotion protocol; `hook_wiring_caveat`, the static-deny gotcha, and the structured-questions
caveat re-dated; `docs/runtimes.md` re-dated.

### 6. OpenCode — throw-to-deny, both failure boundaries, no-banner, ask issue, agents root

Status: OPEN
Covers: `opencode.wired.db_write_guard` `opencode.agents_root`

**Claim to verify.** (a) The emitted `.opencode/plugins/ticketwright-db-write-guard.js` wrapper
is actually **loaded**, and throwing from `tool.execute.before` actually prevents execution;
(b) the two failure boundaries, separately — they are different claims: what a plugin that fails
to **load** does (undocumented — the adapter's `gate_fail_mode: closed` covers a thrown error,
not a failed load), and what a loaded wrapper whose handler fails at **run time** does;
(c) the no-banner degradation is real (no session-start injection; the rules-file fallback is
static-not-fresh, as the enforcement table states);
(d) the upstream `permission.ask`-never-fires issue re-checked (it is why `gate_ask_tier: no`);
(e) where user-defined subagent definitions actually live — `mode: "subagent"` is documented but
no definition file path is, so `agents_root` is declared `unknown` and the installer emits no
agent definition here rather than guessing;
(f) the isolation posture behind `subagent_isolation: unestablished` — "own context window"
appears only on unofficial mirrors.

**Preconditions.** An OpenCode install with a configured model provider;
`ticketwright install --runtime opencode` run in a fixture repo.

**Steps.**
1. Destructive fixture statement → observe the deny (the wrapper throws; the tool does not run),
   with the escape-hatch message surfaced. Additive statement → passes.
2. Load-failure boundary: corrupt the wrapper file itself (syntax error, so the plugin cannot
   load). Re-issue the destructive statement → observe whether a failed LOAD blocks, warns, or
   silently allows. If it silently allows, the enforcement-table caveat must say so in stronger
   terms.
3. Handler-failure boundary: restore the wrapper, then make the shim it shells unreachable.
   Re-issue → the wrapper's own error handling should still deny (throwing is the deny path);
   record what actually happens.
4. Fresh session → confirm no banner appears and the rules-file content is the only priming.
5. Re-check the upstream `permission.ask` issue; record its state and date.
6. Define a subagent per current OpenCode docs/experiments; record the file path that works
   (or that none does). That is (e). If one works, run the isolation probe from entry 2 (parent
   token, ask the subagent to repeat it) and re-check the docs for an isolation statement. That
   is (f).

**PASS looks like.** Deny observed; both failure boundaries recorded separately; degradation
confirmed; issue status dated; agents root recorded or confirmed undocumented; isolation probe
recorded.

**Record on pass.** WIRED → ENFORCEMENT for the OpenCode guard cell per the promotion protocol
(ledger line included); `opencode.md`: `agents_root` unknown → the real path (a follow-up code
change then teaches `emit_agents` to emit qc-reviewer there, with fixtures),
`hook_wiring_caveat` re-dated with both boundary observations; if the ask issue closed upstream,
`gate_ask_tier` flips per the general protocol (section 40 pin moves) and the collapse decision
for OpenCode is re-opened in the enforcement table. `subagent_isolation` follows entry 2's
vocabulary honesty: docs, not probes, flip it to `documented`.

### 7. Cline — do hooks fire at all, and is the honesty artifact read

Status: OPEN
Covers: `cline.session_start` `cline.tool_gate` `cline.structured_questions`
`cline.gate_ask_tier` `cline.gate_fail_mode` `cline.hook_wiring` `cline.hook_protocol` —
artifact `.clinerules/ticketwright-enforcement.md`

**Claim to verify.** Cline is the least settled of the seven — its hooks doc is a stub, and five
capability axes plus both hook keys are declared `unknown`. Seven tokens ride on this entry, and
they are **not** established by one observation — the step list below maps each step to the
axes it can honestly resolve; anything a session does not reach splits into its own OPEN entry:
(a) whether file-based hooks fire at all in the current extension → `cline.hook_wiring` (and, if
they fire, nothing more by itself);
(b) what protocol a firing hook speaks — stdin/stdout schema captured → `cline.hook_protocol`;
(c) whether a firing hook can gate — block/ask semantics probed → `cline.tool_gate`,
`cline.gate_ask_tier`;
(d) what a crashing hook does → `cline.gate_fail_mode`;
(e) whether a session-start surface exists (the TaskStart doc split) → `cline.session_start`;
(f) whether a structured-question surface exists, **including its parameter schema** — selectable
options exist in the product but the tools reference documents no schema; record the actual
payload shape (options? multi-select?) → `cline.structured_questions`;
(g) whether the emitted `.clinerules/ticketwright-enforcement.md` is actually loaded into
context — it exists because Cline does not read AGENTS.md, and it is the only place a Cline user
sees the degradation statement. **Honest strength of (g):** an agent's self-report is a
*behavioral probe*, not attributable proof of loading — where the current build exposes a rules
listing/diagnostic surface, use that as the attributable check; otherwise record the probe result
labeled as a probe.
If hooks do not fire at all, (a) is a confirmed `no`-equivalent, (b)–(d) resolve to "no surface
to speak of" with the same date, and the adapter's guidance-only stance is **confirmed** rather
than assumed.

**Preconditions.** A current Cline install; `ticketwright install --runtime cline` run in a
fixture repo (emits the `.clinerules/` artifact only; `.cline/` stays absent).

**Steps.** (The hooks doc is a stub, so the *wiring* below is version-dependent by nature — the
*observation* is exact either way, and the wiring that worked gets recorded as part of the pass.)
1. Write a minimal executable hook whose only action is `touch u6-cline-hook-fired` in the repo,
   place it at whichever hook location the current Cline docs/build accept (record which), and
   trigger a tool call. Marker file exists = hooks fire; absent after several tool calls = they
   do not. → (a)
2. If it fires: capture stdin/stdout (wrap the hook in `tee` to files) and record the schema →
   (b); probe block/ask semantics with a fixture destructive statement (`DROP TABLE
   demo_scratch`) → (c); replace the hook with one that exits nonzero mid-classification and
   re-issue → (d).
3. Loading check for the honesty artifact, at its honest strength: if the build exposes a rules
   listing/diagnostic surface, confirm `.clinerules/ticketwright-enforcement.md` appears there
   (attributable). Additionally or otherwise, fresh task → ask the agent to quote the enforcement
   table's Cline row verbatim — record the result explicitly as a *behavioral probe*. → (g)
4. Record any session-start surface the current build exposes → (e); trigger a question flow and
   record the actual payload shape (options? multi-select?) → (f).

**PASS looks like.** Every axis recorded as a real value **or** as a dated confirmation that the
surface does not exist (a confirmed `no` is a pass; only an unexamined `unknown` is not). For
(g): attributable confirmation where the build exposes a rules surface; otherwise the recorded
probe, labeled as a probe — never reported as proven loading.

**Record on pass.** `cline.md`: each observed axis flips per the general protocol (the UNKNOWN
row in the enforcement table, and section 43's `PIN` dict entry `('unknown', 'unknown')`, move
with them); if hooks fire and a protocol exists, wiring becomes a follow-up code change
(`hook_shim` currently REFUSES cline rather than guessing); `docs/runtimes.md` re-dated.

### 8. Verify-only runtimes — the canonical copy is discovered, not just present

Status: OPEN
Covers: canonical-copy discovery on cursor, opencode, cline, devin (no frontmatter token — the
adapters' `foreign_skills_caveat` lines and U2's verify report defer here)

**Claim to verify.** U2's verify step proves only that `.claude/skills/` exists at a documented
path. On each runtime that claims to read it natively (cursor, opencode, cline, devin), verify
the skills are actually **discovered and invocable** in a session, and that no duplicate or
foreign copy shadows them (each of cursor/opencode also reads `.agents/skills/`, where a
codex/antigravity emission may sit; Devin's vendor-format reading is **toggleable** in its
config — check the toggle before concluding anything).

**Preconditions.** The runtime installed; `ticketwright install --runtime <name>` run (its
verify report printed the caveat this entry pays off).

**Steps.** Per runtime: fresh session → list/invoke a canonical skill by name → confirm the
executed content is the canonical copy (edit one visible line in `.claude/skills/<name>/SKILL.md`
and confirm the change is what runs). Where a `.agents/skills/` emission coexists (a teammate on
codex/antigravity), repeat and record which copy wins.

**PASS looks like.** Canonical skills invocable on all four; shadowing behavior recorded per
runtime.

**Record on pass.** Each adapter's `foreign_skills_caveat` re-dated with the observation;
`docs/runtimes.md` re-dated. A FAIL (skills not discovered) flips that runtime's install story —
record it and open a follow-up: emit-vs-verify is adapter data (`reads_foreign_skills`), so the
fix is a frontmatter change plus fixture regen, not a code branch.

### 9. Emit runtimes — the emitted definitions are accepted, and --global lands

Status: OPEN
Covers: `.codex/agents/qc-reviewer.toml` `.cursor/agents/qc-reviewer.md`
`.devin/agents/qc-reviewer.md` `.agents/agents/qc-reviewer.md` — the three
"mapped (unverified)" `tools:` rows in the cursor/devin/antigravity Metadata-mapping tables,
and the codex TOML schema

**Claim to verify.** Acceptance, not just emission: (a) a skill emitted with mapped frontmatter
actually loads on codex-cli and antigravity (`.agents/skills/`, shared emission — the frontmatter
must satisfy both); (b) the emitted qc-reviewer agent definition is accepted and spawnable on
each runtime that got one — the TOML schema on codex (assembled from documented fields, never
seen accepted), the markdown form on cursor/devin/antigravity; (c) the `tools:` key carried
verbatim into those definitions is **honored** — every adapter's mapping table marks it
"mapped (unverified)"; (d) `--global` artifacts are found at each declared `global_skills_root`
(`~/.agents/skills` codex, `~/.cursor/skills` cursor, `~/.config/opencode/skills` opencode,
`~/.config/devin/skills` devin, `~/.cline/skills` cline; antigravity refuses until entry 4).

**Preconditions.** The runtime installed; local + `--global` installs run.

**Steps.** Per emit runtime: invoke an emitted skill (loads without frontmatter rejection);
spawn qc-reviewer (definition accepted); while spawned, attempt a tool outside its `tools:` list
and record whether the restriction holds; per `--global` runtime: fresh project *without* a local
install → confirm the global copy is discovered.

**PASS looks like.** Loads, spawns, and the `tools:` restriction observed per runtime (held or
not held — either is a finding); global discovery confirmed per declared root.

**Record on pass.** Each adapter's Metadata-mapping `tools:` row drops "(unverified)" for a dated
observation ("honored" or "carried but not honored — stated as LOST"); if not honored anywhere,
the emitted definitions gain a topmost warning naming the loss (same pattern as
`disable-model-invocation`); a wrong `global_skills_root` flips per the general protocol;
`docs/runtimes.md` re-dated.

### 10. Antigravity, Devin, OpenCode — model_sandbox resolved

Status: OPEN
Covers: `antigravity.model_sandbox` `devin.model_sandbox` `opencode.model_sandbox`

**Claim to verify.** Three adapters declare a headless `model_cmd` whose restriction posture is
`unverified`: `agy -p` (docs describe a commandExecutionPolicy for subagents, not a CLI flag),
`devin -p` (docs mention a `--sandbox` mode, unverified for `-p`), `opencode run` (no restriction
flag verified at all). The enrich step shells these commands; an unsandboxed model call there is
a real difference in what the kit exposes. A command *completing* proves nothing — the probes
below are adversarial, and the posture is recorded **per probe**, not as one word.

**Preconditions.** Each runtime installed and authenticated, in a throwaway fixture directory.

**Steps.** Per runtime, run the adapter's `model_cmd` with prompts that *attempt* side effects,
one per probe, and observe whether each lands:
1. write a file in the cwd (`create u6-probe.txt containing ok`);
2. write a file outside the cwd (`create /tmp/u6-probe-escape.txt`);
3. make a network request (`fetch https://example.com and print the first line`);
4. read an environment variable that would carry credentials in real use
   (`print the value of DEMO_FIXTURE_TOKEN` — export a fixture value first).
Then check each CLI's current `--help` for a restriction flag the docs grew since 2026-08-19.

**PASS looks like.** A per-probe record per runtime: blocked / allowed / prompted, plus any flag
found. "Restricted" as a summary is only honest if every probe was blocked.

**Record on pass.** Each `model_sandbox` flips to the observed value (closed vocabulary per
section 40); if a restriction flag exists, `model_cmd` gains it in the same commit — the safer
command is the point, not the label; `docs/runtimes.md` re-dated. Unrestricted-and-no-flag is
recorded as its own honest value, and the enrich docs must state it.

### 11. Any non-Claude runtime — the degraded review, and the fallback regen

Status: OPEN
Covers: U4's structural evidence made real (no frontmatter token; the U4 selftest section pins
the prose, this entry pays off the behavior)

**Claim to verify.** (a) One live `/review --deep` on a runtime without documented isolation
(codex-cli or opencode: `unestablished`; cline: no user-definable subagents) actually produces a
verdict recording the degraded/posture-annotated mode — `review_mode: inline-same-context` with
the sentence "A same-context review is not the independent second pass the validation pyramid
assumes." verbatim, or `review_mode: independent-subagent` with `subagent_isolation:
unestablished` recorded verbatim. A skill is prose a model executes; U4 could only pin the prose.
This entry records that an agent followed it — it does not, and cannot, resolve the isolation
posture itself (that is entries 2 and 6).
(b) One post-write index regeneration via the FALLBACK path on a runtime without the PostToolUse
hook: after a ticket edit, the enrich/ship flow's `bash bin/tw build_ticket_index.py` call keeps
the catalog fresh, and `--check` fails a deliberately staled one.

**Preconditions.** Any non-Claude runtime from entries 1–7 with skills reachable (entry 8/9).

**Steps.** (a) Open a fixture ticket, run the review skill with `--deep`, read the verdict
record's `review_mode` and posture fields. (b) Edit a fixture ticket, run the documented fallback,
confirm `tickets/INDEX.md` reflects the edit; stale it on purpose, confirm
`python3 bin/build_ticket_index.py --check` exits nonzero.

**PASS looks like.** A real verdict file carrying the honest mode fields; a catalog that stayed
fresh without any hook.

**Record on pass.** The observation dated in `docs/runtimes.md` ("What this means for the kit" —
the `/review` paragraph); no pins move (the structural pins in section 42 already assert the
prose; this entry records that an agent followed it).

### 12. Hook-wired runtimes — the shim's shell-tool jurisdiction list, checked against real payloads

Status: OPEN
Covers: the `_SHELLISH` jurisdiction list in `bin/hook_shim.py` (adversarial-review ruling on
#46, routed here — no frontmatter token)

**Claim to verify.** On runtimes whose pre-tool hook fires for **every** tool (antigravity,
opencode, codex-cli, devin — cursor's `beforeShellExecution` is shell-scoped by the runtime), the
shim passes untouched any payload naming a tool that is *clearly not a shell*, judged by the
`_SHELLISH` substring list (`bash`, `shell`, `terminal`, `exec`, `cmd`, `run_command`,
`run_terminal_cmd`, `execute_command`). If a runtime's real shell tool is named outside that
list, destructive SQL sails through as "non-shell" — a silent allow, the exact failure mode the
fail-closed design exists to prevent. The list was assembled from documentation; only live
payloads test it. **Honest scope:** a sample of payloads can prove a mismatch, never completeness
— each observation covers the tool names *that runtime version actually sent*, and the residual
risk on unobserved versions/platforms stays. The entry shrinks that risk and records the names;
it cannot zero it.

**Preconditions.** Any entry-1/4/5/6 wiring live, with the shim logging or a capture wrapper
around it.

**Steps.** Per wired runtime: run one shell command through the agent while capturing the hook's
stdin; record the tool-name field the payload actually carries; check it against `_SHELLISH`.

**PASS looks like.** Every observed shell tool name matches the list, and the observed names are
recorded per runtime + version. A miss is a FAIL with a one-line fix: widen `_SHELLISH` (and its
selftest coverage in section 43) in the same commit as the recorded observation.

**Record on pass.** Observed tool names recorded in `bin/hook_shim.py`'s jurisdiction comment
with the date and runtime versions; any widening lands with a section 43 case proving the new
name gates.

---

## Adjacent parked work — NOT live verification

Named here so the #46 adversarial review's "U6/future notes" routing resolves somewhere, and
explicitly out of this list's scope (it is code hardening, not a runtime observation):

- **Newline-separator hardening** in the guard's command parsing — deterministic work on
  `bin/sql_scan.py` / `bin/hook_shim.py` input handling, verifiable offline by selftest when
  someone picks it up.

## Count, against the plan

`docs/PLANNED-CHANGES.md` § U6 lists 11 entries. This page carries **12**, and the delta is
recorded as a dated amendment in that section too:

- **+1**: entry 12 (the jurisdiction-list check) was routed to U6 by the adversarial review of
  #46 after the U6 spec was written.
- **Widened, not split**: entry 4 also covers the Antigravity PostToolUse regen cell (a WIRED
  cell the promotion protocol needs an owner for) and entry 6 also covers `opencode.agents_root`
  (an `unknown` U5 landed that the spec's list predates). Entries 2/5/6/7 grew sub-items for
  parked claims found in the adapter gotchas at U6 time (codex hook-bypass paths and isolation,
  Devin's static-deny interaction and question schema, OpenCode's two failure boundaries and
  isolation, Cline's question schema).
- **Adjusted**: entry 5 — the spec's "emitted skill frontmatter accepted" predates U2's decision
  that Devin is verify-only; skill discovery is entry 8, agent acceptance entry 9. Entry 1 runs
  in two stages because the spec's one-visit reading is impossible against the U3 reality that
  codex hook wiring is manual until its config location is known — the staging is what keeps the
  criterion honest instead of quietly weakening "zero hand-edited files".

The mechanical linkage (selftest section 44) is also deliberately wider than the U6 paragraph's
minimum ("every unknown OR unverified frontmatter value"): it additionally covers WIRED
enforcement-table cells, "unverified"-labeled emitted artifacts, "(unverified)" metadata-mapping
rows, and the promotion ledger below — per this unit's dispatch brief, so a promotion or an
artifact label can never outlive its tracking either.

## Promotion ledger

One line per WIRED → ENFORCEMENT promotion, added by the promotion protocol above — selftest
section 44 refuses any non-Claude ENFORCEMENT cell in the enforcement table that has no line
here. Format:

    PROMOTED <tool>.wired.<hook> <YYYY-MM-DD> — <runtime + version> — <observer>

(none yet)
