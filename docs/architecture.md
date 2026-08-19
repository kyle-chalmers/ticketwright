# Architecture — how Ticketwright is built

This is the contributor-facing map. Users don't need any of this; [the README](../README.md)
quickstart is enough to work tickets.

## The AI-layer model

Every repo has a **code layer** (the work) and an **AI layer** (the rules + context + workflows
that guide an agent), versioned together. The AI layer has three tiers:

| Tier | Here | Loaded |
|---|---|---|
| **Global rules** | `AGENTS.md` (rendered from `templates/AGENTS.md.tmpl`; Claude Code loads it via a one-line `CLAUDE.md` `@AGENTS.md` import) | always |
| **On-demand context** | the `documentation/` pack · `/ticket`'s priming slices · `tickets/INDEX.md` + `OBJECTS.md` | selectively |
| **Skills** | `.claude/skills/` (7) | on invocation |

The lifecycle the skills implement — plan → build → check → ship — descends from the PIV loop
(Plan → Implement → Validate) in Cole Medin's "agentic engineering" / Archon material, which also
supplied the AI-layer model and the context-engineering stance (AI fails from missing context, not
weak models).

## Seams, adapters, and the verb contract

A **seam** is a tool slot the kit needs filled: `tracker`, `warehouse`, `chat`, `docstore`, `vcs`,
and the optional `viewer`. A seam may name one tool or several **named targets** (v1: `warehouse`),
and a seam whose tool is absent can still be filled by an adapter over local files — that is how a
repo with no tracker runs unchanged. The wiring is hybrid — config names the tools, verification
proves them:

1. **`.claude/config/stack.yaml`** names which tool fills each seam + project facts + the 10
   policies. Schema: [.claude/config/stack.schema.md](../.claude/config/stack.schema.md).
2. **`adapters/<seam>/<tool>.md`** maps the abstract **verb contract** (`fetch_ticket`, `query`,
   `draft`, `backup`, `commit`, …) to that tool's concrete commands. Contract:
   [adapters/README.md](../adapters/README.md).
3. **`bin/verify_stack.sh`** pings each seam's read-only `verify` before use — reachable seams
   run, unreachable ones halt with the adapter's auth notes.

Skills are written **once against verbs** and never name a tool. Swapping a tool = edit
`stack.yaml` + point at a different adapter; **no skill changes.** Proof: six configs ship —
[`stack.yaml`](../.claude/config/stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub),
[`stack.example.asana-bq.yaml`](../.claude/config/stack.example.asana-bq.yaml)
(Asana/BigQuery/Teams/SharePoint/GitLab), and
[`stack.example.azure.yaml`](../.claude/config/stack.example.azure.yaml)
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos),
[`stack.example.multi-warehouse.yaml`](../.claude/config/stack.example.multi-warehouse.yaml)
(Snowflake **+** Databricks — two targets in one seam),
[`stack.example.solo.yaml`](../.claude/config/stack.example.solo.yaml) (**no tracker**, no chat, no
docstore — the ticket folder is the tracker), and
[`stack.example.no-warehouse.yaml`](../.claude/config/stack.example.no-warehouse.yaml) (**no
warehouse** — document/report deliverables, nothing to query) — the same skills run against all six.

**Adding a tool:** write one adapter (copy the closest reference in the same seam; implement every
verb section; keep the frontmatter), add a `verify` line to your `stack.yaml` seam, run
`bash bin/verify_stack.sh`. No skill edits.

**The one seam whose config is not in `stack.yaml`:** `viewer` — which application opens a `.sql`
or a `.csv` at a review gate. Every other seam names a tool the whole team shares; this one is a
personal preference, and a committed entry could never ask a new cloner what *they* want. So the
repo decides **when** a gate fires (policy `human_review_handoff`) and each person decides **what**
it opens, in a gitignored `.claude/config/viewer.local.yaml` (or a user-level file covering all
their repos). `bin/handoff.sh` resolves the layers and owns the rails — it never launches in CI or
a headless session, never opens a path outside the project, and is a silent no-op when nothing is
configured. Details: [.claude/config/viewer.example.yaml](../.claude/config/viewer.example.yaml).

## Config is three tiers behind one resolver

`stack.yaml` is committed and shared, so a value true only on one machine does not belong in it — a
real `/setup` run put a warehouse profile name and a hardcoded verify command into it, handing every
teammate one person's machine. Config is therefore three files:

| Tier | File | Committed? | Holds |
|---|---|---|---|
| 1 team | `.claude/config/stack.yaml` | yes | which tool fills each seam, which data the team reads, the 10 policies |
| 2 person, portable | `people/<id>.yaml` | yes | display name, identities, comms voice, file-type preferences |
| 3 person, machine | `.claude/config/connections.local.yaml` | no | named profiles/connections, local mount roots |

