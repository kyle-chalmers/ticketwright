# Bar judgment — the `meetings` tool slot against the new-slot bar

The full written judgment behind the outcome recorded in `ROADMAP.md` § "The `meetings` tool
slot — judged against the bar: YES (2026-08-25)". Adversarially adjudicated by an external model
(codex) over four rounds — each earlier round's findings were fixed in this document, never argued
past; the verdicts are appended verbatim at the end.

Judged 2026-08-25 against the rubric in the implementation plan §2.1 (as amended by V3 fix 6),
which operationalizes the bar recorded in `ROADMAP.md:189-223` and originally stated in
`docs/PROMPT-meetings-intake.md:39-51`: a new slot KIND needs (1) a stable tool-independent verb
contract, (2) a distinct lifecycle responsibility, (3) its own auth/verification semantics, and
(4) enough common use that it is not just an option on an existing slot. All four legs must flip
for YES. A NO on any leg ends the stream: ROADMAP records the outcome and nothing else ships.

## The drafted verb contract (leg 1 depends on it, so it comes first)

Three verbs, all read-only. `extract_actions` is NOT a verb (ROADMAP.md:200-206's objection —
model reasoning is not a command translation — is accepted, and its prescribed fix is adopted):

| Verb | Inputs | Returns |
|---|---|---|
| `fetch_transcript` | `meeting_ref` id | transcript text + metadata (title, date, participants, and `content_kind: transcript \| notes` — an adapter whose store holds curated notes rather than a verbatim transcript for this meeting says which, never passes one off as the other) — to context, never to disk |
| `search_meetings` | query and/or date window, limit | list of `{id, title, date, participants}` — `participants: []` is a defined value where the provider's LIST operation exposes no attendees; each adapter's section states what it fills |
| `fetch_action_items` | `meeting_ref` id | typed result: `{ status: ok \| empty \| no_native_export, items: [...] }` |

`fetch_action_items` statuses are mutually exclusive by construction, each with a defined caller
behavior:
- `status: ok` — the provider returned ≥1 native action items; `items` populated.
- `status: empty` — the provider HAS native action-item support and returned zero for this
  meeting; `items: []`. Caller reports "no action items recorded" and does NOT fall back to
  extraction — the provider's answer is authoritative.
- `status: no_native_export` — a STATIC capability fact declared in the adapter's verb section
  (never a runtime probe): this provider has no native action-item export; `items` absent.
  Caller performs the documented manual fallback: extract in-context from `fetch_transcript` text.

The existing `unsupported` sentinel is deliberately NOT reused: `adapters/README.md:62-64` defines
its caller behavior as "skips ranking **silently**", and the no-capability outcome here demands
the opposite (an active, documented fallback). Reusing the word would import wrong semantics.

`fetch_transcript` and `search_meetings` are mandatory with no sentinel.

## Leg 1 — stable tool-independent verb contract: YES

Evidence class: repo-verifiable (the launch adapter files + the contract table above).
Threshold: every launch adapter maps `fetch_transcript` and `search_meetings` to concrete
provider operations with defined return shapes; `fetch_action_items` carries the typed contract;
no verb requires model reasoning.

Per launch provider, the concrete operations the adapters map to (each with its return shape):
- **zoom** (transport both): `fetch_transcript` → `GET /v2/meetings/{id}/meeting_summary`
  (AI Companion summary: `summary_overview` + `summary_details` sections) or, for the verbatim
  record, `GET /v2/meetings/{id}/recordings` → download the `recording_files[]` entry with
  `file_type: TRANSCRIPT` (a WebVTT file rendered to text in context). `search_meetings` →
  `GET /v2/users/me/recordings?from=<date>&to=<date>` (recorded meetings), with
  `GET /v2/users/me/meetings?type=previous_meetings` as the no-recording fallback; each row
  maps to `{id: meeting id, title: topic, date: start_time, participants: [host_email]}` —
  Zoom's list endpoints expose the host but no attendee roster, which the adapter section
  states per the contract's participants note.
  `fetch_action_items` → the same `meeting_summary` response's `next_steps[]` array — ok when
  non-empty, empty when the summary exists with no next steps.
- **fireflies** (transport mcp): the Fireflies GraphQL API (one query operation over the
  MCP/HTTP transport). `fetch_transcript` → `query { transcript(id: "{id}") { title date
  sentences { speaker_name text } } }`. `search_meetings` → `query { transcripts(keyword: <q>,
  fromDate: <d1>, toDate: <d2>, limit: <n>) { id title date participants } }`.
  `fetch_action_items` → the native `live_action_items` query
  (docs.fireflies.ai/graphql-api/query/live_action_items) → ok/empty, never no_native_export.
