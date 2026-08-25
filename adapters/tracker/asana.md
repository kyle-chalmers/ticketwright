---
seam: tracker
tool: asana
transport: mcp         # MCP; server name = seams.tracker.mcp ({mcp})
requires: [workspace_gid, mcp]   # stack.yaml seams.tracker.{workspace_gid, default_project_gid, mcp}
container_key: seams.tracker.default_project_gid   # which config key a ranked container fills (see rank_projects_by_activity)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  The Asana MCP server (`{mcp}`) must be connected (OAuth).
  Verify: an Asana MCP "list workspaces" / "typeahead search" call returns without error.
note: |
  Asana has no "Epic" concept — `default_epic` maps to a parent task or a project section.
  Asana task GIDs are the ticket "id"; there is no DI-style prefix, so set project.key_prefix to a
  short tag you add to task names (e.g. "DI") if you want branch parity.
---

# Asana adapter (reference for the abstraction proof)

Maps the `tracker` verb contract to Asana via its MCP. Demonstrates that swapping Jira→Asana is a
**config + adapter** change with **zero skill edits** — the skills still call `tracker.fetch_ticket`.

## Permission posture (MCP)

### Native control
The connector's **OAuth grant** — which Asana scopes it was authorized with. The grants that
matter are the read-vs-write split: task/project **read** (fetch, search) vs **write** (create
task, comment, move section). External posts stay gated by `hard_halt_before_external_posts` at
the skill layer regardless. An official connector's grant lives in its OAuth consent; a
CLI-configured server in its config file; a homegrown server with its owner (forward the
suggestion).

### Recommended setting (by policy)
Prefer the narrowest connector grant that still covers the verbs the team uses — read-scoped
consent cannot post at all; comment/create consent is what the hard-halt is protecting, so know
which of the two your connector holds.

### Read-only probe
The read call the auth block already names — it proves reachability and which tools exist:
```
mcp__{mcp}__list-workspaces()   # read-only (the server's typeahead search works the same)
```
**What it cannot prove, stated plainly:** the connector's grant set is NOT introspectable
read-only from inside the session, so the posture record caps at `status: unverified` and the
posting policy remains GUIDANCE on this path. Confirm the actual grant in the connector's own
settings surface (OAuth consent / server config / its owner) — record the outcome in gitignored
`.claude/config/posture.local.yaml`.

## verb: fetch_ticket
**In:** task GID. **Out:** name, notes, status (section/custom field), assignee, links, attachments.
```
mcp__{mcp}__get-task(task_gid=<id>)
```

## verb: create_ticket
```
create-task(workspace={workspace_gid}, projects=[{default_project_gid}],
            name=<summary>, notes=<desc>, assignee=<email/gid>)
```
Parent/epic → set `parent` task GID or add to a project section instead of `--parent`.

## verb: transition
Asana "status" = moving a task between **sections** or setting a custom field.
```
update-task(task_gid=<id>, ...) / add-task-to-section(section_gid=<terminal_status section>)
```
`terminal_status` in stack.yaml names the "done" section.

## verb: comment
```
create-task-comment(task_gid=<id>, text=<body with URLs>)
```
Asana stories render URLs inline. Honor `word_limits.tracker_comment`; never post pre-review.

## verb: search
```
search-tasks(workspace={workspace_gid}, text=<topic>)   # or typeahead-search
```

## verb: download_attachments
```
get-attachments-for-task(task_gid=<id>)  → download each attachment's `download_url` with curl
```
(No prebuilt script like Jira's — fall back to curl per attachment.)

## verb: rank_projects_by_activity
The ranked container is an Asana **project** — the `default_project_gid` kind, not the "project
section" this adapter uses as an epic stand-in. **In:** `scope` (the `workspace_gid`),
`window_days` (90), `limit` (5), `scan_cap` (200), `container_cap` (25). **Out:** `{id, name,
activity, last_activity, signal}` per project, most active first, `signal: items_updated`.
Two steps — **candidates first**, then a count per candidate:
```
mcp__{mcp}__list-projects(workspace=<scope>, limit=<container_cap>)   # or the server's projects op
mcp__{mcp}__search-tasks(workspace=<scope>, projects.any=<project gid>,
                         modified_on.after=<ISO date>, limit=<scan_cap>)
```
Count per candidate project rather than grouping one broad search: a task carries **multiple**
project memberships, so grouping search hits double-counts it into every project it belongs to.

The projects-listing op is the one operation here this adapter does not use elsewhere, and its name
varies by server (see the MCP caveat in `adapters/README.md`). Confirm it once against your
connected server; if it exposes no way to enumerate a workspace's projects, there is no candidate
set and the verb returns `unavailable` naming that — do not substitute `typeahead-search`, which
ranks by name similarity and would reintroduce the exact bias this verb removes.

Picking a project sets `seams.tracker.default_project_gid`; `workspace_gid` comes from `scope`.
The key prefix is unaffected — per the note above, Asana has no native id prefix.

**Return `unavailable` on a free workspace.** Asana's task-search endpoint is a paid-tier feature and
will refuse outright there; it also has no offset pagination, so `scan_cap` is a ceiling you may not
be able to reach on a busy project. Say which of the two happened rather than reporting a low count
as if the project were quiet.
