# How it works

The longer version of the [README](../README.md)'s overview: what the team brain is made of, how
the lifecycle maps onto your tools, the commands that drive it, and the rails around it. For how
the kit is *built* (adapters, the verb contract, config tiers), see
[architecture.md](architecture.md).

## Who it's for

Ticketwright is built for the broad
group of people who touch and interact with data — analysts, BI, ops, research, reporting — and it
works for any team storing ticket- or task-driven analysis work in a repo, database or not.

**This is for you if:**

- ✅ your team's work product is an **answer**, not a feature
- ✅ you ship more analyses than anyone can carefully review by hand
- ✅ you want past work written down, findable, and reusable — by people and by AI
- ❌ you need a project tracker, an ETL scheduler, or a BI dashboard — Ticketwright sits beside
  those; it does not replace them

## What it builds: a team brain

A Ticketwright repo is a shared corpus of tickets that makes your team's past work available to
both people and AI. Every analysis lands in one place with its business context, its assumptions,
its QC verdict and its deliverables, so any teammate - or any agent - can find prior work, judge
whether it applies, and reuse it instead of rebuilding it. You can cite my analysis, I can cite
yours, and neither of us has to interrupt the other to do it. Because the corpus is
machine-readable, the assistant gets better at your team's domain the longer the team uses it.

What that buys, and the mechanism behind each piece:

- **Prior-art recall compounds.** `tickets/INDEX.md` is an auto-maintained catalog of every
  ticket, surfaced at the start of every session, and `/ticket` opens with a reuse brief - prior
  work ranked by shared objects, tags and keywords (deterministic, stdlib, no vector store), with
  what to copy and which gotchas carry over. The engine is `bin/recall.py`, and what it ranks
  against is `tickets/index_data.json` - the curated summaries written at ticket close (`/ship`
  routes this through `/refresh index`; `bin/enrich_ticket.py` is the headless-model path,
  `bin/ingest_index_records.py` the agent-neutral one). Every shipped ticket that gets curated
  makes the next search better.
  The failure mode, plainly: curation can fail or be skipped, and a skipped ticket falls back to
  its bare README title (`▱` in the catalog) - keep skipping and the corpus rots toward a folder
  of SQL nobody can find. Details: [docs/ticket-index.md](ticket-index.md).
- **Object-level memory.** `tickets/OBJECTS.md` maps every warehouse object to the tickets that
  touched it, so "has anyone used this view, and what did they learn about it?" is a lookup. This
  is the institutional knowledge hardest to keep in people's heads.
- **Assumptions make prior work citable.** The `reduce_assumptions` policy requires assumptions in
  the ticket README - a workflow policy the skills honor, not a mechanically enforced one. Without
  written assumptions an old analysis is unciteable: you cannot tell whether its numbers apply to
  your question. This is what separates a knowledge base from a file dump.
- **QC verdicts are a quality signal on the corpus.** `/review`'s APPROVE / REQUEST-CHANGES
  verdict sits next to the deliverable, so a reader can tell validated work from exploratory work
  before reusing either.
- **Old work re-runs.** The `deterministic_outputs` policy (explicit `ORDER BY` on exports,
  golden-replay diffs on generated skills) keeps a prior analysis executable where its queries
  and inputs still exist - a stronger claim than a document makes.
- **Continuity.** When someone leaves, their reasoning survives with their SQL: the context,
  assumptions and verdicts stay in the repo, readable by the next person and traceable by the
  next agent.

## The lifecycle is the map

Every ticket moves through the same five phases, whatever tools sit underneath. The tool slots
exist to serve the phases, and one slot can serve more than one phase:

| Phase | Tool slots it can use |
|---|---|
| 1 · Open the work | tracker + vcs + meetings |
| 2 · Do the work | warehouse + local tools (+ meetings, for the spec step) |
| 3 · Quality-check it | no slot of its own - `/review` plus human sign-off |
| 4 · Deliver | vcs + docstore |
| 5 · Announce and share | tracker + chat |

Phase 4 is the one slot with a machine-local prerequisite: the `gdrive` and `sharepoint`
adapters write into a desktop sync mount. [docs/drive-mount.md](drive-mount.md) covers
installing that mount per OS, which half of the path is a team decision and which is yours - or
how to skip the mount entirely with the `rclone` adapter, which needs only the binary.

