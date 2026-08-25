---
seam: meetings
tool: zoom
transport: both        # a Zoom MCP server (server = {mcp}), or the REST API v2 with an OAuth token
requires: []           # + `mcp` (server name) when using the MCP transport
user_keys: []          # nothing here is machine-local config: credentials live in the MCP server's
                       # own config or the OAuth app (env var), never in stack.yaml
auth: |
  A Zoom MCP server connected, OR a Zoom OAuth app (server-to-server works) whose token is exported
  as $ZOOM_TOKEN. Meeting content is gated behind its OWN granular scopes — a meetings-CRUD token
  cannot read it: the AI Companion summary needs the meeting-summary read scope and the recording
  transcript needs the cloud-recording read scope (developers.zoom.us/docs/api/meetings, accessed
  2026-08-25). Verify: a read-only `GET /v2/users/me` (or the MCP's list-meetings call) returns
  without error.
---

# Zoom adapter (meetings)

Maps the `meetings` verb contract to Zoom — the AI Companion summary and the cloud-recording
transcript. Read-only: nothing in this seam writes to the provider. The meeting `{id}` below is the
validated id from a ticket's `meeting_ref:` (grammar in `stack.schema.md`; enumerate with
`bin/meeting_refs.py` — ids arrive per-ticket, never from config).

## verb: fetch_transcript

**⛔ Transcript privacy — carried verbatim in every meetings adapter:** Curated excerpts and action
items are committed; raw full transcripts are not, by default. The transcript goes to CONTEXT for
curation into the committed `YYYY-MM-DD-<slug>-meeting.md` — never to disk. The only opt-in raw
location is `source_materials/private/`, which stays out of git but flags every `/ship` scan and
copy-guard prompt by design. Honesty: curation-in-context and never-save-raw are agent guidance —
the mechanical gates are the gitignore patterns, the scanner's exit contract, and the
source-material guard, and those read filenames and document shape, never meaning.

Two routes, by what the meeting has:

```
curl -s -H "Authorization: Bearer $ZOOM_TOKEN" \
  "https://api.zoom.us/v2/meetings/{id}/meeting_summary"      # AI Companion summary
#   → summary_overview + summary_details[]  → content_kind: notes (an AI summary, not verbatim)
curl -s -H "Authorization: Bearer $ZOOM_TOKEN" \
  "https://api.zoom.us/v2/meetings/{id}/recordings"           # verbatim record
#   → download the recording_files[] entry with file_type: TRANSCRIPT (WebVTT; render the cue
#     text to context) → content_kind: transcript
```

MCP transport: `mcp__{mcp}__get_meeting_summary(meetingId={id})` /
`mcp__{mcp}__get_meeting_recordings(meetingId={id})`.

Returns transcript text + metadata `{title: topic, date: start_time, participants, content_kind}`.
`content_kind` says which route answered — the AI summary is never passed off as a verbatim
transcript.

## verb: search_meetings

```
curl -s -H "Authorization: Bearer $ZOOM_TOKEN" \
  "https://api.zoom.us/v2/users/me/recordings?from=<YYYY-MM-DD>&to=<YYYY-MM-DD>"   # recorded
curl -s -H "Authorization: Bearer $ZOOM_TOKEN" \
  "https://api.zoom.us/v2/users/me/meetings?type=previous_meetings"                # fallback
```

MCP transport: `mcp__{mcp}__list_recordings(from=…, to=…)` / `mcp__{mcp}__list_meetings(…)`.

Each row maps to `{id: meeting id, title: topic, date: start_time, participants: [host_email]}`.
Per the contract's participants note: Zoom's LIST endpoints expose the host but no attendee
roster, so `participants` here carries the host only — `fetch_transcript`'s metadata is the
fuller record.

## verb: fetch_action_items

Native: the AI Companion summary's `next_steps[]` array (same call as `fetch_transcript`'s
summary route).

```
curl -s -H "Authorization: Bearer $ZOOM_TOKEN" \
  "https://api.zoom.us/v2/meetings/{id}/meeting_summary"      # read next_steps[]
```

- `next_steps[]` non-empty → `{status: ok, items: [...]}`.
- Summary exists, `next_steps[]` empty → `{status: empty, items: []}` — report "no action items
  recorded"; the provider's answer is authoritative, no extraction fallback.

## Permission posture (MCP)

On the MCP path the kit's shell hooks cannot see this adapter's traffic, so the permission control
lives in Zoom's own app scopes — and this seam is READ-ONLY by contract, which keeps the posture
simple: the connection should hold read scopes only.

### Native control
The Zoom app's granular scopes, across all three connection shapes: official connector — its app
settings page; CLI-configured MCP server — the OAuth app it wraps; homegrown server — its owner
(this posture becomes a suggestion to forward). Meeting-content reads are their own scopes (the
meeting-summary read scope; the cloud-recording read scope); nothing in this seam needs a write
scope.

### Recommended setting (by policy)
- `db_write_requires_approval` — not in this seam's reach: the meetings contract has no write verb
  and no warehouse traffic flows here; nothing to set.
- `chat_default_draft` / `hard_halt_before_external_posts` — keep the Zoom connection free of any
  posting or meeting-management scope, so this slot cannot become an unreviewed outbound path even
  by misconfiguration.

A grant set here cannot be introspected in-session, so a posture record caps at `unverified`
(GUIDANCE in the rendered table) — a human confirms the scopes on the app's settings page.

### Read-only probe
```
GET https://api.zoom.us/v2/users/me                       # the auth: verify — a plain read
# MCP transport: mcp__{mcp}__list_meetings(type=previous_meetings, page_size=1)
```
The probe proves reachability and read access; it cannot enumerate the token's scopes, so the
comparison outcome is `unverified` by construction.

## gotchas

- The summary exists only when AI Companion was ON for that meeting; a 404 on the summary route
  with a recording present means "use the transcript route", not "no meeting".
- Recording transcripts are WebVTT — timestamps and speakers sit on separate lines; render the cue
  text, don't regex the speaker off the timestamp line.
