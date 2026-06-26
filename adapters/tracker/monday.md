---
seam: tracker
tool: monday
transport: mcp         # mcp__plugin_productivity_monday__*  (GraphQL under the hood)
requires: [board_id]   # stack.yaml seams.tracker.{board_id, status_column_id, done_label}
auth: |
  The `monday` MCP server (plugin_productivity_monday) must be connected (OAuth).
  Verify: a read-only board/items query returns without error.
note: |
  monday models work as **items** on **boards**. "Status" is a status **column** (set by label),
  not a workflow transition; "epic" maps to a parent item or a board **group**. There is no DI-style
  id prefix — item ids are numeric, so set project.key_prefix to a short tag you put in item names if
  you want branch parity (e.g. branch "OPS-<itemId>").
---

# monday.com adapter

Maps the `tracker` verb contract to monday.com via its MCP (GraphQL items API).

## verb: fetch_ticket
**In:** item id. **Out:** name, column values (incl. status), updates, assignee, file-column assets.
```
mcp__plugin_productivity_monday__* get-item(item_id=<id>)
# or GraphQL: items(ids:[<id>]){ name column_values{ id text value } updates{ body } assets{ url } }
```

## verb: create_ticket
```
create-item(board_id={board_id}, item_name=<summary>,
            column_values={ "status": {"label":"<initial>"}, "person": {"personsAndTeams":[…]} })
```
Parent/epic → create as a **subitem** of the parent item, or place in the epic **group** (`group_id`).
monday has no `--parent` flag; the group/subitem is the equivalent.

## verb: transition
"Status" = set the status column's label to `{done_label}` (or any workflow label).
```
change-column-value(item_id=<id>, board_id={board_id}, column_id={status_column_id},
                    value="{\"label\":\"<status>\"}")
```
`project.terminal_status` maps to `{done_label}`.

## verb: comment
```
create-update(item_id=<id>, body=<text with URLs>)
```
Updates render links inline. Honor `word_limits.tracker_comment`. Never post before human review
(policy `hard_halt_before_external_posts`).

## verb: search
```
items-page-by-column-values(board_id={board_id}, columns=[…])   # filter by column
# or a text query across the board's items
```

## verb: download_attachments
Read the item's **file column** `assets{ url }`, then `curl -L <asset url> -o <dest>` per file.
(No prebuilt script like Jira's.)

## gotchas
- Status changes require the exact **label text** the board defines — fetch the column's labels first.
- monday rate-limits GraphQL by complexity; batch item reads rather than looping single-item calls.
