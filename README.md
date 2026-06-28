# Ticketwright

[![CI](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml/badge.svg)](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/tag/kyle-chalmers/ticketwright?label=release&sort=semver&color=blue)](https://github.com/kyle-chalmers/ticketwright/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Python](https://img.shields.io/badge/python-3%20%C2%B7%20stdlib--only-3776AB)
![tool-agnostic](https://img.shields.io/badge/seams-tracker%20%C2%B7%20warehouse%20%C2%B7%20chat%20%C2%B7%20docstore%20%C2%B7%20vcs-success)

**Ticketwright** is a portable, tool-agnostic **AI layer** for ticket-driven work repos (data
intelligence, analytics, ops, regulatory reporting…). Drop it into a repo, run
`/configure-workspace`, and you get a complete **AI layer**: global rules, on-demand context loaders,
reusable PIV-loop workflows, and a self-maintaining ticket index — bound to *your* tools (Jira,
**Azure DevOps**, Linear, Asana, Monday, or GitHub Issues; Snowflake, BigQuery, Databricks, Postgres,
Redshift, or Synapse/Azure SQL; Slack or Teams; Drive or SharePoint; GitHub, GitLab, or Azure Repos)
through one config file and thin adapters. Don't see your tool? Adding one is a single adapter file.

Generalized from a production data-engineering ticket repo; informed by Cole Medin's "agentic
engineering" / Archon material (the AI-layer model, the PIV loop, context engineering).

## The idea: the "AI layer"

Every repo has a **code layer** (the work) and an **AI layer** (the rules + context + workflows that
guide an agent). You version the AI layer alongside the code. It has three tiers:

| Tier | Here | Loaded |
|---|---|---|
| **Global rules** | `AGENTS.md` (rendered from `templates/AGENTS.md.tmpl`) | always |
| **On-demand context** | the `documentation/` pack · `/prime-*` + `/recall` · `tickets/INDEX.md` + `OBJECTS.md` | selectively |
| **Commands & skills** | `.claude/skills/` + `.claude/commands/` | on invocation |

…driven by the **PIV loop — Plan → Implement → Validate:**

```
PLAN        /start-ticket   (+ /prime-ticket, /recall, /prime-warehouse, /prime-domain)
IMPLEMENT   /spec-and-build  spec → (commit) → build      (research-in-parallel, never implement)
VALIDATE    /qc-review [--deep]  →  /deliver-ticket       (pyramid + adversarial panel; hard-halt before posts)
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
+ point at a different adapter; **no skill changes.** Proof: three configs ship —
[`stack.yaml`](.claude/config/stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub),
[`stack.example.asana-bq.yaml`](.claude/config/stack.example.asana-bq.yaml) (Asana/BigQuery/Teams/SharePoint/GitLab),
and [`stack.example.azure.yaml`](.claude/config/stack.example.azure.yaml) (Azure DevOps/Synapse/Teams/SharePoint/Azure Repos)
— the same skills run against all three.

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

The same self-test runs in CI on every push/PR. A pre-release multi-agent hardening review (subagents
+ Codex, adversarially verified) is recorded in [`docs/REVIEW.md`](docs/REVIEW.md).

## Add a new tool

Write **one adapter** (copy the closest reference in the same seam; implement every verb section;
keep the frontmatter), add a `verify` line to your `stack.yaml` seam, and run
`bash bin/verify_stack.sh`. No skill edits. See `adapters/README.md`.

## Policy enforcement (hooks)

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

**Recall & objects.** `/recall <id>` mines the index for the closest prior tickets (ranked by shared
object / tag / cross-ref / keyword) and writes a *reuse brief* in the PLAN phase — so you don't rebuild
what's been built. `tickets/OBJECTS.md` is the object → tickets reverse map ("which tickets touched
`VW_X`?"), populated from enrichment ∪ a deterministic grep of each ticket's SQL. Lexical, stdlib, no
vector store — the rank → read-top-K shape also scales past the point where the whole index fits in context.

## What's inside

- **9 skills** (`.claude/skills/`): configure-workspace, onboard-teammate, start-ticket,
  spec-and-build, qc-review, deliver-ticket, productize-workflow, build-context-pack, build-ticket-index.
- **4 commands** (`.claude/commands/`): prime-ticket, prime-warehouse, prime-domain, recall (prior-art reuse brief).
- **1 sub-agent** (`.claude/agents/`): `qc-reviewer` — independent-context reviewer `qc-review` delegates to.
- **4 hooks + settings** (`.claude/hooks/`, `.claude/settings.json.tmpl`, `.claude/statusline.sh`):
  policy enforcement, session priming, ticket-index surfacing + auto-regen, status line.
- **Adapters** (`adapters/`): 19 across 5 seams — trackers (Jira, Azure DevOps, Linear, Asana, Monday,
  GitHub Issues), warehouses (Snowflake, BigQuery, Databricks, Postgres, Redshift, Synapse/Azure SQL),
  chat (Slack, Teams), docstore (Drive, SharePoint), vcs (GitHub, GitLab, Azure Repos) — full verb coverage each.
- **Templates** (`templates/`): AGENTS.md, ticket README, plan, spec, and the productized-skill skeleton.
- **`bin/`**: `verify_stack.sh` (hybrid verify), `render.sh` (token renderer), `selftest.sh` (kit
  test suite + hook unit tests), and the ticket-index tools (`build_ticket_index.py`,
  `ingest_index_records.py`, `enrich_ticket.py`, `recall.py`).

## Still out of scope (deferred)

The heavy external "knowledge-base + orchestration" harness (Archon-style retrieval over MCP):
skipped. Task management is the tracker's job; orchestration is `productize-workflow` + the host
agent's own subagents. The ticket index covers in-repo recall without any vector store or service.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md) — next up: plugin packaging (one `claude plugin install`) and a tracker
`id_mode` contract so integer trackers (Azure Boards, GitHub Issues) stop being an abstraction leak.

## License

MIT — see [`LICENSE`](LICENSE).
