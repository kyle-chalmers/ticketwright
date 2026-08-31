# `stack.yaml` — the tool registry (schema + policies)

`stack.yaml` is the **single source of truth** for which concrete tool fills each tool slot
and for the project facts the skills need. Skills never hardcode `acli`, `snow`, `slack`, channel
IDs, epics, or paths — those live **here** and in the per-tool adapters. Swapping Jira→Asana or
Snowflake→BigQuery means editing this file and pointing at a different adapter; **no skill changes.**

The `setup` skill writes this file by interviewing you and detecting installed tooling.
`bin/verify_stack.sh` reads it to smoke-test every tool slot.

**This file is TIER 1 of three, and nothing should read it directly** — see "The three tiers" below.
Skills, hooks and scripts read the MERGED result via `bin/effective_config.py`.

---

## The three tiers

`stack.yaml` is committed and shared, so a value that is true only on one machine does not belong in
it. A real `/setup` run put a warehouse CLI profile name, a named connection, and a verify command
with that profile hardcoded into this file — every teammate then inherited one person's machine.
Config is therefore three files, merged by one resolver.

| Tier | File | Committed? | Holds |
|---|---|---|---|
| 1 TEAM | `.claude/config/stack.yaml` | yes | which tool fills each tool slot, which data the team reads, the 10 policies, ticket conventions |
| 2 PERSON, portable | `people/<id>.yaml` | yes | display name, tracker handle, identities, comms voice, file-type preferences |
| 3 PERSON, machine | `.claude/config/connections.local.yaml` | **no** (gitignored) | named profiles/connections, local mount roots, the `person:` key |

Tier 2 has two homes with a stated winner: a cross-repo copy at
`${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/people/<id>.yaml` supplies DEFAULTS, and the in-repo
`people/<id>.yaml` overrides it **key by key** (not whole-file), so you can carry your voice and
file-type preferences between repos while one repo differs in one field.

### Read the merged result, never the raw file

```bash
python3 bin/effective_config.py --root . --json          # everything, with per-key provenance
python3 bin/effective_config.py --root . --key seams.warehouse.cli
python3 bin/effective_config.py --root . --verify-plan   # one row per slot/target
python3 bin/effective_config.py --root . --lint          # machine-local values in committed config
python3 bin/effective_config.py --root . --seam warehouse --target lake   # select one target (inheritance applied)
```

No agent-specific environment variable is required, so this works under any harness. Exit codes:
`0` ok · `2` usage · `3` missing · `4` malformed · `5` stale · `6` prohibited override ·
`7` tool slot not configured · `8` target unresolvable (unknown name, or `targets:` with a
missing/invalid `default:`) — never a silent fallback to another target.

### THE SCOPE RULE — enforced in code, not documented

Tier 3 selects **credentials and local paths**. It may never change **logical data selection**:
`catalog`, `schema`, `database`, `dataset`, `warehouse_id`, target selection, `transport`, or the
slot's `tool`/`adapter`/`cli`. Two teammates must never silently read different data.

Which keys are personal is declared **per adapter**, in a `user_keys:` frontmatter list — never
hardcoded in a skill, and deliberately NOT derived from `requires:` (that is a minimum-capability
declaration; a warehouse can require a CLI yet still share team-level role and target settings).

The merge is an **allowlist over paths**. A tier-2/tier-3 file may write:

- `seams.<seam>.targets.<existing-target>.<key>` where `<key>` is in that target's adapter
  `user_keys:` — `targets` is a legal path *segment* (this is where a multi-target slot's personal
  credentials go) but never a settable value: creating, renaming or deleting a target is refused;
- `seams.<seam>.<key>` on a single-mapping slot only — a multi-target slot has no adapter of its
  own, so there would be nothing to declare which of its keys are personal;
- the structural keys `person`, `schema_version`, `mode`, `stack_fingerprint`;
- the tier-2 person block and the `viewer:` block.

**Anything else is rejected, not ignored** — including `policies:`, which is un-mergeable at every
tier. Tier 3 is gitignored and unreviewed; if it could set `db_write_requires_approval: off` or
`hard_halt_before_external_posts: false`, a per-machine file would disable the kit's safety gates
with nothing in code review to catch it. Ignoring such a block would be just as bad: it would let
someone believe they had turned a gate off.

`mode:` is meaningful. `overrides` applies the file's settings; `defaults` records that the person
accepted the team defaults and **must carry no overrides** — a `defaults` file that also carries
them is rejected, because file existence alone cannot otherwise distinguish empty from half-finished
from deliberately-default. `stack_fingerprint` reports `stale` (exit 5) when the committed stack has
moved since this machine was configured.

