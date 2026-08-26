---
seam: meetings
tool: granola
transport: cli         # the desktop app's local cache, read with jq — no network, no credential
requires: []           # everything it needs is the local cache path below
user_keys: [cache_path]   # tier-3 overridable: where THIS machine's Granola app keeps its cache
                          # (default ~/Library/Application Support/Granola/cache-v3.json)
auth: |
  None — this adapter reads the Granola desktop app's local cache, so being signed into the app IS
  the auth. (Granola's hosted API is separately gated behind its own personal/enterprise API keys —
  docs.granola.ai/introduction, accessed 2026-08-25 — but this adapter deliberately takes the
  credential-free local route.) Verify: `jq -e '.cache' "{cache_path}" >/dev/null`.
---

# Granola adapter (meetings)

Maps the `meetings` verb contract to Granola's local notes cache. Read-only, credential-free,
fixture-friendly. The cache file is **double-encoded JSON** — a top-level `cache` string field
containing the real state — so every command below is a two-step `jq`: unwrap, then select. The
meeting `{id}` below is the validated id from a ticket's `meeting_ref:` (grammar in
`stack.schema.md`; enumerate with `bin/meeting_refs.py` — ids arrive per-ticket, never from config).

## verb: fetch_transcript

**⛔ Transcript privacy — carried verbatim in every meetings adapter:** Curated excerpts and action
items are committed; raw full transcripts are not, by default. The transcript goes to CONTEXT for
curation into the committed `YYYY-MM-DD-<slug>-meeting.md` — never to disk. The only opt-in raw
location is `source_materials/private/`, which stays out of git but flags every `/ship` scan and
copy-guard prompt by design. Honesty: curation-in-context and never-save-raw are agent guidance —
the mechanical gates are the gitignore patterns, the scanner's exit contract, and the
source-material guard, and those read filenames and document shape, never meaning.

**ID encoding — none, and that is a decision, not an omission.** `{id}` is a JSON object KEY in a
`jq` filter here, never a URL path segment or a shell word of its own, so a `/` in the id is inert;
pass it verbatim inside the quoted key. (The charset `bin/meeting_refs.py` enforces excludes quotes
and shell metacharacters, so the value cannot break out of the filter.)

```
jq -r '.cache' "{cache_path}" | jq '.state.documents["{id}"]'
#   → title, created_at, the captured transcript segments (speaker/text entries, present when
#     Granola transcribed the meeting), the note body, and the linked calendar event
```

Returns transcript text + metadata `{title, date: created_at, participants, content_kind}`:
- captured transcript segments present → emit them as the text, `content_kind: transcript`;
- no captured segments → emit the note body, `content_kind: notes` — the metadata says which, so
  notes are never passed off as a verbatim transcript.
Participants come from the cached calendar event's attendees (`[]` for a document with no linked
event).

## verb: search_meetings

```
jq -r '.cache' "{cache_path}" | jq '[.state.documents[]
  | select((.title // "" | test("<q>"; "i")) and (.created_at >= "<d1>") and (.created_at <= "<d2>"))
  | {id, title, date: .created_at,
     participants: [.google_calendar_event.attendees[]?.email]}]'
```

Returns `[{id, title, date, participants}]` — participants from the cached event's attendees;
`[]` for a document with no linked calendar event (per the contract's participants note).

## verb: fetch_action_items

**`status: no_native_export`** — declared statically: Granola notes are free-form and the local
cache carries no separate action-item export. Returns `{status: no_native_export}` (no `items`
key). Caller: the documented manual fallback — extract action items in-context from the
`fetch_transcript` text.

## gotchas

- The cache format is **app-internal and can shift with app updates** — a verify pass that stops
  finding `.state.documents` means the schema moved, not that the meetings are gone. Fix the two
  `jq` selectors here (never a skill).
- `cache_path` is per-machine (tier 3). The default is the macOS location; a teammate on another
  OS sets their own in `connections.local.yaml`.
- Local-only by design: this adapter can only see meetings the signed-in person attended on THIS
  machine — a teammate's meeting needs their machine or a hosted-API provider.
