---
seam: tracker
tool: azure-devops
transport: cli         # `az boards` (Azure CLI + azure-devops extension); REST API as fallback
requires: [org, project]   # stack.yaml seams.tracker.{org, project, done_state}
auth: |
  `az login` + the devops extension: `az extension add --name azure-devops`.
  Set defaults: `az devops configure --defaults organization=https://dev.azure.com/{org} project={project}`.
  A PAT (env `AZURE_DEVOPS_EXT_PAT`) works for non-interactive/CI.
  Verify: `az boards work-item show --id {default_epic}` (read-only) or `az devops project show`.
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
# link to an epic/feature parent:
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

## gotchas
- Ids are integers, not prefixed — keep `key_prefix` for branches/index display, but `fetch_ticket`
  takes the bare number.
- State names differ per process template — resolve `{done_state}` from the project, don't assume "Done".
- HTML (not markdown) in description/discussion fields.