### Keeping machine values out of `verify:`

A `verify` command must not embed a machine-local literal. Use `{token}` interpolation and let tier 3
supply the value; `bin/verify_stack.sh` warns on a literal in a key the adapter declares personal,
and on a machine literal baked into the verify string itself. **An unresolved `{token}` is SKIPPED
with a pointer, never executed** — running a command with a literal brace in it reads as broken auth
rather than as missing config.

Tokenless verifies are correct and stay silent: they name nothing machine-specific.

### Docstore paths are split

`base_path` mixed a team decision with a machine path. The destination is team-owned
(`drive_folder`, tier 1); where it is mounted is per-user (`mount_root`, tier 3). The resolver
composes `base_path` from the two, so adapter verb bodies keep interpolating `{base_path}`
unchanged. A literal `base_path:` still works and warns.

---

## Top-level shape

```yaml
project:        # facts about this workspace, tool-independent
seams:          # one entry per tool slot → concrete tool + adapter + verify
policies:       # behavioral rules every skill inherits (the kit's "global rules")
```

---

## `project`

| Field | Type | Example | Meaning |
|---|---|---|---|
| `key_prefix` | string | `ENG` | Ticket-ID prefix. Branch names = `{key_prefix}-NNNN`. Omit it when `id_mode: slug` — there are no keys to prefix. |
| `id_mode` | enum | `keyed` | `keyed` (default) = folder names carry a tracker key; `slug` = the folder name **is** the id. See "Trackerless work". |
| `key_prefixes` | list | `[ENG]` | Prefixes the ticket index recognizes in folder names. Optional; defaults to `[key_prefix]`. Use when one repo holds tickets from several trackers (e.g. `[ENG, OPS]`). |
| `assignee_dir` | string | `alice` | Last-resort owner subdir under `tickets/`, used only when no people map exists (`bin/whoami.py` returns `miss` and there are no `people/*.yaml`). With a people map, the whoami-resolved person is the owner. |
| `ticket_path` | template | `tickets/{assignee}/{id}` | Where a ticket folder lives. `{assignee}` `{id}` tokens; `{assignee}` is the ticket's **owner** — the whoami-resolved person for new work, or the locator's owner (`owner/id`) when named explicitly. |
| `ticket_subdirs` | list | `[source_materials, final_deliverables, qc_queries, exploratory_analysis]` | Scaffolded per ticket. |
| `default_epic` | string \| null | `ENG-100` | Parent epic for newly created tickets (null if tracker has no epics). |
| `terminal_status` | string | `Done` | The "done" workflow state (not always "Done"). |
| `ticket_url_template` | template \| null | `https://acme.atlassian.net/browse/{id}` | How `tickets/INDEX.md` links each ticket (`{id}` token). Null/omitted → the index renders no per-ticket link. |
| `intake` | list | `[tracker, email]` | Where work arrives; any of `tracker`, `email`, `chat`, `meetings`. Optional; **defaults to `[tracker]`** — the example shows email intake *added* (a "email carries work in" answer in the setup interview), not the default. Consumer: when `email`/`chat`/`meetings` is listed, `/ticket`'s priming step reads `source_materials/` for material a human dropped in — intake beyond the tracker arrives as files, not API calls. **`meetings`** names the AI-notetaker channel: export the notes or a curated transcript excerpt as `source_materials/YYYY-MM-DD-<slug>-meeting.md`. That name is the **committed, curated form** — trimmed to decisions and action items. Raw full transcripts stay out of git by default (`templates/gitignore.tmpl`) and are gated before any commit or docstore copy by `source_material_guard`, whose classifier (`bin/scan_source_materials.py`) matches filenames and document shape, **never meaning** — a curated summary quoting confidential material verbatim passes, so this is a gate against the bulk artifact, not a confidentiality review. |
| `word_limits` | map | `{tracker_comment: 100, chat: 100, pr: 200, ticket: 200}` | Hard caps the comms skills enforce. |
| `role` | enum | `generalist` | Persona for the rendered `AGENTS.md` role-focus snippet: `generalist`, `analyst`, `engineer`, or `scientist` (see `templates/roles/`). Optional; defaults to `generalist`. |
| `domain` | string | `data analysis` | Short phrase naming the team's kind of work; fills the `{{domain}}` token in the rendered `AGENTS.md` ("Ticket-driven *{{domain}}* work"). Optional; defaults to `data analysis`. |
| `analysis_tools` | list | `[notebooks, spreadsheets]` | The tools the team does the actual analysis in, rendered into `AGENTS.md` as **descriptive context for the agent**. Optional; defaults to `[]`. **Not a tool slot**: nothing verifies it and nothing executes from it — it has no adapter and no verb contract; it just tells the agent what the team's outputs are built with. |
| `graph_notes` | bool | `true` | Generate the Obsidian graph layer (`tickets/graph/` + `tickets/objects/`). On by default; set `false` to disable. |
| `graph_config` | bool | `true` | Also write/merge `.obsidian/graph.json` (tickets↔objects filter + color groups) so the Graph view opens ready-to-read. Create/merge-only — never clobbers manual tweaks. On by default; set `false` to keep the nodes but not manage the Obsidian config. Ignored when `graph_notes` is `false`. |
| `voice_profiles` | map \| null | *(see below)* | **LEGACY — still read, no longer written.** Per-person comms **voice profiles** now live in tier 2, `people/<id>.yaml`. This block holds one person's work email and display name in committed TEAM config, which is the identity leak the three-tier split removes. An existing block keeps resolving (with a one-time warning) so upgrading loses nothing; `/setup --voice` writes `people/<id>.yaml` instead. |

