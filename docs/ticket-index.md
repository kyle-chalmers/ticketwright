# Ticket Index

`tickets/INDEX.md` is the master catalog of **every** ticket in the repo — one row per ticket
with status, completion date, a one-line summary, topic tags, and cross-references to related
tickets. It exists so the agent (and humans) can **recall prior work before starting new work** —
"have we done this before? which object did it touch? who was the stakeholder?" — instead of
rediscovering it each time. The agent is shown a slice of it at the start of every session.

## How it works (two layers)

The system deliberately separates a **deterministic renderer** from an **LLM-authored enrichment
store**, so the catalog is reproducible and CI/pre-commit-safe while still carrying good,
human-readable summaries.

| File | Role | Authored by |
|---|---|---|
| `tickets/index_data.json` | Enrichment store: per-ticket `title`, `status`, `date`, one-line `summary`, `tags`, `cross_refs`, `objects`, plus each README's `readme_hash` at enrichment time. | model (build-ticket-index skill / close step) |
| `bin/build_ticket_index.py` | **Renderer.** Discovers every ticket folder, merges the store, writes `tickets/INDEX.md` + `tickets/OBJECTS.md`. Deterministic, LLM-free, stdlib-only. | — |
| `tickets/INDEX.md` | The rendered catalog (committed; read by humans + the SessionStart hook). | generated |
| `tickets/OBJECTS.md` | Reverse index: data object → tickets that touched it (objects = enrichment ∪ a grep of each ticket's SQL). | generated |
| `bin/recall.py` | Prior-art recall: ranks prior tickets vs a seed/query by object/tag/cross-ref/keyword overlap (lexical, stdlib). Behind `/recall`. | — |
| `bin/ingest_index_records.py` | Upserts records into `index_data.json`, stamping each with the live README hash. | — |
| `bin/enrich_ticket.py` | One-command close-step enricher: reads a README, has `claude -p` write the curated summary/status/date/tags/refs, ingests + re-renders. (Claude-Code convenience.) | model (headless) |
| `.claude/hooks/ticket_index_context.py` | SessionStart hook: prints counts + the most-recent tickets + a pointer to grep `INDEX.md`. | — |
| `.claude/hooks/regenerate_ticket_index.py` | PostToolUse (Write/Edit) hook: auto-re-renders `INDEX.md` whenever a file under `tickets/` changes — new tickets appear immediately, edited READMEs flag `⚠`. | — |

**Why split?** Regex can't write a good summary, but a model isn't reproducible and can't run in a
pre-commit gate. So the model writes summaries into `index_data.json`; the renderer only *renders*
(no model at render time) and stays byte-stable for the same on-disk state.

## What counts as a ticket

Any immediate sub-folder of `tickets/<owner>/` whose name contains a **tracker key** — the prefixes
come from `stack.yaml` (`key_prefixes`, else `key_prefix`; e.g. `ENG-12`). Emoji-prefixed names like
`☑️ ENG-12_thing` work too (`☑️` = done, `🛠️` = in progress — an optional convention). Folders with
**no** tracker key are treated as reference/scratch work and skipped (e.g. `adhoc-*`, `scratch-*`,
`ℹ️ notes`). Rows key on **(owner, id)**, so the same id can appear under two owners.

## Configuration (in `stack.yaml`)

- `key_prefix` / `key_prefixes` — which tracker keys the index recognizes in folder names.
- `ticket_url_template` — e.g. `https://acme.atlassian.net/browse/{id}`; how `INDEX.md`/`OBJECTS.md`
  link each ticket. `{id}` = full key (`ENG-12`); `{number}` = trailing integer (for Azure Boards /
  GitHub Issues whose native id is a bare number). Omit/`null` to drop the `↗` link.

## Prior-art recall & the object reverse-index

The index is only valuable if it's *mined*. Two capabilities turn the passive catalog into active reuse:

- **`/recall <id>`** (engine `bin/recall.py`) ranks prior tickets against a seed ticket (or
  `--query` / `--tags` / `--object`) by a transparent lexical score — **object match ×4, tag ×3,
  cross-ref link +5, keyword ×1**, recency as a tiebreak — then reads the top few READMEs and writes a
  *reuse brief* (what to copy, gotchas, what's different). Wired into `/prime-ticket` + `spec-and-build`
  so prior art surfaces automatically in PLAN. Lexical + stdlib (no embeddings); the rank → read-top-K
  shape is the retrieval path that scales past the point where the whole `INDEX.md` fits in context.
- **`tickets/OBJECTS.md`** — reverse map: each data object → tickets that touched it
  (`/recall --object VW_X` queries it live). A ticket's `objects` = **enrichment** (the model names them)
  **∪** a **deterministic grep** of its `*.sql`/`*.py`, keyword-anchored (`FROM`/`JOIN`/… `schema.object`,
  so `os.path.join` isn't a false positive). Rendered + `--check`-gated alongside `INDEX.md`.

## Maintaining it

```bash
python3 bin/build_ticket_index.py            # (re)render INDEX.md from the store + live folders
python3 bin/build_ticket_index.py --check    # staleness gate: exit 1 if INDEX.md != a fresh render
python3 bin/build_ticket_index.py --stats    # coverage: enriched / un-enriched / stale
```

A ticket on disk but absent from `index_data.json` still appears in `INDEX.md` — the renderer falls
back to the README's H1 + first paragraph and marks the row `▱` (not yet curated). If a README
changes after enrichment, the row is marked `⚠` (summary may be stale). Neither breaks `--check`;
both are cues to re-enrich. Use the **`/build-ticket-index`** skill to bootstrap or re-enrich.

**Auto-regeneration.** The `PostToolUse` hook re-renders `INDEX.md` whenever the agent writes/edits
any file under `tickets/` — a new ticket shows up the moment its README is written (`▱`), and an
edited README flags `⚠`. The hook only runs the deterministic renderer (never the model), writes
only when output actually changes, and no-ops for edits outside `tickets/`.

### At ticket close

Upgrade the closed ticket's row from auto-derived to curated, then commit. One command (reads the
README, writes the summary via `claude -p`, ingests, re-renders):

```bash
python3 bin/enrich_ticket.py ENG-123      # or --branch to use the current branch's id
```

Then commit `tickets/INDEX.md` + `tickets/OBJECTS.md` + `tickets/index_data.json` with the ticket
(all three — `--check` gates the two generated files). An agent closing the
ticket already has full context and may instead write the record itself and pipe it to
`bin/ingest_index_records.py --from-json -`; `enrich_ticket.py` is the hands-off path that also works
for a human at the terminal. This is wired into the `deliver-ticket` skill.

## Why markdown, not a vector DB

At a few hundred tickets, a model reading a structured `INDEX.md` outperforms vector similarity for
recall, with zero infrastructure. If the table ever outgrows the session-start context window, the
SessionStart hook already injects only the most-recent slice and points at the full file to grep.

## Enforcement

`--check` is designed to run as a **pre-commit hook or a CI job** so `INDEX.md` can't drift from the
source. The SessionStart hook keeps the agent aware of the catalog every session, which is the
primary freshness mechanism even without CI.
