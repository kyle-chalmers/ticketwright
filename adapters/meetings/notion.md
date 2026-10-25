---
seam: meetings
tool: notion
transport: mcp         # a Notion MCP server (server = {mcp}) exposing the meeting-notes operations
requires: [mcp]        # the MCP server name
user_keys: []          # the Notion connection lives in the MCP server's own config, never in stack.yaml
default_surface: claude-code   # the runtime the `## verb:` sections were checked on (the hosted Notion connector's tool names, 2026-10-25)
surfaces: [codex-cli]          # runtimes that list this connector under other tool names: one `## Runtime surface:` section each, picked by bin/adapter_surface.py
auth: |
  A Notion MCP server connected to the workspace holding the meeting notes. Access rides the
  workspace connection's page permissions — the MCP integration must be granted the meeting-notes
  pages. Verify: a read-only "list recent pages" (or equivalent) MCP call returns without error
  (on a runtime with its own section below, that section's probe: `bin/adapter_surface.py --probe`).
---

# Notion adapter (meetings)

Maps the `meetings` verb contract to Notion meeting-notes pages (the AI meeting notes Notion
captures, or hand-kept meeting pages) via a Notion MCP's named operations. Read-only. The meeting
`{id}` below — a Notion page id — is the validated id from a ticket's `meeting_ref:` (grammar in
`stack.schema.md`; enumerate with `bin/meeting_refs.py` — ids arrive per-ticket, never from
config).

## verb: fetch_transcript

**⛔ Transcript privacy — carried verbatim in every meetings adapter:** Curated excerpts and action
items are committed; raw full transcripts are not, by default. The transcript goes to CONTEXT for
curation into the committed `YYYY-MM-DD-<slug>-meeting.md` — never to disk. The only opt-in raw
location is `source_materials/private/`, which stays out of git but flags every `/ship` scan and
copy-guard prompt by design. Honesty: curation-in-context and never-save-raw are agent guidance —
the mechanical gates are the gitignore patterns, the scanner's exit contract, and the
source-material guard, and those read filenames and document shape, never meaning.

**ID encoding — none, and that is a decision, not an omission.** `{id}` is an MCP call ARGUMENT
here, never a URL path segment, so a `/` in the id is inert; pass it verbatim.

```
mcp__{mcp}__notion-fetch(id={id}, include_transcript=true)
#   → the meeting-notes page as Notion-flavored Markdown: title, date, attendees, body, plus the
#     AI-captured transcript when Notion recorded one
```

`include_transcript=true` is required: the connector's default is false, and then it returns a
placeholder with the page link where the transcript would be, which reads like a notes-only page.

Returns transcript text + metadata `{title, date, participants: attendees, content_kind}`:
- the page carries an AI-captured transcript section → emit it, `content_kind: transcript`;
- a notes-only page → emit the note body, `content_kind: notes` — the metadata says which, so
  notes are never passed off as a verbatim transcript.

## verb: search_meetings

```
mcp__{mcp}__notion-query-meeting-notes(filter={"operator": "and", "filters": [
    {"property": "title", "filter": {"operator": "string_contains", "value": {"type": "exact", "value": <keyword>}}},
    {"property": "created_time", "filter": {"operator": "date_is_within", "value": {"type": "exact", "value": {"type": "daterange", "start_date": <YYYY-MM-DD>, "end_date": <YYYY-MM-DD>}}}}]})
#   → the dedicated meeting-notes query: up to 50 rows, already scoped to meetings the connected
#     user attended or created. One filter per keyword; "or" across them for broad discovery.
```

Returns `[{id: page id, title, date, participants: attendees}]`.

## verb: fetch_action_items

Native: Notion's first-class `to_do` block type (the page's checkboxes), present in the `fetch`
result as checkbox markdown — mechanical structural filtering of provider data, not model
reasoning.

```
mcp__{mcp}__notion-fetch(id={id})       # then filter the returned page for its to_do checkboxes
```

- `to_do` blocks present → `{status: ok, items: [...]}` (text + checked state).
- A page with zero `to_do` blocks → `{status: empty, items: []}` — report "no action items
  recorded"; the provider's answer is authoritative, no extraction fallback.

## Permission posture (MCP)

The shell hooks cannot see MCP traffic, so the permission control lives in the Notion connection's
page grants — and this seam is READ-ONLY by contract.

### Native control
The Notion integration/connection's capabilities and page access (official connector: the
workspace's connection settings — which pages/sections are shared with it, and whether it holds
read-only or read-write capabilities; CLI-configured server: the integration token its config
names; homegrown: its owner — this posture becomes a suggestion to forward). Share ONLY the
meeting-notes section with this connection.

### Recommended setting (by policy)
- `db_write_requires_approval` — not in this seam's reach (no write verb, no warehouse traffic);
  nothing to set.
