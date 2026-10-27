---
name: ticket
description: The front door — open or resume a ticket, auto-load its context and prior art, write the plan (and the spec when the plan calls for one), and wait for your approval before anything is built. Start every ticket here.
argument-hint: <ticket-id | owner/id> [--warehouse <name>] | --create "<summary>" [--type T] [--worktree] | --recall "<topic>" | --recall --object <NAME>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Agent]
---

# /ticket

One command owns the ticket lifecycle: it opens (or creates) the ticket, sets up the workspace,
loads exactly the context this ticket needs, surfaces the closest prior work, and then carries the
work forward in the same window — **plan → build → check → ship**. Every read-only planning step
happens HERE, in Phase 4: the plan, and the spec when the plan calls for one, behind a single
approval — so `/build` never starts on a ticket nobody scoped, and on that approval it starts here. Reads the merged config; everything tool-specific resolves
through the adapters, so it works with any configured tracker/warehouse/vcs.

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

In this skill the questions are step 1's `ambiguous` person, step 2's local-only offer, step 3's
owner choice, step 11's open questions (one round: they go together), and step 12's approval. The
first of them can come before step 8, so run step 8's probe then and keep the result.
- The options come from the resolver's `candidates`, the owner folders that hold the id, and the
  plan's own assumption with the alternatives it weighed.
- **More real options than the limit allows:** show the first ones plus a "Show more" option that
  asks again with the rest.
- **"Never pick one" still holds.** A question lets the person choose; never answer it for them.

## Mode: `--recall` (standalone prior-art lookup, no workspace setup)
`/ticket --recall "<topic>"` or `--recall --object <NAME>` — rank prior tickets and write a reuse
brief, nothing else. Follow [priming.md](priming.md) § Recall. Useful mid-session ("have we built
this before?", "which tickets touched VW_X?").

## Phase 0 — Resolve & preflight (halt-on-fail)
0. **Read the merged config first — it is what decides WHO** — `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" effective_config.py --json`,
   never raw `stack.yaml`. It carries `project.*`, `seams.tracker`, `seams.vcs` — and it settles the
   owner **mechanically**, in one field, so no skill re-derives the rule. If the team config is
   missing, say so and offer `/setup` — don't scaffold blind. Branch on **`owner_source`**, never on
   a `people/` listing of your own: a roster can live entirely in
   `$XDG_CONFIG_HOME/ticketwright/people/` and never appear in this repo, and only the resolver
   looks in both homes — "no `people/*.yaml` here" is not the same question.
   - `resolved` — proceed; `owner` is this person and owns everything below.
   - `unbound` — **HARD STOP here, before any ticket path is rendered.** Say:
     "I can't tell who you are: `people/<id>.yaml` is a placeholder (or no `people/` entry matches
     this machine's identity). Run `/setup --teammate` first — it asks who you are, binds it, and
     sets up your machine." Do **not** fall back to `project.assignee_dir`: with a roster present
     that key names a COLLEAGUE, and their `tickets/<owner>/` folder is exactly where an unbound
     teammate's work silently lands. Never infer an owner from a name.
   - `assignee_dir_fallback` — proceed with `owner`: there is no roster in either home, so
     `project.assignee_dir` is the documented last resort for repos that predate owner routing.
   - `none` — stop: no roster and no `assignee_dir`. Offer `/setup`.
   Read `owner`, never `project.assignee_dir` directly.
1. **Then show who that is** — `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" whoami.py`,
   and show its one-line "Working as …" display. This is the display-and-binding step; the routing
   decision was already made in step 0, and whoami never overrides it. Two statuses still change
   what you do next: `ambiguous` — ask which person it is, with whoami's `candidates` as the
   options (see "How this skill asks the person something"); never rank or pick, and step 0's hard
   stop stands until they answer. `conflict` — proceed as the machine-pinned person and surface the
   warning line verbatim.
2. **Verify** the tracker + vcs seams (run their `verify` commands). If one is unreachable, print
   that adapter's `auth` notes and ask whether to continue **local-only** (workspace + context still
   work; tracker fetch is skipped) or stop and fix the connection first — degrade, don't die.
3. Determine the **ticket locator**: `$ARGUMENTS` gives either `owner/id` (exact) or a bare `id` —
   resolve a bare id against the resolved person's `tickets/<owner>/` first, then across the other
   owners' folders. **If a bare id exists under two or more owners and none of them is the resolved
   person, hard-stop and ask which one, with the `owner/id` choices as the options — never pick
   one.** For `--create`, create the
   ticket first via the tracker adapter's `create_ticket` verb (`project.default_epic` as parent if
   set), then use the new id; created work is owned by the step-0 person.

