---
name: review
description: Independent quality review of a ticket's deliverables — re-runs queries and walks a tiered validation pyramid to an APPROVE / REQUEST-CHANGES verdict. Run before shipping.
---

<!-- emitted by ticketwright install v4.4.1 — do not hand-edit; re-run `ticketwright install --runtime antigravity` to update. -->

# /review

The **check** step of the lifecycle. `/build` runs this at the end of every build; run it directly
to re-check after a fix, for a `--deep` panel, or on someone else's ticket. An *independent* second
pass over a ticket's deliverables —
re-runs queries, walks a tiered validation pyramid, sweeps for anti-patterns, and returns an
APPROVE / REQUEST-CHANGES verdict. Reads `.claude/config/stack.yaml`; warehouse specifics come from
the resolved target's adapter `dialect_notes`, so the same review runs against any warehouse — or
several, when a ticket spans more than one.
Read-only: it reviews and re-runs, it does not edit code (the build owns fixes).
Independence is probed, never assumed: the **capability probe** below decides whether the second
pass gets its own context, and the verdict records which review the ticket actually got.

## How this skill asks the person something
<!-- ticketwright:ask-rule:begin -->
The kit's one question rule, the same in every skill that asks:
- Read `capabilities` from this skill's `kit_paths.py --json` probe the first time a question
  comes up, and keep the result.
- `capabilities.structured_questions` is `yes` and `capabilities.question_tool` is not `none` →
  **ask with that tool**, within `capabilities.question_limits` (when that says `unknown`: one
  question per call, at most four options). Group up to the limit only questions that do not
  depend on each other's answers; ask a dependent question after the one it depends on.
- Otherwise (`no` / `unknown`, or the probe failed) → ask in chat as a short numbered list, one
  question at a time unless this skill says a set goes in one round, and wait for an explicit
  answer.
- The question content is the same either way; only how it is shown changes. No skill names a
  runtime's tool: the runtime's own adapter (`adapters/runtime/<name>.md`) does. A question tool
  is not available inside a subagent, so the main session asks.
- **Never invent an option.** Options come from what this run found or the fixed choices a step
  names. A recommended option goes first, marked recommended, with where it came from; the person
  still picks. Each option says what choosing it changes, and free text is always possible (the
  tool's own "Other", or "or tell me something else" in prose).
- Whatever the person needs to answer is already in chat before the question, so a picker never
  hides it.
- A reply the kit asks for word for word (`ship unreviewed`, `go ahead`, the `yes` before
  destructive SQL) stays typed: an unreviewed ship, an external send or an irreversible write is
  never one click.
<!-- ticketwright:ask-rule:end -->

In this skill the questions are step 0's owner choice, the one-time viewer setup in step ⑤.2, and
the sign-off in step ⑤.4. Its probe is the capability probe's `kit_paths.py --json` (the second
pass section); run it early when step 0 has to ask.

## Phase 0 — Setup
0. Resolve the **ticket locator**: run
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" whoami.py`
   (show the "Working as …" line), then resolve `owner/id` exactly, or a bare `<id>` against the
   resolved person's `tickets/<owner>/` first and other owners second — **two or more foreign owners
   sharing a bare id is a hard stop that asks which one, with the `owner/id` choices as the options,
   never a pick**. Reviewing
   another person's ticket is normal; say whose work is under review.
