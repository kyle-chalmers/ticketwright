---
name: build
description: Execute the plan or spec on file in small build-and-check loops (subagents that see only the record build the spec-sized tickets), then run the independent review and ask before shipping. The IMPLEMENT + CHECK phase — /ticket starts it on approval, and every build ends with a /review verdict.
---

<!-- emitted by ticketwright install v4.4.1 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

# /build

The **build + check** step of the lifecycle. `/ticket` already did every read-only planning step — the
plan, and the spec when the plan called for one — and the human approved that package. `/ticket`
starts this skill in the same window on that approval; run it directly to resume a build, or to
build from a plan someone else approved. It executes the package, validating each step
independently, and **ends by running `/review` on the ticket**. The only exit toward `/ship` is an
APPROVE verdict; quality is ensured by the system, not by remembering to invoke a step.

The work runs in one window, but the execution should not lean on the planning conversation: the
plan and spec are the handoff, and a build that needs the chat to make sense of them has found a gap
in the record. When the runtime allows it, a spec-sized ticket is built by subagents that are given
only the record (step 2b), which tests that handoff without opening a second window.

Reads the merged config (`bin/effective_config.py`, never raw `stack.yaml`). Warehouse-agnostic via
`seams.warehouse`, and works the same when that seam holds several targets — or none.

**Ticket locator:** run
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" whoami.py`
first (show the "Working as …" line). `<ticket-id>` is `owner/id` (exact) or a bare `id`, resolved
against the resolved person's `tickets/<owner>/` first, then other owners — **a bare id two or more
foreign owners share is a hard stop listing the `owner/id` choices, never a pick**.

## Phase 1 — Load what was approved

1. **Find the blueprint.** Read `<ticket-dir>/plan.md` first — its Scope, Deliverables and Validation
   strategy are the acceptance criteria — and take the value on the **`spec:` line of its Next step
   section** (that line only; the template's header explains the values and must not be matched).
   Then branch, halting by name:
   - **No `plan.md`** → stop: "No plan is on file for `<owner>/<id>` — run `/ticket <owner>/<id>`
     first; every ticket is scoped before it is built." (A spec passed as an argument does not
     substitute: the plan is the approval record.)
   - **`spec:` names a path** → that spec is the executable detail; load it (the argument path wins
     if one was given). The path is repo-root-relative (`<ticket-dir>/specs/<id>-<slug>.md`); a bare
     `specs/<id>-<slug>.md` from an older plan resolves inside `<ticket-dir>`, never at the repo
     root. If the named file does not exist → stop: "`plan.md` for `<owner>/<id>` names
     a spec that is not on file — run `/ticket <owner>/<id>` to finish scoping."
   - **`spec: not required`** → the plan is the blueprint.
   - **`spec: after-root-cause`** → run only the plan's investigation steps (read-only against the
     warehouse, plus QC queries that reproduce the problem). When the root cause is known, apply the
     one condition this skill owns: **if the fix creates or alters a persisted object others depend on
     (a warehouse object, a model, a published report), route back to `/ticket <owner>/<id>` Phase 4
     in replan mode** — follow its instructions in full, in this window: the spec is written from
     the real cause and approved, and replan mode returns control here without starting another
     build. Continue from step 2 with the new spec (its targets need the preflight too). If the
     fix touches nothing persisted (a
     corrected export, a documented answer), record the cause in the README and continue.
   - **Anything else on that line** (blank, a `{{token}}`, a value not listed) → stop and name it; a
     plan the build cannot read is not an approved plan.
   Treat the blueprint as the source of truth, but **validate each step independently** — don't
   blindly follow; a plan or spec can be wrong, and finding that out here is what the small loops
   below are for.
   **Then load the team's standards:** run `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" team_docs.py --kind standards` and
   read each doc (a path directly, a link live with whatever reader this runtime has). Build to
   them. A doc you cannot open goes in the README's Assumptions as unreadable, so `/review` knows
   it was not followed knowingly. `none configured` needs no note.
