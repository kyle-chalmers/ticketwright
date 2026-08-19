---
seam: tracker
tool: monday
transport: mcp         # MCP ({mcp}); GraphQL under the hood
requires: [board_id, mcp]   # stack.yaml seams.tracker.{board_id, status_column_id, done_label, mcp}
container_key: seams.tracker.board_id   # which config key a ranked container fills (see rank_projects_by_activity)
auth: |
  The monday MCP server (`{mcp}`) must be connected (OAuth).
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
mcp__{mcp}__get-item(item_id=<id>)
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

## verb: rank_projects_by_activity
The ranked container is a **board** — monday has no project concept. **In:** `scope` (the
workspace), `window_days` (90), `limit` (5), `container_cap` (25). **Out:** `{id, name, activity,
last_activity, signal}` per board, ordered by `last_activity`, with `activity: null` and
`signal: container_updated_at`.
```
mcp__{mcp}__list-boards(workspace_ids=[<scope>], limit=<container_cap>)
# or GraphQL: boards(workspace_ids:[<scope>], limit:<container_cap>){ id name updated_at }
```
**This is a recency signal, not an item count, and the output says so.** Per-item counts are refused
deliberately: monday rate-limits GraphQL by complexity (see gotchas), and counting items across
every board in a workspace is exactly the query shape that trips it. Be honest about the weakness
too — a board's `updated_at` moves on *any* mutation, including a column or settings edit, so a
recently reconfigured but idle board can outrank a busy one. Treat the result as a default the human
confirms, never an auto-selection.

Picking a board sets `seams.tracker.board_id`. It does **not** settle `status_column_id` or
`done_label` — both are per-board, and gotchas below warns against assuming them.

Return `unavailable` with the reason when the MCP server is not connected or the token cannot list
boards.

## gotchas
- Status changes require the exact **label text** the board defines — fetch the column's labels first.
- monday rate-limits GraphQL by complexity; batch item reads rather than looping single-item calls.
