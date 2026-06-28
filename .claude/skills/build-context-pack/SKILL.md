---
name: build-context-pack
description: Bootstrap or refresh the repo's domain knowledge base — object inventory, DDL dump, dependency graph, usage ranking, data catalog, ERD, and business glossary into documentation/. The on-demand-context tier the prime-* commands read.
argument-hint: "[--refresh] [schema-or-scope]"
allowed-tools: [Read, Write, Bash, Glob, Grep]
---

# /build-context-pack

Builds the **on-demand context** tier of the AI layer — the domain knowledge base that `/prime-domain`
and `/prime-warehouse` read from, so day-to-day tickets prime *slices* instead of re-discovering the
warehouse every time. Reads `.claude/config/stack.yaml`; introspects via the warehouse adapter, so it
works on Snowflake, BigQuery, or Databricks. Generalizes a hand-built ERD / analysis doc set
+ `data_catalog.md` + `data_business_context.md`.

## Phase 0 — Setup
1. Read `stack.yaml`; verify the warehouse seam (halt with auth notes if unreachable). Scope to
   `$ARGUMENTS` (a schema/dataset) or the whole configured warehouse. `--refresh` updates an existing
   pack in place (overwrite, don't sprawl).

## Phase 1 — Introspect (read-only, via adapter)
2. **Object inventory** — list tables/views/dynamic-tables in scope, using whatever object-inventory
   idiom the adapter's `dialect_notes` specifies (e.g. an `INFORMATION_SCHEMA`/`system` query).
3. **DDL dump** — `warehouse.describe` each object; write authoritative DDL to
   `documentation/erd/ddl_<schema>_<object>.sql`.
4. **Dependency graph** — derive what-reads-what (lineage views) → an object→object edge list.
5. **Usage ranking** — rank objects by how often they appear across `tickets/**` (`!grep -roh …`) so
   the catalog leads with what's actually used.

## Phase 2 — Generate the pack (into documentation/)
6. **`data_catalog.md`** — per object: purpose, grain, key columns, join keys + cast/filter rules
   (from `dialect_notes`), source layer, usage rank.
7. **`erd.md`** — the relationships + a high-level diagram; the per-object DDL lives under `erd/`.
8. **`glossary.md`** — business terms, status taxonomies, calculation rules, known data-quality
   caveats. Seed from existing READMEs/runbooks; flag gaps for a human to fill (don't invent
   business meaning — `reduce_assumptions`).
9. Add a freshness stamp + scope to each file (the a "re-check if >30 days old" freshness convention).

## Phase 3 — Index & report
10. Update `documentation/AI_LAYER_INDEX.md` with the pack's contents. Report what was generated,
    the top-N most-used objects, and which glossary sections need human input.

## Deferred (noted, not built)
If wholesale loading of this pack ever becomes painful, the natural next step is to **index it for
retrieval over MCP** (an Archon-style knowledge base the agent queries on demand) — out of scope here
per the plan; this skill produces exactly the corpus such an index would consume.

## Generalizes
`documentation/erd_analysis/` + `data_catalog.md` + `data_business_context.md`, warehouse-agnostic.
