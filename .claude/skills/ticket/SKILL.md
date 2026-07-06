---
name: ticket
description: The front door — open or resume a ticket, auto-load its context and prior art, and route to the next step (spec, build, review, or ship). Start every ticket here.
argument-hint: <ticket-id> | --create "<summary>" [--type T] [--worktree] | --recall "<topic>" | --recall --object <NAME>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Agent]
---

# /ticket

One command owns the ticket lifecycle: it opens (or creates) the ticket, sets up the workspace,
loads exactly the context this ticket needs, surfaces the closest prior work, and then tells you the
right next step — **plan → build → check → ship**. Reads `.claude/config/stack.yaml`; everything
tool-specific resolves through the adapters, so it works with any configured tracker/warehouse/vcs.

## Mode: `--recall` (standalone prior-art lookup, no workspace setup)
`/ticket --recall "<topic>"` or `--recall --object <NAME>` — rank prior tickets and write a reuse
brief, nothing else. Follow [priming.md](priming.md) § Recall. Useful mid-session ("have we built
this before?", "which tickets touched VW_X?").

## Phase 0 — Resolve & preflight (halt-on-fail)
1. Read `.claude/config/stack.yaml`: `project.*`, `seams.tracker`, `seams.vcs`. If the file is
   missing, say so and offer `/setup` — don't scaffold blind.
2. **Verify** the tracker + vcs seams (run their `verify` commands). If one is unreachable, print
   that adapter's `auth` notes and offer to continue **local-only** (workspace + context still work;
   tracker fetch is skipped) — degrade, don't die.
3. Determine the ticket id: `$ARGUMENTS` id, or (for `--create`) create it first via the tracker
   adapter's `create_ticket` verb (`project.default_epic` as parent if set), then use the new id.

## Phase 1 — Resume, don't restart
4. Render `project.ticket_path` → the ticket dir. If it exists: read its `README.md`, list
   `final_deliverables/`, check `git log --oneline -10` + `git status`, summarize what's done and
   what remains, re-fetch the ticket for new comments, then **skip to Phase 3**.

## Phase 2 — Workspace (new ticket)
5. **Branch** via the vcs adapter, named `<id>`, off `seams.vcs.default_branch` — or a **worktree**
   when `--worktree` is passed (isolates this ticket from other in-flight work; recommended when you
   run several tickets in parallel).
6. **Scaffold** `project.ticket_path` with `project.ticket_subdirs` (create the subdirs empty —
   **no `.gitkeep` placeholders**; they fill with real files during build and git picks them up
   then); tracker adapter `download_attachments` → `source_materials/` (silent if none); render
   `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/ticket-README.md.tmpl` → the ticket dir.
6b. **Refresh the catalog** so the new ticket shows up immediately — it won't otherwise, because the
   PostToolUse index hook only fires on `Write`/`Edit` and scaffolding happens via Bash:
   `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py"` (writes this
   project's `tickets/INDEX.md` + `OBJECTS.md`; the new row shows `▱` until `/ship` curates it).

## Phase 3 — Prime context automatically (the part you never have to ask for)
7. Follow [priming.md](priming.md), in order:
   - **Ticket slice** — the ticket body + folder + related prior tickets;
   - **Recall** — rank prior art (`bin/recall.py`), read the top 2–4, note what to **reuse**;
   - **Domain slice** — glossary/rules for the ticket's topic (from `documentation/`);
   - **Warehouse slice** — schemas/samples/lineage for the specific objects in play (skip cleanly
     if no warehouse is configured).
   Keep the whole brief tight (≤ ~300 words) — slices, not the whole knowledge base.

## Phase 4 — Route
8. Report the context brief (including the reuse brief) and the recommended next step:
   - non-trivial work → `/spec-and-build spec <id>` (blueprint first, build second);
   - small change → build directly, then `/review <id>`;
   - after review passes → `/ship <id>`.

## Stops here
No SQL, no analysis, no external posts. If the request is ambiguous, state your interpretation and
ask before scaffolding heavy structure (`reduce_assumptions`).
