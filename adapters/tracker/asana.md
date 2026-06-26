---
seam: tracker
tool: asana
transport: mcp         # mcp__plugin_productivity_asana__*
requires: [workspace_gid]   # stack.yaml seams.tracker.{workspace_gid, default_project_gid}
auth: |
  The `asana` MCP server (plugin_productivity_asana) must be connected (OAuth).
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
mcp__plugin_productivity_asana__* get-task(task_gid=<id>)
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