2. **Preflight** each warehouse **target** the blueprint names (resolve per `adapters/README.md`
   § Multi-target seams; verify each; halt with that target's auth notes). No warehouse configured ⇒
   the build is code/analysis/document work — skip the warehouse steps below cleanly.
2b. **Choose who does the work** — probe the runtime the same way `/review` does:
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" kit_paths.py --json`, then
   read `capabilities.subagents` and `capabilities.subagent_isolation` and branch on the **values
   only**, never on the runtime's name:
   - **Subagent-led** — the plan's `spec:` line names a spec, `subagents: yes`, and
     `subagent_isolation` is `documented` or `unestablished`. This session orchestrates. For each
     spec step or object, dispatch one subagent briefed with **only `plan.md`, that step's spec
     section, and the files it touches** — never the planning conversation, which is the point:
     if the subagent cannot do the step from the record, the record has a gap, so fix the plan or
     spec rather than filling it in from memory. When `subagent_isolation` is `unestablished`, say
     so once, verbatim:
     <!-- ticketwright:user-facing:begin -->
     > Helper agents are building this ticket, but this tool cannot confirm they work without seeing our conversation.
     <!-- ticketwright:user-facing:end -->
   - **Inline** — `spec: not required` (the plan judged the ticket small), `spec: after-root-cause`
     while the investigation runs (it is read-only), or any other probe result (`subagents` not
     `yes`, isolation `none` or `unknown`, a failed probe). This session does the work. When the
     plan names a spec, say plainly that the build ran in the planning conversation and the plan
     was not tested as a standalone handoff.
   **A subagent never holds a gate**, because it cannot reliably reach the person: it may run reads
   and the additive dev-target SQL that step 5's policy allows without asking, and it returns
   everything else to this session — any SQL `db_write_requires_approval` gates, and both
   `human_review_handoff` handoffs. Under `human_review_handoff: all`, that means a subagent returns
   the SQL it wrote **before running any of it, reads included**, because step 4 hands generated
   SQL to the person before its first warehouse run. This session also re-runs each step's gate itself (step 4)
   rather than taking a subagent's word that it passed. Record the choice in the ticket README as
   two lines, `build_mode: subagent-led | inline` and `subagent_isolation: <as probed>`, so the
   reviewer and the next person can see which build the ticket got.
2c. **Pick up an open review before rebuilding.** Read the current verdict with
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" review_verdict.py --ticket <ticket-dir> --json`.
   When its `status` is `request-changes` (a `/review` run on its own, or a build that stopped at the
   cap), do not redo Phase 2 from the start: go straight to step 8's REQUEST-CHANGES branch with
   that verdict. If `plan.md` changed after that verdict was written (its git history shows a later
   commit), the replan its scope findings asked for already happened, so treat those findings as
   handled and carry only the defects forward. Any other `status` → continue to Phase 2.

## Phase 2 — Implement in small build-and-check loops

3. **One object / one step at a time.** Develop against the warehouse's **dev target** first
   (`seams.warehouse.dev_target`, else the key the adapter names in its `dev_key:` frontmatter);
   parameterize values at the top **via a CTE params row
   (`WITH params AS (SELECT … AS anchor) … CROSS JOIN params`), not a session `DECLARE`/`SET`** — CTE
   params stay portable and keep CSV exports clean; explicit `ORDER BY` on any export
   (`deterministic_outputs`). In a repo with no warehouse seam, verify each deliverable by its own
   check instead — the document renders, the script runs clean, the numbers cited in the README match
   the files — exactly as `/ship` re-verifies them later.
4. **Embed validation between steps** — after each, run the relevant gate from the spec (or the
   plan's Validation strategy); self-correct before moving on.
   **Under policy `human_review_handoff: all`** — the default `review` skips this, because the gate
   lives in `/review` — put a human in the loop twice: hand the generated SQL over *before* its
   first warehouse run (a bad join is cheapest to catch before it costs a warehouse-minute), and
   hand the exported CSVs over after. Both via
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" handoff.sh <paths>`, then wait for
   sign-off before continuing. Say a file was opened only when handoff printed an `opened:` line
   for it. With no viewer config, `enabled: false`, or only `would run:` lines, nothing opened: say
   so once, with the reason handoff gave (for example "No viewer is configured, so nothing was
   opened"), list the paths, and carry on. This never blocks a build.
5. **Any mutation** ⇒ policy `db_write_requires_approval` (`off` | `high_risk` | `all`). Under the
   default `high_risk`: show the exact SQL, explain the change, and wait for explicit `yes` before
   anything irreversible or access-changing (DROP/DELETE/UPDATE/TRUNCATE/MERGE/GRANT/
   `CREATE OR REPLACE`/non-`ADD` `ALTER`); additive SQL may run without asking. Read the policy
   rather than assuming. Dev-env objects still get shown but are lower-risk.
6. **Keep the record current as you go**: the ticket README's Assumptions and Deliverables sections,
   filenames carrying record counts, QC queries numbered in `qc_queries/`. A build whose only record
   is the chat transcript is not finished.

## Phase 3 — Check (built in, not optional)

7. When the build passes its own gates, **run `/review <owner>/<id>`** — the qualified locator, so the
   review cannot re-resolve a bare id to a different owner's ticket. "Run" here means what it means
   when `/ship` runs `/refresh index`: **follow that skill's instructions, in full, for this ticket** —
   there is no mechanical skill-invocation tool, and the emitted runtimes carry this body verbatim, so
   the instruction travels. `/review` decides on its own capability probe whether the second pass is
   an independent `qc-reviewer` subagent or an honestly-labelled inline walk; this skill never
   pre-judges that. Never write the verdict yourself.
8. **Branch on the verdict `/review` wrote** — read it with
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" review_verdict.py --ticket <ticket-dir> --json`
   (the highest-numbered `qc_queries/<n>_review_verdict.md`, its `verdict:` line), never by eye:
   - **APPROVE** → ask, in one line:
     <!-- ticketwright:user-facing:begin -->
     > Review approved. Ship now?
     <!-- ticketwright:user-facing:end -->
     On yes, **follow
     `/ship <owner>/<id>`'s instructions in full**, in this window. `/ship` still shows every
     tracker comment, chat post and PR and waits for approval before anything leaves the repo, and
     the `review_verdict_guard` hook still asks at push time, so this question only saves you
     typing the command. On no, stop and name `/ship <owner>/<id>` for later.
   - **REQUEST-CHANGES** → read each finding's `kind:` and tier. A finding with no `kind:` (an older
     reviewer) counts as `defect`.
     - **No hard-halt `scope` finding** → apply the remediation list, re-run the affected gates from
       Phase 2, and run `/review <owner>/<id>` again — from this step, never by re-entering `/build`
       from the top (a build inside a build re-resolves everything and never returns here). A
       Warn-tier `scope` finding is listed for the person, not acted on. **Two REQUEST-CHANGES
       rounds is the cap:** after the second, stop and hand the findings to the human rather than
       looping — a defect the build cannot clear is a scoping problem or a data problem, not a retry
       problem — and offer the replan below as one way forward.
     - **Any hard-halt `scope` finding** (or the person chose a replan at the cap) → the plan is
       wrong, so rebuilding will not fix it. Run `/ticket <owner>/<id>` Phase 4 **in replan mode**:
       follow its instructions in full, in this window. It updates `plan.md` and the spec in place,
       gets a fresh approval, names the build steps the change affects, and returns control here
       without starting another build. Then redo, from step 2 (a new spec can name a new target),
       those steps **and** the remediation of every `defect` finding in the same verdict, and run
       `/review <owner>/<id>` again from step 7. This build still owns the review rounds and the ship
       question. A replan restarts the two-round count, because the rounds measured a plan that no
       longer exists; what bounds repeated replans is that each one needs the person's approval.
     When the human says stop, say plainly that the ticket carries a REQUEST-CHANGES verdict and
     `/ship` will refuse it. **There is no path from REQUEST-CHANGES to `/ship`.**

## Pattern
Plan and spec are authored in `/ticket` (read-only, approved once); this skill executes them, with
subagents that see only the record when the ticket is spec-sized, and closes with the independent
check. The PRP spec/execute split, kept in one window, with the check made part of the build and a
route back to planning when the check finds the plan was wrong.