## Phase 1 — Resume, don't restart
4. Render `project.ticket_path` → the ticket dir, filling `{assignee}` with the **locator's owner**
   (the step-0 resolved person for new or bare-id work — never the static `project.assignee_dir`,
   except through step 0's `assignee_dir_fallback` last resort). If the dir exists: read its
   `README.md`, list `final_deliverables/`, check `git log --oneline -10` + `git status`, and
   summarize what's done and what remains, re-fetch the ticket for new comments, then **skip to
   Phase 3**. Resuming another person's ticket (locator owner ≠ resolved person) is fine — say so
   out loud. **Check for the plan:** if `plan.md` exists in the ticket dir, read it and report where
   the work stands against its Approach and Deliverables. If it is missing and work remains, Phase 4
   still runs before anything else — a resumed ticket is not exempt from scoping. If the deliverables
   already exist and a `/review` verdict is on file (the ticket is at review/ship stage), say the plan
   is absent and route onward.

## Phase 2 — Workspace (new ticket)
5. **Branch** via the vcs adapter, named `<id>`, off `seams.vcs.default_branch` — or a **worktree**
   when `--worktree` is passed (isolates this ticket from other in-flight work; recommended when you
   run several tickets in parallel). Branch names stay bare `<id>` — never `owner/id`, because `/`
   is git's ref-namespace separator and `alice/x` would permanently forbid a branch named `alice`.
   **If `<id>` is already taken** (typically another owner's ticket), create `<owner>-<id>` instead
   and say so out loud.
6. **Scaffold** `project.ticket_path` with `project.ticket_subdirs` (create the subdirs empty —
   **no `.gitkeep` placeholders**; they fill with real files during build and git picks them up
   then); tracker adapter `download_attachments` → `source_materials/` (silent if none);
   when `project.intake` lists `email`/`chat`/`meetings`, that folder also carries what a human
   dropped in — meeting notes arrive as `YYYY-MM-DD-<slug>-meeting.md`, and priming enumerates
   them with `scan_source_materials.py --intake` rather than guessing at names;
   resolve the kit once with `KIT="$(bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit)"`, then render
   `"$KIT"/templates/ticket-README.md.tmpl` → the ticket dir —
   **only if that README doesn't already exist**. Where the tracker *is* the ticket folder, step 3's
   `create_ticket` already wrote it, and re-rendering would replace a briefed ticket with empty
   template tokens.
6b. **Refresh the catalog** so the new ticket shows up immediately — it won't otherwise, because the
   PostToolUse index hook only fires on `Write`/`Edit` and scaffolding happens via Bash:
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" build_ticket_index.py` (writes this
   project's `tickets/INDEX.md` + `OBJECTS.md`, and the graph layer when it's on; the new row shows
   `▱` until `/ship` curates it).

## Phase 3 — Prime context automatically (the part you never have to ask for)
7. Follow [priming.md](priming.md), in order:
   - **Ticket slice** — the ticket body + folder + related prior tickets;
   - **Recall** — rank prior art (`bin/recall.py`), read the top 2–4, note what to **reuse**;
     it also offers the tracker's older tickets when recall is weak (priming §2b);
   - **Domain slice** — glossary/rules for the ticket's topic (from `documentation/`);
   - **Warehouse slice** — schemas/samples/lineage for the specific objects in play (skip cleanly
     if no warehouse is configured).
   Keep the whole brief tight (≤ ~300 words) — slices, not the whole knowledge base.
7b. **Meeting references** — the complete rule, stated here in full because it is load-bearing
   even for a reader who skips the reference file. When `seams.meetings` is configured, enumerate the ticket's meeting
   references:
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" meeting_refs.py --ticket <ticket-dir> --json`.
   Zero refs ⇒ do nothing — never fetch speculatively. An invalid ref (exit 4) is a NAMED error to
   surface, never silence; `"reason": "refused-credential"` means a URL or token was committed —
   ask for the bare `<provider>:<id>` instead. For each ref whose provider matches the configured
   tool (check via the config resolver, `--seam meetings`), call the adapter's `fetch_transcript`,
   and `fetch_action_items` handling its typed result: `ok` → use the items; `empty` → report
   "no action items recorded" (the provider's answer is authoritative — no extraction fallback);
   `no_native_export` → extract action items in-context from the transcript text. Curate
   in-context into the committed `YYYY-MM-DD-<slug>-meeting.md` (decisions + action items,
   honoring the word limits). Never write the raw transcript to disk — the only opt-in raw
   location is `source_materials/private/`, which stays out of git but flags every `/ship` scan
   and copy-guard prompt by design. [priming.md](priming.md) §1 carries the expanded detail.

## Phase 4 — Scope: every read-only planning step, then one approval
Every ticket gets a plan, every time — there is no "small change, build directly" branch. Report the
context brief (including the reuse brief) first, then:

8. **Probe the runtime** the same way `/review` does:
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" kit_paths.py --json` — keep
   its `kit_root` (it resolves the templates below; no second launcher call is needed) and read
   `capabilities.plan_mode`, branching on the **value only**, never on the runtime's name:
   - `native`, **and you can enter that mode from where you are** → draft steps 9–11 inside the
     runtime's planning mode and leave it only at step 12, because leaving it IS the approval. Most
     such modes let nothing but their own plan file be written; that is an instruction to the model,
     not a sandbox (the adapter, `adapters/runtime/<tool>.md`, carries the mechanism note), so the
     rule below still binds inside it.
   - anything else (`none`, `unknown`, a failed probe, or a native mode you cannot enter mid-skill) →
     the same steps in the current context, with the approval as an explicit reply. In plain terms:
     **nothing is written to the ticket until step 12; no runtime mode is required.** Read-only here
     is GUIDANCE the agent follows, not a gate the runtime enforces — say so if asked.
9. **Draft the plan — compose it, do not write it yet.** Compose it as Markdown, one `## <Section>`
   block per heading of `templates/plan.md.tmpl` under `kit_root` from Goal to Risks, in its order,
   because step 12 renders the file from exactly these blocks. Next step is not a block: the
   template writes it from the `spec:` value. The template holds the shape only; what goes in each
   block is here:
   - **Goal**: the outcome and why it matters to the requester.
   - **Scope**: `- **In:**` and `- **Explicitly out:**` (what this ticket will not answer, so nobody
     assumes it did).
   - **Builds on**: each prior ticket from the reuse brief as `<owner>/<id>`, why it matched (a
     shared object, named by its name, a shared tag, a cross-reference, or keyword overlap only),
     and what is reused. "None found" is a valid answer. When the repeat check in
     [repeats.md](../skillify/repeats.md) ends in a suggestion, also "This is the Nth instance of
     <pattern> (after <owner>/<id>)".
   - **Deliverables expected**: numbered in review order; each names its grain and carries its
     record count in the filename.
   - **Approach**: ordered steps, with build-and-check loops kept small (one object or change at a
     time).
   - **Validation strategy**: how each step is verified, decided before any code; these are the
     success criteria `/review` checks against (duplicate detection on the grain key and
     record-count reconciliation, source against output, unless the plan says why not).
   - **Touched**: `- **Objects/files:**` and `- **Tool slots:**` (which tracker, warehouse, chat,
     docstore, meetings or vcs, and for what).
   - **Questions for the requester**: asked in step 11; after the answers, each question with its
     answer (they become README assumptions), or "None open".
   - **Risks**: what could make the result wrong or late, and how the plan watches for it.
   Every block has real content: no `…` placeholder lines, no template hints, nothing empty. Header
   facts are not blocks: the ticket id, title, Confidence (1 to 10; below 7, a spec is required),
   owner, `after_ship` and the **`spec:` value**. `after_ship` is empty unless the repeat check
   ends in a suggestion; then it is that one Next step line ("- After /ship: `/skillify <pattern>` (a
   suggestion, not part of this plan)", or the existing skill to run), never a step of this plan.
   The `spec:` value is exactly one of `not required` (the plan is the build's
   blueprint), the spec's path spelled from the repo root as `<ticket-dir>/specs/<id>-<slug>.md`, or
   `after-root-cause`. Inputs: the priming brief + the reuse brief. A spec is required when the work
   creates or alters a persisted object others depend on (a warehouse object, a model, a published
   report), reconciles two or more sources, or confidence is below 7. Choose `after-root-cause` for
   an **investigation-shaped ticket** ("where is this error coming from", "why did this number
   drift"): you cannot blueprint a fix you have not root-caused, and a spec written from the
   ticket's own hypothesis specifies a fix to the wrong place, so the Approach scopes the
   investigation and `/build` returns here for the spec once the cause is found (its Phase 1 owns
   that condition). Scoping is still first; it is scoped to what can honestly be planned.
10. **When a spec is required, draft it now, in this phase** — follow [spec.md](spec.md) (it consumes
    the Phase 3 brief and researches only the delta). Spec authoring is read-only by design, which is
    why it belongs here and not in `/build`. Nothing about planning is left for the build stage.
11. **Reduce assumptions** (policy `reduce_assumptions`): gather the open questions from the plan and
    the spec and **ask them now**, in one round — scoping is where an answer is cheapest. Show the
    scoping package first, then ask each open question as its own question (see "How this skill
    asks the person something"): what the plan assumed is the first, recommended option, and the
    alternatives the plan weighed are the others. These questions do not depend on each other, so
    with a question tool ask up to the limit per call, in as many calls in a row as it takes. When
    an answer differs from what the plan assumed, revise the plan and say what changed before
    step 12.
12. **Present the scoping package and WAIT for one explicit approval** — by leaving planning mode on
    a `native` runtime, by a reply everywhere else. Everywhere else, ask the approval as one
    question once step 11's answers are in, never in the same call (an answer can change the plan
    being approved). Its options are "Approve and build", "Approve, don't build yet" and "Change the
    plan"; the approval is the person's decision, so none is marked recommended. End the package by
    saying what approval does, since on a `native` runtime leaving the mode is the whole answer:
    <!-- ticketwright:user-facing:begin -->
    > Approving starts the build right away. To save the plan without building yet, say "approve, don't build yet".
    <!-- ticketwright:user-facing:end -->
    **Only after the human says go** do the artifacts
    touch the ticket. Write the approved `## <Section>` blocks, exactly as approved (with step 11's
    answers folded in), to a scratch file outside the repo, then render the plan from them with
    `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" render.sh "$kit_root/templates/plan.md.tmpl" ticket_id=… title=… confidence=… spec_required=… owner=… after_ship='…' --sections <scratch file> --strict`
    into a scratch output file, and move it to `<ticket-dir>/plan.md` only when the render exits 0.
    The six header tokens go on the command line (`after_ship=''` when there is no suggestion;
    single-quote a filled one, since it carries backticks); every section comes from the file, so multi-line
    Markdown never passes through shell quoting, and section text is inserted as written (a `{{ }}`
    inside it stays text). `--strict` makes each of these an error that prints nothing: a missing
    section or token, a heading the template has no place for, an empty section, a leftover `…`
    placeholder line. On an error, fix the blocks and render again; never hand-edit the output to
    get past it. **If a `plan.md` already exists (a resumed or re-scoped ticket), update it in
    place; never re-render over an approved plan** — then write the spec
    (`<ticket-dir>/specs/<id>-<slug>.md`) when one was drafted, and commit them together **through
    the vcs adapter's `commit` verb** — `docs: <id> plan for <thing>`, or `docs: <id> plan + spec for
    <thing>` — when `commit_plan_before_implement` is on; leave them uncommitted when it is off.
    Either way they are now **on file**, which is what `/build` requires. A rejected package writes
    nothing: revise and present again.
13. **Continue, always with the qualified `<owner>/<id>` locator** (so the next step can never
    re-resolve a bare id to a different owner's ticket). What happens next depends on what was
    approved. **Check for replan mode first**, because a replan's approval is usually a plain "go"
    too:
    - **Replan mode** (a build called this phase: `/review` found a scope problem, the person chose a
      replan at the review cap, or an `after-root-cause` investigation found the cause) → update
      `plan.md` and the spec in place, get the approval, name the build steps the change affects,
      and **return control to the build that called it**. In replan mode, never enter `/build`: the
      build that called you is still running, and a second one would re-resolve everything and never
      return there.
    - **Approve and build** (outside replan mode, the default; a plain "go" means this) → say
      <!-- ticketwright:user-facing:begin -->
      > Plan approved. Starting the build.
      <!-- ticketwright:user-facing:end -->
      and **follow `/build <owner>/<id>`'s instructions in full**, in this same window.
      "Follow" means what it means when `/build` runs `/review`: there is no mechanical
      skill-invocation tool, and the emitted runtimes carry this body verbatim. `/build` decides on
      its own probe whether the work is done by subagents that see only the plan and spec, or here;
      it ends by running `/review`, and asks before `/ship <owner>/<id>` on APPROVE.
    - **Approve, don't build yet** → write the artifacts and stop, naming `/build <owner>/<id>` as
      the command to run later.

## Stops here
No SQL beyond the describe/sample reads priming and spec research already make, no analysis, no
deliverables, no external posts — while scoping. In Phase 4 the plan and the spec are the only files
written, and only after approval. The build that follows an approval is governed by `/build`, not by
this rule. If the request is ambiguous, state your interpretation and ask before scaffolding heavy
structure (`reduce_assumptions`).
