# `/refresh index` — the ticket catalog in detail

Two layers, kept separate so the catalog is reproducible and CI/pre-commit-safe:

- **`bin/build_ticket_index.py`** — deterministic, LLM-free renderer. Discovers every ticket folder
  (tracker keys from `stack.yaml` `key_prefixes`/`key_prefix`), merges curated fields from
  `tickets/index_data.json`, and writes `INDEX.md` + `OBJECTS.md` (object → tickets reverse index;
  objects = enrichment ∪ a deterministic grep of each ticket's SQL). `--check` (staleness gate,
  covers both files) · `--stats` (coverage) · `--recurring` (frequently-touched objects —
  productization candidates).
- **`tickets/index_data.json`** — the curated store (title/status/date/summary/tags/cross_refs/
  objects + each README's content hash). This skill writes it.

## Phase 0 — Preflight
1. Confirm `stack.yaml` has `key_prefix`/`key_prefixes` and (optionally) `ticket_url_template`.
2. `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py" --stats` — how
   many tickets are discovered, enriched, un-enriched (`▱`), stale (`⚠`).

## Phase 1 — Render (always cheap, no model)
3. `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py"` — every ticket
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
   echo '{"records":[ ... ]}' | python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/ingest_index_records.py" --from-json -
   python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py"
   ```
   (Claude-Code convenience: `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/enrich_ticket.py" <ID>`
   does steps 5–6 for one ticket via `claude -p`. The inline path above is agent-agnostic.)

## Phase 3 — Verify
7. `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py" --check` must
   pass (INDEX.md + OBJECTS.md == fresh render).
8. Report: total tickets, status breakdown, any still un-enriched. Commit `tickets/INDEX.md` +
   `tickets/OBJECTS.md` + `tickets/index_data.json` (all three — `--check` gates the two generated
   files).
