---
seam: tracker
tool: jira
transport: both        # acli (CLI) for reads/creates/transitions; Atlassian MCP for rich comments
requires: [site, cli]  # stack.yaml seams.tracker.{site, cli, mcp, default_epic, terminal_status}
container_key: project.key_prefix   # which config key a ranked container fills (see rank_projects_by_activity)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
default_surface: claude-code   # the runtime the `## verb:` sections' MCP calls were checked on (the Atlassian connector's own tool names, 2026-10-25)
surfaces: [codex-cli]          # runtimes that list this connector under other tool names: one `## Runtime surface:` section each, picked by bin/adapter_surface.py
auth: |
  CLI:  acli jira auth   (token in ~/.config/acli/token.txt; site/email in jira_config.yaml)
  MCP:  the tracker's MCP server (`{mcp}`, e.g. an Atlassian connector) must be connected (OAuth). Used for comment rendering.
        On a runtime with its own section below, that section's MCP calls and probe instead
        (`bin/adapter_surface.py --probe` prints it).
  Verify: `acli jira workitem search --jql "project = {key_prefix}" --limit 1` (read-only; no epic needed).
---

# Jira adapter

Maps the `tracker` verb contract to Atlassian Jira via the `acli` CLI and the Atlassian MCP server.
Reads/creates/transitions go through `acli`; **comments go through the MCP** because the connector
converts the comment to Jira's rich format (ADF), so links render clickable (acli posts plain
text, where links don't render).

## Permission posture (MCP)

### Native control
This adapter is dual-transport, and the two paths have different controls. The CLI path
authenticates as the person (`acli jira auth` token) — the `hard_halt_before_external_posts`
policy stays the gate at the skill layer either way. The MCP path's control is the connector's
**OAuth grant**: which Atlassian scopes it was consented — read (work-item/search) vs write
(comment/transition). What matters here is the read-vs-comment split, since comments are exactly
what this adapter routes through the MCP. An official connector's grant lives in its OAuth
consent; a CLI-configured server in its config file; a homegrown server with its owner (forward
the suggestion).

### Recommended setting (by policy)
`hard_halt_before_external_posts` is carried at the skill layer (nothing posts before a human
go), not by either transport — so prefer the narrowest connector grant that still covers the
comment verb you actually use, and know which grants matter: read-scoped consent cannot post at
all; comment/write consent is the thing the hard-halt is protecting.

