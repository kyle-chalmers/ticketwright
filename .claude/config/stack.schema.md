# `stack.yaml` — the tool registry (schema + policies)

`stack.yaml` is the **single source of truth** for which concrete tool fills each abstract "seam"
and for the project facts the skills need. Skills never hardcode `acli`, `snow`, `slack`, channel
IDs, epics, or paths — those live **here** and in the per-tool adapters. Swapping Jira→Asana or
Snowflake→BigQuery means editing this file and pointing at a different adapter; **no skill changes.**

The `setup` skill writes this file by interviewing you and detecting installed tooling.
`bin/verify_stack.sh` reads it to smoke-test every seam. Every skill reads it at preflight.

---

## Top-level shape

```yaml
project:        # facts about this workspace, tool-independent
seams:          # one entry per abstract seam → concrete tool + adapter + verify
policies:       # behavioral rules every skill inherits (the kit's "global rules")
```

---

## `project`

| Field | Type | Example | Meaning |
|---|---|---|---|
| `key_prefix` | string | `ENG` | Ticket-ID prefix. Branch names = `{key_prefix}-NNNN`. Omit it when `id_mode: slug` — there are no keys to prefix. |
| `id_mode` | enum | `keyed` | `keyed` (default) = folder names carry a tracker key; `slug` = the folder name **is** the id. See "Trackerless work". |
| `key_prefixes` | list | `[ENG]` | Prefixes the ticket index recognizes in folder names. Optional; defaults to `[key_prefix]`. Use when one repo holds tickets from several trackers (e.g. `[ENG, OPS]`). |
| `assignee_dir` | string | `alice` | Default owner subdir under `tickets/`. |
| `ticket_path` | template | `tickets/{assignee}/{id}` | Where a ticket folder lives. `{assignee}` `{id}` tokens. |
| `ticket_subdirs` | list | `[source_materials, final_deliverables, qc_queries, exploratory_analysis]` | Scaffolded per ticket. |
| `default_epic` | string \| null | `ENG-100` | Parent epic for newly created tickets (null if tracker has no epics). |
| `terminal_status` | string | `Done` | The "done" workflow state (not always "Done"). |
| `ticket_url_template` | template \| null | `https://acme.atlassian.net/browse/{id}` | How `tickets/INDEX.md` links each ticket (`{id}` token). Null/omitted → the index renders no per-ticket link. |
| `word_limits` | map | `{tracker_comment: 100, chat: 100, pr: 200, ticket: 200}` | Hard caps the comms skills enforce. |
| `graph_notes` | bool | `true` | Generate the Obsidian graph layer (`tickets/graph/` + `tickets/objects/`). On by default; set `false` to disable. |
| `graph_config` | bool | `true` | Also write/merge `.obsidian/graph.json` (tickets↔objects filter + color groups) so the Graph view opens ready-to-read. Create/merge-only — never clobbers manual tweaks. On by default; set `false` to keep the nodes but not manage the Obsidian config. Ignored when `graph_notes` is `false`. |

## `seams`

These five keys: `tracker`, `warehouse`, `chat`, `docstore`, `vcs` — no others. A seam may be
omitted when the repo genuinely has no such tool (see the per-seam notes below); the skills that use
it then degrade rather than fail. Each present seam is **either** a single mapping (below) **or** a
*multi-target* mapping — see "Multiple warehouses". Fields of a single mapping:

| Field | Type | Meaning |
|---|---|---|
| `tool` | string | The concrete tool, e.g. `jira` / `asana` / `monday` / `linear`. |
| `adapter` | path | The playbook that maps the verb contract → this tool's commands. |
| `verify` | string \| null | A **read-only** smoke-test command. `{token}` interpolation from this seam's own keys + `project`. `null` = skip (skills warn). Non-zero exit ⇒ seam "unreachable". |
| `transport` | enum | `cli` \| `mcp` \| `both` — how the adapter talks to the tool. Drives the verify fallback. |
| *(extra keys)* | any | Tool-specific config the adapter reads (site, warehouse, role, channel, base_path, …). |

The `warehouse` seam may be `null`/omitted for non-data repos — `review`, `spec-and-build`, and
`refresh context` degrade gracefully (skip warehouse steps) when it is. `chat` and `docstore` may
likewise be omitted: `/ship` skips those artifacts and names the `/setup` command that would enable
them rather than blocking. `stack.example.solo.yaml` omits both.

