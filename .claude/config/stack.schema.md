# `stack.yaml` — the tool registry (schema + policies)

`stack.yaml` is the **single source of truth** for which concrete tool fills each abstract "seam"
and for the project facts the skills need. Skills never hardcode `acli`, `snow`, `slack`, channel
IDs, epics, or paths — those live **here** and in the per-tool adapters. Swapping Jira→Asana or
Snowflake→BigQuery means editing this file and pointing at a different adapter; **no skill changes.**

`configure-workspace` writes this file by interviewing you and detecting installed tooling.
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

## `seams`

Exactly these five keys: `tracker`, `warehouse`, `chat`, `docstore`, `vcs`. Each:

| Field | Type | Meaning |
|---|---|---|
| `tool` | string | The concrete tool, e.g. `jira` / `asana` / `monday` / `linear`. |
| `adapter` | path | The playbook that maps the verb contract → this tool's commands. |
| `verify` | string \| null | A **read-only** smoke-test command. `{token}` interpolation from this seam's own keys + `project`. `null` = skip (skills warn). Non-zero exit ⇒ seam "unreachable". |
| `transport` | enum | `cli` \| `mcp` \| `both` — how the adapter talks to the tool. Drives the verify fallback. |
| *(extra keys)* | any | Tool-specific config the adapter reads (site, warehouse, role, channel, base_path, …). |

The `warehouse` seam may also be `null`/omitted for non-data repos — `qc-review`, `spec-and-build`,
and `build-context-pack` degrade gracefully (skip warehouse steps) when it is.

## `policies` (the 9 kit policies — see kit README "AI-layer" section)

| Policy | Default | Enforced by |
|---|---|---|
| `hard_halt_before_external_posts` | `true` | `deliver-ticket`, every productized skill — pause for human go before any tracker/chat/docstore write. |
| `db_write_requires_approval` | `true` | any skill issuing a non-SELECT — show SQL, explain, wait for `yes`. |
| `chat_default_draft` | `true` | `chat.draft` not `chat.send` unless the user says "send it". |
| `hyperlink_everything` | `true` | comms skills wrap every ticket-ID / file / PR in a smart link. |
| `commandify_everything` | `true` | recurring work → `productize-workflow`, not a one-off. |
| `reduce_assumptions` | `true` | ask before building; still document every assumption in the ticket README. |
| `commit_plan_before_implement` | `true` | `spec-and-build` commits the spec/plan artifact before `build` (blame-free retry). |
| `system_evolution` | `true` | `deliver-ticket` retro: a failure fixes the AI layer (rule/context/command/adapter), not just the ticket. |
| `deterministic_outputs` | `true` | data exports use explicit `ORDER BY`; productized skills ship golden-replay diffs. |

`always_include` (under `seams.chat`) — names always added to a chat message (e.g. `[Alice]`); the
"never solo-DM a stakeholder" rule.

---

## Worked example

A worked example lives at [`stack.yaml`](stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub). Two more
prove the abstraction holds with zero skill edits: `stack.example.asana-bq.yaml`
(Asana/BigQuery/Teams/SharePoint/GitLab) and `stack.example.azure.yaml`
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos). To validate any config: `bash bin/verify_stack.sh`.
