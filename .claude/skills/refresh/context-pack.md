# `/refresh context` — the domain knowledge pack in detail

Builds the on-demand knowledge base that `/ticket`'s domain + warehouse priming reads, so
day-to-day tickets prime *slices* instead of re-discovering the warehouse every time. Reads
`.claude/config/stack.yaml`; introspects via each configured warehouse target's adapter, so it works
against any warehouse — or several.

## Phase 0 — Setup
1. Read `stack.yaml`; resolve and verify the warehouse target(s) — see `adapters/README.md`
   § Multi-target seams. With several, each target's pack goes under `documentation/<target>/`.
   Scope to
   the given schema/dataset or the whole configured warehouse. `--refresh` updates an existing
   pack in place (overwrite, don't sprawl).

## Phase 1 — Introspect (read-only, via adapter)
2. **Object inventory** — list tables/views/dynamic-tables in scope, using whatever
   object-inventory idiom the adapter's `dialect_notes` specifies (e.g. an
   `INFORMATION_SCHEMA`/`system` query).
3. **DDL dump** — `warehouse.describe` each object; write authoritative DDL to
   `documentation/erd/ddl_<schema>_<object>.sql`.
4. **Dependency graph** — derive what-reads-what (lineage views) → an object→object edge list.
5. **Usage ranking** — rank objects by how often they appear across `tickets/**` (`grep -roh …`)
   so the catalog leads with what's actually used.

## Phase 2 — Generate the pack (into documentation/)
6. **`data_catalog.md`** — per object: purpose, grain, key columns, join keys + cast/filter rules
   (from `dialect_notes`), source layer, usage rank.
7. **`erd.md`** — the relationships + a high-level diagram; per-object DDL lives under `erd/`.
8. **`glossary.md`** — business terms, status taxonomies, calculation rules, known data-quality
   caveats. Seed from existing READMEs/runbooks; **flag gaps for a human to fill** — don't invent
   business meaning (`reduce_assumptions`).
9. Add a freshness stamp + scope to each file (re-check if >30 days old).

## Phase 3 — Index & report
10. Update `documentation/AI_LAYER_INDEX.md` with the pack's contents. Report what was generated,
    the top-N most-used objects, and which glossary sections need human input.