- `chat_default_draft` / `hard_halt_before_external_posts` — set the connection's capabilities to
  read-only content access; a Notion connection with write capability turns a read-only slot into
  an unreviewed edit path over the pages it can see.

A connection's capability set cannot be introspected in-session, so a posture record caps at
`unverified` (GUIDANCE in the rendered table) — a human confirms in the workspace's connection
settings.

### Read-only probe
```
mcp__{mcp}__notion-query-meeting-notes(filter={"operator": "and", "filters": [{"property": "created_time", "filter": {"operator": "date_is_within", "value": {"type": "relative", "value": "the_past_week"}}}]})   # the dedicated meeting-notes read
# or: mcp__{mcp}__notion-list-recent-pages(limit=1)      # a plain workspace read
```
The probe proves the connection sees the meeting-notes store; it cannot enumerate its
capabilities, so the comparison outcome is `unverified` by construction.

## gotchas

- Page ids are opaque and stable; page TITLES are not — always reference by id in `meeting_ref:`.
- A page the integration wasn't granted returns not-found, not forbidden — grant the meeting-notes
  section to the MCP connection, then retry.
- Tool names differ by agent: Codex CLI lists this connector under other names (its section is
  below). `bin/adapter_surface.py --adapter adapters/meetings/notion.md` picks the right section
  for the agent running now. A name missing from your session's tool list is a gap to report so
  the kit can record it, never a local edit here or in a skill. The self-hosted Notion API server
  is a different tool with no meeting-notes query: give it its own adapter.

## Runtime surface: codex-cli

server: codex_apps

Codex CLI reaches Notion through the ChatGPT Notion app: every tool sits under the one server
`codex_apps` with a `notion_` prefix: the tool Claude lists as `notion-query-meeting-notes`
arrives as `notion_notion_query_meeting_notes`, and `notion-fetch` as `notion_fetch`. The argument
shapes are the same hosted connector's, unchanged (observed 2026-10-24, with the connector's own
tool declarations, in a Codex CLI session). The seam stays read-only.

### verb: fetch_transcript

**⛔ Transcript privacy — carried verbatim in every meetings adapter:** Curated excerpts and action
items are committed; raw full transcripts are not, by default. The transcript goes to CONTEXT for
curation into the committed `YYYY-MM-DD-<slug>-meeting.md` — never to disk. The only opt-in raw
location is `source_materials/private/`, which stays out of git but flags every `/ship` scan and
copy-guard prompt by design. Honesty: curation-in-context and never-save-raw are agent guidance —
the mechanical gates are the gitignore patterns, the scanner's exit contract, and the
source-material guard, and those read filenames and document shape, never meaning.

`{id}` is a call argument, never a URL path segment: pass it verbatim.

```
mcp__codex_apps__notion_fetch(id={id}, include_transcript=true)    # include_transcript defaults to false
```
`include_transcript=true` is required: without it the connector returns a placeholder with the
page link where the transcript would be, which reads like a notes-only page.

Returns transcript text + metadata `{title, date, participants: attendees, content_kind}`:
`content_kind: transcript` when the page carries an AI-captured transcript, `content_kind: notes`
for a notes-only page, so notes are never passed off as a verbatim transcript.

### verb: search_meetings
```
mcp__codex_apps__notion_notion_query_meeting_notes(filter={"operator": "and", "filters": [
    {"property": "title", "filter": {"operator": "string_contains", "value": {"type": "exact", "value": <keyword>}}},
    {"property": "created_time", "filter": {"operator": "date_is_within", "value": {"type": "exact", "value": {"type": "daterange", "start_date": <YYYY-MM-DD>, "end_date": <YYYY-MM-DD>}}}}]})
```
Returns `[{id: page id, title, date, participants: attendees}]`.

### verb: fetch_action_items
```
mcp__codex_apps__notion_fetch(id={id})       # then filter the returned page for its to_do checkboxes
```
`to_do` blocks present give `{status: ok, items: [...]}`; none gives `{status: empty, items: []}`,
reported as "no action items recorded", with no extraction fallback.

### Permission posture on this runtime
The control is the Notion app's connection for the signed-in ChatGPT account: which pages it was
shared and whether it can write. That capability set is NOT introspectable from inside the
session, so the posture record caps at `unverified` exactly as above; share only the meeting-notes
section with the connection and record the outcome in `.claude/config/posture.local.yaml`.

### Read-only probe
```
mcp__codex_apps__notion_notion_list_recent_pages(limit=1)      # read-only: names and metadata, no page body
mcp__codex_apps__notion_notion_query_meeting_notes(filter={"operator": "and", "filters": [{"property": "created_time", "filter": {"operator": "date_is_within", "value": {"type": "relative", "value": "the_past_week"}}}]})   # read-only
```
The probe proves the connection reaches the workspace, not that it was granted every meeting page;
a page it cannot see returns not-found when a ticket asks for it.
