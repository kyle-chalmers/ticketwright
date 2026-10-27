---
name: ship
description: Finalize and deliver a reviewed ticket — commit + PR, merge (after asking), backup, tracker comment, chat draft — with a hard halt before any external post. Run after /review approves.
---

<!-- emitted by ticketwright install v4.6.0 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

# /ship

Ships a ticket that has **passed `/review`** — and warns, waits, and records it when one has not. Split
into a safe Phase A (local, no approval) and a
gated Phase B (every external side effect), honoring `hard_halt_before_external_posts`. Reads
the **merged** config (`bin/effective_config.py`, never raw `stack.yaml` — a raw read misses every
personal and machine override); routes through the docstore / tracker / chat / vcs adapters, so it
works regardless of the underlying tools.

> **THE MODEL-INVOCATION CONFIRM GATE — `/ship` is model-invocable.** When the model reaches for
> `/ship` on its own initiative (the user did not explicitly invoke it), it must **stop and confirm
> before Phase A's first durable action.** Phase A finalizes *in the repo* — it tidies and overwrites
> deliverable files and refreshes the committed ticket-index entry — so a model-initiated run must not
> mutate the ticket before the human has said to ship it. Print the ticket and what Phase A will do,
> then ask it as one question, "Ship it" or "Not now", and wait. An explicit user invocation
> authorizes Phase A as normal, and so does a `ship` reply (or "Approve and ship") to `/review`'s
> sign-off question for this ticket, given as the answer to that question: the person asked for the
> ship. This gate is separate from — and
> earlier than — the Phase B external-post HARD HALT below, which always applies regardless of who
> invoked the skill; it is an instruction the agent follows, not a mechanical block.

## How this skill asks the person something
<!-- ticketwright:ask-rule:begin -->
The kit's one question rule, the same in every skill that asks:
- Read `capabilities` from this skill's `kit_paths.py --json` probe the first time a question
  comes up, and keep the result.
- `capabilities.structured_questions` is `yes` and `capabilities.question_tool` is not `none` →
  **ask with that tool**, within `capabilities.question_limits` (when that says `unknown`: one
  question per call, at most four options). Group up to the limit only questions that do not
  depend on each other's answers; ask a dependent question after the one it depends on.
- Otherwise (`no` / `unknown`, or the probe failed) → ask in chat as a short numbered list, one
  question at a time unless this skill says a set goes in one round, and wait for an explicit
  answer.
- The question content is the same either way; only how it is shown changes. No skill names a
  runtime's tool: the runtime's own adapter (`adapters/runtime/<name>.md`) does. A question tool
  is not available inside a subagent, so the main session asks.