### Read-only probe
One read per transport (the MCP read needs the site's `cloudId`, so the site list comes first):
```
acli jira workitem search --jql "project = {key_prefix}" --limit 1    # CLI path, read-only
mcp__{mcp}__getAccessibleAtlassianResources()                          # MCP path, read-only: the sites this account reaches
mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="project = {key_prefix}", maxResults=1)   # read-only
```
Check that one resource's URL has `{site}` as its host: no match means the connector is signed in to another
Atlassian account, and a comment would fail or land on the wrong site.
**What the MCP probe cannot prove, stated plainly:** the connector's grant set is NOT
introspectable read-only from inside the session, so the posture record caps at
`status: unverified` and the posting policy remains GUIDANCE on this path. Confirm the actual
grant in the connector's own settings surface (OAuth consent / server config / its owner) —
record the outcome in gitignored `.claude/config/posture.local.yaml`.

## verb: fetch_ticket
**In:** `id` (e.g. `TEST-1234`). **Out:** title, description, status, type, assignee, links.
```bash
acli jira workitem view <id>
```
For structured fields: `acli jira workitem view <id> --json`.
**People, for `/ship`'s audience suggestions:** `reporter` is `fields.reporter` in the `--json` output (display name and, when the site shows it, email). `watchers`: not available (`fields.watches` carries a count only, not the people).

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
scheme (common defaults: Task, Story, Bug, Epic); list yours from the project's issue-type metadata.
If your project *requires* a parent Epic, `create` fails without `--parent`; set `default_epic` in
stack.yaml so it's passed automatically.

## verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>"
```
The done state is `{terminal_status}` (defaults to `Done`; set it to your workflow's terminal state).
Status names are workflow-specific: don't assume a fixed ladder; resolve the valid target statuses
from your Jira workflow (the project's board columns / transitions).

## verb: comment
Use the tracker's **MCP** (`{mcp}`), not acli: the connector converts the comment to ADF, so links
render clickable; acli posts plain text.
```
mcp__{mcp}__getAccessibleAtlassianResources()   # once per session: the cloudId of the site at {site}
mcp__{mcp}__addOrEditJiraIssueComment(cloudId=<that cloudId>, issueIdOrKey=<id>, commentBody=<the reviewed comment, Markdown>, contentFormat="markdown")
```
Take the `cloudId` of the resource whose URL's host is `{site}` (the URL carries `https://`;
`{site}` is the bare host). If none matches, STOP and report: never post to another site the
account can reach. The body is Markdown, which the connector converts:
links as `[text](URL)` (ticket keys, PRs, and a Google Drive file's exact URL from docstore/gdrive.md
`link_for`). The tool takes Markdown or HTML, never raw ADF, so an `inlineCard` node cannot be
passed; whether Jira shows a Drive link as a Smart Link card was not checked. An @mention cannot be
written in Markdown here, so name the person in plain words. Never pass `commentId`: with one, the
tool edits that existing comment and replaces its whole body. These are the names the Atlassian
connector lists (checked 2026-10-25); a different Jira MCP server names its tools its own way, so
check its tool list once (its name is `{mcp}` in stack.yaml).
Honor `word_limits.tracker_comment`. **Never post until the human has reviewed** (policy
`hard_halt_before_external_posts`).

## verb: search
```bash
acli jira workitem search --jql "<JQL>" --limit <N> --json   # --csv / --fields also supported
# MCP alt: mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<N>)
```
The MCP alternative needs the `cloudId` of `{site}`: list the sites once per session
(`mcp__{mcp}__getAccessibleAtlassianResources()`) and take the one whose URL's host is `{site}`. If
none matches, STOP and report rather than search another site.
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

## verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments. To DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```

## verb: rank_projects_by_activity
The ranked container is a Jira **project**. **In:** `scope` (the Jira site), `window_days` (90),
`limit` (5), `scan_cap` (200), `container_cap` (25). **Out:** `{id, name, activity, last_activity,
signal}` per project, most active first, `signal: items_updated`.
```bash
acli jira project list --limit {container_cap} --json  # candidates; the CLI ERRORS without one of --recent/--limit/--paginate
acli jira workitem search --json --limit <scan_cap> \
  --jql "project in (<K1>,<K2>,…) AND updated >= -<window_days>d ORDER BY updated DESC"
```
**Group by the issue key's prefix, and take `last_activity` from the ordering, not from fields.**
`acli jira workitem search` does not accept a field selector on every build, so do not assume a
`project` or `updated` column is present. Both are recoverable without one: every Jira key is
`<PROJECT>-<number>` (`TEST-1234` ⇒ project `TEST`), and the JQL already sorts `updated DESC`, so the
**first** row bearing a project's prefix is that project's most recent activity. Row count per
prefix is `activity`.

`last_activity` is that first row's `updated` when the JSON carries the field, and `null` when it
does not. Report the null rather than inventing a date. Ranking is unaffected either way: the rows
arrive in recency order, so relative position is known even when the timestamp is not.

**One search, not one per project**: fanning out N calls is the fast route into the `acli` MFA
lockout (an instant `250001/370001` error is a lockout: wait 15 minutes and do not retry; a hang
is a push still pending). When the total row count equals `scan_cap` the scan saturated, so the
counts are `>= scan_cap` and truncation may have cut a quiet project off entirely; rank the
saturated peers by `last_activity` and say the scan was capped.

