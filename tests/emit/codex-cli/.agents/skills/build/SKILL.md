---
name: build
description: Execute the plan or spec on file in fresh context, in small build-and-check loops, then run the independent review before handing off to ship. The IMPLEMENT + CHECK phase — every build ends with a /review verdict.
---

<!-- emitted by ticketwright install v4.0.3 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

# /build

The **build + check** step of the lifecycle. `/ticket` already did every read-only planning step — the
plan, and the spec when the plan called for one — and the human approved that package. This skill
executes it in fresh context (context-reset discipline: planning and execution never share a
window), validating each step independently, and **ends by running `/review` on the ticket**. The
only exit toward `/ship` is an APPROVE verdict; quality is ensured by the system, not by remembering
to invoke a step.

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
     if one was given). If the named file does not exist → stop: "`plan.md` for `<owner>/<id>` names
     a spec that is not on file — run `/ticket <owner>/<id>` to finish scoping."
   - **`spec: not required`** → the plan is the blueprint.
   - **`spec: after-root-cause`** → run only the plan's investigation steps (read-only against the
     warehouse, plus QC queries that reproduce the problem). When the root cause is known, apply the
     one condition this skill owns: **if the fix creates or alters a persisted object others depend on
     (a warehouse object, a model, a published report), stop and route back to `/ticket <owner>/<id>`**
     — scoping resumes, the spec is written from the real cause, approved, and `/build` runs again
     from Phase 2. If the fix touches nothing persisted (a corrected export, a documented answer),
     record the cause in the README and continue.
   - **Anything else on that line** (blank, a `{{token}}`, a value not listed) → stop and name it; a
     plan the build cannot read is not an approved plan.
   Treat the blueprint as the source of truth, but **validate each step independently** — don't
   blindly follow; a plan or spec can be wrong, and finding that out here is what the small loops
   below are for.
2. **Preflight** each warehouse **target** the blueprint names (resolve per `adapters/README.md`
   § Multi-target seams; verify each; halt with that target's auth notes). No warehouse configured ⇒
   the build is code/analysis/document work — skip the warehouse steps below cleanly.

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
   sign-off before continuing. It exits 0 and stays silent when that user has no viewer config —
   note it once and carry on; this never blocks a build.
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
8. **Branch on the verdict `/review` wrote** (`qc_queries/<n>_review_verdict.md`, `verdict:` line):
   - **APPROVE** → stop and recommend `/ship <owner>/<id>`. Do not ship from here.
   - **REQUEST-CHANGES** → apply the remediation list, re-run the affected gates from Phase 2, and run
     `/review <owner>/<id>` again — from this step, never by re-entering `/build` from the top (a
     build inside a build re-resolves everything and never returns here). **Two REQUEST-CHANGES rounds
     is the cap:** after the second, stop and hand the findings to the human rather than looping — a
     defect the build cannot clear is a scoping problem or a data problem, not a retry problem. When
     the human says stop, say plainly that the ticket carries a REQUEST-CHANGES verdict and `/ship`
     will refuse it. **There is no path from REQUEST-CHANGES to `/ship`.**

## Pattern
Plan and spec are authored in `/ticket` (read-only, approved once); this skill executes them in fresh
context and closes with the independent check. The PRP spec/execute split, with the check made part
of the build rather than a separate thing to remember.
