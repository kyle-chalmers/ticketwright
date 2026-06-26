---
name: start-ticket
description: Open or create a ticket and scaffold its workspace — branch/worktree, folder, attachments, README. Tool-agnostic via the tracker + vcs adapters. The PLAN entry point.
argument-hint: <ticket-id> | --create "<summary>" [--type T] [--assignee email]
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
---

# /start-ticket

The **PLAN** entry point of the PIV loop. Opens an existing ticket (or creates one), sets up an
isolated workspace, and produces a scoped context brief — without committing to implementation.
Reads `.claude/config/stack.yaml`; resolves everything through the **tracker** and **vcs** adapters,
so it works whether the tracker is Jira, Asana, Monday, or Linear.

## Phase 0 — Resolve & preflight (halt-on-fail)
1. Read `.claude/config/stack.yaml`: `project.*`, `seams.tracker`, `seams.vcs`.
2. **Verify** both seams (run their `verify` commands). If a seam is unreachable, **halt** and print
   that adapter's `auth` notes — do not proceed blind.
3. Determine the ticket id: `$ARGUMENTS` id, or (for `--create`) create it first via the tracker
   adapter's `create_ticket` verb (`project.default_epic` as parent if set), then use the new id.

## Phase 1 — Detect existing work (resume, don't restart)
4. Render `project.ticket_path` → the ticket dir. If it exists:
   - Read its `README.md`, list `final_deliverables/`, check `git log --oneline -10` and
     `git status`. Summarize what's done and what remains, then **continue** from there (skip Phase 3
     scaffolding). Re-fetch the ticket for any new comments/requirements since last session.

## Phase 2 — Workspace (new ticket)
5. **Branch/worktree** via the vcs adapter: `branch` named `<id>`, or `worktree` if isolating (the
   Plan→Implement context reset). Branch off `seams.vcs.default_branch`.
6. **Scaffold** the folder: create `project.ticket_path` with `project.ticket_subdirs`.
7. **Attachments:** tracker adapter `download_attachments` → `source_materials/` (silent if none).
8. **README:** render `templates/ticket-README.md.tmpl` (tokens: id, title, type, status, epic,
   tracker URL) → the ticket dir.

## Phase 3 — Prime & brief
9. Run the priming commands for this ticket: `/prime-ticket <id>`, then `/prime-domain <topic>` and
   `/prime-warehouse <objects>` once the topic/objects are clear.
10. **Report** the context brief and propose next step: usually `/spec-and-build spec <id>` for
    anything non-trivial (research-rich planning), or proceed directly for a small change.

## Stops here
This skill does **not** write SQL, run analysis, or post anything. It sets the stage and hands off to
IMPLEMENT. Honors `reduce_assumptions`: if the request is ambiguous, state your interpretation and
ask before scaffolding heavy structure.

## Generalizes
a worktree + ticket-setup flow, with the Jira/git specifics
moved into adapters.
