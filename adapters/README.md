# Adapters — the verb contract

Skills are written **once** against abstract *verbs*. An **adapter** is a small markdown playbook
that translates those verbs into one concrete tool's commands. To support a new tool (Asana, BigQuery,
Teams, …) you write **one adapter** — you never touch a skill.

```
skill  ──calls──▶  verb (e.g. tracker.fetch_ticket)
                     │
   stack.yaml ──picks──▶ adapter (tracker/jira.md)
                     │
                     ▼
            concrete command (acli jira workitem view DI-123)
```

A skill resolves a verb like this:
1. Read `stack.yaml` → `seams.<seam>.adapter`.
2. Open that adapter, find the verb's section.
3. Run the command shown there, substituting `{tokens}` from `stack.yaml` + skill args.
4. If `seams.<seam>.verify` fails first (hybrid preflight), **halt** with the adapter's auth notes.

Every adapter file has the same shape: a **frontmatter** block (seam, tool, transport, required
config keys, auth/setup notes) followed by one `## verb: <name>` section per verb in that seam's
contract. A verb section gives the command(s), inputs, the expected output shape, and any gotchas.

---

## The contract (verbs by seam)

### `tracker` — the ticket system
| Verb | Inputs | Returns |
|---|---|---|
| `fetch_ticket` | `id` | title, description, status, type, assignee, links, attachments list |
| `create_ticket` | type, summary, description, assignee, parent/epic | new `id` + URL |
| `transition` | `id`, `status` | ok/fail |
| `comment` | `id`, body, optional smart-link cards | ok/fail (rendered, not plain text) |
| `search` | query (JQL/equivalent), limit | list of `{id, summary, status}` |
| `download_attachments` | `id`, dest dir | files written (silent if none) |

### `warehouse` — the data/work backend
| Verb | Inputs | Returns |
|---|---|---|
| `query` | SQL, optional `--format csv` | rows / CSV (header row 1, no preamble) |
| `describe` | object name | columns + types (and DDL when supported) |
| `dialect_notes` | — | *static section*: function names, sizing model, dedup idiom, type-cast rules, the warehouse-specific anti-patterns the `review` skill checks |

### `chat` — team messaging
| Verb | Inputs | Returns |
|---|---|---|
| `draft` | channel, body, mentions | a saved draft (human clicks send) |
| `send` | channel, body, mentions | posted message (only on explicit "send it") |
| `lookup_user` | name/email | user ID for mentions |
| `lookup_channel` | name | channel ID |

### `docstore` — durable backup + shareable links
| Verb | Inputs | Returns |
|---|---|---|
| `backup` | local ticket dir, dest name | files copied to the store |
| `link_for` | a backed-up file | a shareable URL (for tracker/chat smart links) |

### `vcs` — version control + PRs
| Verb | Inputs | Returns |
|---|---|---|
| `branch` | name (the ticket id — `{key_prefix}-NNNN`, or the folder slug under `id_mode: slug`) | branch created/checked out |
| `worktree` | branch | isolated worktree path (the Plan→Implement context reset) |
| `commit` | paths, message (semantic) | commit sha |
| `open_pr` | title (semantic), body | PR URL |

---

## Multi-target seams

A seam normally names one tool. A repo that must reach more than one warehouse — prod Snowflake plus
a lakehouse, or two accounts of the same warehouse — declares **named targets** instead:

```yaml
seams:
  warehouse:
    default: prod          # required when `targets:` is present
    cli: snow              # seam-level scalars are inherited by every target
    targets:
      prod: { tool: snowflake,  adapter: adapters/warehouse/snowflake.md,  verify: "…" }
      lake: { tool: databricks, adapter: adapters/warehouse/databricks.md, verify: "…" }
```

`targets:` — not `default:` — is what marks a seam multi-target, because other seams already use
`default_channel` / `default_mode` / `default_branch`. Full field docs: `stack.schema.md`.

### Resolving the active target

First hit wins:

1. an explicit `--warehouse <name>` on the invocation;
2. the `-- warehouse-target: <name>` header comment in the `.sql` file being run or linted;
3. the ticket's declared target — the spec's `primary_target`, else the ticket README's target line;
4. `seams.warehouse.default`;
5. the seam itself, when it is a single mapping (call it `default` in reports).

An unresolvable name is a **halt**: say which names are configured. Never quietly fall back to the
default, because that is precisely the wrong-warehouse failure.

### One file, one target

Line 1 of every `.sql` file names its target:

