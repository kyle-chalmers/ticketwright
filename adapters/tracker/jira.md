---
seam: tracker
tool: jira
transport: both        # acli when it is installed and signed in here, otherwise the Atlassian connector (MCP); comments always go through the connector
requires: [site]       # stack.yaml seams.tracker.{site, cli?, mcp?, default_epic, terminal_status}
requires_by_transport: {cli: [cli], mcp: [mcp], both: [mcp]}   # acli is optional: a connector-only slot sets transport: mcp and no cli
container_key: project.key_prefix   # which config key a ranked container fills (see rank_projects_by_activity)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
default_surface: claude-code   # the runtime the `## verb:` sections' MCP calls were checked on (the Atlassian connector's own tool names, 2026-10-25)
surfaces: [codex-cli]          # runtimes that list this connector under other tool names: one `## Runtime surface:` section each, picked by bin/adapter_surface.py
auth: |
  CLI (optional):  acli jira auth   (token in ~/.config/acli/token.txt; site/email in jira_config.yaml)
  MCP:  the tracker's MCP server (`{mcp}`, e.g. the Atlassian connector) must be connected (OAuth).
        Every verb works through it alone, so a teammate needs no acli. Comments always use it.
        On a runtime with its own section below, that section's MCP calls and probe instead
        (`bin/adapter_surface.py --probe` prints it).
  Verify: `acli jira workitem search --jql "project = {key_prefix}" --limit 1` (read-only; no epic needed)
          when acli is the route. A connector-only slot has `verify: null`: the agent runs the
          read-only probe below in-session, and verify_stack reports it as not shell-checkable.
---

# Jira adapter

Maps the `tracker` verb contract to Atlassian Jira through the official Atlassian connector (MCP)
and, where it is installed, the `acli` CLI. Every verb has both paths, so a machine with only the
connector runs the whole lifecycle. **Comments always go through the connector** because it
converts the comment to Jira's rich format (ADF), so links render clickable (acli posts plain
text, where links don't render).

**Which path a verb takes** is one rule, written in `## gotchas` so it prints with every verb: use
acli when the slot's `transport` is `cli` or `both`, `cli` is set, and acli is installed and signed
in on this machine; otherwise use the connector. On `transport: mcp` the connector is the only path.

**Tool names on the connector path are hints, not the contract.** Each verb says what it needs the
connector to do and names the tools that did it when this file was checked (2026-10-26). The
connector can also find operations itself: when a named tool is not in your session's list, ask the
connector's own search for the operation by what it does, and use that.

## Permission posture (MCP)

### Native control
This adapter is dual-transport, and the two paths have different controls. On a connector-only
machine every verb (reads, creates, transitions, comments) runs on the connector's grant, so that
grant is the whole control there. The CLI path authenticates as the person (`acli jira auth` token) — the `hard_halt_before_external_posts`
policy stays the gate at the skill layer either way. The MCP path's control is the connector's
**OAuth grant**: which Atlassian scopes it was consented — read (work-item/search) vs write
(comment/transition). What matters here is the read-vs-write split: comments always route through the MCP, and on a
machine without acli so do creates and transitions. An official connector's grant lives in its OAuth
consent; a CLI-configured server in its config file; a homegrown server with its owner (forward
the suggestion).

### Recommended setting (by policy)
`hard_halt_before_external_posts` is carried at the skill layer (nothing posts before a human
go), not by either transport — so prefer the narrowest connector grant that still covers the
comment verb you actually use, and know which grants matter: read-scoped consent cannot post at
all; comment/write consent is the thing the hard-halt is protecting.

