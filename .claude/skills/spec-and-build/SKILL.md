---
name: spec-and-build
description: Research-rich spec then execute it. `spec` mode writes a PRP-style blueprint (committed before building); `build` mode implements it in fresh context with independent validation. The IMPLEMENT phase.
argument-hint: spec <ticket-id> "<what to build>" | build <ticket-id> [spec-path]
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Agent]
---

# /spec-and-build

The **IMPLEMENT** phase of the PIV loop, split into two committed steps so planning and execution use
separate context (context-reset discipline). Generalizes the PRP (product-requirement-prompt) pattern
(`generate-data-object-prp` → `prp-data-object-execute`) to any warehouse via the adapter.

Reads `.claude/config/stack.yaml`. Front-loads decisions into a spec **before** any code — the
context-engineering core idea: AI fails from missing context, not weak models.

---

## Mode: `spec` — author the blueprint (this is still PLAN-adjacent; no production writes)

1. **Preflight** the warehouse seam (verify; halt with auth notes if unreachable). If no warehouse
   configured, the spec is code/analysis-only — proceed without warehouse steps.
2. **Research in parallel, never implement.** Spawn read-only research (Agent/Explore or `/prime-*`):
   - explore the objects via `warehouse.describe` + samples; map dependencies + grain;
   - read the 2–4 closest prior tickets (the analogs from `/prime-ticket`);
   - pull the business rules via `/prime-domain`.
   Research agents return findings only; **they do not write code.**
3. **Write the spec** from `templates/spec.md.tmpl` into the ticket's folder
   (`specs/<id>-<slug>.md` or `final_deliverables/`): operation type (new/alter), data grain,
   sources + join/cast rules, transformation logic, **validation gates** (the exact QC the build must
   pass), downstream impact, dev-env target (`seams.warehouse.dev_db`), and a **confidence score
   (1–10)**.
4. **Reduce assumptions:** before finalizing, list open questions and **ask the user** (don't guess).
5. **Commit the spec** via vcs `commit` (`docs: <id> spec for <thing>`) — policy
   `commit_plan_before_implement` enables blame-free retry if the build later reveals a gap.

## Mode: `build` — execute the committed spec (fresh context)

6. **Load** the committed spec (path arg or newest in the ticket's `specs/`). Treat it as the source
   of truth, but **validate each step independently** — don't blindly follow; the spec can be wrong.
7. **Implement in small PIV sub-loops:** one object/step at a time. Develop against
   `seams.warehouse.dev_db` first; parameterize values at the top; explicit `ORDER BY` on any export
   (deterministic outputs).
8. **Embed validation between steps** — after each, run the relevant gate from the spec; self-correct.
9. **Any non-SELECT / DDL** ⇒ policy `db_write_requires_approval`: show the exact SQL, explain the
   change, wait for explicit `yes`. Dev-env objects still get shown but are lower-risk.
10. **Hand off to VALIDATE:** when the build passes its own gates, stop and recommend `/qc-review <id>`
    for the independent pass. Do not deliver from here.

## Generalizes
`generate-data-object-prp` + `prp-data-object-execute` + `PRPs/templates/data-object-initial.md`,
warehouse-agnostic via `seams.warehouse`.
