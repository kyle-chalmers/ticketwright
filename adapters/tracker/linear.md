---
seam: tracker
tool: linear
transport: mcp         # mcp__plugin_productivity_linear__*
requires: [team_id]    # stack.yaml seams.tracker.{team_id, done_state_id}
auth: |
  The `linear` MCP server (plugin_productivity_linear) must be connected (OAuth).
  Verify: a read-only issue/team query returns without error.
note: |
  Linear has first-class issue identifiers (e.g. ENG-123) — a natural fit for project.key_prefix and
  branch names (Linear even suggests `username/eng-123-slug`). "Epic" ≈ a **Project** or a parent
  issue; "status" = workflow **state** (Backlog / Todo / In Progress / Done / Canceled).
---

# Linear adapter

Maps the `tracker` verb contract to Linear via its MCP.

## verb: fetch_ticket
**In:** issue id (e.g. `ENG-123`). **Out:** title, description (markdown), state, assignee, labels,
attachments, parent/project.
```
mcp__plugin_productivity_linear__* get-issue(id=<id>)
```

## verb: create_ticket
```
create-issue(team={team_id}, title=<summary>, description=<markdown>,
             assignee=<email/userId>, project=<epic project id>, parentId=<optional>)
```
Linear auto-mints the identifier from `{team_id}` (your `key_prefix`). Epic → set `project` or `parentId`.

## verb: transition
```
update-issue(id=<id>, stateId={done_state_id})     # move to the workflow state for terminal_status
```
Fetch the team's states once to map `project.terminal_status` → `{done_state_id}`.

## verb: comment
```
create-comment(issueId=<id>, body=<markdown>)
```
Linear comments support full markdown links — `[DI-123](url)`, file links, PR links. Honor
`word_limits.tracker_comment`; never post before human review.

## verb: search
```
list-issues(team={team_id}, query=<text>, filter={state, label, ...})
```

## verb: download_attachments
Read the issue's `attachments{ url }`, `curl -L` each to the dest dir. (Linear attachments are URLs.)

## gotchas
- State ids are team-specific — don't hardcode; resolve from the team's workflow states.
- Linear's native git-branch naming convention pairs well with the `vcs.branch` verb.
