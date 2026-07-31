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
| `key_prefix` | string | `ENG` | Ticket-ID prefix. Branch names = `{key_prefix}-NNNN`. |
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

Exactly these five keys: `tracker`, `warehouse`, `chat`, `docstore`, `vcs`. Each is **either** a
single mapping (below) **or** a *multi-target* mapping — see "Multiple warehouses". Fields of a
single mapping:

| Field | Type | Meaning |
|---|---|---|
| `tool` | string | The concrete tool, e.g. `jira` / `asana` / `monday` / `linear`. |
| `adapter` | path | The playbook that maps the verb contract → this tool's commands. |
| `verify` | string \| null | A **read-only** smoke-test command. `{token}` interpolation from this seam's own keys + `project`. `null` = skip (skills warn). Non-zero exit ⇒ seam "unreachable". |
| `transport` | enum | `cli` \| `mcp` \| `both` — how the adapter talks to the tool. Drives the verify fallback. |
| *(extra keys)* | any | Tool-specific config the adapter reads (site, warehouse, role, channel, base_path, …). |

The `warehouse` seam may also be `null`/omitted for non-data repos — `review`, `spec-and-build`,
and `refresh context` degrade gracefully (skip warehouse steps) when it is.

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

## `policies` (the 9 kit policies — see kit README "AI-layer" section)

| Policy | Default | Enforced by |
|---|---|---|
| `hard_halt_before_external_posts` | `true` | `ship`, every productized skill — pause for human go before any tracker/chat/docstore write. |
| `db_write_requires_approval` | `true` | any skill issuing a non-SELECT — show SQL, explain, wait for `yes`. |
| `chat_default_draft` | `true` | `chat.draft` not `chat.send` unless the user says "send it". |
| `hyperlink_everything` | `true` | comms skills wrap every ticket-ID / file / PR in a smart link. |
| `skillify_everything` | `true` | recurring work → a `/productize` skill the agent can invoke, not a one-off. |
| `reduce_assumptions` | `true` | ask before building; still document every assumption in the ticket README. |
| `commit_plan_before_implement` | `true` | `spec-and-build` commits the spec/plan artifact before `build` (blame-free retry). |
| `system_evolution` | `true` | `ship` retro: a failure fixes the AI layer (rule/context/command/adapter), not just the ticket. |
| `deterministic_outputs` | `true` | data exports use explicit `ORDER BY`; productized skills ship golden-replay diffs. |

`always_include` (under `seams.chat`) — names always added to a chat message (e.g. `[Alice]`); the
"never solo-DM a stakeholder" rule.

---

## Worked example

A worked example lives at [`stack.yaml`](stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub). Three more
prove the abstraction holds with zero skill edits: `stack.example.asana-bq.yaml`
(Asana/BigQuery/Teams/SharePoint/GitLab), `stack.example.azure.yaml`
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos), and `stack.example.multi-warehouse.yaml`
(Jira/**Snowflake + Databricks**/Slack/Drive/GitHub — the named-targets shape above). To validate any
config: `bash bin/verify_stack.sh`.
