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
| `branch` | name (`{key_prefix}-NNNN`) | branch created/checked out |
| `worktree` | branch | isolated worktree path (the Plan→Implement context reset) |
| `commit` | paths, message (semantic) | commit sha |
| `open_pr` | title (semantic), body | PR URL |

---

## Adapters shipped

Pick the one matching your stack (or copy the closest as a starting point). All implement the full
verb contract for their seam:

- **tracker:** `jira`, `azure-devops` (Azure Boards), `linear`, `asana`, `monday`, `github-issues`
- **warehouse:** `snowflake`, `bigquery`, `databricks`, `postgres`, `redshift`, `synapse` (also Azure SQL / SQL Server / Fabric)
- **chat:** `slack`, `teams`
- **docstore:** `gdrive`, `sharepoint`
- **vcs:** `github`, `gitlab`, `azure-repos`

Don't see your tool? Adding one is a single file — see "Writing a new adapter" below. Three worked
`stack.yaml` configs ship (Jira/Snowflake/Slack/Drive/GitHub, Asana/BigQuery/Teams/SharePoint/GitLab,
and Azure DevOps/Synapse/Teams/SharePoint/Azure Repos) — the same skills run against all three.

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