- **Never invent an option.** Options come from what this run found or the fixed choices a step
  names. A recommended option goes first, marked recommended, with where it came from; the person
  still picks. Each option says what choosing it changes, and free text is always possible (the
  tool's own "Other", or "or tell me something else" in prose).
- Whatever the person needs to answer is already in chat before the question, so a picker never
  hides it.
- A reply the kit asks for word for word (`ship unreviewed`, `go ahead`, the `yes` before
  destructive SQL) stays typed: an unreviewed ship, an external send or an irreversible write is
  never one click.
<!-- ticketwright:ask-rule:end -->

In this skill the questions are the confirm gate above, step 1's owner choice and pending sign-off
(asked through `/review` step ⑤.4), step 4(a)'s routing questions, step 6's merge question, and step 12's voice-profile proposal. Its
probe is `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" kit_paths.py --json`,
run the first time one of them comes up. `ship unreviewed` (step 1) and `go ahead` (Phase B) stay
typed.

## Phase A — Finalize (no separate approval when the user invoked `/ship`; internal to repo)
1. **Resolve WHO first** — `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" whoami.py`
   and show its one-line "Working as …" display; the resolved person is the shipper. Then resolve
   the **ticket locator**: `owner/id` is exact; a bare `<id>` resolves against the shipper's
   `tickets/<owner>/` first, then across other owners — **two or more foreign owners sharing it is a
   hard stop that asks which one, with the `owner/id` choices as the options, never a pick**. Shipping a ticket whose owner isn't the
   shipper is allowed — say so out loud before continuing.
   Then read the merged config (`bin/effective_config.py --json`) + the ticket README + the plan +
   **the current verdict, read mechanically:**
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" review_verdict.py --ticket <ticket-dir> --json`
   — it picks the `qc_queries/*_review_verdict.md` with the highest `<n>` (compared numerically:
   `10_` beats `9_`; never a lexical sort or an mtime), reads its lowercase `verdict:` line, and
   returns `status`: `approve` · `request-changes` · `awaiting-signoff` · `skipped` · `none` ·
   `unreadable`, plus any
   `legacy_candidates`. Branch on that `status`, never on your own reading of the folder. A review
   report saved under another name by an earlier kit version still counts: read it,
   and if it states APPROVE or REQUEST-CHANGES plainly, re-save it under the fixed name with the
   `verdict:` line first, then branch on it — never treat reviewed work as unreviewed. Five cases:
   - **APPROVE** → proceed.
   - **REQUEST-CHANGES** → **hard stop.** The review ran and found a defect (count mismatch, duplicate
     gap, reconciliation break, a Critical anti-pattern). Send the user back to `/build <owner>/<id>`,
     which applies the remediation (or replans, when a finding is `kind: scope`) and re-reviews.
     Not overridable here.
   - **AWAITING-SIGNOFF** → the independent review approved, and the person's sign-off is the only
     thing outstanding. **It is not approval:** never continue on it, never offer `ship unreviewed`,
     and never write a `SKIPPED` record over it (that would bury the reviewer's approval). This
     skill does not write the sign-off itself; `/review` step ⑤.4 does, the same way `/build` uses
     it:
     - When `/review`'s hand-off for this ticket, with its "Reply `ship`" line, is earlier in **this
       same conversation** and the person's next message is `ship` or `/ship` for this ticket, that
       message is the `ship` reply to ⑤.4. Do not ask again: apply ⑤.4's `ship` branch, which
       rewrites the record.
     - Otherwise (a new session, another person, or a different reply in between), follow
       `/review <owner>/<id>`'s steps ⑤.1 to ⑤.4 for this ticket: open the files, print the
       what-to-look-at list, then ask the sign-off with ⑤.4's own "Reply `ship`" line and options.
       ⑤.4 answers a question and asks again, asks what to change before recording a change
       request, and rewrites the record on an answer.
     - **A sign-off taken in this run, either way, cancels `--go` for this run.** Phase B still
       prints the delivery plan and waits for a typed `go ahead`, because the sign-off line told
       the person it would. `--go` never answers the sign-off question itself.
     Then re-read the verdict with `review_verdict.py --json` and branch again: `approve` after a
     `ship` reply → continue to step 2 (in this run, ⑤.4's "route as Phase N says" means carrying on
     here, not starting a second `/ship`); `approve` without one ("Approve, don't ship yet") → stop
     and name `/ship <owner>/<id>` for later; `request-changes` → send the person to
     `/build <owner>/<id>`. **Anything else, including `awaiting-signoff` still on file, stops
     here and shows the record: never continue.**
   - **No verdict file at all, or the newest one says `SKIPPED`** → **WARN, then stop and wait.** A
     SKIPPED record never counts as approval; this gate re-fires on every ship until a real review
     supersedes it. Print, verbatim in shape:
     <!-- ticketwright:user-facing:begin -->
     > Nobody has independently reviewed `<owner>/<id>` yet (last review: none | shipped
     > unreviewed on <date>). That means the lint, counts, duplicates, reconciliation, independent
     > re-run and your sign-off have not happened for these deliverables. Reply **`ship unreviewed`**
     > to deliver them anyway, or run `/review <owner>/<id>` first.
     <!-- ticketwright:user-facing:end -->
     Only on that exact phrase: write `qc_queries/<n>_review_verdict.md` with `verdict: SKIPPED`,
     `review_mode: none`, the date, the shipper (from whoami), and the user's instruction verbatim —
     the record shows what review this ticket actually got, the same honesty rule `/review` applies
     to an inline pass. Carry it forward: the PR body's QC section and the curated index summary
     (step 3) say **"shipped without an independent review"**, and the tracker comment claims no QC
     that did not happen. `--go` authorizes Phase B only — it never pre-answers this gate — and a
     model-initiated ship meets the confirm gate above first, then this one.
   - **Anything else** — a `verdict:` value that is none of the four above, a file with no
     `verdict:` line, a truncated report — is **the missing case above, never a pass.** The gate fails closed: an
     unreadable verdict is not a verdict.
   Why this is a gate and not a wall: a hard stop here was routed around (work shipped through other
   commands, leaving no record). `/build` runs the review itself, and the `review_verdict_guard` hook
   asks the same question at `git push` / PR time — so a ship that never enters this skill still
   meets the gate, and every path leaves a record.
2. If the stack has a warehouse seam, re-run the final deliverable queries once more; confirm
   **byte-identical** output to the committed files (`deterministic_outputs` — explicit `ORDER BY`).
   In a repo with no warehouse seam, re-verify each deliverable by its own check instead (the
   document renders, the script runs clean, the numbers cited in the README match the files).
3. Tidy: remove redundant/version-sprawl files (overwrite, don't duplicate); confirm filenames
   carry record counts; confirm the README tells the full business + methodology + QC story. Then
   **refresh this ticket's index entry** so its `tickets/INDEX.md` row gets a curated one-line
   summary: use **`/refresh index <owner>/<id>`** (the qualified locator — a bare id two owners
   share is a hard stop there), which writes the record from this session — and when the verdict on file is `SKIPPED`, the
   curated summary says so ("shipped without an independent review"). You have already
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
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam chat`
   (add `--override <name>` when the user passed `--chat <target>` — that flag is **chat only**, and
   the CLI says so on the plan line when it contradicts the ticket; add `--self "<shipper>"` so an
   `include_self` target adds them). Same call with `--seam docstore`. Exit **7** = that slot isn't
   configured → skip its artifact and name `/setup tool chat` / `/setup tool docstore` as the
   enabler, exactly as before. Exit **0** → use the returned `target`, `destination`, `recipients`,
   `mode` and `sharing_scope` verbatim; they are the plan Phase B prints and executes. A chat exit
   **0** carrying `skipped: declared` is the ticket's own `chat: none`: there is no chat message,
   so draft none, print the plan's Chat line as "none, declared on the ticket" (with the returned
   `skip_reason` when there is one), and leave out the chat step. It is a decision already made, so
   nothing is asked.
   **Any other exit is a HALT, and you resolve it by ASKING, never by choosing:**
   - **9 (nothing declared)** — the plan declares nothing this slot can route on. Three shapes, and the
     CLI's message names which:
     - *A `targets:` slot* has no `audience:`/`classification:`. Ask the user which one this ticket
       is, with the configured values the CLI lists as the options.
     - *A tool-only chat seam* (the default shape — the stack names the tool, not a standing channel)
       has no `chat.channel:`/`chat.recipients:`. Ask the user, by the question rule above, **where
       this goes and who it is for**: the destination (channel / DM / group DM / address) and the
       recipient list. Offer as options only the audience suggestions below, with free text always
       open, and ask for the recipients as a multi-select when the question tool allows one. This
       is the
       per-communication decision the tool-only shape exists for — who a result goes to depends on
       who the analysis is for, so it is asked each ship, never configured once.
       **Offer suggestions as options, never as answers** (see *Audience suggestions* below).
     - *A per-ticket chat target* (the declared audience selected a target marked
       `destination: per_ticket`, which the CLI's message names) has no `chat.channel:`/
       `chat.recipients:`. Ask the same question as for a tool-only seam, for that target's tool:
       **where this goes and who it is for**. If the person picks an audience whose target is
       per-ticket, ask for its destination and recipients in the same turn rather than re-running
       twice.
     **"No chat message" is always one of the answers**, beside the destinations. When the person
     picks it, write `chat: none` into the plan (or `chat:` with `none: true` and their `reason:`
     when they gave one), never a comment: a comment is read by no tool, so the next run would ask
     again and the record would not show the decision.
     In each case, write the answer into `<ticket-dir>/delivery-plan.yaml` (schema: `adapters/README.md`
     § The delivery plan) — the `audience:` for a targets slot, the `chat:` block
     (`channel:`, `kind:` and `recipients:`, which may be empty only for `kind: channel`) for a
     tool-only seam, or both plus `chat.target:` naming the routed target for a per-ticket target —
     then re-run. **Never infer** the
     audience, the channel, OR the recipients from the ticket README, channel names, a label, or how
     the work "feels" — an inferred destination is exactly how a result reaches the wrong room.
     "I could not tell, so I picked the first one" is not available.
     **Audience suggestions.** The question may offer choices drawn from exactly two places, and
     nowhere else: the `suggested_channels` the routing output returns, and the people in the
     tracker's own structured fields for this ticket (`reporter`, `assignee`, `watchers` from
     `tracker.fetch_ticket`). Resolve each person through the chat adapter's `lookup_user` verb
     (or to an address for email) and label every option with where it came from: "Reported this
     ticket: Sam (DM)", "Assigned: Jo (DM)", "A channel you post to: #analytics". Rules:
     nothing is preselected, a suggestion is sent nowhere until the person picks it, an option that
     could not be resolved is left out rather than guessed, and "Someone else" (typed) is always
     there. Write the pick with `kind:` (`channel` from `lookup_channel`, `dm` or `group` from
     `lookup_user`) and `chosen_from:` (`suggested_channels`, `tracker:reporter`,
     `tracker:assignee`, `tracker:watcher` or `typed`); a suggestion they did not pick is dropped.
     For the same reason, no audience, destination or recipient option is ever marked
     recommended: the question rule's recommended-first option does not apply to routing, because
     nothing in a run can know who a result is for.
   - **8 (declared value matches nothing)** — a typo or a retired target. Show the declared value,
     then ask which was meant, with the configured values as the options. Never match it
     approximately.
   - **3 (no plan file)** — same as 9: ask, write the file, re-run.
   The declaration is a ticket artifact, not a session choice: it is committed with the ticket, so
   the next person (or agent) can see who this went to and why.

   **(b) Draft against the routed plan.** Render the tracker comment and the chat message from the
   ticket facts. Tracker comment ≤ `word_limits.tracker_comment`; business-first; segmented with
   counts/%/$. Chat ≤ `word_limits.chat`; carries **the routed target's own `recipients`** — never
   another target's list, and never a slot-level one; **hyperlink everything**
   (`hyperlink_everything`). The PR link and the backed-up file links do not exist yet: step 5
   creates the first and step 7 the others. Write each as a named placeholder (`<link: PR>`,
   `<link: final_deliverables/…>`) and fill it from what those steps return, before the comment
   (step 8) and the chat message (step 9) go out. Never guess a URL. Then, in order:
   - **Comms-lint the drafts first (the hard rails):** each is within its `word_limits.*` cap; ticket
     id(s) are hyperlinked and every file and the PR has its placeholder; the chat message carries every routed recipient. That last
     rail is mechanical, so run it rather than eyeballing it:
     `… delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam chat [--override <name>] --check-draft <the draft file>`
     — non-zero names each recipient the draft fails to carry. Fix any miss before continuing; these
     rails always win.
   - **Voice pass (only if a voice profile RESOLVES).** Resolve the shipper —
     `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" resolve_user.py --json` — and if it
     returns a profile whose file exists, re-phrase the drafts to match that voice profile.
     Gate on the RESOLUTION, never on where the config lives: the map moved to `people/<id>.yaml`
     (tier 2), so a condition naming `project.voice_profiles` is permanently false in a migrated
     repo and would silently switch this whole step off
     **within the rails above** (it shapes phrasing only; it never bends a word limit, a link, or the
     include-list). Empty output / no profile ⇒ leave the drafts as-is (fail open — behaves as today).
   - **Persist the initial drafts** to the ticket's `comms/` (e.g. `comms/draft-tracker.initial.md`,
     `comms/draft-chat.initial.md`). These are **immutable** — the record of what the plugin proposed,
     for the voice-refine diff in Phase C. `comms/` is gitignored (unsent wording never rides the PR).

   **(c) Read where the ticket can move, before the plan names a status.** A status typed from
   memory fails at the very last step when the workflow does not have it (`No allowed transitions
   found for given status`, on a board with no `In Review`). So ask the tracker: run
   **`tracker.list_transitions`** for the ticket, save what it returns, and pick the target with
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" transition_plan.py --transitions <that file> --id <id>`
   (it reads `project.terminal_status` from the merged config). Exit **0** → its `target` is the
   status the plan names and step 10 moves to, through its `via`; `already_there` means step 10 has
   nothing to do. Exit **8** → no single move reaches the configured status: ask the person which
   status this ticket should end in, offering the `available` moves it lists (the `suggestion`
   first when there is one, labelled as the one the tracker files under done), and use their pick
   for this run. If they say it is the workflow's real final status, offer to set
   `project.terminal_status` to it, as a separate change. An exit 8 whose `result` is `ambiguous`
   means two moves reach that status: ask which one, offering each of its `options` by `name`, and
   re-run with `--via <the picked option's via>`. Exit **7** → the moves could not be read (an
   `unavailable` or `unsupported` reply), and exit **4** → the reply could not be parsed: in both,
   the plan names the configured status and says it was not checked against the tracker, so nobody
   reads it as checked. Skip this when the stack has no
   tracker tool slot, or when the merge setting is off (step 10 then moves nothing).

## Phase B — External delivery (HARD HALT → requires `--go` or explicit "go ahead")
Print the **resolved delivery plan**, then **stop and wait** for the user — the human authorizes
THE PLAN, not the word "ship". `--go` does not count in a run where step 1 took the person's
review sign-off: then only a typed `go ahead` does. A docstore link is a shareable URL, so a wrong destination is a
disclosure, not an inconvenience. Resolve each posting seam with
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" effective_config.py --seam <name>`
and render one line per seam from the RESOLVED values, never from memory of the config. For **chat
and docstore, render the plan below from the routing resolved in step 4(a)**, the same resolution
that steps 7 and 9 execute from; never print that JSON or its fingerprint. Preview and execution are one resolution, not two readings of it; re-deriving either
half by hand is how they drift apart. Every line names its resolved **target** (`target: single` on
a single mapping — stating it is the point). The plan must show exactly what steps 5–10 will
execute — nothing the steps don't do may appear in it:
   - **docstore** — tool, target, the declared `classification` that selected it, the exact
     destination it will back up into, and the target's declared `sharing_scope`. Say plainly that
     the scope is **declared, not verified**: the kit checks that the destination exists, never its
     real sharing permissions (`adapters/README.md` § The delivery plan). Print it as
     `Sharing settings: <declared scope> (declared, not checked)`. On a single mapping the line is
     `Sharing settings: not checked (one destination).` (the plan has no sharing scope to show);
   - **tracker** — tool, target, the exact ticket (`owner/id`) the comment lands on;
   - **chat** — tool, target, the declared `audience` that selected it, channel, the full
     recipient list (the routed target's own `recipients`, including the shipper when
     `include_self`), the `sender` when the routed JSON carries one (an email target's sending
     identity — WHO the message goes out as is part of what the human authorizes), and
     draft-vs-send mode. When the target came from `--chat <target>` rather than the ticket's
     declaration, say so on the line — the CLI returns that as a warning, and an override that the
     ticket does not record is a fact the approver should see. For a tool-only seam or a
     `destination: per_ticket` target the channel and recipients are the ones this ticket's plan
     declares, routed in step 4(a): print them on the same line, never a placeholder, so the person
     approves the exact destination and list;
   - **vcs** — tool, target, the branch, that a PR opens, and how it merges: squash-merged by
     `/ship` after asking once more (`ship_merges_pr: true`), or left for the team to merge;
   - then the exact actions, in order (the numbered steps below).

   Print the plan in this shape, one block, with the values filled in from the resolution (the
   block is the text the person reads, so it names no internal field and shows no plan hash). Print
   only the lines the plan actually delivers, one Documents line (with its sharing line) for each
   routed classification, and one Chat line for each routed audience:
   <!-- ticketwright:user-facing:begin -->
   > Delivery plan for `<owner>/<id>`. Nothing has been sent yet.
   > Documents: `<tool>`, target `<target>`, chosen by the classification `<classification>`, backed up to `<destination>`.
   > Sharing settings: <declared scope> (declared, not checked) | not checked (one destination).
   > Ticket: `<tool>`, target `<target>`, comment on `<owner>/<id>`.
   > Chat: `<tool>`, target `<target>`, chosen by the audience `<audience>`, in `<channel>`, to `<recipients>`, sent as `<sender>`, as a draft | sent.
   > Chat: none, declared on the ticket (<reason>).
   > Code: `<tool>`, target `<target>`, branch `<branch>`, a pull request opens, and I merge it (squash) after asking you once more | you merge it by hand (the merge setting is off).
   > This chat target was picked for this run, not declared on the ticket.
   > This ticket declares no chat message, and this run sends one anyway because you picked the chat target.
   > What happens, in this order:
   > 1. Commit the ticket files (and a separate commit for any changed Ticketwright setup files, when there are any), push the branch, and open the pull request.
   > 2. Ask you once more, then squash-merge the pull request into `<default branch>`. If branch rules or checks block it, I stop and tell you why.
   > 3. Scan the ticket folder for raw source material, then back it up to the documents destination above. Unsent drafts stay on this machine.
   > 4. Post the approved comment on the ticket, with links to the backup and the pull request.
   > 5. Draft the chat message for the recipients above, with the same links, or send it only if you say "send it".
   > 6. Move `<id>` to `<status>` once the pull request is merged.
   > Reply `go ahead` to deliver exactly this plan, or tell me what to change.
   <!-- ticketwright:user-facing:end -->
   Leave out the "picked for this run" line unless the chat target came from `--chat <target>`, and
   leave out the sender when the routed JSON carries none. When the routed chat JSON carries
   `overrides_declared_none: true`, also print the "declares no chat message" line under it, so the
   person sees they are sending what the ticket said it does not need. Print one of the two Chat lines: the
   "none, declared" one only when routing returned `skipped: declared` (drop the parentheses when
   no reason was given), and then leave out the chat step. Step 6 names the exact status from
   step 4(c), and adds "(not checked against the tracker)" when the moves could not be read; when
   the ticket is already there, it reads "`<id>` is already in `<status>`, so it stays there." The numbered list is the steps below
   (5 to 10), so drop any step the plan does not deliver (for example the documents backup when no
   documents tool slot is configured, or the merge step when the merge setting is off).

   Resolver exit 7 (tool slot not configured) = skip that line and tell the person:
   <!-- ticketwright:user-facing:begin -->
   > <tool slot> isn't set up yet; run `/setup tool <slot>`.
   <!-- ticketwright:user-facing:end -->
   For **tracker and vcs**, exit 8 or a resolution whose `target` is non-null (a `targets:`
   block on either) = **halt** naming the configured targets: target routing for those two slots is
   deliberately not built (identity and remote-binding work, see `adapters/README.md`), and
   rendering a target the steps below would not deliver to is an authorization mismatch — never fall
   back to another target or to slot-level values.
   **Pin the plan the human just authorized.** Each routed line carries the target name AND its
   `resolution_fingerprint`. Keep both from the resolution; the person is never shown the
   fingerprint or any shortened form of it. Pass both back on **every**
   delivery_plan call in steps 7 and 9: `--expect-target <name> --expect-fingerprint <hex>`, with the same `--self` you routed
   with. The name catches a swapped target; the fingerprint catches what a name check cannot — a
   config or plan edit between approval and delivery that keeps the name while moving the channel,
   the recipient list, or the declared scope. Either mismatch refuses instead of quietly delivering
   a resolution nobody approved — that is what makes preview-equals-execution a mechanism rather
   than a promise. It pins the *resolution*; the file contents shipped are whatever is in the
   folder at delivery time, as always.
   Only on explicit authorization, execute in order:
5. **vcs.commit** — **first, isolate repo-setup / AI-layer files.** If any are dirty
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
   under a `private/` subfolder (both gitignored) first. **Then run the source-material scan**
   (`scan_source_materials.py --ticket <ticket-dir>`, the same one step 7 runs before the backup) and halt on a non-zero exit:
   `source_materials/` is committed too, and a raw transcript whose filename gives nothing away
   (`notes.md`) is matched by no gitignore pattern. Here `private/` IS a valid remedy, alongside
   trimming the file to the curated `YYYY-MM-DD-<slug>-meeting.md` form. Then **vcs.open_pr** (semantic title; body =
   Business Impact / Deliverables / Technical Notes / QC — the QC section names the verdict on file,
   and reads "shipped without an independent review" when it is `SKIPPED`). Keep the PR URL and the head commit sha you just pushed: step 6 merges exactly that sha, and steps
   8 and 9 link the PR. This step runs first on purpose. The comment and the chat message are the
   posts people read, so they go out only once every link they carry exists, and a commit or push
   that fails stops the ship before anything has been shared or anyone told it is done.
6. **vcs.merge_pr, after asking** (policy `ship_merges_pr`). Read it from the merged config. A
   missing value is `true`; an unparseable one is `false`, because unparseable config must never add
   a write. When it is `false`, or the vcs adapter says it cannot merge, skip to step 7 and say in
   one line that the pull request is open for the team to review and merge.
   When it is `true`, the go-ahead covered the plan, and this step still **asks once more, right
   before the merge** (`--go` never pre-answers this question, any more than it answers the review
   gate), because a merge lands on the team's main branch and is the one step here that
   is awkward to take back. Ask it by the question rule above (the runtime's question tool when it
   has one, otherwise in chat), and offer exactly these two answers:
   <!-- ticketwright:user-facing:begin -->
   > The pull request is open: <PR link>. Merge it into `<default branch>` now? It is squash-merged into one commit, then the backup, the comment and the chat message follow.
   > - **Merge now**
   > - **Leave it open**: the team reviews and merges it later, and I won't move the ticket to its final status.
   <!-- ticketwright:user-facing:end -->
   Only on **Merge now**, run `vcs.merge_pr` with the PR and the sha from step 5. The adapter pins
   that sha, so anything pushed after the person confirmed makes the merge refuse instead of landing
   unseen work. Then confirm the merged state with the adapter's verify line. **If the verify line
   does not show the pull request merged, it is blocked**, even when the merge command exited
   cleanly: some code hosts queue a merge or switch on auto-merge instead of merging. When branch
   protection, a required review, a check that failed or has not finished, or a conflict blocks
   the merge, **stop the ship here** and tell the person what is blocking it, in the code host's own
   words. Nothing has been backed up or posted yet, so stopping costs nothing outside the repo.
   Never retry with a bypass, admin or auto-merge option: those skip or defer exactly the checks
   the team set. The `review_verdict_guard` hook also asks before a merge of a ticket with no
   approving verdict on file. On **Leave it open**, carry on with step 7 and leave the merge to the
   team.
7. **Scan the source material first, then docstore.backup.** This runs after step 6, so what is
   shared is the merged work. The backup copies the ticket folder except `comms/` (the unsent
   drafts, which every docstore adapter's `backup` leaves out, since they are kept out of git for
   the same reason), so run
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" scan_source_materials.py --ticket <ticket-dir>`
   and **halt on a non-zero exit** — a raw meeting transcript is about to be copied out of the
   repo. The remedy here is NOT the `private/` folder: `.gitignore` has no bearing on the
   adapter's copy, so `private/` protects git and nothing else. Remove the file from the folder,
   or have the human approve the copy explicitly. (The `source_material_guard` hook asks about the
   same command; this call is what makes the halt visible on runtimes whose hooks are not wired.
   Neither reads MEANING — a curated summary quoting confidential material passes both.) Then
   **docstore.backup** the ticket folder (full-title dest name) **into the routed target's
   destination from step 4(a)** — never another target's, and never a slot-level path. Then record
   each delivered file against the target it actually went to:
   `… delivery_plan.py --plan <ticket-dir>/delivery-plan.yaml --seam docstore --record-delivered <path relative to the ticket> --url <shareable URL> --expect-target <name from the resolution> --expect-fingerprint <full fingerprint from the resolution>`
   and call `docstore.link_for` **against that same recorded target**. The recorded row is what
   makes a link provably come from the store the copy went into, rather than from whichever store
   was resolved a step later. Skip when the docstore seam isn't configured.
   **Routing is per deliverable here.** If the plan's `deliverables:` gives a file its own
   `classification:` (a client-facing summary among internal working files), that file routes to
   *its* target: resolve it with `--file <path>` and back that file up separately, rather than
   assuming the whole folder shares one destination. For that file pass the full
   fingerprint the resolver returned for its line, kept from the resolution, never anything printed to the person.
   Anything the approved plan did not
   show, you do not deliver. **The plan-level classification is folder-wide** — the backup carries
   `qc_queries/` and everything else not split out by a row, so an external plan-level
   classification must be a deliberate statement about the whole folder, and the approval line
   should be read that way.
8. **tracker.comment** — post via the adapter's rich path (smart-link cards for the docstore
   files), with the backup links from step 7 and the PR link from step 5 filled into their
   placeholders. Never before this point (no tracker comments without human review). Always write the
   exact posted text to `comms/draft-tracker.approved.md` — edited or not — so Phase C can diff it
   (an unedited ship just yields `initial == approved` and proposes nothing).
9. **chat.draft** to **the routed target's destination from step 4(a)** — its channel, its
   recipients, its adapter (policy `chat_default_draft` — the human clicks send unless they said
   "send it", in which case `chat.send`). Fill the link placeholders as in step 8, then re-run
   `--check-draft` on the final text: it is the
   last mechanical point at which a message can be caught carrying the wrong audience's list, and it
   costs one command. A routing failure here is a **stop**, never a send to another target. Smart
   links for ticket id(s), files, PR. Write the final drafted text to `comms/draft-chat.approved.md`.
   Skip when the chat seam isn't configured, or when the ticket declares `chat: none`.
10. **transition** the ticket to the status the approved plan named (step 4(c): its `target`, and
    its `via` where the adapter's `transition` section says the call takes one), never another one,
    **and only when
    step 6 merged the pull request.** A move that fails anyway (the workflow changed since step
    4(c)) is reported in the tracker's own words; do not try other statuses. The index row keeps
    the status read in step 3 until the next `/refresh index` reads the new one from the tracker:
    the merged work is not edited again here. When the merge was left to the team (the person chose
    **Leave it open**, or `ship_merges_pr` is `false`), leave the status where it is and say so: a
    ticket marked done with its work unmerged tells the team something that is not true yet.

## Phase C — Post-ship (always, even on success)
11. **System-evolution retro** (policy `system_evolution`). Reflect briefly: did anything go wrong or
    get re-done this ticket? If so, **which layer was insufficient** — a global rule, the context
    pack, a skill, or an adapter? Propose the concrete fix to *that* artifact and note it. Fixing
    the layer, not just the ticket, is what compounds.
    **Then check for a repeat, every time.** Run
    `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" recall.py --for <owner>/<id> --repeats --json`
    (the ticket's SQL now exists, so the answer is `confirmed`) and follow the four steps in
    [repeats.md](../skillify/repeats.md). When they end in a
    suggestion, ask it by the question rule above, offering **Skillify it now** and **Not now**:
    <!-- ticketwright:user-facing:begin -->
    > This repeats dana/TEST-5. Skillify it?
    <!-- ticketwright:user-facing:end -->
    **Skillify it now** starts `/skillify` with the pattern and the `built_from` list (the earlier
    tickets plus this one, each `<owner>/<id>`). When a skill already does this work, say so
    instead: "Next time, `/<skill>` does this." Never start `/skillify` without the yes. *(A stylistic tweak to a comms draft is **not** a layer failure — that's step 12, not
    this retro.)*
12. **Voice refine** (only if a voice profile resolved for the shipper). Diff `comms/draft-<kind>.initial.md` against `comms/draft-<kind>.approved.md`. If they
    differ beyond whitespace, the edits are voice signal: **propose** a small append/edit to the
    person's `voices/<id>.md` capturing the pattern (e.g. "drops the greeting", "prefers 'net:' over
    'in summary'") and **ask before writing**, as one question: "Add it to my voice profile" or
    "Skip". Never write it silently. If `initial` ==
    `approved` (no edits), or the feature is off, do nothing.