### `voice_profiles` (LEGACY tier-1 location — read, never written)

> New setups put this in **tier 2**: `people/<id>.yaml`, with `identities:` and a `voice:` block.
> See `templates/person.yaml.tmpl`. The shape below is documented because existing repos still have
> it and it still resolves — not because anything should create one.

When set, `/ship` resolves the shipper via `bin/resolve_user.py` and, if a profile exists, uses it
as a **phrasing style guide** for the tracker comment / chat / PR body — always *within* the hard
comms rails (`word_limits`, `hyperlink_everything`, business-first segmentation, the include-list),
never overriding them. Fail-open: an unset field, a missing map entry, or a missing profile file all
degrade to today's behavior.

| Sub-field | Type | Example | Meaning |
|---|---|---|---|
| `path` | template | `voices/{profile_id}.md` | Where each person's profile lives (`{profile_id}` token). |
| `map` | map | `{ "alice@acme.example": alice }` | **Explicit** local-identity → `profile_id`. Keys are `git config user.email`, `git config user.name`, or `$USER` — never fuzzy-normalized. A miss fails open. |

Profiles are **personal data** (a writing fingerprint) and are committed by default; a person who
prefers privacy can gitignore their `voices/<id>.md`. Build/refine them with `/setup --voice`.

## `seams`

Each entry under `seams:` fills one **tool slot**. Six slots carry a verb contract skills call
through (see `adapters/README.md`): `tracker`, `warehouse`, `chat`, `docstore`, `meetings`, `vcs`.
They are not
an exclusive list: an optional `viewer:` entry may also sit here, for a team that standardizes
viewers (see "`viewer` — per-user config" below) — it has a real two-verb contract but is
deliberately per-user config rather than team config. Runtime adapters (`adapters/runtime/`) are
the other non-entry: which agent a person is running is per-machine, so it is never declared in
this file at all. (`seams:` stays the literal key — "seam" is the internal name for a tool slot,
and no config key is renamed.)

A tool slot may be omitted when the repo genuinely has no such tool (see the per-slot notes below);
the skills that use it then degrade rather than fail. Each present slot is **either** a single
mapping (below) **or** a *multi-target* mapping — the `targets:` **shape** is generic to every
slot, but which slots operationally resolve targets today is stated explicitly under "Named
targets". Fields of a single mapping:

| Field | Type | Meaning |
|---|---|---|
| `tool` | string | The concrete tool, e.g. `jira` / `asana` / `monday` / `linear`. |
| `adapter` | path | The playbook that maps the verb contract → this tool's commands. |
| `verify` | string \| null | A **read-only** smoke-test command. `{token}` interpolation from this slot's own keys + `project`. `null` = skip (skills warn). Non-zero exit ⇒ slot "unreachable". |
| `transport` | enum | `cli` \| `mcp` \| `both` — how the adapter talks to the tool. Drives the verify fallback. |
| *(extra keys)* | any | Tool-specific config the adapter reads (site, warehouse, role, channel, base_path, …). |

The `warehouse` slot may be `null`/omitted for non-data repos — `review`, `spec-and-build`, and
`refresh context` degrade gracefully (skip warehouse steps) when it is. `chat` and `docstore` may
likewise be omitted: `/ship` skips those artifacts and names the `/setup` command that would enable
them rather than blocking. `stack.example.solo.yaml` omits both. `meetings` is optional the same
way (add it later with `/setup tool meetings`): when it is omitted, the file-backed intake path —
a human export into `source_materials/` per `project.intake`'s `meetings` convention — keeps
working unchanged, and `/ticket` fetches nothing.

