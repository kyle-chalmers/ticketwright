---
seam: meetings
tool: fireflies
transport: mcp         # a Fireflies MCP server (server = {mcp}); every operation is one GraphQL query
requires: [mcp]        # the MCP server name
user_keys: []          # the Fireflies API key lives in the MCP server's own config, never in stack.yaml
auth: |
  A Fireflies MCP server connected, carrying a Fireflies API key (the GraphQL API authenticates
  with a Bearer API key issued by Fireflies itself — docs.fireflies.ai, accessed 2026-08-25;
  standalone product, no suite credential to ride). Verify: a read-only `{ user { email } }`
  query returns without error.
---

# Fireflies adapter (meetings)

Maps the `meetings` verb contract to the Fireflies GraphQL API. Read-only. The meeting `{id}` below
is the validated id from a ticket's `meeting_ref:` (grammar in `stack.schema.md`; enumerate with
`bin/meeting_refs.py` — ids arrive per-ticket, never from config).

## verb: fetch_transcript

**⛔ Transcript privacy — carried verbatim in every meetings adapter:** Curated excerpts and action
items are committed; raw full transcripts are not, by default. The transcript goes to CONTEXT for
curation into the committed `YYYY-MM-DD-<slug>-meeting.md` — never to disk. The only opt-in raw
location is `source_materials/private/`, which stays out of git but flags every `/ship` scan and
copy-guard prompt by design. Honesty: curation-in-context and never-save-raw are agent guidance —
the mechanical gates are the gitignore patterns, the scanner's exit contract, and the
source-material guard, and those read filenames and document shape, never meaning.

**ID encoding — none, and that is a decision, not an omission.** `{id}` is a GraphQL string
ARGUMENT here, never a URL path segment, so a `/` in the id is inert; pass it verbatim inside the
quoted string. (The charset `bin/meeting_refs.py` enforces excludes quotes and shell metacharacters,
so the value cannot break out of the argument.)

```
mcp__{mcp}__query(query='{ transcript(id: "{id}") { title date participants
                            sentences { speaker_name text } } }')
```

Returns transcript text (the `sentences[]` speaker/text pairs, rendered to context) + metadata
`{title, date, participants, content_kind: transcript}` — Fireflies stores the verbatim
transcription, so `content_kind` is always `transcript` here.

## verb: search_meetings

```
mcp__{mcp}__query(query='{ transcripts(keyword: "<q>", fromDate: "<d1>", toDate: "<d2>",
                            limit: <n>) { id title date participants } }')
```

Returns `[{id, title, date, participants}]` — Fireflies' list query carries the participant
emails natively.

## verb: fetch_action_items

Native: Fireflies exposes action items as their own query
(docs.fireflies.ai/graphql-api/query/live_action_items).

```
mcp__{mcp}__query(query='{ live_action_items(meeting_id: "{id}") { items { text assignee } } }')
```

- Items returned → `{status: ok, items: [...]}`.
- Query succeeds with zero items → `{status: empty, items: []}` — report "no action items
  recorded"; the provider's answer is authoritative, no extraction fallback.

## Permission posture (MCP)

The shell hooks cannot see MCP traffic, so the permission control lives with the Fireflies API key
itself — and this seam is READ-ONLY by contract.

### Native control
The Fireflies API key the MCP server carries (official connector: the workspace's API settings;
CLI-configured server: its config file; homegrown: its owner — this posture becomes a suggestion
to forward). Fireflies keys are workspace-scoped: the key sees the meetings its workspace holds,
and there is no narrower read-only grant to select — which is itself the posture fact to know.

### Recommended setting (by policy)
- `db_write_requires_approval` — not in this seam's reach (no write verb, no warehouse traffic);
  nothing to set.
- `chat_default_draft` / `hard_halt_before_external_posts` — the GraphQL API's mutation surface is
  reachable with the same key, so the MCP server should expose only the read queries this adapter
  names; a server exposing mutations turns a read-only slot into a write path.

A key's effective surface cannot be introspected in-session, so a posture record caps at
`unverified` (GUIDANCE in the rendered table) — a human confirms in the workspace's API settings.

### Read-only probe
```
query { user { email } }        # the auth: verify — an API-key read, no arguments
```
The probe proves the key reaches the workspace; it cannot enumerate the key's surface, so the
comparison outcome is `unverified` by construction.

## gotchas

- The MCP surface is one `query` operation; the GraphQL string is the real interface — confirm the
  exact tool name against your connected server once and adjust here (never the skills).
- Fireflies ids are opaque strings; pass them exactly as `meeting_refs.py` validated them.
