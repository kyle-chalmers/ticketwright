# Spec authoring — the deep blueprint, written during scoping

`/ticket` Phase 4 runs this when the plan's **Next step** says `spec: required`. It is **read-only by
design**: research, `describe`, samples, prior tickets, the glossary — then one file written. Nothing
here touches a warehouse object or produces a deliverable; that is `/build`'s job, and `/build` does not
start until the human has approved the plan and this spec together. (Running the same steps later —
a plan that turns out to need a spec after all — is fine; it still happens before the build resumes.)

A spec is warehouse-shaped detail on top of the plan: operation type, data grain, sources and join /
cast rules, transformation logic, the exact validation gates the build must pass, downstream impact,
the dev target, and a confidence score. The plan already holds the scope, the deliverables and the open
questions — read it first and do not restate it.

## Steps

1. **Preflight** each warehouse **target** the plan names (resolve per `adapters/README.md`
   § Multi-target seams; verify each; halt with that target's auth notes). If no warehouse is
   configured, the spec is code/analysis-only — proceed without the warehouse steps.
2. **Research in parallel, never implement.** Spawn read-only research (Agent/Explore where the
   runtime has subagents, otherwise inline), starting from the plan and the priming brief
   ([priming.md](priming.md)):
   - explore the objects via `warehouse.describe` + a 5-row sample each; map dependencies + grain;
   - read the 2–4 closest prior tickets (the reuse brief, or
     `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" recall.py --for <owner>/<id>`)
     and note which SQL / QC artifacts to reuse;
   - pull the business rules from the `documentation/` glossary (the domain slice).
   Research returns findings only; **it writes no code.**
3. **Write the spec** — `KIT="$(bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit)"`,
   then render `"$KIT"/templates/spec.md.tmpl` → `<ticket-dir>/specs/<id>-<slug>.md`: operation type
   (new/alter), data grain, sources + join/cast rules, transformation logic, **validation gates** (the
   exact QC the build must pass — these become `/review`'s checklist too), downstream impact, the
   **dev target** (`seams.warehouse.dev_target`, else the key the warehouse adapter names in its
   `dev_key:` frontmatter), and a **confidence score (1–10)**. Record the spec path in the plan's
   Next step.
4. **Reduce assumptions:** add the spec's open questions to the plan's list — `/ticket` asks them all
   at once, before approval (`reduce_assumptions`).
5. **Do not commit here.** `/ticket` commits the plan and the spec together after the single approval
   (`commit_plan_before_implement`), so the record shows one approved scoping package, not two halves.