### The `meetings` slot and the meeting-reference contract

`seams.meetings` is a read-only slot: three verbs (`fetch_transcript`, `search_meetings`,
`fetch_action_items` — contract in `adapters/README.md`), a read-only `verify:`, worked example in
`stack.example.multi-audience.yaml`. What a ticket writes to name a meeting is defined here, and
`bin/meeting_refs.py` enforces it at parse time (exit family: 0 ok · 2 usage · 4
malformed-or-refused):

- **One canonical placement:** the YAML frontmatter of a
  `source_materials/YYYY-MM-DD-<slug>-meeting.md` stub, key `meeting_ref:`. A `meeting_ref:` in
  any other filename is refused at parse time (`misplaced-ref`) — never quietly honored or
  dropped.
- **Grammar:** `meeting_ref: <provider>:<id>` — `<provider>` is `[a-z0-9-]+` and must equal the
  configured `seams.meetings.tool` (checked by the calling skill via `bin/effective_config.py`,
  not the parser); `<id>` is the provider's opaque id, charset `[A-Za-z0-9._~/=+-]+`. An id
  needing YAML quoting may be double-quoted; the same charset applies after unquoting.
  Whitespace and shell metacharacters are **refused** — the value interpolates into adapter
  commands (the tier-3 injection-refusal precedent). The charset admits `/`, because real provider
  ids carry one; an adapter that puts the id in a URL **path** therefore percent-encodes it as one
  segment first (Zoom double-encodes those UUIDs), and each adapter states its rule under "ID
  encoding". The parser validates the charset and never encodes — encoding is a per-provider
  decision the adapter owns.
- **Bounded reads, and no silent swallow:** the parser reads only the first 8 KB (bytes, not
  characters) of any file, so a raw transcript misnamed as a stub is never read whole. A frontmatter block that opens and does
  not close inside that bound is a named error (`malformed-frontmatter`), never a silent "no
  reference" — silence is reserved for a valid no-ref state.
- **Optional `meeting_date: YYYY-MM-DD`** as a separate key.
- **Exactly one `meeting_ref:` per stub** (a list is invalid — one meeting per curated note);
  multiple stubs are returned ordered by filename, so the date prefix gives chronology.
- **No reference ⇒ silence:** `{"refs": []}`, exit 0 — the slot never fetches speculatively.
- **Invalid reference ⇒ a named error, never silence** (exit 4, offending file + reason).
- **Credential prohibition:** a value carrying `://`, a `?` query string, or a credential-shaped
  token (`token=`, `access_token`, `key=`, `Bearer `) is refused at parse time with
  `"reason": "refused-credential"` — committed refs never carry URLs or secrets.

### Named targets (more than one tool in a slot)

A repo whose tool slot must hold more than one tool — prod Snowflake plus a Databricks lakehouse,
or two Snowflake accounts — declares **named targets** instead of one flat mapping. The shape is
generic to every slot; the worked (and today the only skill-routed) example is the warehouse:

```yaml
  warehouse:
    default: prod              # REQUIRED when `targets:` is present; must name a key below
    cli: snow                  # slot-level scalars are inherited by every target
    targets:
      prod: { tool: snowflake,  adapter: adapters/warehouse/snowflake.md,  verify: "snow connection test" }
      lake: { tool: databricks, adapter: adapters/warehouse/databricks.md, verify: "…" }
```

| Field | Type | Meaning |
|---|---|---|
| `targets` | map | Named targets. **Its presence is the discriminator** for a multi-target slot. |
| `default` | string | Which target skills use when nothing else selects one. Required with `targets`. |

Rules:

- **Inheritance.** A target inherits any key it doesn't define itself, including `tool` / `adapter` /
  `verify` — so two targets on one account can share all three and differ only in, say,
  `default_warehouse`. A target's own key wins. Inheritance is keyed on *absence*: an explicit
  `verify: null` on a target means "skip", it does not fall back to the slot's command.
- **List the default first.** Readers that predate this feature (an un-relaunched session's statusline
  and SessionStart banner) show the first target they find, so first == default keeps them honest.
  `bin/verify_stack.sh` warns when the default isn't first, and fails when `default` is missing or
  names an unknown target.
- **Which target is active** is resolved per `adapters/README.md` § Multi-target seams — the
  caller-context precedence lives there, and the config half is
  `bin/effective_config.py --seam <slot> [--target <name>]`. A `.sql` file
  names its own target in a `-- warehouse-target: <name>` header comment; that never goes in a CSV,
  whose header must stay on row 1 with no preamble.
