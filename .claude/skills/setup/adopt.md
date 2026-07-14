# Adopt mode — set up Ticketwright on a repo that already has ticket work

Triggered automatically when Phase 1 detection finds an existing repo: ticket-looking folders
(`tickets/**` or similar), an existing `INDEX.md`, an `AGENTS.md`/`CLAUDE.md`, or custom
`.claude/commands` / `.claude/skills`. The rule: **map onto what exists — never scaffold over it,
never demand a rewrite.**

## 1 · Inventory what's there (read-only)
- **Ticket layout:** find the ticket folders and infer `project.ticket_path` from the observed
  structure (e.g. `tickets/{assignee}/{id}`), the key prefix(es) from folder names, and the
  assignee dirs. Confirm the inference with the user in ONE question.
- **Tools in use:** infer seams from evidence — CI configs, helper scripts, MCP servers, CLIs on
  PATH, existing docs. Pre-select these in the (still ≤5-question) interview.
- **Custom commands/skills:** list everything in `.claude/commands/` and `.claude/skills/` and
  classify each against the plugin's skills: **shadows** (does what a plugin skill does),
  **extends** (domain-specific variant — e.g. a warehouse-specific spec/build flow), or
  **unrelated** (keep as-is).
- **Existing rules file:** if `AGENTS.md`/`CLAUDE.md` exists, do NOT overwrite it.

## 2 · Write config from observed reality
Compose `stack.yaml` from the inventory + interview answers. Point `project.*` at the *existing*
layout. Skip any scaffold step whose target already exists (folders, `.gitignore` — merge new rules
in, never replace).

## 3 · Non-destructive scaffold
- `AGENTS.md` exists → render the template to `AGENTS.ticketwright.md` instead and note the diff
  worth merging (the stack table, the policies, the lifecycle line). The human merges.
- Ticket index: seed `index_data.json` only if absent; then `/refresh index --all` to bootstrap
  the catalog over the existing backlog (deterministic render first, curated enrichment after).

## 4 · Write `MIGRATION.md` (the adoption checklist)
One row per finding, with a recommendation:
| Item | Classification | Recommendation |
|---|---|---|
| custom `start-work.md` command | shadows `/ticket` | **replace** — plugin covers it; delete after a trial ticket |
| custom warehouse-specific spec/build flow | extends `/spec-and-build` | **keep** — domain-optimized; note it in AGENTS.md |
| hand-maintained rules file | overlaps rendered AGENTS.md | **merge** — adopt the stack table + policies block |
Include: what was auto-configured, what needs a human decision, and the suggested trial — run ONE
real ticket through `/ticket → /review → /ship` before deleting anything custom.

## 5 · Verify & report
Same as Phase 4 of the default mode: `selftest.sh` (**kit integrity** — the plugin's own example
stacks) then `verify_stack.sh .claude/config/stack.yaml` (**your repo's** seams). Label the two in
the report so the kit's example stack is never mistaken for the repo's config. The report leads with
the MIGRATION.md path and the trial-ticket suggestion — adoption is incremental by design.
