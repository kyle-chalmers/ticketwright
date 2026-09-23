# Spec authoring — the deep blueprint, written during scoping

`/ticket` Phase 4 runs this when the plan's `spec:` decision is that a spec is required. It is
**read-only by design**: research, `describe`, samples, prior tickets, the glossary — then one file
drafted. Nothing
here touches a warehouse object or produces a deliverable; that is `/build`'s job, and `/build` does not
start until the human has approved the plan and this spec together. (Running the same steps later —
a plan that turns out to need a spec after all — is fine; it still happens before the build resumes.)

A spec is the warehouse-shaped detail on top of the plan — the sections are whatever
`templates/spec.md.tmpl` defines, and that file is the only inventory of them. The plan already holds
the scope, the deliverables and the open questions — read it first and do not restate it.

## Steps

1. **Preflight** each warehouse **target** the plan names (resolve per `adapters/README.md`
   § Multi-target seams; verify each; halt with that target's auth notes). If no warehouse is
   configured, the spec is code/analysis-only — proceed without the warehouse steps.
2. **Research the delta, in parallel, never implement.** Phase 3 already ran the four priming slices
   ([priming.md](priming.md)) — its reuse brief and warehouse slice are inputs here, not work to
   repeat. Spawn read-only research (Agent/Explore where the runtime has subagents, otherwise
   inline) only for what the plan added that priming did not cover:
   - explore the objects via `warehouse.describe` + a 5-row sample each; map dependencies + grain;
   - read the 2–4 closest prior tickets (the reuse brief, or
     `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" recall.py --for <owner>/<id>`)
     and note which SQL / QC artifacts to reuse;
   - pull the business rules from the `documentation/` glossary (the domain slice).
   Research returns findings only; **it writes no code.**
3. **Draft the spec** from `templates/spec.md.tmpl` (under the `kit_root` the Phase 4 probe already
   returned — no second launcher call) and fill every section it defines; its **validation gates**
   become `/review`'s checklist, and its **dev target** is `seams.warehouse.dev_target`, else the key
   the warehouse adapter names in its `dev_key:` frontmatter. Set the plan's `spec:` line to the path
   it will be written to, `<ticket-dir>/specs/<id>-<slug>.md`, spelled out from the repo root (for
   example `tickets/alice/ENG-130/specs/ENG-130-returns.md`) so `/build` cannot resolve it anywhere
   else. Like the plan, it is drafted now and written to the ticket only at `/ticket` step 12, after
   approval.
4. **Reduce assumptions:** add the spec's open questions to the plan's list — `/ticket` asks them all
   at once, before approval (`reduce_assumptions`).
5. **Do not write or commit here.** `/ticket` step 12 writes the plan and the spec and commits them
   together after the single approval (`commit_plan_before_implement`), so the record shows one
   approved scoping package, not two halves.
