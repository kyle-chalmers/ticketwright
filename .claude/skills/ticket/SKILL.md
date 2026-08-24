---
name: ticket
description: The front door — open or resume a ticket, auto-load its context and prior art, and route to the next step (spec, build, review, or ship). Start every ticket here.
argument-hint: <ticket-id | owner/id> [--warehouse <name>] | --create "<summary>" [--type T] [--worktree] | --recall "<topic>" | --recall --object <NAME>
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep, Agent]
---

# /ticket

One command owns the ticket lifecycle: it opens (or creates) the ticket, sets up the workspace,
loads exactly the context this ticket needs, surfaces the closest prior work, and then tells you the
right next step — **plan → build → check → ship**. Reads `.claude/config/stack.yaml`; everything
tool-specific resolves through the adapters, so it works with any configured tracker/warehouse/vcs.

## Mode: `--recall` (standalone prior-art lookup, no workspace setup)
`/ticket --recall "<topic>"` or `--recall --object <NAME>` — rank prior tickets and write a reuse
brief, nothing else. Follow [priming.md](priming.md) § Recall. Useful mid-session ("have we built
this before?", "which tickets touched VW_X?").

## Phase 0 — Resolve & preflight (halt-on-fail)
0. **Resolve WHO first** — `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" whoami.py`
   and show its one-line "Working as …" display. This person is the default owner for everything
   below. By status:
   - `resolved` — proceed; new work belongs to this person.
   - `miss` with a people map present (any `people/*.yaml`) — ask once ("I don't recognize
     `<identity>`. Who are you?"), then `whoami.py --bind <id>`; never infer from a name.
   - `miss` with **no people map at all** — fall back to `project.assignee_dir`, the documented
     last resort for repos that predate owner routing.
   - `ambiguous` — ask which person it is; never rank or pick.
   - `conflict` — proceed as the machine-pinned person and surface the warning line verbatim.
1. Read the merged config — `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" effective_config.py --json`,
   never raw `stack.yaml`: `project.*`, `seams.tracker`, `seams.vcs`. If the team config is
   missing, say so and offer `/setup` — don't scaffold blind.
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
   except through step 0's no-people-map last resort). If the dir exists: read its `README.md`, list
   `final_deliverables/`, check `git log --oneline -10` + `git status`, summarize what's done and
   what remains, re-fetch the ticket for new comments, then **skip to Phase 3**. Resuming another
   person's ticket (locator owner ≠ resolved person) is fine — say so out loud.

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
   resolve the kit once with `KIT="$(bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" --kit)"`, then render
   `"$KIT"/templates/ticket-README.md.tmpl` → the ticket dir —
   **only if that README doesn't already exist**. Where the tracker *is* the ticket folder, step 3's
   `create_ticket` already wrote it, and re-rendering would replace a briefed ticket with empty
   template tokens.
6b. **Refresh the catalog** so the new ticket shows up immediately — it won't otherwise, because the
   PostToolUse index hook only fires on `Write`/`Edit` and scaffolding happens via Bash:
   `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" build_ticket_index.py` (writes this
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

## Phase 4 — Route
8. Report the context brief (including the reuse brief) and the recommended next step — always
   with the **qualified `<owner>/<id>` locator**, so the next step can never re-resolve a bare id
   to a different owner's ticket:
   - non-trivial work → `/spec-and-build spec <owner>/<id>` (blueprint first, build second);
   - small change → build directly, then `/review <owner>/<id>`;
   - after review passes → `/ship <owner>/<id>`.

## Stops here
No SQL, no analysis, no external posts. If the request is ambiguous, state your interpretation and
ask before scaffolding heavy structure (`reduce_assumptions`).