- **Operational support is per slot, and stated here explicitly.** The `targets:` shape is legal on
  any slot — `bin/verify_stack.sh` validates it anywhere, and
  `bin/effective_config.py --seam <slot> --target <name>` selects a target on any slot. Three slots
  are routed end to end by skills: **warehouse** (the `.sql` header, the dev-target rule, and the
  `db_write_guard` cross-check), and now **chat** and **docstore** (the delivery plan below).
  **tracker** and **vcs** are deferred — a multi-tracker repo needs target-owned id prefixes and
  per-target URL templates before an id can name its own tracker, and PR routing must be bound to a
  specific remote first. **meetings** is likewise not target-routed: a `meeting_ref:`'s provider
  must equal the slot's single configured `tool`. A `targets:` block on any of these validates,
  but no skill routes between them, and `/ship` halts rather than pretending otherwise.

### Delivery routing for `chat` and `docstore` — declared, never inferred

The warehouse names its target inside the `.sql` file because that file IS the executable artifact.
A chat message and a docstore backup have no such file, so **the declaration lives in the ticket's
`delivery-plan.yaml`** (committed with the ticket; schema in `adapters/README.md` § The delivery
plan). Chat routes on its `audience:`, docstore on its `classification:`, matched **exactly** —
never case-folded, never fuzzy — against the value each target declares:

```yaml
  chat:
    default: internal          # STRUCTURAL only: required by the verifier and shown by pre-routing
    default_mode: draft        # readers. Chat and docstore routing never reads it.
    targets:
      internal:
        audience: internal                 # the routing key a ticket declares
        tool: slack
        adapter: adapters/chat/slack.md
        default_channel: C0XXXXXXXXX       # this tool's destination key (adapter `channel_key:`)
        always_include: [Alice]            # THIS target's list, applied AFTER routing
      client:
        audience: client
        tool: teams                        # a slot may hold two different TOOLS
        adapter: adapters/chat/teams.md
        channel: "19:…@thread.tacv2"       # Teams spells its destination key differently
        always_include: [Dana]
```

| Field | Slot | Meaning |
|---|---|---|
| `audience` | chat target | What a ticket declares to reach this target. Required per target, unique across the slot, never set at slot level (a slot-level scalar would be inherited, and a routing key must never be). |
| `classification` | docstore target | Same, for deliverables — e.g. `internal_archive` vs `client_delivery`. |
| `always_include` | chat target | This target's own non-empty stakeholder list, applied **after** routing. Never inherited from the slot or another target. |
| `sharing_scope` | docstore target | `team` \| `org` \| `external` — the **declared** scope of the destination, printed at the `/ship` approval. |
| *(destination)* | both | The key the adapter names in its `channel_key:` / `destination_key:` frontmatter (Slack `default_channel`, Teams `channel`, the Gmail/Outlook email adapters `to`). Each target must set its own. |

