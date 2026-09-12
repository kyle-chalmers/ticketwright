---
name: ticket
description: The front door — open or resume a ticket, auto-load its context and prior art, write the plan (and the spec when the plan calls for one), and wait for your approval before anything is built. Start every ticket here.
---

<!-- emitted by ticketwright install v4.0.3 — do not hand-edit; re-run `ticketwright install --runtime antigravity` to update. -->

# /ticket

One command owns the ticket lifecycle: it opens (or creates) the ticket, sets up the workspace,
loads exactly the context this ticket needs, surfaces the closest prior work, and then tells you the
right next step — **plan → build → check → ship**. Every read-only planning step happens HERE, in
Phase 4: the plan, and the spec when the plan calls for one, behind a single approval — so `/build`
never starts on a ticket nobody scoped. Reads the merged config; everything tool-specific resolves
through the adapters, so it works with any configured tracker/warehouse/vcs.

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
   what you do next: `ambiguous` — ask which person it is; never rank or pick, and step 0's hard
   stop stands until they answer. `conflict` — proceed as the machine-pinned person and surface the
   warning line verbatim.
2. **Verify** the tracker + vcs seams (run their `verify` commands). If one is unreachable, print
   that adapter's `auth` notes and offer to continue **local-only** (workspace + context still work;
   tracker fetch is skipped) — degrade, don't die.
3. Determine the **ticket locator**: `$ARGUMENTS` gives either `owner/id` (exact) or a bare `id` —
   resolve a bare id against the resolved person's `tickets/<owner>/` first, then across the other
   owners' folders. **If a bare id exists under two or more owners and none of them is the resolved
   person, hard-stop and list the `owner/id` choices — never pick one.** For `--create`, create the
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
9. **Draft the plan — compose it, do not write it yet.** Its shape is `templates/plan.md.tmpl` under
   `kit_root`: Goal, Scope (in / explicitly out), Deliverables expected, Approach, Validation
   strategy, Touched, Questions for the requester, Risks, Next step, Confidence. Inputs: the priming
   brief + the reuse brief. Decide the **`spec:` value** by the criteria in the template's header —
   `not required`, or a spec path (required when the work creates or alters a persisted object others
   depend on, reconciles two or more sources, or confidence is below 7), or `after-root-cause` for an
   **investigation-shaped ticket** ("where is this error coming from", "why did this number drift"):
   you cannot blueprint a fix you have not root-caused, and a spec written from the ticket's own
   hypothesis specifies a fix to the wrong place, so the Approach scopes the investigation and
   `/build` returns here for the spec once the cause is found (its Phase 1 owns that condition).
   Scoping is still first; it is scoped to what can honestly be planned.
10. **When a spec is required, draft it now, in this phase** — follow [spec.md](spec.md) (it consumes
    the Phase 3 brief and researches only the delta). Spec authoring is read-only by design, which is
    why it belongs here and not in `/build`. Nothing about planning is left for the build stage.
11. **Reduce assumptions** (policy `reduce_assumptions`): gather the open questions from the plan and
    the spec and **ask them now**, in one round — scoping is where an answer is cheapest.
12. **Present the scoping package and WAIT for one explicit approval** — by leaving planning mode on
    a `native` runtime, by a reply everywhere else. **Only after the human says go** do the artifacts
    touch the ticket: render the plan with
    `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" render.sh "$kit_root/templates/plan.md.tmpl" ticket_id=… title=… confidence=… goal=… spec_required=… owner=… --strict`
    (all six tokens; `--strict` so a missing one is an error, not a `{{token}}` committed into the
    record) into `<ticket-dir>/plan.md` — **if a `plan.md` already exists (a resumed or re-scoped
    ticket), update it in place; never re-render over an approved plan** — then write the spec
    (`<ticket-dir>/specs/<id>-<slug>.md`) when one was drafted, and commit them together **through
    the vcs adapter's `commit` verb** — `docs: <id> plan for <thing>`, or `docs: <id> plan + spec for
    <thing>` — when `commit_plan_before_implement` is on; leave them uncommitted when it is off.
    Either way they are now **on file**, which is what `/build` requires. A rejected package writes
    nothing: revise and present again.
13. **Route, always forward, with the qualified `<owner>/<id>` locator** (so the next step can never
    re-resolve a bare id to a different owner's ticket): `/build <owner>/<id>` — it executes the spec
    when one exists, else the plan, and ends by running `/review` itself. Then `/ship <owner>/<id>`
    on APPROVE.

## Stops here
No SQL beyond the describe/sample reads priming and spec research already make, no analysis, no
deliverables, no external posts. In Phase 4 the plan and the spec are the only files written, and
only after approval. If the request is ambiguous, state your interpretation and ask before
scaffolding heavy structure (`reduce_assumptions`).