### Read-only probe
One read per path this machine uses: the acli line only where acli is the route (see `## gotchas`);
on a connector-only machine run just the two connector reads. The MCP read needs the site's
`cloudId`, so the site list comes first:
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
**Connector path:** one read of the issue.
```
mcp__{mcp}__getJiraIssue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, view="evidence")
```
`view="evidence"` carries the description, status, type, assignee, reporter and issue links.
**People, for `/ship`'s audience suggestions:** `reporter` is `fields.reporter` in the `--json` output, or the reporter in the connector's result (display name and, when the site shows it, email). `watchers`: not available (`fields.watches` carries a count only, not the people).

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
**Connector path:** one create, with the parent passed only when `{default_epic}` is set.
```
mcp__{mcp}__createJiraIssue(cloudId=<the {site} cloudId>, projectKey="{key_prefix}", issueType="<TYPE>", summary="<SUMMARY>", description=<DESC, Markdown>, parent="{default_epic}", assignee=<accountId>)
```
Leave out `parent` when `default_epic` is unset. The connector's assignee is an **accountId**, not
an email: for the person running the command, the connector's current-user call returns it
(`atlassianUserInfo` when checked); for someone else, look them up with the connector's
assignable-users operation for this project (`listJiraIssueAssignableUsers` when checked, reached
through the connector's read runner). No match: create unassigned and say so, never guess an
account. A rejected create names the field at fault and its allowed values: fix that one field
and retry once, and never create a second issue when the first response already carries a key.

## verb: assign_ticket
**In:** `id`, `assignee`. **Out:** `{ok, mode: "replace"}`: Jira has one assignee, so this replaces
whoever holds the ticket now. Called only after the person said yes to `/ticket`'s offer.
**Which account:** `tracker_handle` in the person's `people/<id>.yaml`, as their Atlassian
**accountId** (preferred: it is what the connector takes) or their Atlassian **email** (what acli
takes). Unset: the account signed in here, as a real id: the connector's current-user call returns
its accountId (`atlassianUserInfo` when checked); on acli, the email `acli jira auth status` shows.
Give the check that value, never `@me` (no fetched assignee is ever `@me`, so every ticket would look
like someone else's); `@me` is fine in the acli write itself. The caller says it used that account.
**An email handle on the connector path:** the fetch usually shows no emails (Atlassian hides them),
so look the email up to its accountId first (the assignable-users lookup below) and pass that as
`--handle-id`, so a ticket already on the person is recognized and the write takes the accountId.
```bash
acli jira workitem assign --key "<id>" --assignee "<email, or @me>" --yes
```
acli takes the email, not the accountId. Without `--yes` the CLI can wait on a confirmation prompt.
**Connector path:** one edit of the assignee field, by accountId.
```
mcp__{mcp}__editJiraIssue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, fields={"assignee": {"accountId": "<accountId>"}})
```
A `tracker_handle` written as an email: look up its accountId with the connector's assignable-users
operation for this issue's project (`listJiraIssueAssignableUsers` when checked, through the
connector's read runner) and use the one exact match; no match or several, say so and assign
nothing, never a near match. A rejected edit (the person cannot be assigned in this project, or the
grant is read-only) is reported in one line with Jira's reason and is not retried.

## verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>" --yes
```
`<status>` is the `to` of a move `list_transitions` returned: `acli` takes the status NAME. The
connector's `transitionJiraIssue` takes the move's `via` instead, as `transitionId`. When two moves
reach the same status (`transition_plan.py` reports `ambiguous` and the person picks one), only the
`via` tells them apart, so make that move through the connector with the picked `via`, never with
`acli --status`. Never a status name typed from memory: workflows differ per project, and a status this
ticket cannot reach fails with `No allowed transitions found for given status`. Without `--yes` the
CLI waits for a confirmation prompt and a non-interactive run hangs.

**Connector path:** take the move from `list_transitions` whose `to` is `<status>`, then make it
by its `via`:
```
mcp__{mcp}__transitionJiraIssue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, transitionId=<that move's via>)
```
No move reaches `<status>` from where the issue is now: stop and report the statuses it can reach,
never step through others to get there. The call returns the status the issue landed in, so no
read-back is needed.

## verb: list_transitions
**In:** `id`. **Out:** `{current, transitions: [{to, via, category}], free_form: false}` (shape in
`adapters/README.md` § tracker), or `unavailable` + reason.
```
mcp__{mcp}__executeRead(cloudId=<the {site} cloudId>, name="listJiraIssueTransitions", inputs={"issueIdOrKey": "<id>"})
acli jira workitem view <id> --json      # `current` = fields.status.name
```
Observed 2026-10-26 on the Atlassian connector: `listJiraIssueTransitions` is not one of its
primary tools; it runs through the read-only operation runner `executeRead` (find it with
`discover`, query "list available transitions for a jira issue", if the name moves).
Map each returned transition to `to` = `to.name`, `via` = its `id`, `name` = its own `name`
(what the person recognizes when two moves reach one status), and `category` from
`to.statusCategory.key` (`new` = `todo`, `indeterminate` = `in_progress`, `done` = `done`). Only
transitions with `isAvailable: true` count. The connector lists the moves open to the signed-in
person, which is who `transition` runs as.

The `cloudId` is resolved as in `search`: the site whose URL's host is `{site}`, or STOP. **`acli`
cannot list transitions** (its `workitem` commands are archive, assign, attachment, clone, comment,
create, edit, link, search, transition, view and watcher; checked 2026-10-26), so on a CLI-only
install return `unavailable` with that reason. The caller then says the target status was not
checked against the tracker.

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
```
**Connector path** (at most 100 rows a page; follow the result's next-page marker until it says
there are no more, which was `pageInfo.hasNextPage` / `pageInfo.endCursor` when checked):
```
mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<N>)
```
The connector path needs the `cloudId` of `{site}`: list the sites once per session
(`mcp__{mcp}__getAccessibleAtlassianResources()`) and take the one whose URL's host is `{site}`. If
none matches, STOP and report rather than search another site.
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

**By `ids`** (the index status read): one search for the whole list, in batches of 50 keys.
```bash
acli jira workitem search --jql "key in (TEST-1, TEST-2)" --fields "key,summary,status" --limit 50 --json
# MCP alt: mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="key in (TEST-1, TEST-2)", maxResults=50)
```
`status` is `fields.status.name`. A key the site does not know makes Jira reject the whole JQL, so
on that error retry the batch one key at a time and leave out the ones that fail.

## verb: search_history
Older tickets that look like some text, in one fixed shape. This is the tool-neutral twin of `search`,
which takes raw JQL: the caller never writes a query. Read-only.
**In:** `<text>` (plain words), `<before>` (an ISO date, or empty for no cutoff), `<scope>` (the Jira
project, default `{key_prefix}`), `<limit>` (default 20), `<filter>` (optional, exactly one of
`project:<x>`, `label:<x>`, `parent:<x>`, `person:<x>`). **Out:** a JSON list of `{key, fetch_id, title,
description, labels, created, url, status}`, at most `<limit>` rows, `[]` when nothing matches.
`description` is cut to 600 characters, `labels` is a list of strings, `created` is an ISO date or `null`.
```bash
# <JQL> = project = <scope> AND text ~ "<text>" AND created < "<before>" ORDER BY created DESC
acli jira workitem search --jql "<JQL>" --limit <limit> --json --fields summary,description,labels,created,status
# MCP alt: mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<limit>)
```
Escape `"` and `\` in `<text>` with a backslash. An empty `<before>` means no date clause: the JQL is
`project = <scope> AND text ~ "<text>" ORDER BY created DESC`.

Filters: `project:<x>` replaces `<scope>` (`project = <x>`); `label:<x>` adds `AND labels = "<x>"`;
`parent:<x>` adds `AND parent = <x>` (an epic or parent key); `person:<x>` adds
`AND (assignee = "<x>" OR reporter = "<x>")` (`<x>` is the person's email).

If the build rejects `--fields`, drop it, search for the keys alone, then run `fetch_ticket` once per hit, in
order, stopping at the first auth error (an instant `250001/370001` is the MFA lockout: do not retry).
The MCP alternative needs the `cloudId` of `{site}`: take the one whose URL's host is `{site}`, as in
`search`; if none matches, STOP and report rather than search another site. Ask for the same five fields
when the tool takes a `fields` argument.

If `acli` is not signed in, the site cannot be reached, or the tracker rejects the search, say so in one
plain sentence and return `[]`.

Output mapping: `key` and `fetch_id` are both the issue key (`TEST-130`); `title` is `fields.summary`;
`description` is `fields.description` as plain text (flattened if it arrives as a document tree); `labels`
is `fields.labels`; `created` is `fields.created` cut to `YYYY-MM-DD`; `url` is
`https://{site}/browse/<key>`; `status` is `fields.status.name`.

## verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments. To DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```
**Connector path:** the issue's attachment list, then one download command per file.
```
mcp__{mcp}__getJiraIssue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, fields=["attachment"])
mcp__{mcp}__executeRead(cloudId=<the {site} cloudId>, name="downloadJiraIssueAttachment", inputs={"attachmentId": "<numeric id>", "outputPath": "<ticket>/source_materials/<filename>"})
```
The download operation returns a short-lived download command; run it from the shell to save the
file. A raw meeting transcript among the attachments stays out of git (the source-material guard
checks before any commit).

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
**Connector path:** the project list carries each project's last update, so one call ranks them.
```
mcp__{mcp}__executeRead(cloudId=<the {site} cloudId>, name="listJiraProjects", inputs={"maxResults": {container_cap}, "expand": "insight"})
mcp__{mcp}__searchJiraIssuesUsingJql(cloudId=<the {site} cloudId>, jql="project in (<K1>,<K2>,…) AND updated >= -<window_days>d ORDER BY updated DESC", maxResults=100)
```
`insight` gives each project's last update time, which is `last_activity`; a project with no
issues has none, so its `last_activity` is `null`. The search gives `activity`, counted by key
prefix exactly as above; follow its next-page marker up to `scan_cap` rows, and the same
saturation rule applies. The project list alone is enough to show the choices when
the person said no to counting activity.

Return `unavailable` with the reason when neither path can list projects (acli absent or signed
out, and the connector not connected or not reaching `{site}`). The caller says that line, then
asks as it would have anyway.

## gotchas
- **Which path, for every verb (the one rule).** acli when the slot's `transport` is `cli` or
  `both`, `cli` is set, and `command -v <cli>` succeeds and its read-only probe passes on this
  machine; otherwise the Atlassian connector (`{mcp}`). On `transport: mcp` the connector is the
  only path, and acli is never needed. Comments take the connector on every transport. When acli
  fails partway (signed out, an MFA lockout), finish on the connector rather than stop, and say
  which path ran. Before redoing a **write** on the connector (a create, a transition), read
  first: search for an issue with the same summary created in the last few minutes, or fetch the
  issue's status, because acli may have finished before it failed. Never create a second issue. Neither path available: report the verb `unavailable` with the reason.
- **Every connector call resolves the site first.** List the sites the account reaches once per
  session, take the `cloudId` of the one whose URL's host is `{site}`, and pass it on every call. No
  match: STOP and report. Never read from or write to another site the account can reach.
- **The connector's tool names drift; the job does not.** A tool named in a verb that is missing
  from your session's list: ask the connector's own operation search for the job (for example
  "list transitions for a jira issue") and use the operation it returns, through the read or write
  runner it names. The site rule, the review-before-posting rule and the never-edit-a-comment rule
  hold for whatever operation you find. Report the drift so the kit can update this file.
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
family; this adapter does not use it. The operations this file reaches through the connector's
read runner (`atlassian_executeread`: transitions, projects, assignable users, attachment
downloads) and the fetch, create and transition tools follow the same naming pattern but were not
observed in a Codex session; where one is missing, the default sections' rule applies: find the
operation through the connector's own search and report the gap. Only the MCP path differs by
agent: the `acli` commands are the same everywhere, so the CLI lines below repeat the default
sections word for word. The rules
of the default sections hold unchanged here: nothing posts before a human has reviewed it (policy
`hard_halt_before_external_posts`), and a comment goes only to the site at `{site}`.

### verb: fetch_ticket
**In:** `id` (e.g. `TEST-1234`). **Out:** title, description, status, type, assignee, links.
```bash
acli jira workitem view <id>
```
For structured fields: `acli jira workitem view <id> --json`.
**Connector path:** one read of the issue.
```
mcp__codex_apps__atlassian_getjiraissue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, view="evidence")
```
`view="evidence"` carries the description, status, type, assignee, reporter and issue links.
**People, for `/ship`'s audience suggestions:** `reporter` is `fields.reporter` in the `--json` output, or the reporter in the connector's result (display name and, when the site shows it, email). `watchers`: not available (`fields.watches` carries a count only, not the people).

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
**Connector path:** one create, with the parent passed only when `{default_epic}` is set.
```
mcp__codex_apps__atlassian_createjiraissue(cloudId=<the {site} cloudId>, projectKey="{key_prefix}", issueType="<TYPE>", summary="<SUMMARY>", description=<DESC, Markdown>, parent="{default_epic}", assignee=<accountId>)
```
Leave out `parent` when `default_epic` is unset. The connector's assignee is an **accountId**, not
an email: for the person running the command, the connector's current-user call returns it
(`atlassianUserInfo` when checked); for someone else, look them up with the connector's
assignable-users operation for this project (`listJiraIssueAssignableUsers` when checked, reached
through the connector's read runner). No match: create unassigned and say so, never guess an
account. A rejected create names the field at fault and its allowed values: fix that one field
and retry once, and never create a second issue when the first response already carries a key.

### verb: assign_ticket
**In:** `id`, `assignee`. **Out:** `{ok, mode: "replace"}`: Jira has one assignee, so this replaces
whoever holds the ticket now. Called only after the person said yes to `/ticket`'s offer.
**Which account:** `tracker_handle` in the person's `people/<id>.yaml`, as their Atlassian
**accountId** (preferred: it is what the connector takes) or their Atlassian **email** (what acli
takes). Unset: the account signed in here, as a real id: the connector's current-user call returns
its accountId (`atlassianUserInfo` when checked); on acli, the email `acli jira auth status` shows.
Give the check that value, never `@me` (no fetched assignee is ever `@me`, so every ticket would look
like someone else's); `@me` is fine in the acli write itself. The caller says it used that account.
**An email handle on the connector path:** the fetch usually shows no emails (Atlassian hides them),
so look the email up to its accountId first (the assignable-users lookup below) and pass that as
`--handle-id`, so a ticket already on the person is recognized and the write takes the accountId.
```bash
acli jira workitem assign --key "<id>" --assignee "<email, or @me>" --yes
```
acli takes the email, not the accountId. Without `--yes` the CLI can wait on a confirmation prompt.
**Connector path:** one edit of the assignee field, by accountId.
```
mcp__codex_apps__atlassian_editjiraissue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, fields={"assignee": {"accountId": "<accountId>"}})
```
A `tracker_handle` written as an email: look up its accountId with the connector's assignable-users
operation for this issue's project (`listJiraIssueAssignableUsers` when checked, through the
connector's read runner) and use the one exact match; no match or several, say so and assign
nothing, never a near match. A rejected edit (the person cannot be assigned in this project, or the
grant is read-only) is reported in one line with Jira's reason and is not retried.

### verb: transition
```bash
acli jira workitem transition --key "<id>" --status "<status>" --yes
```
`<status>` is the `to` of a move `list_transitions` returned: `acli` takes the status NAME. The
connector's `transitionJiraIssue` takes the move's `via` instead, as `transitionId`. When two moves
reach the same status (`transition_plan.py` reports `ambiguous` and the person picks one), only the
`via` tells them apart, so make that move through the connector with the picked `via`, never with
`acli --status`. Never a status name typed from memory: workflows differ per project, and a status this
ticket cannot reach fails with `No allowed transitions found for given status`. Without `--yes` the
CLI waits for a confirmation prompt and a non-interactive run hangs.

**Connector path:** take the move from `list_transitions` whose `to` is `<status>`, then make it
by its `via`:
```
mcp__codex_apps__atlassian_transitionjiraissue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, transitionId=<that move's via>)
```
No move reaches `<status>` from where the issue is now: stop and report the statuses it can reach,
never step through others to get there. The call returns the status the issue landed in, so no
read-back is needed.

### verb: list_transitions
**In:** `id`. **Out:** `{current, transitions: [{to, via, category}], free_form: false}` (shape in
`adapters/README.md` § tracker), or `unavailable` + reason.
```
mcp__codex_apps__atlassian_executeread(cloudId=<the {site} cloudId>, name="listJiraIssueTransitions", inputs={"issueIdOrKey": "<id>"})
acli jira workitem view <id> --json      # `current` = fields.status.name
```
Not observed on Codex: the app's read-only operation runner is assumed to follow the
connector's naming (`executeRead` lower-cased behind `atlassian_`). If the session does not list
it, return `unavailable` rather than guessing another name.
Map each returned transition to `to` = `to.name`, `via` = its `id`, `name` = its own `name`
(what the person recognizes when two moves reach one status), and `category` from
`to.statusCategory.key` (`new` = `todo`, `indeterminate` = `in_progress`, `done` = `done`). Only
transitions with `isAvailable: true` count. The connector lists the moves open to the signed-in
person, which is who `transition` runs as.

The `cloudId` is resolved as in `search`: the site whose URL's host is `{site}`, or STOP. **`acli`
cannot list transitions** (its `workitem` commands are archive, assign, attachment, clone, comment,
create, edit, link, search, transition, view and watcher; checked 2026-10-26), so on a CLI-only
install return `unavailable` with that reason. The caller then says the target status was not
checked against the tracker.

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
```
**Connector path** (at most 100 rows a page; follow the result's next-page marker until it says
there are no more, which was `pageInfo.hasNextPage` / `pageInfo.endCursor` when checked):
```
mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<N>)
```
The connector path needs the `cloudId` of `{site}`: list the sites once per session
(`mcp__codex_apps__atlassian_getaccessibleatlassianresources({})`) and take the one whose URL's host is `{site}`. If
none matches, STOP and report rather than search another site.
Example (related prior tickets): `project = {key_prefix} AND text ~ "<topic>" ORDER BY created DESC`.

**By `ids`** (the index status read): one search for the whole list, in batches of 50 keys.
```bash
acli jira workitem search --jql "key in (TEST-1, TEST-2)" --fields "key,summary,status" --limit 50 --json
# MCP alt: mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="key in (TEST-1, TEST-2)", maxResults=50)
```
`status` is `fields.status.name`. A key the site does not know makes Jira reject the whole JQL, so
on that error retry the batch one key at a time and leave out the ones that fail.

### verb: search_history
Older tickets that look like some text, in one fixed shape. This is the tool-neutral twin of `search`,
which takes raw JQL: the caller never writes a query. Read-only.
**In:** `<text>` (plain words), `<before>` (an ISO date, or empty for no cutoff), `<scope>` (the Jira
project, default `{key_prefix}`), `<limit>` (default 20), `<filter>` (optional, exactly one of
`project:<x>`, `label:<x>`, `parent:<x>`, `person:<x>`). **Out:** a JSON list of `{key, fetch_id, title,
description, labels, created, url, status}`, at most `<limit>` rows, `[]` when nothing matches.
`description` is cut to 600 characters, `labels` is a list of strings, `created` is an ISO date or `null`.
```bash
# <JQL> = project = <scope> AND text ~ "<text>" AND created < "<before>" ORDER BY created DESC
acli jira workitem search --jql "<JQL>" --limit <limit> --json --fields summary,description,labels,created,status
# MCP alt: mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="<JQL>", maxResults=<limit>)
```
Escape `"` and `\` in `<text>` with a backslash. An empty `<before>` means no date clause: the JQL is
`project = <scope> AND text ~ "<text>" ORDER BY created DESC`.

Filters: `project:<x>` replaces `<scope>` (`project = <x>`); `label:<x>` adds `AND labels = "<x>"`;
`parent:<x>` adds `AND parent = <x>` (an epic or parent key); `person:<x>` adds
`AND (assignee = "<x>" OR reporter = "<x>")` (`<x>` is the person's email).

If the build rejects `--fields`, drop it, search for the keys alone, then run `fetch_ticket` once per hit, in
order, stopping at the first auth error (an instant `250001/370001` is the MFA lockout: do not retry).
The MCP alternative needs the `cloudId` of `{site}`: list the sites once per session
(`mcp__codex_apps__atlassian_getaccessibleatlassianresources({})`) and take the one whose URL's host is
`{site}`. If none matches, STOP and report rather than search another site. Ask for the same five fields
when the tool takes a `fields` argument.

If `acli` is not signed in, the site cannot be reached, or the tracker rejects the search, say so in one
plain sentence and return `[]`.

Output mapping: `key` and `fetch_id` are both the issue key (`TEST-130`); `title` is `fields.summary`;
`description` is `fields.description` as plain text (flattened if it arrives as a document tree); `labels`
is `fields.labels`; `created` is `fields.created` cut to `YYYY-MM-DD`; `url` is
`https://{site}/browse/<key>`; `status` is `fields.status.name`.

### verb: download_attachments
Pull a ticket's attachments into its `source_materials/` (skip silently when there are none).
`acli jira workitem attachment list <id>` only LISTS attachments. To DOWNLOAD, use a small `curl`
script against the REST API that follows the 303 redirect to the download URL:
```bash
# e.g. a helper you keep in bin/: download_jira_attachments.sh <id> <dest_dir>
```
**Connector path:** the issue's attachment list, then one download command per file.
```
mcp__codex_apps__atlassian_getjiraissue(cloudId=<the {site} cloudId>, issueIdOrKey=<id>, fields=["attachment"])
mcp__codex_apps__atlassian_executeread(cloudId=<the {site} cloudId>, name="downloadJiraIssueAttachment", inputs={"attachmentId": "<numeric id>", "outputPath": "<ticket>/source_materials/<filename>"})
```
The download operation returns a short-lived download command; run it from the shell to save the
file. A raw meeting transcript among the attachments stays out of git (the source-material guard
checks before any commit).

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
**Connector path:** the project list carries each project's last update, so one call ranks them.
```
mcp__codex_apps__atlassian_executeread(cloudId=<the {site} cloudId>, name="listJiraProjects", inputs={"maxResults": {container_cap}, "expand": "insight"})
mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="project in (<K1>,<K2>,…) AND updated >= -<window_days>d ORDER BY updated DESC", maxResults=100)
```
`insight` gives each project's last update time, which is `last_activity`; a project with no
issues has none, so its `last_activity` is `null`. The search gives `activity`, counted by key
prefix exactly as above; follow its next-page marker up to `scan_cap` rows, and the same
saturation rule applies. The project list alone is enough to show the choices when
the person said no to counting activity.

Return `unavailable` with the reason when neither path can list projects (acli absent or signed
out, and the connector not connected or not reaching `{site}`). The caller says that line, then
asks as it would have anyway.

### Permission posture on this runtime
The CLI path is unchanged: `acli` authenticates as the person. The MCP path's control is the
Atlassian app's connection for the signed-in ChatGPT account: which Atlassian account and sites it
reaches, and whether its grant covers commenting. That grant is NOT introspectable from inside the
session, so the posture record caps at `status: unverified` exactly as above; confirm it where the
app was connected and record the outcome in `.claude/config/posture.local.yaml`.

### Read-only probe
The acli line only where acli is the route; a connector-only machine runs just the connector reads.
```
acli jira workitem search --jql "project = {key_prefix}" --limit 1    # CLI path, read-only
mcp__codex_apps__atlassian_getaccessibleatlassianresources({})         # MCP path, read-only: the sites this account reaches
mcp__codex_apps__atlassian_searchjiraissuesusingjql(cloudId=<the {site} cloudId>, jql="project = {key_prefix}", maxResults=1)   # read-only
```
Check that one resource's URL has `{site}` as its host: no match means the app is signed in to another
Atlassian account, and a comment would fail or land on the wrong site.