**Email is a chat target, not a slot of its own.** The `gmail`/`outlook` adapters fill a chat target
whose destination key is `to` — ONE address string (a person or a distribution list); extra
recipients belong in that target's `always_include`, rendered as visible Cc. Give an email target
its own `audience:` and its own non-empty `always_include:` like any other, plus an `identity:` —
the shared mailbox mail goes out AS (the adapters' `sender_key:`); routing refuses a named email
target without one, prints it on the `/ship` plan line, and pins it in the fingerprint. Set
`default_mode: draft` on it **explicitly** — an unset `default_mode` is not documented as meaning
draft, and an email cannot be unsent. Worked examples: `stack.example.multi-audience.yaml` (Gmail)
and `stack.example.azure.yaml` (Outlook).

**Docstore routing is per deliverable.** The plan's `classification:` covers the ticket; a
`deliverables:` row may declare its own for one file (a client-facing summary alongside internal
working files). Both are declarations someone wrote — neither is a fallback to a target. Rows are
schema-checked: a row whose `classification:` is present but not a non-empty string, or that
carries an unknown key, is malformed (exit 4) — never a silent fallthrough to the plan-level value.
**The plan-level value is folder-wide**: the backup copies the whole ticket folder, so an external
classification at plan level sends `qc_queries/` and everything else along unless rows split the
internal files out.

**An unresolvable audience is a halt, not a default.** No declaration, or a declared value matching
no target, stops the flow and lists what is configured — it never falls through to `default:` or to
the first-listed target, because that target may be the external one. `/ship` resolves this before
drafting (so the draft carries the right list), prints it at the approval gate — each routed line
carrying a `resolution_fingerprint` — and executes from the same resolution, passing
`--expect-target`/`--expect-fingerprint` back so a config or plan edit after the approval refuses
rather than silently changing the destination, the recipients, or the scope. `--chat <target>`
overrides the declaration explicitly; nothing else does.

**Inheritance vs. fallback.** Slot-level `default_channel` / `default_mode` are still inherited by
targets that do not define their own, per the normal rule — but a *routable* target must name its
own destination, so an inherited channel is never where a routed message lands, and inheritance is
never a fallback when routing fails.

**Every rule above binds only when `targets:` is present.** The **default single-mapping chat shape is
tool-only** — the stack names the tool and transport, with no standing `default_channel` or
`always_include`; the destination and a non-empty recipient list are declared per-communication in
the ticket's `delivery-plan.yaml` (`chat.channel:` + `chat.recipients:`), asked at `/ship`, and
routing halts (exit 9) when a ticket declares none. A single mapping that *does* set a standing
`default_channel` still validates and routes to itself exactly as before (an omitted `always_include`
is allowed there too). `bin/verify_stack.sh` enforces the multi-target rules and **fails** on a
violation (the full table is in `adapters/README.md`).

**A docstore needs no desktop mount.** The `gdrive`/`sharepoint` adapters write into a sync folder,
so they need one installed (per-OS steps:
<https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>). The `rclone` adapter
fills the same slot with no mount at all, across Drive, OneDrive, Dropbox, S3 and Box. It splits the
destination on the same tier line: `remote_path` is the team's destination (tier 1, committed, and
path-only — never prefixed with a remote name) and `target_sentinel` is the team-pinned token that
proves a remote reaches it; the rclone `remote` NAME is per-machine (tier 3), because one person's
alias for an account is not a team decision. The resolver composes `{base_path}` =
`{remote}:{remote_path}` exactly as it composes `{mount_root}/{drive_folder}`, so a tier-3 alias
change moves the `resolution_fingerprint` and refuses rather than redirecting a delivery. Every
rclone command interpolates `{base_path}` rather than the two halves — that is what keeps the
destination a delivery EXECUTES identical to the one a human approved, including when a team pins
`base_path` literally in committed config (which is linted, since it discards the tier split).
Reachability is not identity: `rclone lsd` can succeed against a different account holding the same
path, so the shipped `verify` compares the sentinel's exact contents.

**What the kit does not check.** `sharing_scope` is a declaration: the docstore verify confirms the
destination exists, never its real sharing permissions. Routing a file to the target you meant is
not evidence that the folder's ACL matches the scope you wrote. With `rclone` the blast radius is
wider — an S3 bucket can be public and `rclone link` mints accountless URLs — and none of that is
inspected either.

**Known limitation:** `tickets/OBJECTS.md` and the graph layer fold object names case-insensitively
and are warehouse-blind, so `ANALYTICS.CUSTOMERS` on one target and `analytics.customers` on another
collapse into one node. Usually that's the useful reading (a genuine cross-system relationship), but
it is not a per-target index.

**Dev target.** The dev environment is `seams.warehouse[.targets.<name>].dev_target`. When that key
is absent it falls back to the key named by the warehouse adapter's `dev_key:` frontmatter (`dev_db`
for Snowflake, `dev_dataset` for BigQuery, `dev_catalog` for Databricks, `dev_schema` for
Postgres/Redshift/Synapse) — so configs written before `dev_target` existed keep working untouched.

## Trackerless work (`id_mode: slug`)

Set `id_mode: slug` when the repo has **no ticketing system** — self-defined analysis, a personal or
team notebook. A folder under `tickets/<owner>/` named however you name it becomes the unit of work,
and its `README.md` is the ticket. Pair it with `tracker: local`
([adapter](../../adapters/tracker/local.md)), which maps the tracker verbs onto that folder, and with
`ticket_url_template: null`, since there is nothing external to link to. Worked config:
[`stack.example.solo.yaml`](stack.example.solo.yaml).

What changes:

| | `keyed` (default) | `slug` |
|---|---|---|
| A folder is a ticket when | its name contains a tracker key (`ENG-12`) | its whole name, after an optional leading status emoji, matches `[a-z0-9][a-z0-9_-]*` |
| The id is | the matched key | the whole folder name |
| `key_prefix` | conventional (absent, the index falls back to matching any `LETTERS-digits`) | omit it — the banner and statusline label the repo by its directory |
| Cross-references come from | any `ENG-1234` in the README prose | **only** `[[wiki-links]]` |
| Ordering | date, then ticket number, then id | date, then id (every slug scores 0 on the number) |

