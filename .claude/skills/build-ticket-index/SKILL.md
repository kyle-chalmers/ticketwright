---
name: build-ticket-index
description: Build or refresh tickets/INDEX.md — the catalog of every ticket (status, one-line summary, tags, cross-refs) that the agent reads at session start to recall prior work. Renders deterministically from disk; enriches summaries with the model.
argument-hint: "[--all] [TICKET-ID ...]"
allowed-tools: [Read, Write, Bash, Glob, Grep]
---

# /build-ticket-index

Maintains **`tickets/INDEX.md`**, the master catalog of all prior ticket work, so the agent (and
humans) can recall "have we done this before? which object/stakeholder/report?" before starting new
work. This is the kit's **knowledge index** — the deterministic renderer keeps it *complete*; the
model writes the *curated* one-line summaries.

Two layers (kept separate so the catalog is reproducible and CI/pre-commit-safe):
- **`bin/build_ticket_index.py`** — deterministic, LLM-free renderer. Discovers every ticket folder
  (tracker keys from `stack.yaml` `key_prefixes`/`key_prefix`), merges curated fields from
  `tickets/index_data.json`, and writes `INDEX.md` + `OBJECTS.md` (object → tickets reverse index;
  objects = enrichment ∪ a deterministic grep of each ticket's SQL). `--check` (staleness gate, covers
  both files) · `--stats` (coverage).
- **`tickets/index_data.json`** — the curated store (title/status/date/summary/tags/cross_refs/objects
  + each README's content hash). This skill writes it.

## Phase 0 — Preflight
1. Confirm `stack.yaml` has `key_prefix`/`key_prefixes` and (optionally) `ticket_url_template`.
2. `!python3 bin/build_ticket_index.py --stats` — see how many tickets are discovered, enriched,
   un-enriched (`▱`), and stale (`⚠`).

## Phase 1 — Render (always cheap, no model)
3. `!python3 bin/build_ticket_index.py` — every ticket on disk now has a row (un-enriched ones get a
   deterministic title + first-paragraph summary, marked `▱`).

## Phase 2 — Enrich (the model half)
4. Decide scope: `$ARGUMENTS` ticket id(s); `--all` for the whole backlog; or default to the
   un-enriched/stale set from `--stats`.
5. For each target ticket, read its `README.md` and write ONE record:
   `{id, owner, title, status, date, summary (<=180 chars, lead with what was delivered + key
   numbers), tags (1-4 kebab-case), cross_refs (other ticket ids), objects (qualified data objects the
   ticket read/wrote, e.g. SCHEMA.VIEW; [] if none)}`. **id/owner come from the folder, not your
   judgment.** Status vocab: Completed · Deployed · In Review · In Progress · Blocked · Unknown.
6. Collect them and upsert + re-render:
   ```bash
   echo '{"records":[ ... ]}' | python3 bin/ingest_index_records.py --from-json -
   python3 bin/build_ticket_index.py
   ```
   (Claude-Code convenience: `python3 bin/enrich_ticket.py <ID>` does steps 5–6 for one ticket via
   `claude -p`. The inline path above is agent-agnostic.)

## Phase 3 — Verify
7. `!python3 bin/build_ticket_index.py --check` must pass (INDEX.md + OBJECTS.md == fresh render).
8. Report: total tickets, status breakdown, any still un-enriched. Commit `tickets/INDEX.md` +
   `tickets/OBJECTS.md` + `tickets/index_data.json` (all three — `--check` gates the two generated files).

## Stays fresh on its own
- **SessionStart** (`ticket_index_context.py`) surfaces the catalog every session.
- **PostToolUse** (`regenerate_ticket_index.py`) re-renders `INDEX.md` whenever a ticket folder
  changes — new tickets appear instantly (as `▱`), edited READMEs flag `⚠`.
- At **ticket close**, `deliver-ticket` refreshes the closed ticket's curated summary.

So you typically only invoke this skill to **bootstrap** the index over an existing backlog, or to
re-enrich a batch. Day-to-day, the hooks keep it current.
