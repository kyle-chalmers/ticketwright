# Architecture — how Ticketwright is built

This is the contributor-facing map. Users don't need any of this; [the README](../README.md)
quickstart is enough to work tickets.

## The AI-layer model

Every repo has a **code layer** (the work) and an **AI layer** (the rules + context + workflows
that guide an agent), versioned together. The AI layer has three tiers:

| Tier | Here | Loaded |
|---|---|---|
| **Global rules** | `AGENTS.md` (rendered from `templates/AGENTS.md.tmpl`) | always |
| **On-demand context** | the `documentation/` pack · `/ticket`'s priming slices · `tickets/INDEX.md` + `OBJECTS.md` | selectively |
| **Skills** | `.claude/skills/` (7) + deprecated v1 aliases in `.claude/commands/` | on invocation |

The lifecycle the skills implement — plan → build → check → ship — descends from the PIV loop
(Plan → Implement → Validate) in Cole Medin's "agentic engineering" / Archon material, which also
supplied the AI-layer model and the context-engineering stance (AI fails from missing context, not
weak models).

## Seams, adapters, and the verb contract

A **seam** is a tool slot the kit needs filled: `tracker`, `warehouse`, `chat`, `docstore`, `vcs`.
The wiring is hybrid — config names the tools, verification proves them:

1. **`.claude/config/stack.yaml`** names which tool fills each seam + project facts + the 9
   policies. Schema: [.claude/config/stack.schema.md](../.claude/config/stack.schema.md).
2. **`adapters/<seam>/<tool>.md`** maps the abstract **verb contract** (`fetch_ticket`, `query`,
   `draft`, `backup`, `commit`, …) to that tool's concrete commands. Contract:
   [adapters/README.md](../adapters/README.md).
3. **`bin/verify_stack.sh`** pings each seam's read-only `verify` before use — reachable seams
   run, unreachable ones halt with the adapter's auth notes.

Skills are written **once against verbs** and never name a tool. Swapping a tool = edit
`stack.yaml` + point at a different adapter; **no skill changes.** Proof: three configs ship —
[`stack.yaml`](../.claude/config/stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub),
[`stack.example.asana-bq.yaml`](../.claude/config/stack.example.asana-bq.yaml)
(Asana/BigQuery/Teams/SharePoint/GitLab), and
[`stack.example.azure.yaml`](../.claude/config/stack.example.azure.yaml)
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos) — the same skills run against all three.

**Adding a tool:** write one adapter (copy the closest reference in the same seam; implement every
verb section; keep the frontmatter), add a `verify` line to your `stack.yaml` seam, run
`bash bin/verify_stack.sh`. No skill edits.

## Policy enforcement (hooks)

Policies are only as good as the agent's memory unless something enforces them. The plugin ships
Claude Code hooks (declared in `.claude-plugin/plugin.json`; `setup` also wires them into a repo's
`.claude/settings.json` for non-plugin installs):

- **`db_write_guard.py`** (PreToolUse/Bash) — makes `db_write_requires_approval` mechanical: asks
  before any destructive warehouse statement (CREATE/ALTER/DROP/DELETE/UPDATE/INSERT/TRUNCATE/
  MERGE/GRANT/REVOKE), **including SQL hidden in a `-f` file or a stdin redirect**; read-only
  SELECT/DESCRIBE/SHOW pass straight through.
- **`session_context.py`** (SessionStart) — primes every session with the configured stack, the
  skills, and the lifecycle.
- **`ticket_index_context.py`** (SessionStart) — surfaces the ticket catalog (counts + most recent
  tickets + a pointer to grep `tickets/INDEX.md` before starting related work).
- **`regenerate_ticket_index.py`** (PostToolUse/Write·Edit) — re-renders `tickets/INDEX.md`
  whenever a ticket folder changes.

Hooks are the one Claude-Code-specific layer; the rest of the kit is agent-agnostic. Other agents
enforce the same policies via the skill-level hard-halts.

## What's inside

- **7 skills** (`.claude/skills/`): setup, ticket, spec-and-build, review, ship, productize,
  refresh — each SKILL.md is short, with depth in per-skill reference files
  (`ticket/priming.md`, `setup/adopt.md`, `productize/authoring.md`, …).
- **12 deprecated aliases** (`.claude/commands/`): the v1 names, each a stub routing to its v2
  skill; removed in v3.
- **1 sub-agent** (`.claude/agents/`): `qc-reviewer` — the independent-context reviewer `/review`
  delegates to (one per pyramid layer in `--deep` mode).
- **4 hooks + settings** (`.claude/hooks/`, `.claude/settings.json.tmpl`, `.claude/statusline.sh`).
- **19 adapters** (`adapters/`) across 5 seams — full verb coverage each.
- **Templates** (`templates/`): AGENTS.md, ticket README, plan, spec, `.gitignore` (anchored
  `**/final_deliverables/*.csv` PII guard), role snippets, and the productized-skill skeleton.
- **`bin/`**: `verify_stack.sh`, `render.sh` + `render_and_validate.sh` (render gate),
  `split_and_export.sh`, `selftest.sh` (the CI suite + hook unit tests), and the index/recall
  engines (`build_ticket_index.py`, `ingest_index_records.py`, `enrich_ticket.py`, `recall.py`) —
  all stdlib-only.
- **`ticketwright/`**: the pip package; the wheel bundles the kit under `ticketwright/_kit/` via
  `pyproject.toml` force-includes, so the repo layout is the single source.

## Design stances

- **No vector store.** Recall is lexical + structural (object match ×4, tag ×3, cross-ref +5,
  keyword ×1, IDF down-weighting, recency tiebreak) over a deterministic index. The
  rank → read-top-K shape scales past the point where the whole index fits in context.
- **Deterministic before model.** Catalog rendering, recall ranking, render validation, and export
  plumbing are all plain code the model *calls*, not prose the model *approximates*.
- **Degrade, don't die.** Missing seams skip their steps and name the fix (`/setup chat`);
  unreachable seams halt with auth notes only where proceeding blind would be wrong.
- **Out of scope (deliberately):** a heavy external knowledge-base/orchestration service
  (Archon-style retrieval over MCP). Task management is the tracker's job; orchestration is
  `/productize` + the host agent's own subagents.