### Multiple warehouses (named targets)

A repo that must reach more than one warehouse — prod Snowflake plus a Databricks lakehouse, or two
Snowflake accounts — declares **named targets** instead of one flat mapping:

```yaml
  warehouse:
    default: prod              # REQUIRED when `targets:` is present; must name a key below
    cli: snow                  # seam-level scalars are inherited by every target
    targets:
      prod: { tool: snowflake,  adapter: adapters/warehouse/snowflake.md,  verify: "snow connection test" }
      lake: { tool: databricks, adapter: adapters/warehouse/databricks.md, verify: "…" }
```

| Field | Type | Meaning |
|---|---|---|
| `targets` | map | Named targets. **Its presence is the discriminator** for a multi-target seam. |
| `default` | string | Which target skills use when nothing else selects one. Required with `targets`. |

Rules:

- **Inheritance.** A target inherits any key it doesn't define itself, including `tool` / `adapter` /
  `verify` — so two targets on one account can share all three and differ only in, say,
  `default_warehouse`. A target's own key wins. Inheritance is keyed on *absence*: an explicit
  `verify: null` on a target means "skip", it does not fall back to the seam's command.
- **List the default first.** Readers that predate this feature (an un-relaunched session's statusline
  and SessionStart banner) show the first target they find, so first == default keeps them honest.
  `bin/verify_stack.sh` warns when the default isn't first, and fails when `default` is missing or
  names an unknown target.
- **Which target is active** is resolved per `adapters/README.md` § Multi-target seams. A `.sql` file
  names its own target in a `-- warehouse-target: <name>` header comment; that never goes in a CSV,
  whose header must stay on row 1 with no preamble.
- v1 implements multi-target for **`warehouse`** only. `verify_stack.sh` handles the shape for any
  seam, but no skill resolves targets for the other four, so don't rely on it there yet.

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
  `.lock` suffix). Two folders that reduce to one id (`refi-lift` and `☑️ refi-lift`) are reported on
  stderr, and the later one wins.

---

## `policies` (the 9 kit policies — see kit README "AI-layer" section)

| Policy | Type | Default | Enforced by |
|---|---|---|---|
| `hard_halt_before_external_posts` | bool | `true` | `ship`, every productized skill — pause for human go before any tracker/chat/docstore write. |
| `db_write_requires_approval` | enum | `high_risk` | the `db_write_guard` hook (Claude Code) + any skill issuing a non-SELECT. See below. |
| `chat_default_draft` | `true` | `chat.draft` not `chat.send` unless the user says "send it". |
| `hyperlink_everything` | `true` | comms skills wrap every ticket-ID / file / PR in a smart link. |
| `skillify_everything` | `true` | recurring work → a `/productize` skill the agent can invoke, not a one-off. |
| `reduce_assumptions` | `true` | ask before building; still document every assumption in the ticket README. |
| `commit_plan_before_implement` | `true` | `spec-and-build` commits the spec/plan artifact before `build` (blame-free retry). |
| `system_evolution` | `true` | `ship` retro: a failure fixes the AI layer (rule/context/command/adapter), not just the ticket. |
| `deterministic_outputs` | `true` | data exports use explicit `ORDER BY`; productized skills ship golden-replay diffs. |

All are booleans except `db_write_requires_approval`.

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
hooks are the only mechanically enforced layer.

`always_include` (under `seams.chat`) — names always added to a chat message (e.g. `[Alice]`); the
"never solo-DM a stakeholder" rule.

---

## Worked examples

A worked example lives at [`stack.yaml`](stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub). Four more
prove the abstraction holds with zero skill edits: `stack.example.asana-bq.yaml`
(Asana/BigQuery/Teams/SharePoint/GitLab), `stack.example.azure.yaml`
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos), `stack.example.multi-warehouse.yaml`
(Jira/**Snowflake + Databricks**/Slack/Drive/GitHub — the named-targets shape above), and
`stack.example.solo.yaml` (**no tracker at all** — `tracker: local` + `id_mode: slug`, and no chat or
docstore). To validate any config: `bash bin/verify_stack.sh`.
