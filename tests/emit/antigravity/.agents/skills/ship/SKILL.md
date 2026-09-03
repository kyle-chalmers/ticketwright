---
name: ship
description: Finalize and deliver a reviewed ticket — backup, tracker comment, chat draft, commit + PR — with a hard halt before any external post. Run after /review approves.
---

<!-- emitted by ticketwright install v4.0.3 — do not hand-edit; re-run `ticketwright install --runtime antigravity` to update. -->

# /ship

Ships a ticket that has **passed `/review`**. Split into a safe Phase A (local, no approval) and a
gated Phase B (every external side effect), honoring `hard_halt_before_external_posts`. Reads
the **merged** config (`bin/effective_config.py`, never raw `stack.yaml` — a raw read misses every
personal and machine override); routes through the docstore / tracker / chat / vcs adapters, so it
works regardless of the underlying tools.

> **THE MODEL-INVOCATION CONFIRM GATE — `/ship` is model-invocable.** When the model reaches for
> `/ship` on its own initiative (the user did not explicitly invoke it), it must **stop and confirm
> before Phase A's first durable action.** Phase A finalizes *in the repo* — it tidies and overwrites
> deliverable files and refreshes the committed ticket-index entry — so a model-initiated run must not
> mutate the ticket before the human has said to ship it. Print the ticket and what Phase A will do,
> then wait. An explicit user invocation authorizes Phase A as normal. This gate is separate from — and
> earlier than — the Phase B external-post HARD HALT below, which always applies regardless of who
> invoked the skill; it is an instruction the agent follows, not a mechanical block.