"More tools" almost always means named targets inside a slot - two warehouses, a team chat and a
client chat - not more slots. A new slot KIND is rare and has to clear a recorded bar (a stable
tool-independent verb contract, a distinct lifecycle responsibility, its own auth semantics, and
common use - see [ROADMAP](../ROADMAP.md)); the read-only `meetings` slot is the one addition that
has cleared it. And phase 3 is worth a second look: quality checking has no tool slot of its
own. Every other phase has a dedicated external system available to it (available, not always
present - trackerless, warehouse-less and docstore-less setups are all supported), but there is
no QC service to plug in. `/review` and the `qc-reviewer` agent borrow the warehouse slot to
re-run the deliverable queries, and under the default `human_review_handoff` policy the final
gate is a person reading the output - the deliverables open in each reviewer's own applications,
a per-user choice whose portable half lives in committed `people/<id>.yaml` and whose machine
wiring stays local.

The commands that drive these phases are in [How work flows](#how-work-flows) below.

It works with **your** tools, through one config file:

| Tool slot | Works with |
|---|---|
| Tracker | Jira · Azure DevOps · Linear · Asana · Monday · GitHub Issues · etc. — or **none at all** |
| Warehouse | Snowflake · BigQuery · Databricks · Postgres · Redshift · Synapse · Supabase · DuckDB · etc. — or **none at all** |
| Chat | Slack · Teams · email (Gmail · Outlook) · etc. |
| Docs | Google Drive · SharePoint · Dropbox · S3 · Box · etc. — mounted, or mountless via rclone |
| Meetings | Zoom · Fireflies · Granola · Teams · Notion — optional; any provider via a new adapter file |
| Git | GitHub · GitLab · Azure Repos · Bitbucket · etc. |

- **The lists are examples, not a whitelist** — any tool that fills a slot works. The first six
  trackers, six warehouses, and the Slack/Teams/Gmail/Outlook/Drive/SharePoint/GitHub/GitLab/Azure-Repos
  set ship as adapters today; wiring up another (Supabase, DuckDB, Bitbucket, …) is
  [a single adapter file](../adapters/README.md) — the skills never change. For document stores the
  shipped `rclone` adapter already covers Dropbox, S3 and Box without a desktop sync mount.
- **More than one warehouse is fine** — name the targets.
- **No warehouse is fine too** — a team whose deliverables are documents, models, or reports just
  omits the tool slot ([worked example](../.claude/config/stack.example.no-warehouse.yaml)).
- **No ticketing system is fine too** — set `id_mode: slug` and a folder you name becomes the ticket.

## How work flows

Four steps — **plan → build → check → ship** — and one command to remember. Skills are shown by
their short names here and below; **on a plugin install, use the namespaced form**
(`/ticketwright:ticket`, `/ticketwright:review`, …). The short names work when the kit's skill
files live in the repo itself — vendored, or installed via pip (`ticketwright init` copies
`.claude/skills/` into the repo). A plugin install exposes only the namespaced form, however
fully the repo is configured — `/setup` writes config, never skill folders.

```
/ticket <id>        opens or resumes the ticket, auto-loads its context + closest prior work,
                    writes the plan (and the spec when the plan calls for one), and waits for
                    your approval before anything is built ↓
/build              executes the approved plan or spec in fresh context, then runs /review itself
/review [--deep]    the independent QC pass /build runs for you: re-runs queries, walks the validation
                    pyramid → APPROVE / REQUEST-CHANGES; run it directly to re-check or go --deep
                    …and at the top of that pyramid, opens the deliverables in YOUR apps and waits
/ship [--go]        backup → tracker comment → chat draft → commit + PR — HARD HALT before anything
                    external; warns, waits for a typed `ship unreviewed`, and records it when no
                    review verdict is on file
```

Three supporting skills you'll reach for occasionally:

| Skill | What it does |
|---|---|
| `/setup` | Configure the repo (once) · add a tool later (`/setup tool chat`) · pick which apps open your deliverables (`/setup viewer`) · onboard a person (`/setup --teammate`, entered automatically for an unrecognized person) |
| `/refresh` | Rebuild the ticket catalog (`index`) or the domain knowledge pack (`context`) — day-to-day, hooks keep these fresh automatically |
| `/skillify` | Turn a recurring workflow (quarterly pull, monthly report) into its own parameterized, golden-tested skill |

(The v1 command names — `/start-ticket`, `/qc-review`, … — were retired in v3; see the rename map
in [docs/troubleshooting.md](troubleshooting.md#upgrading).)

## Sound like you (voice profiles)

Every ticket ends with `/ship` drafting the tracker comment, chat message, and PR body — and you
almost always edit that draft before it goes out. **Voice profiles** capture how *you* write so the
draft arrives already sounding like you, and then learn from the edits you still make.

- **Opt-in.** Off until a person has a `voice:` block in `people/<id>.yaml`. Build a profile with
  `/setup --voice`: a short interview (and, if you want, a few of your own already-sent lines).
- **Per person.** `bin/whoami.py` resolves who is working (offline, via the identities each person
  enumerates in `people/<id>.yaml` — never a fuzzy guess; on a miss it asks who you are and
  remembers the answer with `--bind`). `/ship` maps that person to their voice profile
  (`bin/resolve_user.py`, a thin shim over it) and loads their `voices/<id>.md`.
- **Within the rails, always.** Voice shapes *phrasing only*. `/ship` runs a comms-lint step first
  (word limits, hyperlinks, include-list) and only then applies voice, so the profile can never
  breach a word limit, drop a hyperlink, or skip the stakeholder include-list.
- **It combs itself.** `/ship` diffs what it drafted against what you approved and *proposes* profile
  updates from the delta — you approve each one; nothing is learned silently.
- **Personal data.** A profile is your writing fingerprint. Committed by default (so a team shares
  them like the ticket index); to keep yours private, point your `voice.path` outside the repo —
  or gitignore it *before* its first commit, since gitignoring a file git already tracks does
  nothing. It stores short
  approved exemplars — never full confidential threads.

## Safety rails (on by default)

- **High-risk DB writes ask first** — a hook inspects every warehouse CLI command run through Bash
  (SQL sent through an MCP tool never reaches it) and prompts before anything irreversible (`DROP`/`DELETE`/`UPDATE`/`TRUNCATE`/`CREATE OR REPLACE`/…), *even SQL
  hidden in a `-f` file*. Additive work (plain `CREATE`, `INSERT INTO`, `ALTER … ADD`) runs without
  a prompt. Tune with `policies.db_write_requires_approval`: `off` | `high_risk` (default) | `all`.
- **External posts hard-halt** — `/ship` prints exactly what it's about to post (tracker comment,
  chat message, PR) and waits for your explicit go.
- **Chat defaults to draft** — you click send.
- **Deliverables commit with the ticket, PII opts out** — exports are committed by default so results
  show in the PR; keep customer data out of git by naming it `*.private.csv` or dropping it in a
  `private/` subfolder, and `/ship` lists what it's about to commit so nothing sensitive slips in.
- **Every assumption is written down** — the ticket README template enumerates them by category.

## Hooks, in full

Trust demands transparency: this plugin runs hooks, so here is every one of them. All are
Python stdlib-only, make **no network calls**, never write outside the repo, and fail open —
a hook error never blocks your session.

Two places where the DB guard *removes* a prompt rather than adding one, stated plainly:

- **Verifiably read-only SQL is auto-approved** — a single simple command, every referenced file
  read, and every statement a `SELECT`/`SHOW`/`DESCRIBE`/`EXPLAIN`.
- **Under `bypassPermissions` it prints a `systemMessage` instead of asking**, because you already
  opted out of prompting for that session.

Neither can loosen a `deny` rule in your settings — hooks can tighten permissions, never widen them
past what your own rules allow.

| Event | Script | What it does |
|---|---|---|
| PreToolUse (Bash) | `.claude/hooks/db_write_guard.py` | Pauses for confirmation before a warehouse CLI command carrying high-risk SQL (including SQL hidden in `-f` files / stdin redirects); auto-approves verifiably read-only SQL |
| PreToolUse (Bash) | `.claude/hooks/source_material_guard.py` | Pauses for confirmation before a raw meeting transcript in a ticket's `source_materials/` is staged for commit or copied into a docstore backup (`cp` / `rclone`); it reads filenames and document shape, not meaning (classifier: `bin/scan_source_materials.py`) |
| PreToolUse (Bash) | `.claude/hooks/review_verdict_guard.py` | Pauses for confirmation before `git push` / a PR is opened or merged for a ticket that has deliverables but no APPROVE review verdict on file (read by `bin/review_verdict.py`); silent on approved or not-yet-built tickets |
| PostToolUse (Write\|Edit) | `.claude/hooks/regenerate_ticket_index.py` | Regenerates `tickets/INDEX.md` / `OBJECTS.md` when the curated store changes |
| SessionStart | `.claude/hooks/session_context.py`, `ticket_index_context.py` | Emits a short repo/catalog banner inside a ticketwright repo; silent elsewhere |

Every hook is repo-gated: zero cost (and zero output) in repos that aren't set up for
ticketwright. Explicit timeouts are declared so a hung hook can never stall a session. To turn
them all off, disable the plugin (`claude plugin disable ticketwright`); the skills can still
be vendored without hooks via the kit install.
