---
seam: meetings
tool: notion
transport: mcp         # a Notion MCP server (server = {mcp}) exposing the meeting-notes operations
requires: [mcp]        # the MCP server name
user_keys: []          # the Notion connection lives in the MCP server's own config, never in stack.yaml
auth: |
  A Notion MCP server connected to the workspace holding the meeting notes. Access rides the
  workspace connection's page permissions — the MCP integration must be granted the meeting-notes
  pages. Verify: a read-only "list recent pages" (or equivalent) MCP call returns without error.
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

```
mcp__{mcp}__fetch(id={id})
#   → the meeting-notes page as structured content: title, date, attendees, body — including the
#     AI-captured transcript section when Notion recorded one
```

Returns transcript text + metadata `{title, date, participants: attendees, content_kind}`:
- the page carries an AI-captured transcript section → emit it, `content_kind: transcript`;
- a notes-only page → emit the note body, `content_kind: notes` — the metadata says which, so
  notes are never passed off as a verbatim transcript.

## verb: search_meetings

```
mcp__{mcp}__query-meeting-notes(query=<keywords>, date range=<window>)
#   → the dedicated meeting-notes query operation
```

Returns `[{id: page id, title, date, participants: attendees}]`.

## verb: fetch_action_items

Native: Notion's first-class `to_do` block type (the page's checkboxes), present in the `fetch`
result as checkbox markdown — mechanical structural filtering of provider data, not model
reasoning.

```
mcp__{mcp}__fetch(id={id})       # then filter the returned blocks for the to_do type
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
mcp__{mcp}__query-meeting-notes(query="", limit=1)        # the dedicated meeting-notes read
# or: mcp__{mcp}__list-recent-pages(limit=1)              # a plain workspace read
```
The probe proves the connection sees the meeting-notes store; it cannot enumerate its
capabilities, so the comparison outcome is `unverified` by construction.

## gotchas

- Page ids are opaque and stable; page TITLES are not — always reference by id in `meeting_ref:`.
- A page the integration wasn't granted returns not-found, not forbidden — grant the meeting-notes
  section to the MCP connection, then retry.
- MCP op names vary by Notion server build — confirm `fetch` / `query-meeting-notes` once against
  your connected server and adjust here (never the skills).
