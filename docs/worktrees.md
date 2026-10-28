# Sessions that run in a git worktree

Many coding agents start each session in its own git worktree. The Claude desktop app does it by
default (a "Worktree" checkbox, on unless you turn it off), putting the session in
`<repo>/.claude/worktrees/<name>` on a branch it names. Codex and other agents do the same. Ticketwright
works the same way in a worktree as in the main checkout; this page says what it does differently
and why.

## What a worktree shares, and what it does not

A worktree shares the repository's commits and branches with the main checkout. It does not share
files git ignores. Ticketwright keeps two of those per machine:

- `.claude/config/connections.local.yaml`: who you are (`person:`) plus your drive mount and any
  personal connection names.
- `.claude/config/viewer.local.yaml`: which apps open your deliverables, when you chose "this repo only".

**What Ticketwright does:** in a worktree with no copy of its own, it reads the main checkout's copy,
and writes go there too, so a value set in one session is there in the next. A copy inside the
worktree still wins, if you put one there. Ask where a file lives with:

```bash
bash bin/tw kit_paths.py --local-config connections.local.yaml
```

One exception keeps your machine values out of git: until the main checkout has the setup commit
(and with it the `.gitignore` rule for these files), writes stay inside the worktree instead.

Do not list these two files in Claude Code's `.worktreeinclude`. That copies a snapshot into each new
worktree, and the snapshot then wins over the main checkout's copy, so later changes stop reaching
that session.

## `/setup` in a worktree

Setup writes the team's files (`stack.yaml`, `AGENTS.md`, the launcher in `bin/`) into the worktree,
and its commit lands on the session's branch. The main checkout, your other sessions and your
teammates see the setup only once that branch is merged, so setup offers to push it and open a pull
request.

**A repository with no commits yet.** Recent git can start a worktree in an empty repository, but
the first commit then lands on the session's branch. Setup pushes it as the default branch
(`git push -u origin HEAD:main`), so the remote does not start life with the session's branch name.
If your agent refuses to start a worktree in an empty repository, run setup in the main checkout
for that first commit; worktrees work from the next session on.

## `/ticket` in a worktree

The worktree already keeps the ticket apart from other work, so `/ticket <id>` does not nest a
second worktree inside it, even with `--worktree`. It makes the ticket's own `<id>` branch from the
default branch on the remote, in place:

```bash
git fetch origin main
git switch -c TEST-14 --no-track origin/main
```

It never runs `git checkout main` first: the main checkout already has `main` checked out, and git
refuses to check out one branch in two places. Starting from the remote also means the ticket sees
your teammates' merged tickets, even when the main checkout has not pulled them. The session's own
branch is left alone.

## `/ship` in a worktree

`/ship` commits, pushes the `<id>` branch and opens the pull request from the worktree, like
anywhere else. The squash merge happens on the code host, and `/ship` never deletes a branch
locally, so it never needs the branch the main checkout holds. The worktree itself stays your
agent app's to clean up; Ticketwright does not remove it. The backup copies the ticket folder from the worktree, and
the drive mount comes from the main checkout's `connections.local.yaml`.

## Recall, `INDEX.md` and `OBJECTS.md`

Recall reads the tickets committed on the branch you are on. A ticket branch made by `/ticket`
starts from the remote's default branch, so it sees every teammate's merged ticket. Tickets still in
flight in another session's worktree are not visible until they merge, the same as a teammate's
unmerged branch.

## Other agents (Codex, Cursor, and the PyPI install)

None of this depends on Claude Code. The worktree check reads the `.git` file, and the commands
above are plain git, so a session Codex or Cursor starts in a worktree behaves the same way. The one
Claude Code piece is the plugin itself: a project-scope install is recorded against the main
checkout, and `bin/tw` finds it from any of its worktrees.
