# Agentic Ticket Harness

A **portable, tool-agnostic agentic-engineering harness** for ticket-driven work repos (data
intelligence, analytics, ops, regulatory reporting…). Drop it into a repo, run
`/configure-workspace`, and you get a complete **AI layer**: global rules, on-demand context loaders,
reusable PIV-loop workflows, and a self-maintaining ticket index — bound to *your* tools (Jira **or**
Asana **or** Monday/Linear; Snowflake **or** BigQuery/Databricks; Slack **or** Teams; Drive **or**
SharePoint; GitHub **or** GitLab) through one config file and thin adapters.

Generalized from a production data-engineering ticket repo; informed by Cole Medin's "agentic
engineering" / Archon material (the AI-layer model, the PIV loop, context engineering).

## The idea: the "AI layer"

Every repo has a **code layer** (the work) and an **AI layer** (the rules + context + workflows that
guide an agent). You version the AI layer alongside the code. It has three tiers:

| Tier | Here | Loaded |
|---|---|---|
| **Global rules** | `AGENTS.md` (rendered from `templates/AGENTS.md.tmpl`) | always |
| **On-demand context** | the `documentation/` pack + the `/prime-*` commands + `tickets/INDEX.md` | selectively |
| **Commands & skills** | `.claude/skills/` + `.claude/commands/` | on invocation |

…driven by the **PIV loop — Plan → Implement → Validate:**

```
PLAN        /start-ticket   (+ /prime-ticket, /prime-warehouse, /prime-domain)
IMPLEMENT   /spec-and-build  spec → (commit) → build      (research-in-parallel, never implement)
VALIDATE    /qc-review  →  /deliver-ticket                (pyramid; hard-halt before external posts)
META        /productize-workflow  ·  /build-context-pack  ·  /build-ticket-index
SETUP       /configure-workspace   (once)             ·   /onboard-teammate     (new person)
```

## How tooling is wired (hybrid: config + verify)

1. **`.claude/config/stack.yaml`** names which tool fills each *seam* (tracker, warehouse, chat,
   docstore, vcs) + project facts + the 9 policies. (Schema: `.claude/config/stack.schema.md`.)
2. **`adapters/<seam>/<tool>.md`** maps the abstract **verb contract** (`fetch_ticket`, `query`,
   `draft`, `backup`, `commit`, …) to that tool's concrete commands. (Contract: `adapters/README.md`.)
3. **`bin/verify_stack.sh`** pings each seam's read-only `verify` before use — reachable seams run,
   unreachable ones halt with the adapter's auth notes (the hybrid half).

Skills are written **once against verbs** and never name a tool. Swapping a tool = edit `stack.yaml`
+ point at a different adapter; **no skill changes.** Proof: two configs ship —
[`stack.yaml`](.claude/config/stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub) and
[`stack.example.asana-bq.yaml`](.claude/config/stack.example.asana-bq.yaml)
(Asana/BigQuery/Teams/SharePoint/GitLab) — the same skills run against both.

## Install into a repo

Copy the four directories into your work repo, then configure:

```bash
# from a clone of this repo (or use GitHub's "Use this template")
cp -r .claude   <your-repo>/.claude          # skills, commands, hooks, agents, config, settings.tmpl, statusline
cp -r adapters templates bin   <your-repo>/

cd <your-repo>
/configure-workspace        # detects tooling, interviews, writes stack.yaml + AGENTS.md + settings.json, wires hooks, scaffolds, verifies
bash bin/selftest.sh        # kit integrity + hook unit tests — expect "0 failed"
```

## Add a new tool

Write **one adapter** (copy the closest reference in the same seam; implement every verb section;
keep the frontmatter), add a `verify` line to your `stack.yaml` seam, and run
`bash bin/verify_stack.sh`. No skill edits. See `adapters/README.md`.

## Harness enforcement (hooks)

Policies are only as good as the agent's memory unless something enforces them. The kit ships Claude
Code **hooks** (wired by `configure-workspace` into `.claude/settings.json`):

- **`db_write_guard.py`** (PreToolUse/Bash) — turns `db_write_requires_approval` into a *mechanical*
  ask: it inspects warehouse-CLI commands and **asks before any destructive statement**
  (CREATE/ALTER/DROP/DELETE/UPDATE/INSERT/TRUNCATE/MERGE/GRANT/REVOKE), **including SQL hidden in a
  `-f` file** — read-only `SELECT`/`DESCRIBE`/`SHOW` pass straight through.
- **`session_context.py`** (SessionStart) — primes every session with the configured stack, the
  available skills/commands, and the PIV loop (the always-on context slice).
- **`ticket_index_context.py`** (SessionStart) — surfaces the ticket catalog: counts + the most
  recent tickets + a pointer to grep `tickets/INDEX.md` before starting related work.
- **`regenerate_ticket_index.py`** (PostToolUse/Write·Edit) — re-renders `tickets/INDEX.md` whenever
  a ticket folder changes, so the catalog is never stale.

Hooks are the one Claude-Code-specific layer; the rest of the kit is agent-agnostic. Other agents
enforce the same policies via the skill-level hard-halts.

## Ticket index — recall before you rebuild

`tickets/INDEX.md` is an auto-maintained catalog of **every** ticket (status, one-line summary, tags,
cross-references) that the agent reads at session start, so prior work is recalled before new work
begins. It's split into a **deterministic renderer** (`bin/build_ticket_index.py`, stdlib-only,
byte-stable, `--check` gate) and a **curated store** (`tickets/index_data.json`) that the model
writes — so the catalog is reproducible *and* readable. It self-maintains: the PostToolUse hook keeps
it complete on every folder change, and `deliver-ticket` curates a ticket's summary at close. Bootstrap
an existing backlog with `/build-ticket-index --all`. Full details: [`docs/ticket-index.md`](docs/ticket-index.md).

## What's inside

- **9 skills** (`.claude/skills/`): configure-workspace, onboard-teammate, start-ticket,
  spec-and-build, qc-review, deliver-ticket, productize-workflow, build-context-pack, build-ticket-index.
- **3 prime commands** (`.claude/commands/`): prime-ticket, prime-warehouse, prime-domain.
- **1 sub-agent** (`.claude/agents/`): `qc-reviewer` — independent-context reviewer `qc-review` delegates to.
- **4 hooks + settings** (`.claude/hooks/`, `.claude/settings.json.tmpl`, `.claude/statusline.sh`):
  policy enforcement, session priming, ticket-index surfacing + auto-regen, status line.
- **Adapters** (`adapters/`): 5 working references + 8 stubs filled to full verb coverage.
- **Templates** (`templates/`): AGENTS.md, ticket README, plan, spec, and the productized-skill skeleton.
- **`bin/`**: `verify_stack.sh` (hybrid verify), `render.sh` (token renderer), `selftest.sh` (kit
  test suite + hook unit tests), and the ticket-index tools (`build_ticket_index.py`,
  `ingest_index_records.py`, `enrich_ticket.py`).

## Still out of scope (deferred)

The heavy external "knowledge-base + orchestration" harness (Archon-style retrieval over MCP):
skipped. Task management is the tracker's job; orchestration is `productize-workflow` + the host
agent's own subagents. The ticket index covers in-repo recall without any vector store or service.

## License

MIT — see [`LICENSE`](LICENSE).
