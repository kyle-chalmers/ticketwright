# Context priming — the four slices `/ticket` loads

Small, scoped priming keeps the build phase focused and cheap. Load *slices*, never the whole
knowledge base. Each slice below was a separate command in v1 (`/prime-ticket`, `/recall`,
`/prime-domain`, `/prime-warehouse`); `/ticket` now runs them as one pass.

## 1 · Ticket slice

- **Fetch the ticket** via the tracker adapter's `fetch_ticket` verb (title, description, type,
  status, links). If the tracker seam is down, fall back to the local `README.md`.
- **Read the ticket folder** at the rendered `project.ticket_path` if it exists: `README.md` +
  a listing of `final_deliverables/` — summarize prior progress (resume, don't restart).
- **When `project.intake` lists `email`, `chat`, or `meetings`**, also read `source_materials/`
  for material a human dropped in (a forwarded thread, a chat export, meeting notes from an AI
  notetaker) — work arriving outside the tracker arrives as files, not API calls, so this is the
  intake channel's entire consumer. Enumerate it rather than guessing at names:
  ```
  bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" scan_source_materials.py --ticket <ticket-dir> --intake
  ```
  It lists exactly the files to read and **omits raw transcripts on purpose** — a full transcript
  belongs in the ticket folder, not in your context. Meeting notes arrive as
  `YYYY-MM-DD-<slug>-meeting.md`, the committed curated form.
- **When `seams.meetings` is configured**, the ticket can also *reference* a meeting instead of
  (or before) carrying an export: a `meeting_ref: <provider>:<id>` frontmatter key in a
  `source_materials/YYYY-MM-DD-<slug>-meeting.md` stub (grammar in `stack.schema.md`). Enumerate
  them mechanically — never by guessing at frontmatter:
  ```
  bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" meeting_refs.py --ticket <ticket-dir> --json
  ```
  Exit family: 0 ok · 2 usage · 4 malformed-or-refused. Zero refs ⇒ do nothing (never fetch
  speculatively). Exit 4 ⇒ surface the named error — `refused-credential` means a URL/token was
  committed; ask for the bare id. For each ref whose provider matches the configured tool
  (resolve via the config resolver, `--seam meetings` — a mismatch is an error to surface, not a
  silent skip), call the adapter's `fetch_transcript` — the text comes **to context, never to
  disk** — and `fetch_action_items`, handling the typed result per the adapter contract: `ok` →
  use the items; `empty` → report "no action items recorded" and do NOT extract (the provider's
  answer is authoritative); `no_native_export` → extract action items in-context from the
  transcript text. Then curate into the committed stub (decisions + action items). The raw
  transcript's only opt-in location on disk is `source_materials/private/` — gitignored, and
  every `/ship` scan and copy-guard prompt flags it by design. Refs come back ordered by
  filename, so the date prefix gives chronology; process in order.
- Note the ticket's key nouns (objects, stakeholders, report names) — they drive the other slices.

## 2 · Recall (prior art — never rebuild what's built)

- **Rank candidates** (deterministic, instant — no vector store):
  ```
  bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" recall.py --for <owner>/<id>
  #  or: --query "<topic>"   |   --tags a,b   |   --object <NAME>   (add --json for structured)
  #  pass the qualified locator you resolved in Phase 0 — a bare id works while one owner has it,
  #  but an id under two owners hard-stops (equivalently: --for <id> --owner <owner>)
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
- Resolve and **preflight** the target(s) in play — see `adapters/README.md` § Multi-target seams.
  If one fails, halt this slice with
  the adapter's auth notes — don't guess at schemas.
- **Resolve object names** (topic → real names via the local pack and the adapter's discovery
  query), then per object: `describe` (columns/types/DDL), a 5-row sample via `query`, and
  dependencies per the adapter's `dialect_notes` lineage approach.
- Brief per object: **which target it lives on** (two targets can hold same-named objects at
  different grain), key columns, join keys (+ cast/filter rules from `dialect_notes`), grain, and
  the safest source layer to read from.
