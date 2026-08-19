# `/refresh index` — the ticket catalog in detail

Two layers, kept separate so the catalog is reproducible and CI/pre-commit-safe:

- **`bin/build_ticket_index.py`** — deterministic, LLM-free renderer. Discovers every ticket folder
  (by tracker key from `stack.yaml` `key_prefixes`/`key_prefix`, or by folder name under
  `id_mode: slug`), merges curated fields from
  `tickets/index_data.json`, and writes `INDEX.md` + `OBJECTS.md` (object → tickets reverse index;
  objects = enrichment ∪ a deterministic grep of each ticket's SQL). `--check` (staleness gate,
  covers both files) · `--stats` (coverage) · `--recurring` (frequently-touched objects —
  productization candidates).
- **`tickets/index_data.json`** — the curated store (title/status/date/summary/tags/cross_refs/
  objects + each README's content hash). This skill writes it.

## Phase 0 — Preflight
1. Confirm `stack.yaml` has `key_prefix`/`key_prefixes` — or `id_mode: slug`, where folder names are
   the ids and no prefix is needed — and (optionally) `ticket_url_template`.
2. `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" build_ticket_index.py --stats` — how
   many tickets are discovered, enriched, un-enriched (`▱`), stale (`⚠`).

## Phase 1 — Render (always cheap, no model)
3. `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" build_ticket_index.py` — every ticket
   on disk now has a row (un-enriched ones get a deterministic title + first-paragraph summary,
   marked `▱`).

## Phase 2 — Enrich (the model half)
4. Decide scope (enrichment is the model (re)writing curated summaries — **never rewrite curated
   summaries silently**):
   - a **specific ticket id (or ids)** — enrich just those;
   - **default** (no flag): only the **un-enriched + stale** set from `--stats` — the safe day-to-day
     scope;
   - **`--all`**: cover every ticket **but skip those already enriched and fresh** — the bootstrap
     scope for a new or newly-adopted backlog (render everything, then enrich only what's missing or
     changed);
   - **`--force`** (a.k.a. `--reenrich-all`): genuinely re-enrich **everything**, rewriting even
     hand-curated, non-stale summaries. Rare, and destructive to curation — only on an explicit ask.
5. For each target ticket, read its `README.md` and write ONE record:
   `{id, owner, title, status, date, summary (<=180 chars, lead with what was delivered + key
   numbers), tags (1-4 kebab-case), cross_refs (other ticket ids), objects (qualified data objects
   the ticket read/wrote, e.g. SCHEMA.VIEW; [] if none)}`. **id/owner come from the folder, not
   your judgment.** Status vocab: Completed · Deployed · In Review · In Progress · Blocked · Unknown.
6. Collect them and upsert + re-render:
   ```bash
   echo '{"records":[ ... ]}' | bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" ingest_index_records.py --from-json -
   bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" build_ticket_index.py
   ```
   **This inline path is the primary one** — it works under every runtime, because the host agent
   you are already talking to writes the record. Skipping enrichment is what rots the corpus into a
   folder of SQL nobody can find, so the path that always works is the one to lead with.

   (Shortcut: `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" enrich_ticket.py <ID>` does steps 5–6 for one
   ticket by calling a model headlessly. The command it runs resolves from the detected runtime's
   `adapters/runtime/<name>.md`, so it is no longer Claude-only — but a runtime that documents no
   headless command will tell you so and point back here.)

## Phase 3 — Verify
7. `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" build_ticket_index.py --check` must
   pass (INDEX.md + OBJECTS.md == fresh render).
8. Report: total tickets, status breakdown, any still un-enriched. Commit `tickets/INDEX.md` +
   `tickets/OBJECTS.md` + `tickets/index_data.json` (all three — `--check` gates the two generated
   files).