Two consequences worth knowing before you adopt it:

- **Cross-references must be explicit.** A slug is free to be an ordinary phrase (`data-quality`), so
  matching prose would turn stray words into catalog rows and graph edges. Only a `[[wiki-link]]`
  naming an existing ticket counts — which is what the graph layer emits anyway. A link inside a
  fenced or inline code block is treated as an example, not a reference.
- **The folder name is the id, so renaming it renames the ticket** — in `INDEX.md`, in `OBJECTS.md`,
  in the graph, and as the branch name. The character set is restricted precisely so an id stays valid
  as a git branch and a filename (dots are excluded because git rejects `a..b`, a trailing `.`, and a
  `.lock` suffix). Two folders that reduce to one id (`signup-lift` and `☑️ signup-lift`) are reported on
  stderr, and the later one wins.

---

## `policies` (the 10 kit policies — see kit README "AI-layer" section)

| Policy | Type | Default | Enforced by |
|---|---|---|---|
| `hard_halt_before_external_posts` | bool | `true` | `ship`, every productized skill — pause for human go before any tracker/chat/docstore write. |
| `db_write_requires_approval` | enum | `high_risk` | the `db_write_guard` hook (Claude Code) + any skill issuing a non-SELECT. See below. |
| `source_material_guard` | `on` \| `off` | `on` | Ask before a raw meeting transcript is staged for commit or copied into a docstore backup. Optional; **defaults to `on`**, and a missing or unparseable value resolves to `on` — unparseable config must never quietly widen what leaves the repo. Enforced by `.claude/hooks/source_material_guard.py` over `bin/scan_source_materials.py`; `/ship` calls the same classifier so the halt is visible where hooks are not wired. Matches filenames and document shape, **never meaning**. |
| `chat_default_draft` | bool | `true` | `chat.draft` not `chat.send` unless the user says "send it". |
| `hyperlink_everything` | bool | `true` | comms skills wrap every ticket-ID / file / PR in a smart link. |
| `skillify_everything` | bool | `true` | recurring work → a `/productize` skill the agent can invoke, not a one-off. |
| `reduce_assumptions` | bool | `true` | ask before building; still document every assumption in the ticket README. |
| `commit_plan_before_implement` | bool | `true` | `spec-and-build` commits the spec/plan artifact before `build` (blame-free retry). |
| `system_evolution` | bool | `true` | `ship` retro: a failure fixes the AI layer (rule/context/command/adapter), not just the ticket. |
| `deterministic_outputs` | bool | `true` | data exports use explicit `ORDER BY`; productized skills ship golden-replay diffs. |
| `human_review_handoff` | enum | `review` | `review` layer ⑤ (and `spec-and-build` under `all`) — open deliverables in the user's own apps and wait for sign-off. See below. |

All are booleans except `db_write_requires_approval` and `human_review_handoff`.

### `db_write_requires_approval` — the one enum

| Value | Behavior | Also accepts |
|---|---|---|
| `off` | Never ask. | `false`, `none`, `null` |
| `high_risk` | **Default.** Ask only for irreversible, access-changing, or unrecognized SQL. | `true`, `destructive` |
| `all` | Ask for any mutation at all. | `strict`, `always` |

Reads (`SELECT`/`SHOW`/`DESCRIBE`/`EXPLAIN`/`WITH … SELECT`/`LIST`/`USE`) pass in every value;
`all` means every *write*, not every command.

Classification is **default-deny**. Only a narrow allowlist is treated as additive — plain
`CREATE` (no `OR REPLACE`), `INSERT INTO` (no `OVERWRITE`), `ALTER … ADD`, and `COMMENT ON`.
Everything else that mutates is high-risk, *including anything the scanner does not recognize*.
Enumerating dangerous forms instead would leave holes: `ALTER TABLE … MODIFY COLUMN` can change
a type and truncate data while matching no plausible "destructive verb" list.

A missing, malformed, or unrecognized value resolves to `all`, never to something weaker —
unparseable config must not quietly widen what runs unprompted. Note the asymmetry: an explicit
legacy `true` *does* relax to `high_risk`, because it is a value someone chose rather than a
value the parser failed on.

Under `bypassPermissions` the hook stays silent and emits a `systemMessage` instead of asking —
the operator has already opted out of prompting, so a prompt there is incoherent. Every other
permission mode gets a normal `ask`. For agents other than Claude Code this policy is
**guidance, not enforcement**: they read it in `AGENTS.md` and are trusted to honor it, since
hooks are the only mechanically enforced layer. And even under Claude Code the hook's
jurisdiction is **Bash**: it inspects warehouse CLI commands in shell payloads (a `-f` file or
stdin redirect included), so SQL issued through a warehouse MCP server never reaches it — on
`transport: mcp` the policy is skill-level guidance there too. Route writes through the CLI.

