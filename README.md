# Ticketwright

[![CI](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml/badge.svg)](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/tag/kyle-chalmers/ticketwright?label=release&sort=semver&color=blue)](https://github.com/kyle-chalmers/ticketwright/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Python](https://img.shields.io/badge/python-3%20%C2%B7%20stdlib--only-3776AB)
![tool-agnostic](https://img.shields.io/badge/works%20with-your%20tracker%20%C2%B7%20warehouse%20%C2%B7%20chat%20%C2%B7%20docs%20%C2%B7%20git-success)

**Ticketwright turns a Claude Code session into a careful data analyst.** Point it at a
ticket-driven work repo (data intelligence, analytics, ops, regulatory reporting…) and it opens
tickets, loads exactly the context each one needs, remembers every past ticket so you never rebuild
what's been built, QC-reviews its own work against a validation pyramid, and never posts anything
externally without your explicit go.

It works with **your** tools — Jira, Azure DevOps, Linear, Asana, Monday, or GitHub Issues;
Snowflake, BigQuery, Databricks, Postgres, Redshift, or Synapse; Slack or Teams; Drive or
SharePoint; GitHub, GitLab, or Azure Repos — through one config file. Don't see yours? Adding it is
[a single adapter file](adapters/README.md).

## Quickstart (5 minutes)

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git
claude plugin install ticketwright@ticketwright
```

Then, in your repo:

```
/ticketwright:setup          # detects your tools, asks ≤5 questions, writes the config — once per repo
/ticketwright:ticket ENG-123 # start working
```

That's it. `setup` also handles repos that **already have** ticket history — it maps onto your
existing layout instead of scaffolding, and writes a `MIGRATION.md` checklist (see
[Adopting an existing repo](#adopting-an-existing-repo)).

**Project-scoped by default.** A plugin can't set its own install scope — so instead, `setup` commits
the enablement into the repo's `.claude/settings.json`. That's the *repo* opting in at project scope:
it travels *with the repo*, so every teammate who opens (and trusts) the repo is prompted to install
Ticketwright (no marketplace to add, no config to write), and it keeps working after the person who
set it up moves on:

```jsonc
{
  "extraKnownMarketplaces": {
    "ticketwright": { "source": { "source": "url", "url": "https://github.com/kyle-chalmers/ticketwright.git" }, "autoUpdate": true }
  },
  "enabledPlugins": { "ticketwright@ticketwright": true }
}
```

The marketplace source is an explicit `https://…git` URL, not the `owner/repo` shorthand: the
shorthand can resolve to SSH and fail for anyone without GitHub SSH keys, while the URL clones over
HTTPS through your existing git credential helper (keychain / `gh auth login`). A fork edits just
this one URL.

`autoUpdate` re-installs **only on a formal release** — Claude Code refreshes when the plugin's
*version* changes, and the version only moves in a tagged release commit, so day-to-day commits to
`main` never pull teammates onto un-released work. (Prefer the user-level `/plugin install` above for
personal, cross-repo use; use the committed block when you want the whole team on it.)

## How work flows

Four steps — **plan → build → check → ship** — and one command to remember:

```
/ticket <id>        opens or resumes the ticket, auto-loads its context + closest prior work,
                    and routes you to the right next step ↓
/spec-and-build     spec mode writes the blueprint (committed first); build mode executes it
/review [--deep]    independent QC pass: re-runs queries, walks the validation pyramid → APPROVE / REQUEST-CHANGES
/ship [--go]        backup → tracker comment → chat draft → commit + PR — HARD HALT before anything external
```

Three supporting skills you'll reach for occasionally:

| Skill | What it does |
|---|---|
| `/setup` | Configure the repo (once) · add a tool later (`/setup chat`) · onboard a person (`/setup --teammate`) |
| `/refresh` | Rebuild the ticket catalog (`index`) or the domain knowledge pack (`context`) — day-to-day, hooks keep these fresh automatically |
| `/productize` | Turn a recurring workflow (quarterly pull, monthly report) into its own parameterized, golden-tested skill |

Plugin skills are namespaced (`/ticketwright:ticket`); inside a configured repo the short names
work too. (The v1 command names — `/start-ticket`, `/qc-review`, … — were retired in v3; see the
rename map in [docs/troubleshooting.md](docs/troubleshooting.md#upgrading).)

## Never rebuild what's been built

`tickets/INDEX.md` is an auto-maintained catalog of **every** ticket — status, one-line summary,
tags, objects touched, cross-references — surfaced at the start of every session. When you open a
ticket, `/ticket` ranks your prior work by shared objects/tags/keywords (deterministic, stdlib, no
vector store) and writes a *reuse brief*: what to copy, which gotchas carry over, what's different
this time. `tickets/OBJECTS.md` answers the reverse question — "which tickets touched `VW_X`?"
Details: [docs/ticket-index.md](docs/ticket-index.md).

## See it as a graph (Obsidian)

Ticketwright also writes a small, auto-maintained graph layer under `tickets/` — `graph/<id>.md`
(a node per ticket) and `objects/<object>.md` (a node per data object) — so you can open the repo as
an [Obsidian](https://obsidian.md) vault and *browse* your work: open a table like `ANALYTICS.VW_LOAN`
and its local graph is every ticket that touched it; open a ticket and you see the objects it touched
plus the tickets it built on. It **also writes `.obsidian/graph.json`**, so the Graph view opens
already focused on the tickets↔objects web — READMEs and other notes filtered out, ticket nodes and
object nodes color-coded — with **zero manual setup**. It never clobbers your own graph tweaks (forces,
zoom, custom filter/groups are all preserved). It's plain markdown (no plugins, no wikilinks) and
renders on GitHub too. On by default; set `project.graph_notes: false` to turn off the whole layer, or
`project.graph_config: false` to keep the nodes but stop managing `.obsidian/graph.json`.

## Safety rails (on by default)

- **DB writes ask first** — a hook inspects every warehouse command and prompts before anything
  destructive (`UPDATE`/`DROP`/`CREATE OR REPLACE`/…), *even SQL hidden in a `-f` file*.
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
a hook error never blocks your session; a guard only ever *adds* a confirmation.

| Event | Script | What it does |
|---|---|---|
| PreToolUse (Bash) | `.claude/hooks/db_write_guard.py` | Pauses for confirmation before a warehouse CLI command carrying destructive SQL (including SQL hidden in `-f` files / stdin redirects) |
| PostToolUse (Write\|Edit) | `.claude/hooks/regenerate_ticket_index.py` | Regenerates `tickets/INDEX.md` / `OBJECTS.md` when the curated store changes |
| SessionStart | `.claude/hooks/session_context.py`, `ticket_index_context.py` | Emits a short repo/catalog banner inside a ticketwright repo; silent elsewhere |

Every hook is repo-gated: zero cost (and zero output) in repos that aren't set up for
ticketwright. Explicit timeouts are declared so a hung hook can never stall a session. To turn
them all off, disable the plugin (`claude plugin disable ticketwright`); the skills can still
be vendored without hooks via the kit install.

## Adopting an existing repo

Already have years of ticket folders and your own conventions? Run `/setup` — it detects the
existing layout, infers the config from evidence (folders, CI, CLIs, MCP servers), classifies any
custom commands you've built as *shadows / extends / unrelated* against the plugin's skills, and
writes a `MIGRATION.md` checklist instead of overwriting anything. Adoption is incremental: run one
real ticket through `/ticket → /review → /ship` before deleting anything custom.

## Also a standalone CLI

The pip package runs the deterministic engines without Claude Code:

```bash
pip install ticketwright                 # zero runtime dependencies; stdlib only
ticketwright recall --for ENG-123       # prior-art ranking
ticketwright index --stats              # catalog coverage
ticketwright init                       # vendor the kit into a repo (plugin-free installs)
```

## Learn more

- [docs/architecture.md](docs/architecture.md) — how it's built: the AI-layer model, seams,
  adapters and the verb contract, and how to add a new tool.
- [docs/troubleshooting.md](docs/troubleshooting.md) — a skill failed mid-way, a tool is
  unreachable, the index looks stale, upgrade paths.
- [docs/ticket-index.md](docs/ticket-index.md) — the ticket catalog + recall engine in depth.
- [CONTRIBUTING.md](CONTRIBUTING.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

CI runs the full self-test on every push; PyPI publishing is OIDC Trusted Publishing (no stored
tokens) — see [docs/pypi-setup.md](docs/pypi-setup.md).

## License

MIT — see [`LICENSE`](LICENSE).
