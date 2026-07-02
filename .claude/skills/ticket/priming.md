# Context priming — the four slices `/ticket` loads

Small, scoped priming keeps the build phase focused and cheap. Load *slices*, never the whole
knowledge base. Each slice below was a separate command in v1 (`/prime-ticket`, `/recall`,
`/prime-domain`, `/prime-warehouse`); `/ticket` now runs them as one pass.

## 1 · Ticket slice

- **Fetch the ticket** via the tracker adapter's `fetch_ticket` verb (title, description, type,
  status, links). If the tracker seam is down, fall back to the local `README.md`.
- **Read the ticket folder** at the rendered `project.ticket_path` if it exists: `README.md` +
  a listing of `final_deliverables/` — summarize prior progress (resume, don't restart).
- Note the ticket's key nouns (objects, stakeholders, report names) — they drive the other slices.

## 2 · Recall (prior art — never rebuild what's built)

- **Rank candidates** (deterministic, instant — no vector store):
  ```
  python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/recall.py" --for <id>
  #  or: --query "<topic>"   |   --tags a,b   |   --object <NAME>   (add --json for structured)
  ```
  Scoring is transparent: object match ×4, tag ×3, cross-ref link +5, keyword overlap ×1; recency
  is a tiebreak. The seed ticket is excluded.
- **Read the top 2–4** candidate READMEs (+ their `final_deliverables/` and `qc_queries/`
  listings). Many candidates → spawn read-only Explore agents in parallel (findings only).
- **Write the reuse brief** (≤ ~200 words): the closest prior work, **what to copy** (which SQL/QC
  artifact + path), known **gotchas** those tickets carried, and **what's different** this time.

## 3 · Domain slice (business meaning)

- `grep -ril "<topic>" documentation/` and read only the matching sections — the definitions,
  status taxonomies, calculation/eligibility rules, exclusions, and documented data-quality
  gotchas for this topic.
- Scan `AGENTS.md` for any hard rule mentioning the topic (e.g. "as-of date is month-end").
- If `documentation/` is empty, note that `/refresh context` would build the knowledge pack —
  don't block on it.

## 4 · Warehouse slice (only the objects in play)

- Skip cleanly if `seams.warehouse` is absent/null ("no warehouse configured").
- **Preflight** the warehouse seam (`seams.warehouse.verify`); if it fails, halt this slice with
  the adapter's auth notes — don't guess at schemas.
- **Resolve object names** (topic → real names via the local pack and the adapter's discovery
  query), then per object: `describe` (columns/types/DDL), a 5-row sample via `query`, and
  dependencies per the adapter's `dialect_notes` lineage approach.
- Brief per object: key columns, join keys (+ cast/filter rules from `dialect_notes`), grain, and
  the safest source layer to read from.
