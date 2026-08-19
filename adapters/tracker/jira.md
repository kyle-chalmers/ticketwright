---
seam: tracker
tool: jira
transport: both        # acli (CLI) for reads/creates/transitions; Atlassian MCP for rich comments
requires: [site, cli]  # stack.yaml seams.tracker.{site, cli, mcp, default_epic, terminal_status}
container_key: project.key_prefix   # which config key a ranked container fills (see rank_projects_by_activity)
auth: |
  CLI:  acli jira auth   (token in ~/.config/acli/token.txt; site/email in jira_config.yaml)
  MCP:  the tracker's MCP server (`{mcp}`, e.g. an Atlassian connector) must be connected (OAuth). Used for comment rendering.
  Verify: `acli jira workitem search --jql "project = {key_prefix}" --limit 1` (read-only; no epic needed).
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
**In:** type, summary, description, assignee (email), optional parent/epic.
```bash
acli jira workitem create \
  --project "{key_prefix}" --type "<TYPE>" \
  --summary "<SUMMARY>" --description "<DESC>" \
  --assignee "<email>"
# add --parent "{default_epic}" only when default_epic is set (some projects require a parent Epic; many don't)
```
Notes: assignee is the **email**, not the username. `--type` must match your project's issue-type
scheme (common defaults: Task, Story, Bug, Epic) — list yours from the project's issue-type metadata.
If your project *requires* a parent Epic, `create` fails without `--parent`; set `default_epic` in
stack.yaml so it's passed automatically.

## verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>"
```
The done state is `{terminal_status}` (defaults to `Done`; set it to your workflow's terminal state).
Status names are workflow-specific — don't assume a fixed ladder; resolve the valid target statuses
from your Jira workflow (the project's board columns / transitions).

## verb: comment
Use the tracker's **MCP** (`{mcp}`), not acli — the MCP renders ADF (clickable links/mentions); acli posts plain text.
```
mcp__{mcp}__addCommentToJiraIssue(cloudId, issueIdOrKey=<id>, commentBody=<ADF>)
```
Tool/param names vary by MCP server — confirm once against your connected server (its name is `{mcp}` in stack.yaml).
For a clickable Google-Drive Smart Link, embed an `inlineCard` ADF node with the file URL (see
docstore/gdrive.md `link_for`). Plain text only otherwise — Jira has its own formatter (no markdown).
Honor `word_limits.tracker_comment`. **Never post until the human has reviewed** (policy
`hard_halt_before_external_posts`).

## verb: search
```bash
acli jira workitem search --jql "<JQL>" --limit <N> --json   # --csv / --fields also supported
# MCP alt: mcp__{mcp}__searchJiraIssuesUsingJql
```
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

## verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments — to DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```

## verb: rank_projects_by_activity
The ranked container is a Jira **project**. **In:** `scope` (the Jira site), `window_days` (90),
`limit` (5), `scan_cap` (200), `container_cap` (25). **Out:** `{id, name, activity, last_activity,
signal}` per project, most active first, `signal: items_updated`.
```bash
acli jira project list --json                          # candidates; take the first {container_cap}
acli jira workitem search --json --limit <scan_cap> \
  --jql "project in (<K1>,<K2>,…) AND updated >= -<window_days>d ORDER BY updated DESC"
```
**Group by the issue key's prefix, and take `last_activity` from the ordering — not from fields.**
`acli jira workitem search` does not accept a field selector on every build, so do not assume a
`project` or `updated` column is present. Both are recoverable without one: every Jira key is
`<PROJECT>-<number>` (`ENG-1234` ⇒ project `ENG`), and the JQL already sorts `updated DESC`, so the
**first** row bearing a project's prefix is that project's most recent activity. Row count per
prefix is `activity`.

**One search, not one per project** — fanning out N calls is the fast route into the `acli` MFA
lockout in gotchas below. When the total row count equals `scan_cap` the scan saturated, so the
counts are `>= scan_cap` and truncation may have cut a quiet project off entirely; rank the
saturated peers by `last_activity` and say the scan was capped.

Picking a project sets `project.key_prefix` (this adapter's `container_key`) — a `project:` key, not
a tracker seam key. It does **not** settle `default_epic` or `terminal_status`; resolve those from
the chosen project's issue-type scheme and workflow.

Return `unavailable` with the reason when `acli` is unauthenticated or the token cannot list
projects — the caller says that line, then asks as it would have anyway.

## gotchas
- `acli` Duo/MFA: an instant `250001/370001` = lockout (wait 15 min, don't retry); a hang = push pending.
- If your project requires a parent Epic, a link error means `--parent` was missing (set `default_epic`). "User not found" ⇒ use the exact email.
