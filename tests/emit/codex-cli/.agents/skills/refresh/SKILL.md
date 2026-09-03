---
name: refresh
description: Maintain the repo's knowledge — `index` rebuilds the ticket catalog (INDEX.md), `context` rebuilds the domain knowledge pack (documentation/). Day-to-day, hooks keep these fresh automatically.
---

<!-- emitted by ticketwright install v4.0.3 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

# /refresh

One maintenance skill for the two knowledge stores the other skills read:

- **`/refresh index`** — the ticket catalog: `tickets/INDEX.md` (every ticket, status, one-line
  summary, tags, cross-refs) + `tickets/OBJECTS.md` (object → tickets reverse map). This is what
  `/ticket`'s recall mines. Details: [index.md](index.md).
- **`/refresh context`** — the domain knowledge pack in `documentation/`: data catalog, DDL, ERD,
  dependency graph, business glossary. This is what `/ticket`'s domain + warehouse priming reads.
  With no warehouse seam, the pack is the glossary + domain notes built from tickets and repo docs
  (the introspection phases skip cleanly). Details: [context-pack.md](context-pack.md).
- **`/refresh all`** — both.

## You rarely need this
Day-to-day the index maintains itself: the PostToolUse hook re-renders `INDEX.md` on every ticket
folder change, the SessionStart hook surfaces the catalog, and `/ship` curates each ticket's
summary at close. Invoke `/refresh` to:
- **bootstrap** an existing backlog (`/refresh index --all` — render every ticket, then enrich);
- **re-enrich** a batch after bulk edits (`/refresh index ID1 ID2 …`);
- **build or update the knowledge pack** (`/refresh context`, scoped to a schema if given;
  `--refresh` updates in place — overwrite, don't sprawl).

## Mode: `index`
Follow [index.md](index.md): render deterministically (`bin/build_ticket_index.py` — stdlib, no
model), enrich the un-enriched/stale set (the model writes one curated record per ticket, ingested
via `bin/ingest_index_records.py`), re-render, then verify with `--check` and commit the whole index
together — `INDEX.md`, `OBJECTS.md`, `index_data.json`, and the graph layer (`tickets/graph/` +
`tickets/objects/`) when `project.graph_notes` is on (the default).

## Mode: `context`
Follow [context-pack.md](context-pack.md): verify each configured warehouse target, introspect via its adapter
(inventory → DDL → dependencies → usage ranking), generate `data_catalog.md` / `erd.md` /
`glossary.md` into `documentation/` with freshness stamps, and update
`documentation/AI_LAYER_INDEX.md`. Don't invent business meaning — flag glossary gaps for a human
(`reduce_assumptions`).
