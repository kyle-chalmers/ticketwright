---
seam: meetings
tool: teams
transport: mcp         # a Microsoft Graph MCP (server = {mcp})
requires: [mcp]        # the MCP server name
user_keys: []          # Graph auth lives in the MCP server's own config, never in stack.yaml
auth: |
  A Graph MCP server connected. Meeting transcripts are gated behind their OWN Graph permission
  (the OnlineMeetingTranscript.Read family) — a base M365 credential cannot read them — and the
  meeting AI INSIGHTS (action items) additionally require the user to hold a Microsoft 365 Copilot
  license (learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/
  meeting-insights, accessed 2026-08-25). Stated plainly: without Copilot licensing,
  fetch_action_items will be refused by the provider even though fetch_transcript works.
  Verify: a read-only "list my online meetings" MCP call returns without error.
---

# Microsoft Teams adapter (meetings)

Maps the `meetings` verb contract to Microsoft Graph. Read-only. The meeting `{id}` below is the
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

```
mcp__{mcp}__graph_get(path="/me/onlineMeetings/{id}/transcripts")                    # list
mcp__{mcp}__graph_get(path="/me/onlineMeetings/{id}/transcripts/<transcriptId>/content?$format=text/vtt")
```

Returns transcript text (the WebVTT content, rendered to context) + metadata `{title: subject,
date: start, participants: attendees, content_kind: transcript}` — Graph transcripts are the
verbatim record, so `content_kind` is always `transcript` here.

## verb: search_meetings

```
mcp__{mcp}__graph_get(path="/me/calendarView?startDateTime=<d1>&endDateTime=<d2>&$filter=isOnlineMeeting eq true")
```

Returns `[{id: the onlineMeeting id, title: subject, date: start, participants: attendees}]` —
the calendar view carries the attendee list natively.

## verb: fetch_action_items

Native — but license-gated (see `auth:`): the meeting AI insights endpoint.

```
mcp__{mcp}__graph_get(path="/copilot/users/<userId>/onlineMeetings/<joinWebUrl>/aiInsights")
#   → read actionItems[]
```

- `actionItems[]` non-empty → `{status: ok, items: [...]}`.
- Insights exist with zero action items → `{status: empty, items: []}` — report "no action items
  recorded"; the provider's answer is authoritative, no extraction fallback.
- A licensing refusal from the provider is an ERROR to surface with the `auth:` note (the Copilot
  dependency), not a `no_native_export` — the capability exists; this user's license doesn't.

## gotchas

- The insights route addresses the meeting by `joinWebUrl`, not the meeting id — resolve it from
  the fetched onlineMeeting object first.
- Transcription must have been ON for the meeting; a meeting with no transcript returns an empty
  transcripts list, which is "nothing recorded", not an auth failure.
- MCP op names vary by Graph server — confirm them once against your connected server and adjust
  here (never the skills).