1. Read the merged config (`bin/effective_config.py --json`), not raw `stack.yaml`. Resolve every
   warehouse **target** this ticket touches and verify each one
   (halt with that target's adapter auth notes if unreachable) — resolution order in
   `adapters/README.md` § Multi-target seams. Load each target's `dialect_notes`: the lint layer is
   parameterized **per file**, by the target its header names.
2. Read the ticket README, the plan (`<ticket-dir>/plan.md` — its Validation strategy and
   Deliverables are part of what this review checks against), the spec (if any), and list
   `final_deliverables/` + `qc_queries/`.
3. **Load the team's docs:** `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" team_docs.py --json`. Read every `standards` doc and any
   `context` doc that defines a metric or table this ticket reports (a path directly, a link live
   with whatever reader this runtime has). Mark each one `opened` or `unreadable`; a row with
   `exists: false` is `unreadable`. **An unreadable standards doc is never reported as checked:**
   the verdict says it could not be opened. Check the deliverables against what was opened: a broken
   rule is a finding, `Should-fix` by default, `Critical` only where the doc itself makes the rule a
   must (must, required, never, always). A reported metric that contradicts its written definition
   is a finding too. If the command exits 3, the team config could not be read: record
   `team_docs: unknown (team config unreadable)`, never `none configured`.
   When you spawn `qc-reviewer`, pass the rows and, for each doc you opened, the rules that apply
   to this ticket, in the prompt: the reviewer may have no way to open a link itself, and a link it
   cannot open is a standard it cannot check.

## The validation pyramid (bottom = cheap/automated, top = human)

Layers ①–④ apply to query/export deliverables. When the repo has no warehouse seam — or a ticket's
deliverables are documents, models, or code rather than queries — skip the layers with nothing to
run and review at layer ⑤ plus a **claims-vs-evidence walk**: every number, claim, and filename the
README asserts must trace to a file in the ticket, and every stated method must match what the
artifacts actually do. The verdict discipline below is unchanged.

**① Dialect lint** (static, per the `dialect_notes` of *that file's* target — in a multi-target repo
a `.sql` with no target header is a **Should-fix** finding, and is linted against whatever the
canonical order resolves next — the ticket's declared target before the seam default)
- `= NULL` → must be `IS NULL`; missing div-by-zero guard; `SELECT *` in deliverables; functions on
  filtered columns; implicit cross-source type mismatches (missing `CAST`); hardcoded values that
  should be parameters; missing required schema/instance filters; `LEFT JOIN` predicate in `WHERE`
  that silently becomes an inner join; `NOT IN` with nullable columns; `UNION` vs `UNION ALL`;
  session-variable/`DECLARE` parameterization in a shipped or exported query (prefer a CTE params
  row — portable, single-statement, export-clean; session vars pollute `--format csv` output and
  don't survive into single-statement JDBC/ODBC clients).

**② Counts & dedup** (re-run independently)
- Re-run the row-count; compare to the documented count. **Duplicate detection is the primary test:**
  `COUNT(*)` vs `COUNT(DISTINCT <grain key>)` — any gap is a halt until explained.
- NULL-rate on critical/key columns; value-range sanity (no negative amounts where impossible).

**③ Cross-source reconciliation**
- Join-match rates (unmatched `LEFT JOIN` rows quantified, not hidden). Date ranges within scope.
- Reconcile totals against the source of truth (e.g. SUM vs the input file/feed) within tolerance.

**④ Independent re-run + anti-pattern sweep**
- Re-execute each deliverable **against the target its header names** — re-running one target's SQL
  on another is not a reproduction. Diff results to the committed output (byte-level
  for CSVs — `deterministic_outputs` requires explicit `ORDER BY`).
- Sweep the full anti-pattern set (correctness, performance, data-quality, dialect-specific,
  maintainability). Classify each finding Critical / Should-fix / Review.

**⑤ Human sign-off** — *the one layer a model cannot complete on its own*
- Output format check (CSV headers row 1, no preamble/blank rows; filenames carry record counts;
  **ASCII punctuation only in cell values** — no em/en dashes, smart quotes, or ellipsis chars, which
  render as mojibake in Excel/CSV viewers).
- README completeness (assumptions enumerated, QC results, business context).
- **Hand the deliverables to the human, then stop** (policy `human_review_handoff`; skip this whole
  bullet when it is `off`). Layers ①–④ prove the query is *internally* consistent; only a person can
  say the numbers are the right numbers. Do not record an APPROVE before this:
  1. `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" handoff.sh <final_deliverables + qc_queries paths>`
     routes each file to the app that user chose. **Say a file was opened only when handoff
     printed an `opened:` line for it.** With no `opened:` line (no viewer config, `enabled: false`,
     or `would run:` in a session with no desktop), nothing was opened: say so plainly and **once**
     (for example "No viewer is configured, so nothing was opened"), list the paths so the person
     can open them, and continue. Never block. Its stderr names which case it was.
  2. If it opened nothing and no **usable** config exists, offer the one-time setup (as questions;
     they do not depend on each other): which app
     for `.sql`, which for `.csv`, this repo only or all their repos. Their answers are written to
     `.claude/config/viewer.local.yaml` (gitignored, per-user) or the user-level path — see
     `.claude/config/viewer.example.yaml`. "None / don't ask again" writes `enabled: false`.
     Check usable, not merely present:
     `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" effective_config.py --viewer-plan`
     reports `"usable": false` when config exists but opens nothing — a real state now that the
     portable half (globs → categories, in `people/<id>.yaml`) and the machine half (categories →
     applications, in `.claude/config/connections.local.yaml`) can be configured independently.
     Treating "a file exists" as "configured" would leave that person permanently stuck with a
     gate that never opens anything and never offers to fix itself.
  3. Print a short **what to look at** list — row counts, the grain key, and anything the counts or reconciliation checks flagged —
     so they know where to aim, not just that files opened.
  4. **Ask for the sign-off, then wait.** `ship` counts as a sign-off **only when the second pass
     returned APPROVE** (no hard-halt finding and, under `--deep`, no uncertain Critical / count /
     reconcile finding), so the person's sign-off is the only thing outstanding. In that case:
     - First save the record as `verdict: AWAITING-SIGNOFF` (Phase N says how), so the record itself
       says "the reviewer approved, waiting on you" instead of looking never reviewed.
     - End the hand-off with this line, and ask it as one question whose options are "Approve and
       ship" (first), "Approve, don't ship yet" and "Change something":
       <!-- ticketwright:user-facing:begin -->
       > Reply `ship` to approve and deliver, or tell me what to change. Replying `ship` means you checked the numbers and they are right. `/ship` still shows you everything it would send, and waits for your go-ahead before anything leaves the repo.
       <!-- ticketwright:user-facing:end -->
     - `ship`, or "Approve and ship" → update the record to `verdict: APPROVE` with the sign-off,
       then route as Phase N says, which starts `/ship`. It counts as the person invoking `/ship`
       (they asked for it), so `/ship`'s confirm gate for a run the model started does not apply,
       and its hard halt before anything is sent still does.
     - An approval without `ship` ("signed off", "approve", "Approve, don't ship yet") → update
       the record to `verdict: APPROVE` with the sign-off and route as Phase N says, without
       shipping.
     - Anything else (what to change, a question) → answer or record it; a change request updates
       the record to `verdict: REQUEST-CHANGES` with the person's points as findings.
     When the second pass found a hard-halt finding, the verdict is REQUEST-CHANGES whatever the
     person replies: still hand the files over so they can see the problem, but do not offer
     `ship`, and if they reply `ship` anyway, say the review found problems, so `ship` cannot
     approve this ticket. Under `--deep`, an **uncertain** Critical / count / reconcile finding is
     not an APPROVE either: no AWAITING-SIGNOFF, no `ship`, no one-click approval. The person may
     still sign off on it by naming the finding in their own words; that, and only that, writes
     `verdict: APPROVE` with a `human_signoff:` line quoting them. Under `all`, note what they already approved earlier in the build and
     focus this pass on what changed since; never skip the gate silently just because an earlier
     one fired.

## Tiers & halting
- **Hard-halt** findings (Critical, count mismatch, dup gap, reconciliation break) → verdict
  REQUEST-CHANGES with structured remediation.
- **Warn** findings (perf, style) → list but don't block.
- **Info** (distributions) → record.

Tag every finding **`kind: defect | scope`**, alongside its severity. A *defect* is the build not
doing what the approved plan says: a wrong join, a count that does not reconcile, a missing
`ORDER BY`. A *scope* finding means the plan itself is wrong: the requirement was misread, the grain
is wrong for the question, or a deliverable or validation the work needs was never in the plan.
Fixing a defect is the build's job; a scope finding sends the ticket back to planning, because no
amount of rebuilding fixes a plan that asks for the wrong thing. When unsure, say `defect`: a
scope tag costs the person an approval, and the build can still escalate after two rounds. Only a
hard-halt finding tagged `scope` sends the ticket back to planning; a Warn-tier one is listed for the
person.

## The second pass — capability probe

The pyramid's independence claim is only true when the runtime can actually give the reviewer a
second context. Probe what the current runtime declares before spawning anything:

```
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" kit_paths.py --json
```

Read two capability keys from `capabilities` — `subagents` and `subagent_isolation` — and branch on
the **values only**. The runtime's name also appears in that JSON; never branch on it. The adapter
data decides, so a new runtime changes this skill's behavior without changing this skill.

1. **`subagents: yes` and `subagent_isolation: documented`** → run the second pass as an
   independent subagent, as described in this file (a single `qc-reviewer` pass by default; the
   `--deep` panel fans out per layer). The verdict records `review_mode: independent-subagent`
   and `subagent_isolation: documented`.
2. **`subagents: yes` and `subagent_isolation: unestablished`** → still fan out —
   the stronger check is not refused — but the verdict must record the isolation posture
   **verbatim** from the probe (`subagent_isolation: unestablished`): a second context exists;
   its independence is not established. `review_mode` stays `independent-subagent`.
3. **Anything else** → **inline fallback**, the weaker check, recorded as such. This branch is the
   floor for `subagents` not `yes` (a runtime with no user-definable subagents reports `no`, and
   so does an unrecognized runtime), for `subagent_isolation: none`, for `unknown` (an unknown
   capability is treated as absent, never assumed), and for a probe that fails outright. Walk the
   qc-reviewer checklist (`.claude/agents/qc-reviewer.md`) in this same context — under `--deep`,
   take the panel's layers sequentially, then still run the adversarial-verify pass. The verdict
   records `review_mode: inline-same-context`, `subagent_isolation:` as probed (`unknown` when the
   probe failed, noting the failure), and this sentence, verbatim:
   <!-- ticketwright:user-facing:begin -->
   **This review ran in the same conversation that did the work, so it is not the independent second check the review process expects.**
   <!-- ticketwright:user-facing:end -->
   Never present an inline pass as independent.

When a branch spawns, pass `review_mode` and the probed `subagent_isolation` value in every
subagent's prompt — the record copies both from there, verbatim. A subagent never guesses its own
posture: it cannot see the adapter data that decides it.

## Deep mode (`--deep`) — adversarial panel
For high-blast-radius work (compliance/regulatory pulls, irreversible writes), replace the single
pass with a panel, spawned per the capability probe above (on a degraded runtime the panel runs
inline, layer by layer, and the verdict says so):
1. **Fan out** one independent `qc-reviewer` subagent per pyramid layer (① dialect-lint ·
   ② counts&dedup · ③ cross-source reconcile · ④ re-run + anti-pattern sweep) — each scoped to its
   layer, re-running its own queries, returning findings only. Run them in parallel.
2. **Adversarially verify** every reported finding before it counts: a second pass re-reads the
   cited `file:line` / re-runs the query and rules each finding confirmed / false-positive /
   **uncertain**. A finding it cannot reproduce is **uncertain, not dismissed** — silently dropping
   a Critical / count / reconcile finding is the expensive failure. Only a clear, demonstrated
   non-issue is ruled false-positive.
3. **Synthesize** confirmed findings (deduped across layers) into one verdict — and **carry
   uncertain findings into the verdict too**: any uncertain Critical / count / reconcile finding
   forces REQUEST-CHANGES (or explicit human sign-off), never a silent APPROVE.

Default (no flag) is the single `qc-reviewer` pass. `/ticket` recommends `--deep` automatically for
high-risk tickets (external/compliance deliverables, irreversible writes) — reach for it whenever
the cost of a missed defect is high.

## Phase N — Verdict
Emit the structured report (Summary · review mode · pyramid results per layer · findings by
severity · verification queries run · **APPROVE** or **REQUEST-CHANGES**). The report says WHICH
review this ticket actually got: `review_mode: independent-subagent` or
`review_mode: inline-same-context`, each with the `subagent_isolation:` posture the capability
probe returned — and an inline record carries the probe section's weaker-check sentence verbatim.
An inline-degraded APPROVE must never read identically to an independent-subagent APPROVE.
**Save the report as `qc_queries/<n>_review_verdict.md`** (`<n>` = the next number in that folder)
with the lowercase `verdict: APPROVE` or `verdict: REQUEST-CHANGES` as its first line after the
title, then `review_mode:` and `subagent_isolation:` — that fixed name and field are what `/ship`
reads. **When the sign-off gate runs** (policy `human_review_handoff` is not `off`) and the second
pass approved, save the file first with `verdict: AWAITING-SIGNOFF`, before the hand-off, and
update **that same file** when the person answers: `verdict: APPROVE` plus a `human_signoff:` line
(the date, the person from whoami, and their reply verbatim), or `verdict: REQUEST-CHANGES` with
their points as findings. `AWAITING-SIGNOFF` never counts as approval: `/ship` and the push guard
treat it as not approved yet, and a session that ends before the answer leaves it on file for the
next one to ask. Add a `team_docs:` line after them: `team_docs: <location> opened; <location> unreadable`
for each doc from Phase 0 step 3, or `team_docs: none configured`. **The current verdict is the file with the highest `<n>`, compared numerically** — `10_` is
newer than `9_`; a lexical sort or a file mtime is not the rule — so a later review supersedes an
earlier one, including a `SKIPPED` record `/ship` wrote for an unreviewed ship. **Confirm the record
parses before routing:**
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" review_verdict.py --ticket <ticket-dir> --json`
and compare its `status` field (`approve`, `request-changes`, or `awaiting-signoff` before the
answer) to the verdict you just wrote. **With `AWAITING-SIGNOFF` on file, stop here and wait for
step ⑤.4's answer;** the result line and the routing below come after the record is rewritten, so
the result is never printed as APPROVE before the person has signed off. A
`status` of `unreadable` marks a file `/ship` and the `review_verdict_guard` hook treat as missing.
Read the `status` field, never the plain-words line the command prints without `--json`, because
that line is for the person and its wording can change. Then print one plain line for the person,
alongside the saved record:
<!-- ticketwright:user-facing:begin -->
> Review result: <APPROVE | REQUEST-CHANGES>. <one sentence on what was checked>.
<!-- ticketwright:user-facing:end -->
When `review_mode` is `inline-same-context`, the sentence after the result is not a description of
what was checked: it is the same-conversation honesty sentence from the probe section ("This review
ran in the same conversation that did the work, so it is not the independent second check the review
process expects."), so an inline result never reads like an independent one.
Then route:
**If this review was run from inside `/build` (its Phase 3), return to that build's step 8 for
either verdict** — on APPROVE it ships when the person replied `ship` and otherwise asks (or stops,
when they chose not to ship yet), and on REQUEST-CHANGES it fixes defects or replans scope;
starting a new `/build` instead would nest a build inside a build. Otherwise: APPROVE after a
`ship` reply ⇒ **follow `/ship <owner>/<id>`'s instructions in full**, in this window. Any other
APPROVE ⇒ recommend `/ship <owner>/<id>` (the qualified locator, so `/ship` cannot re-resolve a bare
id to a different owner's ticket). REQUEST-CHANGES ⇒ recommend `/build <owner>/<id>`, which applies
the remediation (or replans, when a finding is `kind: scope`) and runs this review again.
