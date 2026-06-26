---
name: productize-workflow
description: Turn a recurring "clone-the-last-ticket" workflow into a productized, parameterized skill — phased pipeline, QC checkpoints, golden-replay test, hard-halt before external posts. The meta-skill.
argument-hint: "<workflow name>" (e.g. "monthly vendor reconciliation")
allowed-tools: [Read, Write, Edit, Bash, Glob, AskUserQuestion]
---

# /productize-workflow

The **meta-skill** — embodies `commandify_everything`. When a task recurs (quarterly sale, monthly
report, periodic reconciliation), this stamps out a new **folder skill** with the productized
skeleton: a phased PIV-with-hard-halts pipeline, parameterized SQL/steps, a QC checkpoint, a
golden-replay regression test, and a hard halt before any external post. Typical outputs: a
`quarterly-<thing>` pull or a `monthly-<report>` deliverable that you'd otherwise rebuild by
cloning last quarter's ticket.

## Phase 1 — Interview the workflow (reduce_assumptions)
Ask (AskUserQuestion) for:
- **Name & cadence** (→ kebab skill name) and the **parameters** that change each run (e.g.
  `--period`, `--as-of-date`, `--ticket`, an input file) — with formats + validation rules.
- **Steps**: the ordered phases. For each, what it reads, what it writes, and whether it has external
  side effects or DB writes (those become hard-halt / approval gates).
- **QC checks**: per check — what it tests, and its tier (hard-halt / warn / info) + remediation hint.
- **Determinism anchor**: the known-good prior run to use as the **golden fixture** (counts/totals to
  assert; the byte-identical output file to diff against).

## Phase 2 — Stamp from the template
1. Copy `templates/productized-skill/` → `.claude/skills/<name>/` (SKILL.md + `sql/ templates/ bin/
   golden/`).
2. Render `SKILL.md.tmpl` with the interview answers into the canonical phase shape:
   **Phase 0** pre-flight (validate params + `verify_stack` for touched seams + a view/object drift
   check → halt-on-fail) → **render & run** parameterized steps → **QC** atomic checkpoint (hard-halt
   tiers) → **export** (deterministic `ORDER BY`) → **render docs** (README + tracker-comment draft)
   → **HARD HALT for human review** → **post-review** (the external posts, in a separate invocation).
3. Write the `{{token}}` step files into `sql/` (or `bin/` for non-SQL), the output templates into
   `templates/`, and seed `golden/<run>.json` with the determinism anchor.
4. Scaffold `bin/drift_check.sh` (confirms every object/view the workflow reads is still reachable —
   the Phase-0 catch for relocations).

## Phase 3 — Wire to the stack & self-test
5. The stamped skill reads `.claude/config/stack.yaml` and resolves all I/O through adapters (no
   hardcoded tools in the orchestration). Confirm the SKILL.md prose is tool-neutral:
   `!grep -REn "acli|snow |slack|gh " .claude/skills/<name>/SKILL.md || echo OK`. (The leaf
   `bin/drift_check.sh` is allowed to name your warehouse CLI — it's the tool-bound probe (a
   view/object drift-check); fill it in for your stack.)
6. Document the **golden test** + **failure-mode tests** in the new SKILL.md (how to replay the known
   run and assert the fixture; how each Phase-0/QC halt is expected to trigger).
7. **Report** the new skill path, its parameters, and how to run its golden test.

## Output shape (what every stamped skill guarantees)
Parameterized · phased · QC-gated · golden-tested · hard-halts before external posts · idempotent
where possible (re-run converges) · records a rollback key for any DB write.

## What it produces
A self-contained folder skill (the productized-skill skeleton under `templates/`) — the recurring
workflow extracted into a reusable, parameterized, golden-tested stamper.
