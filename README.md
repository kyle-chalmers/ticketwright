# Ticketwright

[![CI](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml/badge.svg)](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/tag/kyle-chalmers/ticketwright?label=release&sort=semver&color=blue)](https://github.com/kyle-chalmers/ticketwright/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Python](https://img.shields.io/badge/python-3%20%C2%B7%20stdlib--only-3776AB)
![tool-agnostic](https://img.shields.io/badge/works%20with-your%20tracker%20%C2%B7%20warehouse%20%C2%B7%20chat%20%C2%B7%20docs%20%C2%B7%20git-success)

## Mission

**Ticketwright empowers a team to do a high volume of analysis without letting quality slide, on whatever tools they already use.**

## Vision

**Any new or experienced member can pick up any analysis and be productive the same day, because the team's past work is written down and organized, and AI can trace it.**

---

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
  of SQL nobody can find. Details: [docs/ticket-index.md](docs/ticket-index.md).
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
  golden-replay diffs on productized skills) keeps a prior analysis executable where its queries
  and inputs still exist - a stronger claim than a document makes.
- **Continuity.** When someone leaves, their reasoning survives with their SQL: the context,
  assumptions and verdicts stay in the repo, readable by the next person and traceable by the
  next agent.

## The lifecycle is the map

Every ticket moves through the same five phases, whatever tools sit underneath. The tool slots
exist to serve the phases, and one slot can serve more than one phase:

| Phase | Tool slots it can use |
|---|---|
| 1 · Open the work | tracker + vcs |
| 2 · Do the work | warehouse + local tools |
| 3 · Quality-check it | no slot of its own - `/review` plus human sign-off |
| 4 · Deliver | vcs + docstore |
| 5 · Announce and share | tracker + chat |

Phase 4 is the one slot with a machine-local prerequisite: the `gdrive` and `sharepoint`
adapters write into a desktop sync mount. [docs/drive-mount.md](docs/drive-mount.md) covers
installing that mount per OS, which half of the path is a team decision and which is yours - or
how to skip the mount entirely with the `rclone` adapter, which needs only the binary.

"More tools" means named targets inside a slot - two warehouses, a team chat and a client chat -
never more slots. And phase 3 is worth a second look: quality checking has no tool slot of its
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
| Git | GitHub · GitLab · Azure Repos · Bitbucket · etc. |

- **The lists are examples, not a whitelist** — any tool that fills a slot works. The first six
  trackers, six warehouses, and the Slack/Teams/Gmail/Outlook/Drive/SharePoint/GitHub/GitLab/Azure-Repos
  set ship as adapters today; wiring up another (Supabase, DuckDB, Bitbucket, …) is
  [a single adapter file](adapters/README.md) — the skills never change. For document stores the
  shipped `rclone` adapter already covers Dropbox, S3 and Box without a desktop sync mount.
- **More than one warehouse is fine** — name the targets.
- **No warehouse is fine too** — a team whose deliverables are documents, models, or reports just
  omits the tool slot ([worked example](.claude/config/stack.example.no-warehouse.yaml)).
- **No ticketing system is fine too** — set `id_mode: slug` and a folder you name becomes the ticket.

## Quickstart (5 minutes)

From inside the repo you want to work tickets in:

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

That writes the repo's own `.claude/settings.json`. Add one more key by hand to its `"ticketwright"`
marketplace entry — no CLI flag sets this one — so teammates pick up tagged releases:

```json
"autoUpdate": true
```

One honest caveat while the gap reported in
[claude-code#61854](https://github.com/anthropics/claude-code/issues/61854) persists (verified live
2026-08-23): `autoUpdate` refreshes the marketplace CATALOG on session start, but Claude Code does not
yet re-install a project-scoped plugin from it - so a new release reaches every teammate's machine
without being swapped in. Until that lands upstream, picking up a release is one command pair, run
from the repo:

```bash
claude plugin uninstall ticketwright@ticketwright --scope project && claude plugin install ticketwright@ticketwright --scope project
```

(It may reorder keys in `.claude/settings.json`; the content is identical - `git checkout` the file
if you want zero diff.)

Then **commit the file**, and Ticketwright travels with the repo. `/ticketwright:setup` adds that key for
you if you'd rather not hand-edit; see [Project-scoped by default](#project-scoped-by-default) for the
finished file. Both commands default to `--scope user`, so **omit `--scope project` only if you want
Ticketwright for yourself across every repo** rather than for this repo's team.

Now, in that repo:

```
/ticketwright:setup          # detects your tools, interviews you in rounds, writes the config — once per repo
/ticketwright:ticket ENG-123 # start working
```

That's it. `setup` also handles repos that **already have** ticket history — it maps onto your
existing layout instead of scaffolding, and writes a `MIGRATION.md` checklist (see
[Adopting an existing repo](#adopting-an-existing-repo)).

### What `setup` actually does

It runs once per repo, and **detects before it asks** — detection produces the facts each question
depends on, and a question exists only where a wrong or missing value would fail *silently* (a dead
catalog link, a generic persona, a message with no stakeholders). Anything that fails loudly at
verification or first use ships as a commented default instead.

**What it looks at first, before asking you anything:**

- **Which CLIs are on your PATH** — `snow`, `acli`, `gh`, `glab`, `bq`, `databricks`, `yq`, `jq`, `git` —
  to pre-select the tools you already have.
- **Which MCP servers are connected** in the session (tracker / chat / warehouse).
- **What's already in the repo** — an existing `.claude/config/stack.yaml` (it offers to edit and never
  overwrites), or existing ticket folders and indexes, which switch it into adopt mode.
- **Who you are.** On a repo that's already configured, an unrecognized person is routed straight
  into teammate onboarding — a new cloner is never offered the team's shared config as their first
  action.

Config is three tiers: `.claude/config/stack.yaml` is the **team's** committed answer,
`people/<id>.yaml` holds each person's portable settings, and `.claude/config/connections.local.yaml`
holds the per-machine ones and is gitignored. `bin/effective_config.py` merges them — read that, not
the raw file. The machine tier can supply credentials and local paths; it can never change which data
gets read, and never a policy.

**Work that arrives from a meeting.** `project.intake` names where work comes from — `tracker`,
`email`, `chat`, `meetings`. Meeting notes arrive as a file in the ticket's `source_materials/`,
named `YYYY-MM-DD-<slug>-meeting.md`: the **committed, curated form**, trimmed to decisions and
action items. Raw full transcripts are a different matter — they are the most PII-dense thing a
ticket folder holds, so they stay out of git by default, and a guard asks before one is committed
or copied into a docstore backup. It reads filenames and document shape, **not meaning**, so it
catches the bulk artifact and does not pretend to be a confidentiality review.

**What it then asks — in rounds, detected answers pre-selected.** Four rounds always run: **who**
(you, confirmed from identity resolution, and who else is on the team), **where work comes from**
(tracker or *none*, key prefix, the tracker's "done" state, how catalog rows link back), **where
the data lives** (warehouse or *none*, its required keys, a dev target), and **where work goes**
(git host confirmed from `origin`, docstore, chat and its stakeholder include-list, and one
question covering email intake and delivery plus whether an AI notetaker carries work in). Two
more are individually skippable, each skip labeled with its cost — **how you work** (role,
domain, analysis tools) and **house rules** (the two
policies whose defaults most often differ by team). A skipped round becomes a `# TODO` in the
config plus a punch-list entry naming the command that finishes it later (`/setup role`,
`/setup policies`). The other eight policies ship as commented defaults you can edit any time.

**What it writes:**

- **`.claude/config/stack.yaml`** — your chosen tool slots live (the config key is `seams:` — "tool
  slot" is the same thing, internally called a seam), optional ones as commented blocks, each
  policy with a one-line "when to change this" note.
- **`autoUpdate: true` on the marketplace entry** — the one key no CLI flag can set, so running `setup`
  is how auto-update gets turned on at all. It *merges*: an existing entry keeps the `source` you have
  (forks edit that URL), and a deliberate `false` is left alone.
- **`AGENTS.md`** (rules, tuned to your role) and a one-line **`CLAUDE.md`** that imports it.
- **`.claude/settings.json`** — read-only CLI allows, plus the hooks on a vendored install (omitted on a
  plugin install, where `plugin.json` already wires them).
- **Folders + `.gitignore`** — `tickets/<you>/`, `documentation/`, `resources/`, `specs/`; deliverable
  CSVs committed by default, PII opting out via `*.private.csv` or a `private/` folder.
- **The AI-layer index and a seeded ticket index.**

**Then it verifies and hands off:** two clearly-labelled checks — `selftest.sh` for kit integrity and
`verify_stack.sh` for whether *your* tools are actually reachable (an unreachable tool isn't fatal at
setup time; it prints the auth fix) — then offers to commit the scaffold, since an uncommitted setup
means later ticket PRs reference rules that aren't in the repo's history.

### Project-scoped by default

A plugin can't set its own install scope — the **repo** does. `--scope project` writes the enablement
into the repo's `.claude/settings.json`, so it travels *with the repo*: every teammate who opens (and
trusts) it is prompted to install Ticketwright (no marketplace to add, no config to write), and it keeps
working after the person who set it up moves on. Commit the file. This is what the two Quickstart
commands produce, plus the one key they don't write:

```json
{
  "extraKnownMarketplaces": {
    "ticketwright": {
      "source": { "source": "git", "url": "https://github.com/kyle-chalmers/ticketwright.git" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "ticketwright@ticketwright": true }
}
```

Three details in that block are deliberate:

- **The source is an explicit `https://…git` URL**, not the `owner/repo` shorthand. The shorthand can
  resolve to SSH and fail for anyone without GitHub SSH keys; the URL clones over HTTPS through your
  existing git credential helper (keychain / `gh auth login`). A fork edits just this one URL.
- **`source: "git"` is the discriminator `claude plugin marketplace add` writes** for an `https://…git`
  URL — that `source` object is copied from the CLI's own output rather than hand-authored. (`git` and
  `url` are *different* marketplace source types; don't swap one for the other.)
- **`autoUpdate` is scoped to formal releases.** The version only moves in a tagged release commit —
  so day-to-day commits to `main` never put teammates onto un-released work. Neither Quickstart command
  writes this key (no flag sets it); `/ticketwright:setup` adds it, or add it by hand. What it does
  today: it refreshes the marketplace *catalog*; Claude Code does not yet swap the installed
  project-scoped plugin to the new version (the Quickstart caveat above has the pick-up command pair,
  and `claude plugin marketplace update ticketwright` refreshes the catalog by hand).

Installing without `--scope project` puts Ticketwright in your own `~/.claude/settings.json` instead —
right for personal, cross-repo use, but your teammates get nothing. Use the committed block when you
want the whole team on it.

## How work flows

Four steps — **plan → build → check → ship** — and one command to remember:

```
/ticket <id>        opens or resumes the ticket, auto-loads its context + closest prior work,
                    and routes you to the right next step ↓
/spec-and-build     spec mode writes the blueprint (committed first); build mode executes it
/review [--deep]    independent QC pass: re-runs queries, walks the validation pyramid → APPROVE / REQUEST-CHANGES
                    …and at the top of that pyramid, opens the deliverables in YOUR apps and waits
/ship [--go]        backup → tracker comment → chat draft → commit + PR — HARD HALT before anything external
```

Three supporting skills you'll reach for occasionally:

| Skill | What it does |
|---|---|
| `/setup` | Configure the repo (once) · add a tool later (`/setup tool chat`) · pick which apps open your deliverables (`/setup viewer`) · onboard a person (`/setup --teammate`, entered automatically for an unrecognized person) |
| `/refresh` | Rebuild the ticket catalog (`index`) or the domain knowledge pack (`context`) — day-to-day, hooks keep these fresh automatically |
| `/productize` | Turn a recurring workflow (quarterly pull, monthly report) into its own parameterized, golden-tested skill |

Plugin skills are namespaced (`/ticketwright:ticket`); inside a configured repo the short names
work too. (The v1 command names — `/start-ticket`, `/qc-review`, … — were retired in v3; see the
rename map in [docs/troubleshooting.md](docs/troubleshooting.md#upgrading).)

## See it as a graph (Obsidian)

Ticketwright writes a small, auto-maintained graph layer under `tickets/` — `graph/<owner>.<id>.md`
(a node per ticket, keyed by owner + id so two people's same-named tickets never merge) and
`objects/<object>.md` (a node per data object) — so you can open the repo as an
[Obsidian](https://obsidian.md) vault and *browse* your work.

The graph and the catalog are two renderings of one relationship model. The same cross-reference
resolution in `bin/build_ticket_index.py` writes both in a single pass: `tickets/INDEX.md` and
`tickets/OBJECTS.md` are how an agent queries the relationships, and the graph is how a person
sees the shape of the corpus at a glance - which analyses cluster, which objects are load-bearing
across many tickets, where the orphans are. Generated together, they cannot drift apart.

- **Open a table** like `ANALYTICS.VW_ORDERS` and its local graph is every ticket that touched it.
- **Open a ticket** and you see the objects it touched, plus the tickets it built on.
- **Zero manual setup.** It also writes `.obsidian/graph.json`, so the Graph view opens already
  focused on the tickets↔objects web — READMEs filtered out, ticket and object nodes color-coded.
- **Your tweaks survive.** Forces, zoom, and custom filters/groups are never clobbered.
- **Plain markdown** — no plugins, no wikilinks. It renders on GitHub too.

`/ship` stages the graph layer with the catalog — `tickets/graph/` and `tickets/objects/` alongside
`tickets/INDEX.md`, `tickets/OBJECTS.md` and `tickets/index_data.json` — so the graph a teammate
opens is the graph you see. Nothing ignores the nodes, and the same `--check` gate covers them, so
a node left out surfaces as index drift in CI instead of a graph only your clone has.

On by default. Set `project.graph_notes: false` to turn off the whole layer, or
`project.graph_config: false` to keep the nodes but stop managing `.obsidian/graph.json`.

Don't have Obsidian? The layer still renders (plain markdown, browsable on GitHub), and `/setup`
prints one pointer instead of asking anything — install steps, opening the repo as a vault, and
what the node types mean are in [docs/obsidian.md](docs/obsidian.md).

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

- **High-risk DB writes ask first** — a hook inspects every warehouse command and prompts before
  anything irreversible (`DROP`/`DELETE`/`UPDATE`/`TRUNCATE`/`CREATE OR REPLACE`/…), *even SQL
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
| PostToolUse (Write\|Edit) | `.claude/hooks/regenerate_ticket_index.py` | Regenerates `tickets/INDEX.md` / `OBJECTS.md` when the curated store changes |
| SessionStart | `.claude/hooks/session_context.py`, `ticket_index_context.py` | Emits a short repo/catalog banner inside a ticketwright repo; silent elsewhere |

Every hook is repo-gated: zero cost (and zero output) in repos that aren't set up for
ticketwright. Explicit timeouts are declared so a hung hook can never stall a session. To turn
them all off, disable the plugin (`claude plugin disable ticketwright`); the skills can still
be vendored without hooks via the kit install.

## Adopting an existing repo

Already have years of ticket folders and your own conventions? Run `/setup`. It:

- **detects your existing layout** and maps onto it rather than scaffolding over it
- **infers the config from evidence** — folders, CI, installed CLIs, MCP servers
- **classifies your custom commands** against the plugin's skills as *shadows / extends / unrelated*
- **writes a `MIGRATION.md` checklist** instead of overwriting anything

Adoption is incremental: run one real ticket through `/ticket → /review → /ship` before you delete
anything custom.

## Installing without the plugin

The plugin above is the primary channel and the one to use with Claude Code. The pip package
covers the two cases it can't: vendoring the kit's files into a repo, and running the
deterministic engines from a shell or CI.

```bash
pip install ticketwright                 # zero runtime dependencies; stdlib only
ticketwright init                        # vendor the kit into a repo (no plugin required)
ticketwright install --runtime codex-cli # translate the skills for a non-Claude runtime
ticketwright recall --for ENG-123        # prior-art ranking      — no Claude Code needed
ticketwright index --stats               # catalog coverage       — no Claude Code needed
ticketwright enrich ENG-123              # curated index summary  — needs a model CLI on PATH
```

- **`recall` and `index`** are pure stdlib and run anywhere.
- **`enrich`** calls a model headlessly. Which command it runs is resolved per runtime from
  `adapters/runtime/<name>.md` (`--model-cmd` overrides it), falling back to `claude -p`. A runtime
  that documents no headless command says so and points at the agent-neutral ingest path instead.
- **`init`** copies the kit's files — skills, agents, hooks, adapters, templates, `bin/` — and
  preserves your edits on re-runs (`--force` to overwrite).
- **`install --runtime <name>`** is the compatibility layer between the canonical `.claude/skills/`
  source and each runtime's own layout (`bin/install.sh` is the same command for a vendored
  install), covering all seven runtimes and driven by each runtime adapter's declared
  capabilities, never a name baked into code. Where the runtime already reads the canonical copy
  it VERIFIES and emits no skills — `--runtime claude-code` natively (the Claude Code path is
  unchanged), and cursor/opencode/cline/devin because they read `.claude/skills/` directly; the
  printed report states what that shared file cannot carry for a foreign reader (`allowed-tools`
  and `disable-model-invocation` are Claude-specific keys those runtimes ignore, warned per
  affected skill). Where the runtime cannot see the canonical copy it EMITS a translated copy:
  codex-cli and antigravity share one `.agents/skills/<name>/SKILL.md` emission, each file stamped
  with a provenance header — hand-copying skill files between layouts is unsupported, because a
  stale duplicate silently winning over the canonical copy is the failure mode the installer
  exists to prevent; re-run it to update (a file the installer did not emit is never overwritten —
  the install fails loudly instead). Skills marked user-invocable-only
  (`disable-model-invocation: true` — `/setup`, `/ship`, `/productize`) are emitted with a topmost
  warning block stating that nothing mechanical prevents model invocation there; every other
  metadata loss is recorded per runtime in `adapters/runtime/<name>.md` § Metadata mapping. The
  `qc-reviewer` agent definition is emitted wherever subagents are user-definable
  (`.codex/agents/*.toml`; markdown for cursor/devin/antigravity); where they are not (cline) or
  the definition path is undocumented (opencode), the report says so. `--global` emits into the
  runtime's declared per-user skills root and REFUSES where that root is unknown (antigravity —
  its documented sources disagree) rather than guessing a path. The install also wires the
  **DB-write guard** where the runtime documents a home for it — `.cursor/hooks.json` (with
  `failClosed: true`, required configuration), `.agents/hooks.json` for antigravity, a
  throw-to-deny plugin under `.opencode/plugins/` — all fronting one scanner
  (`bin/sql_scan.py`) through `bin/hook_shim.py`. Runtimes with no `ask` tier get the
  `high_risk` policy as **deny-with-escape** (the deny names a one-shot re-approval), and the
  report says so at install time; where even the hooks-config location is undocumented
  (codex-cli, devin) the installer prints the manual wiring line instead of guessing. What is
  ENFORCEMENT (proven — the native Claude hooks) vs WIRED (emitted, live confirmation owed) vs
  GUIDANCE vs UNKNOWN per runtime × per hook is stated in the rendered
  `AGENTS.md` enforcement table (and emitted into `.clinerules/` for cline).

**`init` is a file copy, not a working setup.** It deliberately writes no `stack.yaml` and no
`AGENTS.md` — `/setup` renders both from evidence in your repo, and `/setup` runs in Claude Code.
On another harness you get the skill files (translated by `install` where needed) but still have to
render the config yourself. A harness-agnostic setup path is on the [roadmap](ROADMAP.md), not
shipped — don't read this section as "Ticketwright runs anywhere today."

## Learn more

- [docs/architecture.md](docs/architecture.md) — how it's built: the AI-layer model, tool slots,
  adapters and the verb contract, and how to add a new tool.
- [docs/troubleshooting.md](docs/troubleshooting.md) — a skill failed mid-way, a tool is
  unreachable, the index looks stale, upgrade paths.
- [docs/ticket-index.md](docs/ticket-index.md) — the ticket catalog + recall engine in depth.
- [docs/obsidian.md](docs/obsidian.md) — browse your tickets as a graph: install Obsidian, open
  the repo as a vault, the two node types, and the opt-outs.
- [docs/drive-mount.md](docs/drive-mount.md) — backing up to a cloud drive: install the Drive
  or OneDrive mount per OS, the `mount_root` tier split, or go mountless with rclone.
- [CONTRIBUTING.md](CONTRIBUTING.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

CI runs the full self-test on every push; PyPI publishing is OIDC Trusted Publishing (no stored
tokens) — see [docs/pypi-setup.md](docs/pypi-setup.md).

## License

MIT — see [`LICENSE`](LICENSE).
