---
name: spec-and-build
description: Research-rich spec then execute it. `spec` mode writes a PRP-style blueprint (committed before building); `build` mode implements it in fresh context with independent validation. The IMPLEMENT phase.
argument-hint: spec <ticket-id> "<what to build>" [--warehouse <name>] | build <ticket-id> [spec-path]
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Agent]
---

# /spec-and-build

The **build** step of the lifecycle, split into two committed steps so planning and execution use
separate context (context-reset discipline). Generalizes the PRP (product-requirement-prompt) pattern
(`generate-data-object-prp` → `prp-data-object-execute`) to any warehouse via the adapter.

Reads `.claude/config/stack.yaml`. Front-loads decisions into a spec **before** any code — the
context-engineering core idea: AI fails from missing context, not weak models.

---

## Mode: `spec` — author the blueprint (this is still PLAN-adjacent; no production writes)

1. **Preflight** each warehouse **target** the ticket needs (resolve per `adapters/README.md`
   § Multi-target seams; verify each; halt with that target's auth notes). If no warehouse
   configured, the spec is code/analysis-only — proceed without warehouse steps.
2. **Research in parallel, never implement.** Spawn read-only research (Agent/Explore, or re-run
   the priming slices from `/ticket` — see `skills/ticket/priming.md`):
   - explore the objects via `warehouse.describe` + samples; map dependencies + grain;
   - read the 2–4 closest prior tickets (from `/ticket`'s reuse brief, or
     `bin/recall.py --for <id>`) and reuse their SQL/QC where it fits;
   - pull the business rules from the `documentation/` glossary (the domain slice).
   Research agents return findings only; **they do not write code.**
3. **Write the spec** from `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/spec.md.tmpl` into the ticket's folder
   (`specs/<id>-<slug>.md` or `final_deliverables/`): operation type (new/alter), data grain,
   sources + join/cast rules, transformation logic, **validation gates** (the exact QC the build must
   pass), downstream impact, the **dev target** (`seams.warehouse.dev_target`, else the key the
   warehouse adapter names in its `dev_key:` frontmatter), and a **confidence score (1–10)**.
4. **Reduce assumptions:** before finalizing, list open questions and **ask the user** (don't guess).
5. **Commit the spec** via vcs `commit` (`docs: <id> spec for <thing>`) — policy
   `commit_plan_before_implement` enables blame-free retry if the build later reveals a gap.

## Mode: `build` — execute the committed spec (fresh context)

6. **Load** the committed spec (path arg or newest in the ticket's `specs/`). Treat it as the source
   of truth, but **validate each step independently** — don't blindly follow; the spec can be wrong.
7. **Implement in small build-and-check sub-loops:** one object/step at a time. Develop against
   the warehouse's **dev target** first; parameterize values at the top **via a CTE params row
   (`WITH params AS (SELECT … AS anchor) … CROSS JOIN params`), not a session `DECLARE`/`SET`** —
   CTE params stay portable and keep CSV exports clean; explicit `ORDER BY` on any export
   (deterministic outputs).
8. **Embed validation between steps** — after each, run the relevant gate from the spec; self-correct.
9. **Any mutation** ⇒ policy `db_write_requires_approval` (`off` | `high_risk` | `all`). Under the
   default `high_risk`: show the exact SQL, explain the change, and wait for explicit `yes` before
   anything irreversible or access-changing (DROP/DELETE/UPDATE/TRUNCATE/MERGE/GRANT/
   `CREATE OR REPLACE`/non-`ADD` `ALTER`); additive SQL may run without asking. Read the policy
   rather than assuming. Dev-env objects still get shown but are lower-risk.
10. **Hand off to the check step:** when the build passes its own gates, stop and recommend
    `/review <id>` for the independent pass. Do not ship from here.

## Generalizes
`generate-data-object-prp` + `prp-data-object-execute` + `PRPs/templates/data-object-initial.md`,
warehouse-agnostic via `seams.warehouse`, and works the same when that seam holds several targets.