## Phase A — Finalize (no separate approval when the user invoked `/ship`; internal to repo)
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
4. **Route the delivery FIRST, then draft the comms artifacts** (don't post yet).

   **(a) Resolve routing before writing a word.** Who the message is for decides which recipient
   list it carries, so it cannot be settled after drafting:
   `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam chat`
   (add `--override <name>` when the user passed `--chat <target>` — that flag is **chat only**, and
   the CLI says so on the plan line when it contradicts the ticket; add `--self "<shipper>"` so an
   `include_self` target adds them). Same call with `--seam docstore`. Exit **7** = that slot isn't
   configured → skip its artifact and name `/setup tool chat` / `/setup tool docstore` as the
   enabler, exactly as before. Exit **0** → use the returned `target`, `destination`, `recipients`,
   `mode` and `sharing_scope` verbatim; they are the plan Phase B prints and executes.
   **Any other exit is a HALT, and you resolve it by ASKING, never by choosing:**
   - **9 (nothing declared)** — the plan declares nothing this slot can route on. Two shapes, and the
     CLI's message names which:
     - *A `targets:` slot* has no `audience:`/`classification:`. Show the configured values the CLI
       lists and ask the user which one this ticket is.
     - *A tool-only chat seam* (the default shape — the stack names the tool, not a standing channel)
       has no `chat.channel:`/`chat.recipients:`. Ask the user, in prose, **where this goes and who
       it is for**: the destination (channel / DM / address) and the recipient list. This is the
       per-communication decision the tool-only shape exists for — who a result goes to depends on
       who the analysis is for, so it is asked each ship, never configured once.
     Either way, write the answer into `<ticket-dir>/delivery-plan.yaml` (schema: `adapters/README.md`
     § The delivery plan) — the `audience:` for a targets slot, or the `chat:` block
     (`channel:` + a non-empty `recipients:`) for a tool-only seam — then re-run. **Never infer** the
     audience, the channel, OR the recipients from the ticket README, channel names, a label, or how
     the work "feels" — an inferred destination is exactly how a result reaches the wrong room.
     "I could not tell, so I picked the first one" is not available.
   - **8 (declared value matches nothing)** — a typo or a retired target. Show the declared value
     and the configured ones; ask which was meant. Never match it approximately.
   - **3 (no plan file)** — same as 9: ask, write the file, re-run.
   The declaration is a ticket artifact, not a session choice: it is committed with the ticket, so
   the next person (or agent) can see who this went to and why.

   **(b) Draft against the routed plan.** Render the tracker comment and the chat message from the
   ticket facts. Tracker comment ≤ `word_limits.tracker_comment`; business-first; segmented with
   counts/%/$. Chat ≤ `word_limits.chat`; carries **the routed target's own `recipients`** — never
   another target's list, and never a slot-level one; **hyperlink everything**
   (`hyperlink_everything`). Then, in order:
   - **Comms-lint the drafts first (the hard rails):** each is within its `word_limits.*` cap; ticket
     id(s), files, and PR are hyperlinked; the chat message carries every routed recipient. That last
     rail is mechanical, so run it rather than eyeballing it:
     `… delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam chat [--override <name>] --check-draft <the draft file>`
     — non-zero names each recipient the draft fails to carry. Fix any miss before continuing; these
     rails always win.
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
and render one line per seam from the RESOLVED values, never from memory of the config. For **chat
and docstore, print the routing resolved in step 4(a)** — the same JSON, unedited, that steps 5 and
7 execute from. Preview and execution are one resolution, not two readings of it; re-deriving either
half by hand is how they drift apart. Every line names its resolved **target** (`target: single` on
a single mapping — stating it is the point). The plan must show exactly what steps 5–9 will
execute — nothing the steps don't do may appear in it:
   - **docstore** — tool, target, the declared `classification` that selected it, the exact
     destination it will back up into, and the target's declared `sharing_scope`. Say plainly that
     the scope is **declared, not verified**: the kit checks that the destination exists, never its
     real sharing permissions (`adapters/README.md` § The delivery plan). On a single mapping the
     honest line stays "sharing scope: not declared — single destination";
   - **tracker** — tool, target, the exact ticket (`owner/id`) the comment lands on;
   - **chat** — tool, target, the declared `audience` that selected it, channel, the full
     recipient list (the routed target's own `recipients`, including the shipper when
     `include_self`), the `sender` when the routed JSON carries one (an email target's sending
     identity — WHO the message goes out as is part of what the human authorizes), and
     draft-vs-send mode. When the target came from `--chat <target>` rather than the ticket's
     declaration, say so on the line — the CLI returns that as a warning, and an override that the
     ticket does not record is a fact the approver should see;
   - **vcs** — tool, target, the branch, and that a PR opens;
   - then the exact actions, in order (the numbered steps below).
   Resolver exit 7 (seam not configured) = skip that line and name the `/setup tool <name>` enabler,
   as today. For **tracker and vcs**, exit 8 or a resolution whose `target` is non-null (a `targets:`
   block on either) = **halt** naming the configured targets: target routing for those two slots is
   deliberately not built (identity and remote-binding work, see `adapters/README.md`), and
   rendering a target the steps below would not deliver to is an authorization mismatch — never fall
   back to another target or to slot-level values.
   **Pin the plan the human just authorized.** Each routed line carries the target name AND its
   `resolution_fingerprint` (print both). Pass both back on **every** delivery_plan call in steps
   5–7: `--expect-target <name> --expect-fingerprint <hex>`, with the same `--self` you routed
   with. The name catches a swapped target; the fingerprint catches what a name check cannot — a
   config or plan edit between approval and delivery that keeps the name while moving the channel,
   the recipient list, or the declared scope. Either mismatch refuses instead of quietly delivering
   a resolution nobody approved — that is what makes preview-equals-execution a mechanism rather
   than a promise. It pins the *resolution*; the file contents shipped are whatever is in the
   folder at delivery time, as always.
   Only on explicit authorization, execute in order:
5. **Scan the source material first, then docstore.backup.** The backup copies the WHOLE ticket
   folder, so run
   `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" scan_source_materials.py --ticket <ticket-dir>`
   and **halt on a non-zero exit** — a raw meeting transcript is about to be copied out of the
   repo. The remedy here is NOT the `private/` folder: `.gitignore` has no bearing on the
   adapter's `cp -r`, so `private/` protects git and nothing else. Remove the file from the folder,
   or have the human approve the copy explicitly. (The `source_material_guard` hook asks about the
   same command; this call is what makes the halt visible on runtimes whose hooks are not wired.
   Neither reads MEANING — a curated summary quoting confidential material passes both.) Then
   **docstore.backup** the ticket folder (full-title dest name) **into the routed target's
   destination from step 4(a)** — never another target's, and never a slot-level path. Then record
   each delivered file against the target it actually went to:
   `… delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam docstore --record-delivered <path relative to the ticket> --url <shareable URL> --expect-target <approved> --expect-fingerprint <approved>`
   and call `docstore.link_for` **against that same recorded target**. The recorded row is what
   makes a link provably come from the store the copy went into, rather than from whichever store
   was resolved a step later. Skip when the docstore seam isn't configured.
   **Routing is per deliverable here.** If the plan's `deliverables:` gives a file its own
   `classification:` (a client-facing summary among internal working files), that file routes to
   *its* target: resolve it with `--file <path>` and back that file up separately, rather than
   assuming the whole folder shares one destination. Its `--expect-target`/`--expect-fingerprint`
   are the ones the plan line showed for that classification. Anything the approved plan did not
   show, you do not deliver. **The plan-level classification is folder-wide** — the backup carries
   `qc_queries/` and everything else not split out by a row, so an external plan-level
   classification must be a deliberate statement about the whole folder, and the approval line
   should be read that way.
6. **tracker.comment** — post via the adapter's rich path (smart-link cards for the docstore
   files). Never before this point (no tracker comments without human review). Always write the
   exact posted text to `comms/draft-tracker.approved.md` — edited or not — so Phase C can diff it
   (an unedited ship just yields `initial == approved` and proposes nothing).
