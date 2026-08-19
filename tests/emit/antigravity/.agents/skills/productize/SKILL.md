---
name: productize
description: Turn a recurring "clone-the-last-ticket" workflow into a parameterized skill of its own — phased pipeline, QC checkpoints, golden-replay test, hard-halt before external posts.
---

<!-- emitted by ticketwright install v3.5.0 — do not hand-edit; re-run `ticketwright install --runtime antigravity` to update. -->

> **User-invocable only — not enforced on antigravity.** The canonical source of this skill
> declares `disable-model-invocation: true`: a person invokes it deliberately; the model
> must never choose it on its own. antigravity has no equivalent control, so nothing mechanical
> prevents model invocation here — treat any model-initiated use of this skill as a bug.
> Its canonical `allowed-tools` restriction ([Read, Write, Edit, Bash, Glob]) is not enforced here either.

# /productize

The meta-skill (`skillify_everything`). When a task recurs (quarterly sale, monthly report,
periodic reconciliation), this stamps out a new **folder skill** with the productized skeleton:
a phased pipeline with hard halts, parameterized SQL/steps, a QC checkpoint, a golden-replay
regression test, and a hard halt before any external post. `/refresh index` + the `--recurring`
flag of `bin/build_ticket_index.py` surface candidates ("this object shows up in 7 tickets").

## Phase 1 — Interview the workflow (reduce_assumptions)
Ask, in prose (runtimes that render structured options show chips; others a numbered list), for:
- **Name & cadence** (→ kebab skill name) and the **parameters** that change each run (e.g.
  `--period`, `--as-of-date`, `--ticket`, an input file) — with formats + validation rules.
- **Steps**: the ordered phases. For each, what it reads, what it writes, and whether it has
  external side effects or DB writes (those become hard-halt / approval gates).
- **QC checks**: per check — what it tests, and its tier (hard-halt / warn / info) + remediation hint.
- **Determinism anchor**: the known-good prior run to use as the **golden fixture** (counts/totals
  to assert; the byte-identical output file to diff against).

## Phase 2 — Stamp from the template
1. `KIT="$(bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" --kit)"`, then copy
   `"$KIT"/templates/productized-skill/` → `.claude/skills/<name>/` (SKILL.md + `sql/ templates/
   bin/ golden/`).
2. Render `SKILL.md.tmpl` with the interview answers into the canonical phase shape:
   **Phase 0** pre-flight (validate params + `verify_stack` for touched seams + an object drift
   check → halt-on-fail) → **render & run** parameterized steps → **QC** atomic checkpoint
   (hard-halt tiers) → **export** (deterministic `ORDER BY`) → **render docs** (README +
   tracker-comment draft) → **HARD HALT for human review** → **post-review** (the external posts,
   in a separate invocation).
3. Write the `{{token}}` step files into `sql/` (or `bin/` for non-SQL), the output templates into
   `templates/`, and seed `golden/<run>.json` with the determinism anchor. **Follow the two SQL
   authoring rules in [authoring.md](authoring.md)** — a render gate enforces both.
4. Scaffold `bin/drift_check.sh` (confirms every object the workflow reads is still reachable —
   the Phase-0 catch for relocations).

## Phase 3 — Wire to the stack & self-test
5. The stamped skill reads `.claude/config/stack.yaml` and resolves all I/O through adapters (no
   hardcoded tools in the orchestration). Confirm the SKILL.md prose is tool-neutral:
   `!grep -REn "acli|snow |slack|gh " .claude/skills/<name>/SKILL.md || echo OK`. (The leaf
   `bin/drift_check.sh` is allowed to name your warehouse CLI — it's the tool-bound probe.)
6. Wire the **render gate** (`bin/render_and_validate.sh`) and **export helpers**
   (`bin/split_and_export.sh`) into the stamped phases so authoring defects fail *closed*, not
   silently — details and rationale in [authoring.md](authoring.md).
7. Document the **golden test** + **failure-mode tests** in the new SKILL.md (how to replay the
   known run and assert the fixture; how each Phase-0/QC/render-gate halt is expected to trigger).
8. **Report** the new skill path, its parameters, and how to run its golden test.

## Output shape (what every stamped skill guarantees)
Parameterized · phased · QC-gated · golden-tested · hard-halts before external posts · idempotent
where possible (re-run converges) · records a rollback key for any DB write. Heavy pulls run in the
**background**, not the foreground — mark slow phases at stamp time so the operator launches them
detached from the start.
