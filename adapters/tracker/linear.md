---
seam: tracker
tool: linear
transport: mcp         # MCP; server name = seams.tracker.mcp ({mcp})
requires: [team_id, mcp]    # stack.yaml seams.tracker.{team_id, done_state_id, mcp}
container_key: seams.tracker.team_id   # which config key a ranked container fills (see rank_projects_by_activity)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  The Linear MCP server (`{mcp}`) must be connected (OAuth).
  Verify: a read-only issue/team query returns without error.
note: |
  Linear has first-class issue identifiers (e.g. ENG-123) — a natural fit for project.key_prefix and
  branch names (Linear even suggests `username/eng-123-slug`). "Epic" ≈ a **Project** or a parent
  issue; "status" = workflow **state** (Backlog / Todo / In Progress / Done / Canceled).
---

# Linear adapter

Maps the `tracker` verb contract to Linear via its MCP.

## Permission posture (MCP)

### Native control
The connector's **OAuth grant** — Linear tokens carry an explicit read vs write scope, and that
split is the control: issue **read** (fetch, list, search) vs **write** (create issue, comment,
change state). External posts stay gated by `hard_halt_before_external_posts` at the skill layer
regardless. An official connector's grant lives in its OAuth consent; a CLI-configured server in
its config file; a homegrown server with its owner (forward the suggestion).

### Recommended setting (by policy)
Prefer the narrowest connector grant that still covers the verbs the team uses — a read-scoped
token cannot post at all; comment/create scope is what the hard-halt is protecting, so know which
of the two your connector holds.

### Read-only probe
The read call the auth block already names — it proves reachability and which tools exist:
```
mcp__{mcp}__list-teams()   # read-only (a filtered list-issues works the same)
```
**What it cannot prove, stated plainly:** the connector's grant set is NOT introspectable
read-only from inside the session, so the posture record caps at `status: unverified` and the
posting policy remains GUIDANCE on this path. Confirm the actual grant in the connector's own
settings surface (OAuth consent / server config / its owner) — record the outcome in gitignored
`.claude/config/posture.local.yaml`.

## verb: fetch_ticket
**In:** issue id (e.g. `ENG-123`). **Out:** title, description (markdown), state, assignee, labels,
attachments, parent/project.
```
mcp__{mcp}__get-issue(id=<id>)
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
Linear comments support full markdown links — `[ENG-123](url)`, file links, PR links. Honor
`word_limits.tracker_comment`; never post before human review.

## verb: search
```
list-issues(team={team_id}, query=<text>, filter={state, label, ...})
```

## verb: download_attachments
Read the issue's `attachments{ url }`, `curl -L` each to the dest dir. (Linear attachments are URLs.)

## verb: rank_projects_by_activity
The ranked container is a Linear **team** — not a Linear *Project*, which is this adapter's stand-in
for an epic (see the note above). **In:** `scope` (inert here — the workspace is whatever the OAuth
token is bound to), `window_days` (90), `limit` (5), `scan_cap` (200), `container_cap` (25).
**Out:** `{id, name, activity, last_activity, signal}` per team, most active first,
`signal: items_updated`.
```
mcp__{mcp}__list-teams()                                    # first <container_cap> candidates
mcp__{mcp}__list-issues(team=<teamId>, filter={updatedAt: {gte: <ISO date>}}, limit=<scan_cap>)
```
Count per team and take the newest `updatedAt` as `last_activity`. A team whose count equals
`scan_cap` saturated the scan — rank saturated peers by `last_activity`.

Picking a team sets `seams.tracker.team_id`. It does **not** settle `done_state_id`: workflow state
ids are team-specific (see gotchas), so resolve them from the chosen team afterwards.

Return `unavailable` with the reason when the MCP server is not connected or the token cannot list
teams.

## gotchas
- State ids are team-specific — don't hardcode; resolve from the team's workflow states.
- Linear's native git-branch naming convention pairs well with the `vcs.branch` verb.