- **granola** (transport cli): Granola's desktop app persists every meeting's state in a local
  cache file (`{cache_path}`, a tier-3 personal path key — default
  `~/Library/Application Support/Granola/cache-v3.json`). The file is double-encoded JSON (a
  top-level `cache` string field containing the real state) — the adapter's commands spell
  that out rather than leaving it a surprise. A cached document carries the transcript
  segments Granola captured (speaker/text entries, present when Granola transcribed the
  meeting), the note body, and the linked calendar event with its attendees.
  `fetch_transcript` → `jq -r '.cache' "{cache_path}" | jq '.state'`, selecting document
  `{id}`: emit the transcript segments as the text with `content_kind: transcript`; when the
  document has no captured segments, emit the note body with `content_kind: notes` — the
  metadata says which, so notes are never passed off as a verbatim transcript. Participants
  come from the cached calendar event's attendees. `search_meetings` → the same two-step `jq`
  over `.state.documents`, filtering title and `created_at` against the query/window and
  emitting `{id, title, date, participants}` (participants from the cached event's attendees;
  `[]` for a document with no linked event — stated in the adapter section).
  `fetch_action_items` → `no_native_export`, declared statically (free-form notes; the local
  cache carries no separate action-item export); the adapter's gotchas state honestly that the
  cache format is app-internal and can shift with app updates.
- **teams** (transport mcp): MS Graph. `fetch_transcript` →
  `GET /me/onlineMeetings/{meetingId}/transcripts` (list), then
  `GET /me/onlineMeetings/{meetingId}/transcripts/{transcriptId}/content?$format=text/vtt`
  (the content download, rendered to text in context). `search_meetings` → the calendar view /
  `GET /me/onlineMeetings` filtered to the window, mapping `{id, title: subject, date: start,
  participants: attendees}`. `fetch_action_items` → the meeting AI insights call
  (`GET /copilot/users/{userId}/onlineMeetings/{joinWebUrl}/aiInsights`, reading
  `actionItems[]`) — ok/empty; the `auth:` frontmatter states the Copilot-licensing dependency
  for AI insights honestly.
- **notion** (transport mcp): the Notion MCP's named operations, templated `mcp__{mcp}__…` per
  the MCP-adapter convention (adapters/README.md:425-427). `fetch_transcript` →
  `mcp__{mcp}__fetch(id={id})` — returns the meeting-notes page (title, date, attendees, body
  including any AI-captured transcript section) as structured content. `search_meetings` →
  `mcp__{mcp}__query-meeting-notes(query=<keywords>, date range=<window>)` — the dedicated
  meeting-notes query operation, returning pages as `{id, title, date, participants}`.
  `fetch_action_items` → filter the fetched page's blocks for Notion's first-class `to_do`
  block type (present in the `fetch` result as checkbox markdown) — mechanical structural
  filtering of provider data, not model reasoning — ok/empty.

Every verb is a command translation with a defined return shape. The one place model judgment
appears — extracting action items when a provider has none natively — is explicitly SKILL-side
fallback behavior documented in the contract, not an adapter verb. This is exactly
ROADMAP.md:204-206's prescribed fix ("split into a provider-native `fetch_action_items` …
plus a skill-side extraction step, and write the contract that way").

Ordering honesty: this judgment is the FIRST deliverable, so the adapter files do not exist at
the moment of judging — the leg is judged on the drafted contract and the named concrete
operations above, and it is repo-verifiable the moment the same change lands (selftest pins
assert exactly 3 verb sections per meetings adapter and the typed statuses in the contract
table). ROADMAP's own record anticipated this: the verb-contract objection was to
`extract_actions` specifically, with `fetch_transcript` and `search_meetings` already conceded
as fine ("each maps to a provider command with a defined return shape", ROADMAP.md:200-201),
and its prescribed fix is what the drafted contract implements. **Leg flips: YES** (conditional
only on the adapters shipping as drafted, in the same change this judgment gates).

## Leg 2 — distinct lifecycle responsibility: YES

Evidence class: written argument reconciled with `docs/architecture.md:34-44`'s phase map.
Threshold — ROADMAP's own bar, exactly as its "To flip it" states it (ROADMAP.md:210-211): "a
positive argument that reconciles with that map, rather than an appeal to being 'upstream'".
(The judgment deliberately does NOT use a "populates the artifact mechanically" threshold — no
slot's verbs write curated lifecycle artifacts; tracker's `fetch_ticket` does not write the spec
either. What a slot owns is the retrieval its verbs perform.)

