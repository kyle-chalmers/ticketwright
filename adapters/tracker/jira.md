---
seam: tracker
tool: jira
transport: both        # acli (CLI) for reads/creates/transitions; Atlassian MCP for rich comments
requires: [site, cli]  # stack.yaml seams.tracker.{site, cli, mcp, default_epic, terminal_status}
auth: |
  CLI:  acli jira auth   (token in ~/.config/acli/token.txt; site/email in jira_config.yaml)
  MCP:  the `atlassian` MCP server must be connected (OAuth). Used for comment rendering.
  Verify: `acli jira workitem view {default_epic}` (read-only).
---

# Jira adapter

Maps the `tracker` verb contract to Atlassian Jira via the `acli` CLI and the Atlassian MCP server.
Reads/creates/transitions go through `acli`; **comments go through the MCP** because ADF renders
clickable smart links and @mentions (acli posts plain text — links don't render).

## verb: fetch_ticket
**In:** `id` (e.g. `ENG-1234`). **Out:** title, description, status, type, assignee, links.
```bash
acli jira workitem view <id>
```
For structured fields: `acli jira workitem view <id> --json`.

## verb: create_ticket
**In:** type, summary, description, assignee (email), parent/epic.
```bash
acli jira workitem create \
  --project "{key_prefix}" --type "<TYPE>" \
  --summary "<SUMMARY>" --description "<DESC>" \
  --assignee "<email>" --parent "<epic or {default_epic}>"
```
Notes: **every DI type needs `--parent` (an Epic)** or create fails. Assignee is the **email**, not
username. Valid types: Reporting, Data Pull, Automation, Dashboard, Research, Data Engineering Task,
Data Engineering Bug, Epic.

## verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>"
```
The done state is `{terminal_status}` (here `Deployed`, not "Done"). Common: Backlog, In Spec,
In-Progress, Blocked, Deployed.

## verb: comment
Use the **Atlassian MCP**, not acli — ADF format renders links/mentions.
```
mcp__atlassian__addCommentToJiraIssue(cloudId, issueIdOrKey=<id>, commentBody=<ADF>)
```
For a clickable Google-Drive Smart Link, embed an `inlineCard` ADF node with the file URL (see
docstore/gdrive.md `link_for`). Plain text only otherwise — Jira has its own formatter (no markdown).
Honor `word_limits.tracker_comment`. **Never post until the human has reviewed** (policy
`hard_halt_before_external_posts`).

## verb: search
```bash
acli jira workitem search --jql "<JQL>" --limit <N> --json   # --csv / --fields also supported
# MCP alt: mcp__atlassian__searchJiraIssuesUsingJql
```
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

## verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments — to DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```

## gotchas
- `acli` Duo/MFA: an instant `250001/370001` = lockout (wait 15 min, don't retry); a hang = push pending.
- Epic link errors ⇒ you forgot `--parent`. "User not found" ⇒ use the exact email.