Picking a project sets `project.key_prefix` (this adapter's `container_key`), a `project:` key, not
a tracker seam key. It does **not** settle `default_epic` or `terminal_status`; resolve those from
the chosen project's issue-type scheme and workflow.

Return `unavailable` with the reason when `acli` is unauthenticated or the token cannot list
projects. The caller says that line, then asks as it would have anyway.

## gotchas
- `acli` Duo/MFA: an instant `250001/370001` = lockout (wait 15 min, don't retry); a hang = push pending.
- If your project requires a parent Epic, a link error means `--parent` was missing (set `default_epic`). "User not found" ⇒ use the exact email.
- Tool names differ by agent on the MCP path: Codex CLI lists the Atlassian connector under other
  names (in its own section of this file). `bin/adapter_surface.py --adapter
  adapters/tracker/jira.md` picks the right section for the agent running now. A name missing from
  your session's tool list is a gap to report so the kit can record it, never a local edit to
  this file: an edited copy silently drifts from the kit on the next upgrade.

## Runtime surface: codex-cli

server: codex_apps

Codex CLI reaches Jira through the ChatGPT Atlassian app: its tools sit under the one server
`codex_apps` as `atlassian_` plus the connector's own tool name in lower case, so
`addOrEditJiraIssueComment` arrives as `atlassian_addoreditjiraissuecomment`. It is the same
Atlassian server the default sections describe, so the arguments are its own: a `cloudId` on
every Jira call, resolved once per session, and a Markdown comment body. Observed 2026-10-24 from
the connector's tool declarations in a Codex CLI session: the comment and site-list declarations
were captured in full, while the search tool's arguments were not and are the same server's
schema as Claude lists it (2026-10-25). The app also lists an older `atlassian_rovo__legacy__*`
family; this adapter does not use it. Only the MCP path differs by agent: the `acli` commands are
the same everywhere, so the CLI verbs below repeat the default sections word for word. The rules
of the default sections hold unchanged here: nothing posts before a human has reviewed it (policy
`hard_halt_before_external_posts`), and a comment goes only to the site at `{site}`.

### verb: fetch_ticket
**In:** `id` (e.g. `TEST-1234`). **Out:** title, description, status, type, assignee, links.
```bash
acli jira workitem view <id>
```
For structured fields: `acli jira workitem view <id> --json`.
**People, for `/ship`'s audience suggestions:** `reporter` is `fields.reporter` in the `--json` output (display name and, when the site shows it, email). `watchers`: not available (`fields.watches` carries a count only, not the people).

### verb: create_ticket
**In:** type, summary, description, assignee (email), optional parent/epic.
```bash
acli jira workitem create \
  --project "{key_prefix}" --type "<TYPE>" \
  --summary "<SUMMARY>" --description "<DESC>" \
  --assignee "<email>"
# add --parent "{default_epic}" only when default_epic is set (some projects require a parent Epic; many don't)
```
Notes: assignee is the **email**, not the username. `--type` must match your project's issue-type
scheme (common defaults: Task, Story, Bug, Epic); list yours from the project's issue-type metadata.
If your project *requires* a parent Epic, `create` fails without `--parent`; set `default_epic` in
stack.yaml so it's passed automatically.

### verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>"
```
The done state is `{terminal_status}` (defaults to `Done`; set it to your workflow's terminal state).
Status names are workflow-specific: don't assume a fixed ladder; resolve the valid target statuses
from your Jira workflow (the project's board columns / transitions).

### verb: comment
Use the MCP path, not acli: the connector converts the comment to ADF, so links render clickable;
acli posts plain text.
```
mcp__codex_apps__atlassian_getaccessibleatlassianresources({})   # once per session: the cloudId of the site at {site}
mcp__codex_apps__atlassian_addoreditjiraissuecomment(cloudId=<that cloudId>, issueIdOrKey=<id>, commentBody=<the reviewed comment, Markdown>, contentFormat="markdown")
```
Take the `cloudId` of the resource whose URL's host is `{site}` (the URL carries `https://`;
`{site}` is the bare host). If none matches, STOP and report: never post to another site the
account can reach. The body is Markdown, which the connector converts:
links as `[text](URL)` (ticket keys, PRs, and a Google Drive file's exact URL from docstore/gdrive.md
`link_for`). The tool takes Markdown or HTML, never raw ADF; whether Jira shows a Drive link as a
Smart Link card was not checked. An @mention cannot be written in Markdown here, so name the person
in plain words. Never pass `commentId`: with one, the tool edits that existing comment and
replaces its whole body.
Honor `word_limits.tracker_comment`. **Never post until the human has reviewed** (policy
`hard_halt_before_external_posts`).

### verb: search
```bash
acli jira workitem search --jql "<JQL>" --limit <N> --json   # --csv / --fields also supported
# MCP alt: mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<N>)
```
The MCP alternative needs the `cloudId` of `{site}`: list the sites once per session
(`mcp__codex_apps__atlassian_getaccessibleatlassianresources({})`) and take the one whose URL's host
is `{site}`. If none matches, STOP and report rather than search another site.
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

### verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments. To DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```

### verb: rank_projects_by_activity
The ranked container is a Jira **project**. **In:** `scope` (the Jira site), `window_days` (90),
`limit` (5), `scan_cap` (200), `container_cap` (25). **Out:** `{id, name, activity, last_activity,
signal}` per project, most active first, `signal: items_updated`.
```bash
acli jira project list --limit {container_cap} --json  # candidates; the CLI ERRORS without one of --recent/--limit/--paginate
acli jira workitem search --json --limit <scan_cap> \
  --jql "project in (<K1>,<K2>,…) AND updated >= -<window_days>d ORDER BY updated DESC"
```
**Group by the issue key's prefix, and take `last_activity` from the ordering, not from fields.**
`acli jira workitem search` does not accept a field selector on every build, so do not assume a
`project` or `updated` column is present. Both are recoverable without one: every Jira key is
`<PROJECT>-<number>` (`TEST-1234` ⇒ project `TEST`), and the JQL already sorts `updated DESC`, so the
**first** row bearing a project's prefix is that project's most recent activity. Row count per
prefix is `activity`.

`last_activity` is that first row's `updated` when the JSON carries the field, and `null` when it
does not. Report the null rather than inventing a date. Ranking is unaffected either way: the rows
arrive in recency order, so relative position is known even when the timestamp is not.

**One search, not one per project**: fanning out N calls is the fast route into the `acli` MFA
lockout (an instant `250001/370001` error is a lockout: wait 15 minutes and do not retry; a hang
is a push still pending). When the total row count equals `scan_cap` the scan saturated, so the
counts are `>= scan_cap` and truncation may have cut a quiet project off entirely; rank the
saturated peers by `last_activity` and say the scan was capped.

Picking a project sets `project.key_prefix` (this adapter's `container_key`), a `project:` key, not
a tracker seam key. It does **not** settle `default_epic` or `terminal_status`; resolve those from
the chosen project's issue-type scheme and workflow.

Return `unavailable` with the reason when `acli` is unauthenticated or the token cannot list
projects. The caller says that line, then asks as it would have anyway.

### Permission posture on this runtime
The CLI path is unchanged: `acli` authenticates as the person. The MCP path's control is the
Atlassian app's connection for the signed-in ChatGPT account: which Atlassian account and sites it
reaches, and whether its grant covers commenting. That grant is NOT introspectable from inside the
session, so the posture record caps at `status: unverified` exactly as above; confirm it where the
app was connected and record the outcome in `.claude/config/posture.local.yaml`.

### Read-only probe
```
acli jira workitem search --jql "project = {key_prefix}" --limit 1    # CLI path, read-only
mcp__codex_apps__atlassian_getaccessibleatlassianresources({})         # MCP path, read-only: the sites this account reaches
mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="project = {key_prefix}", maxResults=1)   # read-only
```
Check that one resource's URL has `{site}` as its host: no match means the app is signed in to another
Atlassian account, and a comment would fail or land on the wrong site.
