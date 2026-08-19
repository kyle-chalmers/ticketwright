---
seam: tracker
tool: azure-devops
transport: cli         # `az boards` (Azure CLI + azure-devops extension); REST API as fallback
requires: [org, project]   # stack.yaml seams.tracker.{org, project, done_state}
container_key: seams.tracker.project   # which config key a ranked container fills (see rank_projects_by_activity)
auth: |
  `az login` + the devops extension: `az extension add --name azure-devops`.
  Set defaults: `az devops configure --defaults organization=https://dev.azure.com/{org} project={project}`.
  A PAT (env `AZURE_DEVOPS_EXT_PAT`) works for non-interactive/CI.
  Verify: `az devops project show --project {project}` (read-only; no epic needed).
note: |
  Azure Boards "work items" are the tickets; ids are plain integers (e.g. 1234), so `key_prefix` is a
  display convention, not part of the id. "Epic" is a work-item type (Epic→Feature→User Story→Task)
  linked via parent/child relations; "status" = the work item's **State** (New / Active / Resolved /
  Closed, or your process's states). Convention: name ticket folders/branches `{key_prefix}-<number>`
  so the index discovers them, but set `ticket_url_template` to use the `{number}` token (not `{id}`)
  and pass the bare integer to `az boards` — the work-item URL and CLI need the number, not the prefix.
---

# Azure DevOps (Boards) adapter

Maps the `tracker` verb contract to Azure Boards via the `az boards` CLI.

## verb: fetch_ticket
**In:** work-item id (integer). **Out:** title, description, state, type, assignee, relations, attachments.
```bash
az boards work-item show --id <id> --output json
```
Description is `fields."System.Description"` (HTML). Relations (parents, attachments) are in `relations`.

## verb: create_ticket
```bash
az boards work-item create --title "<summary>" --type "User Story" \
  --assigned-to "<email>" --fields "System.Description=<html/desc>" --output json
# link to an epic/feature parent (only when default_epic is set):
az boards work-item relation add --id <new-id> --relation-type parent --target-id {default_epic}
```
Returns the new integer id + `_links.html.href` (the URL).

## verb: transition
```bash
az boards work-item update --id <id> --state "<State>"      # e.g. {done_state} for terminal_status
```
States are process-specific (Agile: New/Active/Resolved/Closed; Basic: To Do/Doing/Done) — map
`project.terminal_status` → `{done_state}`.

## verb: comment
```bash
az boards work-item update --id <id> --discussion "<body>"   # adds a comment to the work item
```
Discussion accepts HTML (links render). Honor `word_limits.tracker_comment`; never post before review.

## verb: search
```bash
az boards query --wiql "SELECT [System.Id],[System.Title],[System.State] FROM workitems \
  WHERE [System.TeamProject]='{project}' AND [System.Title] CONTAINS '<text>' \
  ORDER BY [System.ChangedDate] DESC" --output json
```

## verb: download_attachments
`az boards work-item show --id <id>` → `relations[?rel=='AttachedFile']`. Each has a `url`;
`curl -L -u :$AZURE_DEVOPS_EXT_PAT "<url>" -o <dest>/<name>` (silent if none).

## verb: rank_projects_by_activity
The ranked container is an Azure Boards **project**. **In:** `scope` (the org), `window_days` (90),
`limit` (5), `scan_cap` (200), `container_cap` (25). **Out:** `{id, name, activity, last_activity,
signal}` per project, most active first, `signal: items_updated`.
```bash
az devops project list --org "https://dev.azure.com/<scope>" --output json   # first <container_cap>
az boards query --org "https://dev.azure.com/<scope>" --project "<candidate>" --output json \
  --wiql "SELECT [System.Id],[System.ChangedDate] FROM workitems \
          WHERE [System.TeamProject]='<candidate>' AND [System.ChangedDate] >= @today-<window_days>"
```
**Pass `--org` and `--project` explicitly on every call.** The auth block above configures a single
default project — the very value being chosen here — so relying on the default silently queries the
old one. `az boards query` has no result-limit flag, so `scan_cap` is applied client-side after the
full result set comes back; it bounds what you count, not what the wire returns.

Picking a project sets `seams.tracker.project`. It does **not** settle `done_state` — state names
are process-specific (see gotchas), so resolve them from the chosen project.

Return `unavailable` with the reason when `az login` is missing, the devops extension is absent, or
the identity cannot list projects at org level.

## gotchas
- Ids are integers, not prefixed — keep `key_prefix` for branches/index display, but `fetch_ticket`
  takes the bare number.
- State names differ per process template — resolve `{done_state}` from the project, don't assume "Done".
- HTML (not markdown) in description/discussion fields.
