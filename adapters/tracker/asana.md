---
seam: tracker
tool: asana
transport: mcp         # MCP; server name = seams.tracker.mcp ({mcp})
requires: [workspace_gid, mcp]   # stack.yaml seams.tracker.{workspace_gid, default_project_gid, mcp}
container_key: seams.tracker.default_project_gid   # which config key a ranked container fills (see rank_projects_by_activity)
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
```
mcp__{mcp}__search-tasks(workspace=<scope>, projects.any=<project gid>,
                         modified_on.after=<ISO date>, limit=<scan_cap>)
```
Query per candidate project rather than grouping one broad search: a task carries **multiple**
project memberships, so grouping search hits double-counts it into every project it belongs to.
Bound the candidate list at `container_cap`.

Picking a project sets `seams.tracker.default_project_gid`; `workspace_gid` comes from `scope`.
The key prefix is unaffected — per the note above, Asana has no native id prefix.

**Return `unavailable` on a free workspace.** Asana's task-search endpoint is a paid-tier feature and
will refuse outright there; it also has no offset pagination, so `scan_cap` is a ceiling you may not
be able to reach on a busy project. Say which of the two happened rather than reporting a low count
as if the project were quiet.
