---
description: Prime context for one ticket — load only what this ticket needs, not the whole AI layer
argument-hint: <ticket-id> (empty = infer from current branch)
allowed-tools: [Read, Bash, Glob, Grep]
---

# /prime-ticket

Selective context loader (the **on-demand context** tier of the AI layer). Loads *just enough* to
work a ticket — the ticket itself, its folder, and the handful of related prior tickets — instead of
dumping all of `AGENTS.md` + the whole catalog into context. Run this at the start of PLAN.

## Resolve

- **Ticket id:** `$ARGUMENTS`, else the current branch (`!git branch --show-current`).
- **Config:** read `.claude/config/stack.yaml` for `project.*` and `seams.tracker.adapter`.

## Steps

1. **Fetch the ticket** via the tracker adapter's `fetch_ticket` verb (open `seams.tracker.adapter`,
   run the command for the resolved id). Capture title, description, type, status, links.
2. **Locate the ticket folder** at the rendered `project.ticket_path`. If it exists, read its
   `README.md` and list `final_deliverables/` — summarize prior progress (resume, don't restart).
3. **Find related prior tickets** via the adapter's `search` verb (text on the ticket's key nouns)
   AND locally: `!grep -rl "<key noun>" tickets/*/*/README.md 2>/dev/null | head`. Surface 2–4 most
   relevant with one line each — these are your closest analogs.
4. **Report a tight context brief** (≤ ~200 words): what the ticket asks, the likely data
   sources/objects involved, the closest prior ticket to mirror, and any open questions. Do **not**
   load schemas or the catalog here — that's `/prime-warehouse` and `/prime-domain`.

## Why
Context is king: small, scoped priming keeps the implement phase focused and cheap. This is the
loader many setups lack — they tend to load `AGENTS.md` + the whole ERD wholesale.