```sql
-- warehouse-target: lake
```

That one token drives execution, the dialect lint, and the re-run, so it cannot drift from reality
the way a separate annotation would. A ticket spanning two targets carries two sets of files.

**Never put this in a CSV.** A deliverable CSV must keep its header on row 1 with no preamble.
Record a CSV's target in the ticket README's deliverables list instead.

The header is **required only in a multi-target repo**. In a single-warehouse repo its absence is
correct and silent — otherwise every existing ticket everywhere becomes non-conformant.

Two things check it, deliberately:

- **`/review`** flags a headerless or mismatched `.sql` as a Should-fix finding. This is the
  authoritative half — it reads the header directly and works under any agent.
- **the `db_write_guard` hook** prompts *before* a command runs when the invoked CLI doesn't match
  the header's target, including for read-only SQL, since a read on the wrong warehouse returns
  plausible wrong numbers rather than an error. This half is best-effort: it resolves the target's
  CLI with a stdlib scan, and stays silent on anything it can't read confidently (a flow mapping for
  the whole `targets:` value, a target defined by a YAML alias). It is also Claude-Code-only, because
  hooks don't run under other agents.

So the hook catches things earlier and the review catches them more reliably. Neither replaces the
other, which is why both exist.

### Resolving the dev target

`dev_target` on the resolved target, else the key named by that target's adapter `dev_key:`
frontmatter. Adapters spell their own legacy key; skills never name one.

### Cross-target work is out of scope

Routing a query to the right warehouse is this kit's job. Joining data *across* warehouses is not,
and the boundary is deliberate: moving rows between them is a write subject to
`db_write_requires_approval`, the extract side is a governance decision the kit has no vocabulary
for (note `pii_role` is a *per-target* key), and a hand-rolled bridge breaks `deterministic_outputs`.
A team that genuinely needs it already has federation configured in the warehouse, where the
federated objects are reachable from one target and need no support here.

The supported shape is two single-target queries → two exports → an explicit local combine step,
documented in the spec, whose reconciliation is a validation gate.

## Adapters shipped

Pick the one matching your stack (or copy the closest as a starting point). All implement the full
verb contract for their seam:

- **tracker:** `jira`, `azure-devops` (Azure Boards), `linear`, `asana`, `monday`, `github-issues`,
  `local` (**no tracker at all** — the ticket folder itself; pair with `project.id_mode: slug`)
- **warehouse:** `snowflake`, `bigquery`, `databricks`, `postgres`, `redshift`, `synapse` (also Azure SQL / SQL Server / Fabric)
- **chat:** `slack`, `teams`
- **docstore:** `gdrive`, `sharepoint`
- **vcs:** `github`, `gitlab`, `azure-repos`

Don't see your tool? Adding one is a single file — see "Writing a new adapter" below. Five worked
`stack.yaml` configs ship — Jira/Snowflake/Slack/Drive/GitHub, Asana/BigQuery/Teams/SharePoint/GitLab,
Azure DevOps/Synapse/Teams/SharePoint/Azure Repos, Snowflake **+** Databricks (two warehouse targets
in one seam), and a solo repo with **no tracker and no chat/docstore**. The same skills run against
all five, unedited — which is the claim those configs exist to keep honest.

> **MCP-transport adapters** (Asana, Linear, Monday, Teams, Slack) reference each operation with a
> server-namespaced placeholder like `mcp__<server>__<op>`. The exact tool name + parameters depend on
> your connected MCP server — confirm them once and adjust the adapter (never the skills).

## Writing a new adapter

1. Copy the closest reference adapter in the same seam.
2. Keep the frontmatter keys (`seam`, `tool`, `transport`, `requires`, `auth`).
3. Implement **every** verb section for that seam — if the tool can't do one, say so and give the
   manual fallback (skills will surface it rather than silently skipping).
4. Add a `verify` command to your `stack.yaml` seam entry (read-only, exits non-zero when unreachable).
5. Run `bash bin/verify_stack.sh` — it confirms each seam's adapter file exists and runs the seam's
   read-only `verify` to check reachability. (`bash bin/selftest.sh` checks verb coverage vs. this contract.)

**Rule:** adapters may name concrete tools/CLIs/IDs freely. **Skills may not.** `bin/selftest.sh`
(section 3) enforces this: it greps `.claude/skills/**` + `.claude/commands/**` for tool names, with
two sanctioned exceptions (the CLI-detection probe in `setup` and the self-lint line in
`productize`).
