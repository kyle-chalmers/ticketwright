---
name: ship
description: Finalize and deliver a reviewed ticket — backup, tracker comment, chat draft, commit + PR — with a hard halt before any external post. Run after /review approves.
argument-hint: <ticket-id> [--go]   (--go authorizes the external Phase B after review)
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
disable-model-invocation: true
---

# /ship

Ships a ticket that has **passed `/review`**. Split into a safe Phase A (local, no approval) and a
gated Phase B (every external side effect), honoring `hard_halt_before_external_posts`. Reads
`.claude/config/stack.yaml`; routes through the docstore / tracker / chat / vcs adapters, so it
works regardless of the underlying tools.

## Phase A — Finalize (no approval needed; internal to repo)
1. Read `stack.yaml` + the ticket README + the `/review` verdict. If the verdict isn't APPROVE,
   **stop** and send the user back to `/review`.
2. If the stack has a warehouse seam, re-run the final deliverable queries once more; confirm
   **byte-identical** output to the committed files (`deterministic_outputs` — explicit `ORDER BY`).
   In a repo with no warehouse seam, re-verify each deliverable by its own check instead (the
   document renders, the script runs clean, the numbers cited in the README match the files).
3. Tidy: remove redundant/version-sprawl files (overwrite, don't duplicate); confirm filenames
   carry record counts; confirm the README tells the full business + methodology + QC story. Then
   **refresh this ticket's index entry** so its `tickets/INDEX.md` row gets a curated one-line
   summary: `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" enrich_ticket.py <id>` — a shortcut that calls a
   model headlessly, resolved per runtime. If it reports no headless command available, use
   `/refresh index <id>`, which writes the record from this session and always works. The PostToolUse hook already keeps the row present; this upgrades it
   from auto-derived (`▱`) to curated.
4. **Draft the comms artifacts** (don't post yet): render the tracker comment and the chat message
   from the ticket facts. Tracker comment ≤ `word_limits.tracker_comment`; business-first;
   segmented with counts/%/$. Chat ≤ `word_limits.chat`; includes `seams.chat.always_include`;
   **hyperlink everything** (`hyperlink_everything`). If chat/docstore aren't configured, skip
   those artifacts and note `/setup chat` / `/setup docstore` as the enabler — don't block.
   Then, in order:
   - **Comms-lint the drafts first (the hard rails):** each is within its `word_limits.*` cap; ticket
     id(s), files, and PR are hyperlinked; the chat message carries `always_include` (+ `include_self`
     if configured). Fix any miss before continuing — these rails always win.
   - **Voice pass (only if `project.voice_profiles` is set).** Resolve the shipper —
     `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" resolve_user.py --json` — and if it
     returns a profile whose file exists, re-phrase the drafts to match that voice profile
     **within the rails above** (it shapes phrasing only; it never bends a word limit, a link, or the
     include-list). Empty output / no profile ⇒ leave the drafts as-is (fail open — behaves as today).
   - **Persist the initial drafts** to the ticket's `comms/` (e.g. `comms/draft-tracker.initial.md`,
     `comms/draft-chat.initial.md`). These are **immutable** — the record of what the plugin proposed,
     for the voice-refine diff in Phase C. `comms/` is gitignored (unsent wording never rides the PR).

## Phase B — External delivery (HARD HALT → requires `--go` or explicit "go ahead")
Print a summary of exactly what will happen, then **stop and wait** for the user. Only on explicit
authorization, execute in order:
5. **docstore.backup** the ticket folder (full-title dest name); then `docstore.link_for` each
   delivered file to get shareable URLs. Skip when the docstore seam isn't configured.
6. **tracker.comment** — post via the adapter's rich path (smart-link cards for the docstore
   files). Never before this point (no tracker comments without human review). Always write the
   exact posted text to `comms/draft-tracker.approved.md` — edited or not — so Phase C can diff it
   (an unedited ship just yields `initial == approved` and proposes nothing).
7. **chat.draft** to `seams.chat.default_channel` (policy `chat_default_draft` — the human clicks
   send unless they said "send it", in which case `chat.send`). Smart links for ticket id(s),
   files, PR. Write the final drafted text to `comms/draft-chat.approved.md`. Skip when the chat
   seam isn't configured.
8. **vcs.commit** — **first, isolate repo-setup / AI-layer files.** If any are dirty
   (`.claude/settings.json`, `.claude/config/stack.yaml`, `.claude/statusline.sh`, `AGENTS.md`/
   `CLAUDE.md`, `documentation/AI_LAYER_INDEX.md`, `.gitignore`) they belong to the repo's plugin
   setup, not this ticket — give them a separate `chore(plugins): …` commit on this ticket's branch
   (a distinct commit that rides the ticket's one PR — not a second PR, never folded into the ticket
   commit); `.claude/settings.local.json` +
   `.claude/worktrees/` are gitignored, leave them. Then stage this ticket's paths (deliverable files
   included: they're committed by default so results live with the ticket and show in the PR) **plus
   `tickets/INDEX.md` + `tickets/OBJECTS.md` + `tickets/index_data.json`** (all three, or `--check`
   flags drift in CI; semantic message + Co-Authored-By). **Before staging, list the
   `final_deliverables/` files that will be committed and confirm none carry PII/customer data that
   shouldn't be in git** — if any do, have the user rename them `*.private.csv` (etc.) or move them
   under a `private/` subfolder (both gitignored) first. Then **vcs.open_pr** (semantic title; body =
   Business Impact / Deliverables / Technical Notes / QC).
9. **transition** the ticket toward `project.terminal_status` if appropriate.

## Phase C — Post-ship (always, even on success)
10. **System-evolution retro** (policy `system_evolution`). Reflect briefly: did anything go wrong or
    get re-done this ticket? If so, **which layer was insufficient** — a global rule, the context
    pack, a skill, or an adapter? Propose the concrete fix to *that* artifact and note it. A repeated
    manual step is a signal to `/productize` it. Fixing the layer, not just the ticket, is what
    compounds. *(A stylistic tweak to a comms draft is **not** a layer failure — that's step 11, not
    this retro.)*
11. **Voice refine** (only if `project.voice_profiles` is set **and** a profile resolved for the
    shipper). Diff `comms/draft-<kind>.initial.md` against `comms/draft-<kind>.approved.md`. If they
    differ beyond whitespace, the edits are voice signal: **propose** a small append/edit to the
    person's `voices/<id>.md` capturing the pattern (e.g. "drops the greeting", "prefers 'net:' over
    'in summary'") and **wait for confirmation before writing** — never silent. If `initial` ==
    `approved` (no edits), or the feature is off, do nothing.