7. **chat.draft** to **the routed target's destination from step 4(a)** — its channel, its
   recipients, its adapter (policy `chat_default_draft` — the human clicks send unless they said
   "send it", in which case `chat.send`). Re-run `--check-draft` on the final text first: it is the
   last mechanical point at which a message can be caught carrying the wrong audience's list, and it
   costs one command. A routing failure here is a **stop**, never a send to another target. Smart
   links for ticket id(s), files, PR. Write the final drafted text to `comms/draft-chat.approved.md`.
   Skip when the chat seam isn't configured.
8. **vcs.commit** — **first, isolate repo-setup / AI-layer files.** If any are dirty
   (`.claude/settings.json`, `.claude/config/stack.yaml`, `.claude/statusline.sh`, `AGENTS.md`/
   `CLAUDE.md`, `documentation/AI_LAYER_INDEX.md`, `.gitignore`) they belong to the repo's plugin
   setup, not this ticket — give them a separate `chore(plugins): …` commit on this ticket's branch
   (a distinct commit that rides the ticket's one PR — not a second PR, never folded into the ticket
   commit); `.claude/settings.local.json` +
   `.claude/worktrees/` are gitignored, leave them. Then stage this ticket's paths (deliverable files
   included: they're committed by default so results live with the ticket and show in the PR) **plus
   the whole index — `tickets/INDEX.md` + `tickets/OBJECTS.md` + `tickets/index_data.json`, and
   `tickets/graph/` + `tickets/objects/` when `project.graph_notes` is on (the default)** (`--check`
   gates the *rendered* ones — the two catalog files and the graph nodes, not the curated store — so
   a rendered path left out is drift in CI; semantic message + Co-Authored-By). The render is
   repo-wide, so review the index diff before committing: a row or node that moved for **another**
   ticket is the renderer catching up, and belongs in the commit message rather than bundled in
   silently. **Before staging, list the
   `final_deliverables/` files that will be committed and confirm none carry PII/customer data that
   shouldn't be in git** — if any do, have the user rename them `*.private.csv` (etc.) or move them
   under a `private/` subfolder (both gitignored) first. **Then run the same source-material scan
   as step 5** (`scan_source_materials.py --ticket <ticket-dir>`) and halt on a non-zero exit:
   `source_materials/` is committed too, and a raw transcript whose filename gives nothing away
   (`notes.md`) is matched by no gitignore pattern. Here `private/` IS a valid remedy, alongside
   trimming the file to the curated `YYYY-MM-DD-<slug>-meeting.md` form. Then **vcs.open_pr** (semantic title; body =
   Business Impact / Deliverables / Technical Notes / QC).
9. **transition** the ticket toward `project.terminal_status` if appropriate.

## Phase C — Post-ship (always, even on success)
10. **System-evolution retro** (policy `system_evolution`). Reflect briefly: did anything go wrong or
    get re-done this ticket? If so, **which layer was insufficient** — a global rule, the context
    pack, a skill, or an adapter? Propose the concrete fix to *that* artifact and note it. A repeated
    manual step is a signal to `/skillify` it. Fixing the layer, not just the ticket, is what
    compounds. *(A stylistic tweak to a comms draft is **not** a layer failure — that's step 11, not
    this retro.)*
11. **Voice refine** (only if a voice profile resolved for the shipper). Diff `comms/draft-<kind>.initial.md` against `comms/draft-<kind>.approved.md`. If they
    differ beyond whitespace, the edits are voice signal: **propose** a small append/edit to the
    person's `voices/<id>.md` capturing the pattern (e.g. "drops the greeting", "prefers 'net:' over
    'in summary'") and **wait for confirmation before writing** — never silent. If `initial` ==
    `approved` (no edits), or the feature is off, do nothing.