[`bin/effective_config.py`](../bin/effective_config.py) is the single authority that merges them, and
every consumer goes through it — nothing parses `stack.yaml` on its own any more. It is a public CLI
needing no agent-specific environment variable, so it answers the same way under any harness.

**The scope rule is code, not documentation.** Tier 3 selects credentials and local paths; it can
never change which catalog, schema, database or target is read, and it can never contribute a
`policies:` block. Which keys are personal is declared per adapter in `user_keys:` frontmatter.
Anything outside that allowlist is **rejected**, not ignored — a gitignored file nobody reviews must
not be able to switch a safety gate off, and quietly discarding the attempt would be just as bad as
honoring it.

YAML is read by [`bin/_yamlite.py`](../bin/_yamlite.py), an explicit supported subset in stdlib
Python that fails loudly with a `file:line` rather than misreading. That is what lets the resolver
keep the kit's zero-runtime-dependency promise, and it is why `bin/verify_stack.sh` no longer
requires `yq`.

**Two deliberate exceptions.** `db_write_guard` and its `_stack` helper still read the policy
in-process. Routing them through a subprocess resolver would turn their failure mode from fail-safe
(an unreadable policy gates MORE) into fail-open, because the hook wraps everything in a blanket
"never block a session" handler. The reasoning is written at the top of `.claude/hooks/_stack.py`,
and a selftest asserts the guard still gates with the resolver deleted.

## Policy enforcement (hooks)

Policies are only as good as the agent's memory unless something enforces them. The plugin ships
Claude Code hooks (declared in `.claude-plugin/plugin.json`; `setup` also wires them into a repo's
`.claude/settings.json` for non-plugin installs):

- **`db_write_guard.py`** (PreToolUse/Bash) — makes `db_write_requires_approval` mechanical.
  The policy is a three-value enum (`off` | `high_risk` | `all`, default `high_risk`), so routine
  additive work doesn't cost a confirmation while irreversible work still does. Classification is
  **default-deny**: only plain `CREATE`, `INSERT INTO`, `ALTER … ADD`, and `COMMENT ON` count as
  additive; everything else that mutates — *including anything the scanner doesn't recognize* — is
  high-risk. It sees SQL hidden in a `-f` file or a stdin redirect, and strips comments and string
  literals first so a verb quoted as data isn't mistaken for a statement. Read-only SQL takes an
  `allow` fast-path. Under `bypassPermissions` it emits a `systemMessage` instead of asking, since
  the operator has already opted out of prompting.
- **`session_context.py`** (SessionStart) — primes every session with the configured stack, the
  skills, and the lifecycle.
- **`ticket_index_context.py`** (SessionStart) — surfaces the ticket catalog (counts + most recent
  tickets + a pointer to grep `tickets/INDEX.md` before starting related work).
- **`regenerate_ticket_index.py`** (PostToolUse/Write·Edit) — re-renders `tickets/INDEX.md`
  whenever a ticket folder changes.

Hooks are the one Claude-Code-specific layer; the rest of the kit is agent-agnostic. Other agents
read the same policies from `stack.yaml` and honor them via the skill-level hard-halts — that is
**guidance, not enforcement**, and the docs should not imply those agents get equivalent runtime
protection. The policy value is the shared contract; only the enforcement mechanism differs.

## What's inside

- **7 skills** (`.claude/skills/`): setup, ticket, spec-and-build, review, ship, productize,
  refresh — each SKILL.md is short, with depth in per-skill reference files
  (`ticket/priming.md`, `setup/adopt.md`, `productize/authoring.md`, …).
- **1 sub-agent** (`.claude/agents/`): `qc-reviewer` — the independent-context reviewer `/review`
  delegates to (one per pyramid layer in `--deep` mode).
- **4 hooks + settings** (`.claude/hooks/`, `.claude/settings.json.tmpl`, `.claude/statusline.sh`).
- **30 adapters** (`adapters/`) across 7 directories — full verb coverage each, including a `local`
  tracker whose "API" is the ticket folder itself and three `viewer` adapters (one per OS). Six of
  those directories are tool seams; the seventh, `runtime/`, declares what each agent harness can do
  (see [runtimes.md](runtimes.md)) and carries no verbs, because it is not a tool the project calls.
- **Templates** (`templates/`): AGENTS.md (+ the one-line `CLAUDE.md` `@AGENTS.md` import), ticket
  README, plan, spec, `.gitignore` (deliverables committed by default; PII opts out via
  `*.private.csv` / a `private/` subfolder), role snippets, and the productized-skill skeleton.
- **`bin/`**: `verify_stack.sh`, `render.sh` + `render_and_validate.sh` (render gate),
  `split_and_export.sh`, `handoff.sh` (the review-gate opener),
  `selftest.sh` (the CI suite + hook unit tests), and the index/recall
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