The positive argument. The slot's distinct responsibility is **retrieving the spoken record by
reference from a provider store that no existing slot's verbs can reach**. The lifecycle
artifact this feeds is the curated `source_materials/YYYY-MM-DD-<slug>-meeting.md` record of a
spoken decision trail (the committed, curated form Stage 1 shipped). Today the raw material for
that artifact arrives only via a manual human export each time — a person opens the provider,
copies text out, drops a file. No existing slot's verbs can retrieve it at all:
- **tracker** fetches written tickets — its read verbs return ticket fields and attachments
  (`adapters/README.md:31-39`), not a provider's meeting store;
- **chat**'s verbs are outbound (`draft`, `send`, `lookup_user`, `lookup_channel`,
  `adapters/README.md:76-82`) — there is no read verb at all;
- **docstore** is `backup`/`link_for` (`adapters/README.md:84-88`) — it moves artifacts the
  ticket already produced outward; it cannot address a meeting by provider id;
- **warehouse**/**vcs** are categorically elsewhere.

ROADMAP.md:216-219 itself concedes the contract mismatch: "a transcript provider satisfies
neither `chat` (`draft`/`send`/…) nor `docstore` (`backup`/`link_for`) — so it genuinely would
not be a target on either."

Reconciliation with the phase map, not an "upstream" appeal: `docs/architecture.md:34-44` states
one slot can serve more than one phase and the matrix lists what a phase *can* use, not exclusive
assignments. The meetings slot adds itself to phase 1 (Open the work — the spoken ask becomes the
ticket's source material) and phase 2's spec step (Do the work — the decision trail informs the
spec), the canonical phase names per the spec (:47-49). That is an addition to two phases'
"can use" lists, exactly the shape the map allows; it claims no exclusivity over any phase and
leaves phase 3's deliberate hole untouched. The responsibility that is *distinct* is not the
phase — it is the store and the retrieval: no other slot's verb contract can turn a meeting
reference into the transcript text from which the curated committed record (the one the vision
— "written down and organized, and AI can trace it" — is about) gets made. Curation itself
remains agent/human work under the documented privacy rule, as it is for every slot's fetched
material. **Leg flips: YES.**

## Leg 3 — own auth/verification semantics: YES

Evidence class: sourced external docs with access dates (the `docs/runtimes.md` sourcing
convention). Threshold: ≥3 of 4 providers gate meeting-content reads behind a scope/license/key
distinct from a collaboration suite's base credential.

- **Zoom** — meeting summaries and cloud-recording transcripts are gated behind their own
  granular OAuth scopes (meeting summary read scopes; cloud recording read scopes), distinct from
  base meeting-management scopes. Source: developers.zoom.us/docs/api/meetings (accessed
  2026-08-25). GATED: yes — a Zoom app authorized for meetings CRUD cannot read summaries or
  transcripts without the additional scopes.
- **Microsoft Teams** — meeting transcripts require dedicated Graph permissions
  (OnlineMeetingTranscript.Read.All family), and meeting AI insights additionally require a
  Microsoft 365 Copilot license for the user. Source:
  learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/meeting-insights
  (accessed 2026-08-25). GATED: yes — both a distinct permission and a paid license sit between a
  base M365 credential and the meeting content.
- **Fireflies** — the GraphQL API (including transcripts and the native `live_action_items`
  query) authenticates with a Fireflies API key (Bearer token) issued by Fireflies itself;
  standalone product, no suite credential to ride. Sources: docs.fireflies.ai (GraphQL API
  authentication — API-key Bearer auth) and
  docs.fireflies.ai/graphql-api/query/live_action_items, both accessed 2026-08-25.
  GATED: yes (own key).
- **Granola** — stated honestly, because the launch adapter and the auth evidence are different
  routes: Granola's hosted API uses Granola's own personal/enterprise API keys
  (docs.granola.ai/introduction, accessed 2026-08-25) — its meeting content is behind a
  product-specific key, not a suite credential. The LAUNCH ADAPTER, however, deliberately takes
  the local-notes-cache route (transport `cli`, credential-free, fixture-friendly), which
  sidesteps auth entirely. So Granola supports the leg as a provider fact (own-key gating
  exists) while contributing nothing through the adapter route the kit ships. The threshold is
  therefore met WITHOUT counting Granola at all.

Zoom, Teams, and Fireflies — 3 of 4 launch-set providers judged (Granola set aside per the
honesty note above) — gate meeting-content reads behind a distinct scope, license, or
product-specific key; the threshold is ≥3 of 4. This answers ROADMAP.md:212-215's objection
directly: reading meetings is independently authorized, not a ride on a collaboration suite's
existing credentials — even inside the suites (Zoom, Teams), the transcript read is a
separately-granted permission. **Leg flips: YES.**

## Leg 4 — commonness: YES (maintainer-context, explicitly not source-verifiable)

Evidence class: maintainer-context attestation, cited per the spec's `:6-9` maintainer-context
convention and labeled NOT source-verifiable from this repo. Threshold: attested recurring
(≥monthly) meeting-origin ticket work across ≥2 providers. Vendor selection is explicitly NOT
adoption evidence.

Attested by the maintainer on 2026-08-25: meeting-origin ticket work recurs at least monthly
across two independent providers among the launch set (Zoom and Notion). That meets the threshold
exactly — no more is claimed, and vendor selection played no part in the evidence. Honest limit,
recorded: this leg rests on attestation, so if the attestation were withdrawn the leg would be
unproven and the judgment would flip to NO — the ROADMAP record says so too. **Leg flips: YES.**

## Verdict

**YES on all four legs.** The slot clears the bar as rubricized. Consequences: the full Stage 2
implementation proceeds — five launch adapters (zoom, fireflies, granola, teams, notion), the
three-verb contract with the typed `fetch_action_items` result, the `meeting_ref:` contract with
`bin/meeting_refs.py` as its mechanical parser, the optional `seams.meetings` slot, and every
fixed-five-slot surface extended. `ROADMAP.md:189-223` is rewritten to this judgment record.

## Appendix — the codex adjudication, verbatim

Four rounds. Round 1 was mis-administered (it transmitted a retired leg-2 threshold and omitted
leg 1's ordering fact) and is reproduced for honesty; rounds 2-4 ran the binding rubric. Each
round's findings were fixed in the judgment body above before the next round.

**Round 1 (mis-administered rubric; verdict not binding):**

> LEG 1: NO — No launch adapters exist, and several asserted operations/return shapes are placeholders rather than concrete mappings.
> LEG 2: NO — Fetching context cannot mechanically populate the curated lifecycle artifact; its creation still requires human/model work.
> LEG 3: NO — Granola's credential-free cache contradicts its claimed key gate, while the Fireflies citation is not an auth source, leaving fewer than three substantiated providers.
> LEG 4: NO — Only Zoom is attested as recurring ticket work; Notion is merely described as recurring use, without monthly ticket-work evidence.
> OVERALL: NO

**Round 2 (corrected rubric):**

> LEG 1: NO — Granola's "local cache file reads" and Notion's generic templated MCP query do not name concrete, implementable fetch/search operations, so the all-provider contract condition is not met.
> LEG 2: YES — It positively identifies provider-store spoken-record retrieval as a responsibility no existing slot's verbs cover and reconciles that addition with the non-exclusive phase map.
> LEG 3: YES — The cited Zoom, Teams, and Fireflies evidence plausibly establishes three independently gated meeting-content-read paths, while honestly excluding Granola's credential-free shipped route.
> LEG 4: YES — The explicitly labeled maintainer attestation states recurring meeting-origin ticket work at least monthly for both Zoom and Notion, without treating vendor selection as adoption evidence.
> OVERALL: NO

**Round 3 (Granola/Notion mappings made concrete):**

> LEG 1: NO — Granola's mappings omit required participants and treat a note body as a transcript without guaranteeing it, so the drafted common return contract is internally inconsistent.
> LEG 2: YES — It positively assigns provider-store spoken-record retrieval, which no existing slot contract covers, while adding support to phases without claiming exclusive phase ownership.
> LEG 3: YES — Zoom, Teams, and Fireflies plausibly require distinct transcript scopes, permissions/licenses, or product keys, and Granola's credential-free shipped route is candidly excluded.
> LEG 4: YES — The explicitly labeled maintainer attestation states recurring meeting-origin ticket work for both Zoom and Notion, satisfying the accepted two-provider threshold.
> OVERALL: NO

**Round 4 (participants/content_kind contract fixes) — the binding verdict:**

> LEG 1: YES — The draft gives all five providers concrete operations and return mappings, explicitly separates native action retrieval from skill-side reasoning, and defines the two previously ambiguous Granola cases.
> LEG 2: YES — It positively assigns retrieval of provider-hosted spoken records, reconciles that addition with the non-exclusive phase map, and shows no existing slot contract can perform it.
> LEG 3: YES — Zoom, Teams, and Fireflies plausibly require distinct transcript/content scopes, licensing, or product credentials, while Granola's credential-free shipped route is candidly excluded from the count.
> LEG 4: YES — The explicitly non-source-verifiable maintainer attestation states recurring meeting-origin ticket work at least monthly across Zoom and Notion, satisfying the stated threshold.
> OVERALL: YES
