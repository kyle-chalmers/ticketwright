---
name: deliver-ticket
description: Finalize and ship a reviewed ticket — backup, tracker comment, chat draft, commit + PR — with a hard halt before any external post and a system-evolution retro. The delivery half of VALIDATE.
argument-hint: <ticket-id> [--go]   (--go authorizes the external Phase B after review)
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
---

# /deliver-ticket

Ships a ticket that has **passed `/qc-review`**. Split into a safe Phase A (local, no approval) and a
gated Phase B (every external side effect), honoring `hard_halt_before_external_posts`. Reads
`.claude/config/stack.yaml`; routes through the docstore / tracker / chat / vcs adapters, so it works
regardless of the underlying tools.

## Phase A — Finalize (no approval needed; internal to repo)
1. Read `stack.yaml` + the ticket README + the `/qc-review` verdict. If the verdict isn't APPROVE,
   **stop** and send the user back to `/qc-review`.
2. Re-run the final deliverable queries once more; confirm **byte-identical** output to the committed
   files (deterministic_outputs — explicit `ORDER BY`).
3. Tidy: remove redundant/version-sprawl files (overwrite, don't duplicate); confirm filenames carry
   record counts; confirm the README tells the full business + methodology + QC story. Then **refresh
   this ticket's index entry** so its `tickets/INDEX.md` row gets a curated one-line summary:
   `python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/enrich_ticket.py" <id>` (or `/build-ticket-index <id>`). The PostToolUse hook already
   keeps the row present; this upgrades it from auto-derived (`▱`) to curated.
4. **Draft the comms artifacts** (don't post yet): render the tracker comment and the chat message
   from the ticket facts. Tracker comment ≤ `word_limits.tracker_comment`; business-first; segmented
   with counts/%/$. Chat ≤ `word_limits.chat`; includes `seams.chat.always_include`; **hyperlink
   everything** (`hyperlink_everything`).

## Phase B — External delivery (HARD HALT → requires `--go` or explicit "go ahead")
Print a summary of exactly what will happen, then **stop and wait** for the user. Only on explicit
authorization, execute in order:
5. **docstore.backup** the ticket folder (full-title dest name); then `docstore.link_for` each
   delivered file to get shareable URLs.
6. **tracker.comment** — post via the adapter's rich path (smart-link cards for the docstore files).
   Never before this point (saved rule: no tracker comments without human review).
7. **chat.draft** to `seams.chat.default_channel` (policy `chat_default_draft` — the human clicks
   send unless they said "send it", in which case `chat.send`). Smart links for ticket id(s),
   files, PR.
8. **vcs.commit** (stage this ticket's paths **plus `tickets/INDEX.md` + `tickets/OBJECTS.md` +
   `tickets/index_data.json`** — all three, or `--check` flags drift in CI; semantic message +
   Co-Authored-By) then
   **vcs.open_pr** (semantic title; body = Business Impact / Deliverables / Technical Notes / QC).
9. **transition** the ticket toward `project.terminal_status` if appropriate.

## Phase C — System-evolution retro (always, even on success)
10. Reflect briefly: did anything go wrong or get re-done this ticket? If so, **which AI-layer tier
    was insufficient** — a global rule, on-demand context (`/prime-*`/context pack), a command/skill,
    or an adapter? Propose the concrete fix to *that* artifact (policy `system_evolution`) and note
    it. A repeated manual step is a signal to `/productize-workflow` it. Fixing the layer, not just
    the ticket, is what compounds.

## Generalizes
A close-out flow (backup → tracker comment → chat draft → PR) + a standard closing procedure, with all
tool specifics in adapters and the retro added from the agentic-engineering "system evolution" rule.