### `human_review_handoff` — the other enum

Every other pause in the kit guards a side effect *leaving* the machine. This one guards the
opposite: it stops the flow so a person can **look at what was just produced**, in an application
that can actually render it, before the verdict is written.

| Value | Behavior |
|---|---|
| `off` | Never hand files over automatically. |
| `review` | **Default.** At `/review` layer ⑤ only: open `final_deliverables/` + `qc_queries/`, then wait for sign-off. |
| `all` | Also in `spec-and-build build` — the generated SQL before its first warehouse run, and the CSVs after export. |

Under `all` the earlier gates do **not** cancel the review gate: `/review` notes what was already
signed off and focuses on what changed since. Skipping silently is how a deliverable reaches a
verdict unseen, which is the failure this policy exists to prevent.

On-demand is always available whenever the value is not `off` — ask to see anything and the skill
calls `bash bin/handoff.sh <paths>`.

Enforcement is **prose**, like `hard_halt_before_external_posts`: a skill contract, not a hook.
Analysis work does not have a fixed enough shape for a hook to gate it without getting in the way,
and a hook that launched a desktop app on every file write would be a nuisance rather than a gate.

### `viewer` — per-user config, deliberately not in this file

The policy above decides **when** a gate fires; it does not name a single application. Which app
opens a `.sql` is a personal choice — one teammate wants a SQL IDE, another a text editor, a third
wants nothing to open — so that config is **per-user**, resolved first-hit-wins. Its portable half
(which file types you care about) can live in your committed `people/<id>.yaml`; the machine half
(which application) stays in gitignored local files:

| # | Path | Scope |
|---|---|---|
| 1 | `.claude/config/viewer.local.yaml` | you, this repo (gitignored) |
| 2 | `${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml` | you, every repo |
| 2b | `people/<id>.yaml` (globs → categories, committed) + `connections.local.yaml` (categories → apps, gitignored) | you, composed from tiers 2 + 3 |
| 3 | a `viewer:` block under `seams:` in this file | the whole team (committed) |

None present ⇒ nothing opens, regardless of the policy value. Layer 3 exists for a team that wants
to standardize, but it is not the default: a committed entry cannot give each teammate their own
apps, and it cannot ask a new cloner what they want.

The file shape, all keys, and per-platform variants: `.claude/config/viewer.example.yaml`. Adapters:
`adapters/viewer/{macos-open,xdg-open,windows-start}.md`. Check routing without launching anything
with `bash bin/handoff.sh --dry-run <file>`.

`always_include` (under `seams.chat`, optional) — a **standing stakeholder list** added to every chat
message; the "never solo-DM a stakeholder" rule. It is *not* a self-tag. The default tool-only shape
sets no standing list — the recipient list is declared per-ticket in `delivery-plan.yaml`
(`chat.recipients:`, non-empty), asked at `/ship`. Under `targets:` a per-target `always_include`
becomes **required and non-empty there**, enforced by `bin/verify_stack.sh`; a slot-level list is
then dead config (lists are not inherited) and warns.

`include_self` (under `seams.chat`, optional, default off) — when `true`, the chat adapter also
mentions the **shipper** (resolved via `bin/resolve_user.py`) *in addition to* `always_include`.
Keeps the fixed stakeholder list intact instead of overloading it with a per-teammate name.

---

## Worked examples

A worked example lives at [`stack.yaml`](stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub). Six more
prove the abstraction holds with zero skill edits: `stack.example.asana-bq.yaml`
(Asana/BigQuery/Teams/SharePoint/GitLab), `stack.example.azure.yaml`
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos), `stack.example.multi-warehouse.yaml`
(Jira/**Snowflake + Databricks**/Slack/Drive/GitHub — the named-targets shape above),
[`stack.example.multi-audience.yaml`](stack.example.multi-audience.yaml)
(**two audiences** — Slack + Teams in one chat slot, Drive + SharePoint in one docstore slot,
routed by the ticket's declared audience/classification),
`stack.example.no-warehouse.yaml` (**no warehouse slot** — document/report deliverables), and
`stack.example.solo.yaml` (**no tracker at all** — `tracker: local` + `id_mode: slug`, and no chat or
docstore). To validate any config: `bash bin/verify_stack.sh`.
