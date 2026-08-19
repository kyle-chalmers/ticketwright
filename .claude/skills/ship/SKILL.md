---
name: ship
description: Finalize and deliver a reviewed ticket — backup, tracker comment, chat draft, commit + PR — with a hard halt before any external post. Run after /review approves.
argument-hint: <ticket-id | owner/id> [--go]   (--go authorizes the external Phase B after review)
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
disable-model-invocation: true
---

# /ship

Ships a ticket that has **passed `/review`**. Split into a safe Phase A (local, no approval) and a
gated Phase B (every external side effect), honoring `hard_halt_before_external_posts`. Reads
the **merged** config (`bin/effective_config.py`, never raw `stack.yaml` — a raw read misses every
personal and machine override); routes through the docstore / tracker / chat / vcs adapters, so it
works regardless of the underlying tools.

## Phase A — Finalize (no approval needed; internal to repo)
1. **Resolve WHO first** — `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" whoami.py`
   and show its one-line "Working as …" display; the resolved person is the shipper. Then resolve
   the **ticket locator**: `owner/id` is exact; a bare `<id>` resolves against the shipper's
   `tickets/<owner>/` first, then across other owners — **two or more foreign owners sharing it is a
   hard stop listing the `owner/id` choices, never a pick**. Shipping a ticket whose owner isn't the
   shipper is allowed — say so out loud before continuing.
   Then read the merged config (`bin/effective_config.py --json`) + the ticket README + the `/review` verdict. If the verdict isn't APPROVE,
   **stop** and send the user back to `/review`.
2. If the stack has a warehouse seam, re-run the final deliverable queries once more; confirm
   **byte-identical** output to the committed files (`deterministic_outputs` — explicit `ORDER BY`).
   In a repo with no warehouse seam, re-verify each deliverable by its own check instead (the
   document renders, the script runs clean, the numbers cited in the README match the files).
3. Tidy: remove redundant/version-sprawl files (overwrite, don't duplicate); confirm filenames
   carry record counts; confirm the README tells the full business + methodology + QC story. Then
   **refresh this ticket's index entry** so its `tickets/INDEX.md` row gets a curated one-line
   summary: use **`/refresh index <owner>/<id>`** (the qualified locator — a bare id two owners
   share is a hard stop there), which writes the record from this session. You have already
   read this ticket — no second model call is needed, and this path works under every runtime.
   The PostToolUse hook already keeps the row present; this upgrades it from auto-derived (`▱`) to
   curated.

   *Not in this flow:* `enrich_ticket.py` does the same job by handing the ticket README to a
   **headless model**. That README is usually tracker-sourced — text someone outside the repo wrote —
   and `/ship` is the flow that then posts externally, so a shipping run should not put attacker-
   influenceable text in front of a fresh agent before its own approval gate. Run it deliberately via
   `/refresh index` when you want it, on a runtime whose adapter declares a restricted
   `model_sandbox`.
4. **Draft the comms artifacts** (don't post yet): render the tracker comment and the chat message
   from the ticket facts. Tracker comment ≤ `word_limits.tracker_comment`; business-first;
   segmented with counts/%/$. Chat ≤ `word_limits.chat`; includes `seams.chat.always_include`;
   **hyperlink everything** (`hyperlink_everything`). If chat/docstore aren't configured, skip
   those artifacts and note `/setup tool chat` / `/setup tool docstore` as the enabler — don't block.
   Then, in order:
   - **Comms-lint the drafts first (the hard rails):** each is within its `word_limits.*` cap; ticket
     id(s), files, and PR are hyperlinked; the chat message carries `always_include` (+ `include_self`
     if configured). Fix any miss before continuing — these rails always win.
   - **Voice pass (only if a voice profile RESOLVES).** Resolve the shipper —
     `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" resolve_user.py --json` — and if it
     returns a profile whose file exists, re-phrase the drafts to match that voice profile.
     Gate on the RESOLUTION, never on where the config lives: the map moved to `people/<id>.yaml`
     (tier 2), so a condition naming `project.voice_profiles` is permanently false in a migrated
     repo and would silently switch this whole step off
     **within the rails above** (it shapes phrasing only; it never bends a word limit, a link, or the
     include-list). Empty output / no profile ⇒ leave the drafts as-is (fail open — behaves as today).
   - **Persist the initial drafts** to the ticket's `comms/` (e.g. `comms/draft-tracker.initial.md`,
     `comms/draft-chat.initial.md`). These are **immutable** — the record of what the plugin proposed,
     for the voice-refine diff in Phase C. `comms/` is gitignored (unsent wording never rides the PR).

## Phase B — External delivery (HARD HALT → requires `--go` or explicit "go ahead")
Print the **resolved delivery plan**, then **stop and wait** for the user — the human authorizes
THE PLAN, not the word "ship". A docstore link is a shareable URL, so a wrong destination is a
disclosure, not an inconvenience. Resolve each posting seam with
`bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" effective_config.py --seam <name>`
and render one line per seam from the RESOLVED values, never from memory of the config. Every line
names its resolved **target** — today that renders as `target: single` (the resolution's null
target on a single mapping), and stating it is the point: the plan the human authorizes is
target-aware even while every seam has one tool. The plan must show exactly what steps 5–9 will
execute — nothing the steps don't do may appear in it:
   - **docstore** — tool, target, the exact destination it will back up into, and the sharing
     scope the delivery plan declares ("sharing scope: not declared — single destination" is the
     honest line until one exists; see `adapters/README.md` § The delivery plan);
   - **tracker** — tool, target, the exact ticket (`owner/id`) the comment lands on;
   - **chat** — tool, target, channel, the FULL recipient list (`always_include` + the shipper
     when `include_self`), and draft-vs-send mode;
   - **vcs** — tool, target, the branch, and that a PR opens;
   - then the exact actions, in order (the numbered steps below).
   Resolver exit 7 (seam not configured) = skip that line and name the `/setup tool <name>` enabler,
   as today. Exit 8, or a resolution whose `target` is non-null (a `targets:` block on one of these
   seams) = **halt** naming the configured targets: this flow cannot route between named targets
   yet, and rendering a target the steps below would not deliver to is an authorization mismatch —
   never fall back to another target or to seam-level values. With today's single-target seams the
   plan resolves trivially; render it anyway — the delivery-plan release inherits this rendering.
   Only on explicit authorization, execute in order:
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
11. **Voice refine** (only if a voice profile resolved for the shipper). Diff `comms/draft-<kind>.initial.md` against `comms/draft-<kind>.approved.md`. If they
    differ beyond whitespace, the edits are voice signal: **propose** a small append/edit to the
    person's `voices/<id>.md` capturing the pattern (e.g. "drops the greeting", "prefers 'net:' over
    'in summary'") and **wait for confirmation before writing** — never silent. If `initial` ==
    `approved` (no edits), or the feature is off, do nothing.
