---
name: skillify
description: Turn a recurring "clone-the-last-ticket" workflow into a parameterized skill of its own — phased pipeline, QC checkpoints, golden-replay test, hard-halt before external posts.
---

<!-- emitted by ticketwright install v4.5.0 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

# /skillify

The meta-skill (`skillify_everything`). When a task recurs (quarterly sale, monthly report,
periodic reconciliation), this stamps out a new **folder skill** with the generated-skill skeleton:
a phased pipeline with hard halts, parameterized SQL/steps, a QC checkpoint, a golden-replay
regression test, and a hard halt before any external post. Candidates come from two places: the
repeat check in [repeats.md](repeats.md) (`recall.py --repeats`: this ticket reads the same tables
as an earlier one), which `/ticket`, `/ship`'s retro and a session's closing message run at the
second instance, and the `--recurring` flag of `bin/build_ticket_index.py` ("this object shows up
in 7 tickets").

**Where it came from.** When the run starts from a repeat suggestion, it arrives with the tickets
the pattern came from. Use them as the golden fixture's known-good run (Phase 1) and write them,
always as `<owner>/<id>`, into the new skill's `built_from:`, with the tables they read in
`read_objects:`. That is how the next repeat check finds this skill instead of suggesting a second
one. A bare id that more than one owner has is not written: ask which ticket it meant.

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

In this skill the questions are Phase 1's interview about the workflow.

## Phase 1 — Interview the workflow (reduce_assumptions)
Ask by the question rule in "How this skill asks the person something" above (its probe is
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" kit_paths.py --json`), one question at a time
in prose, for:
- **Name & cadence** (→ kebab skill name) and the **parameters** that change each run (e.g.
  `--period`, `--as-of-date`, `--ticket`, an input file) — with formats + validation rules.
- **Steps**: the ordered phases. For each, what it reads, what it writes, and whether it has
  external side effects or DB writes (those become hard-halt / approval gates).
- **QC checks**: per check — what it tests, and its tier (hard-halt / warn / info) + remediation hint.
- **Determinism anchor**: the known-good prior run to use as the **golden fixture** (counts/totals
  to assert; the byte-identical output file to diff against).

## Phase 2 — Stamp from the template (HARD HALT → confirm before writing a new skill)
`/skillify` is model-invocable: the model may reach for it when it notices a workflow recurring.
Because this phase writes a **brand-new skill** into the repo — self-modifying tooling — it stops
first. **Print the plan, then stop and wait for the user** before any file is created: the skill
name, its path (`.claude/skills/<name>/`), and the file list about to be written (`SKILL.md`,
`sql/`, `templates/`, `bin/`, `golden/`). Only on explicit confirmation, stamp the files.
1. `KIT="$(bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit)"`, then copy
   `"$KIT"/templates/generated-skill/` → `.claude/skills/<name>/` (SKILL.md + `sql/ templates/
   bin/ golden/`).
2. Render `SKILL.md.tmpl` with the interview answers (`built_from` and `read_objects` are
   comma-separated, and empty when the run did not start from a repeat) into the canonical phase shape:
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
