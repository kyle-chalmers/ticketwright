<!-- markdownlint-disable MD033 MD041 -->
![Ticketwright: the Claude Code plugin for ticket-driven analysis. Prior work recalled, every result reviewed, nothing sent without your go-ahead. A KC AI Labs project.](https://raw.githubusercontent.com/kyle-chalmers/ticketwright/main/docs/images/banner.png)

<div align="center">

[Get started](#get-started) · [Try it](#try-it) · [Skills](#the-skills) · [Safety](#safety-rails) · [Data and network](#data-and-network) · [Docs](docs/README.md) · [Changelog](CHANGELOG.md)

[![CI](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml/badge.svg)](https://github.com/kyle-chalmers/ticketwright/actions/workflows/ci.yml) [![PyPI](https://img.shields.io/pypi/v/ticketwright?label=pypi&color=c4ff00&labelColor=030303)](https://pypi.org/project/ticketwright/) [![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-c4ff00?labelColor=030303)](#get-started) [![Python 3.9+, stdlib only](https://img.shields.io/badge/python-3.9%2B%20%C2%B7%20stdlib%20only-c4ff00?labelColor=030303)](pyproject.toml) [![License: MIT](https://img.shields.io/badge/license-MIT-c4ff00?labelColor=030303)](LICENSE)

</div>

![A rendered walkthrough of one ticket in a Claude Code chat. /ticket opens TEST-130, ranks bob's TEST-118 as the closest prior work, writes the plan and waits for approval. /build runs the plan. /review walks the validation pyramid (dialect lint, counts and duplicates, reconciliation, an independent re-run) to the person's sign-off and an APPROVE. /ship shows its delivery plan and stops until the person says go ahead, then files the ticket into the team index.](https://raw.githubusercontent.com/kyle-chalmers/ticketwright/main/docs/images/demo.gif)

<sub>A rendered walkthrough drawn from the skills' own wording, not a screen recording.</sub>

**Ticketwright is a Claude Code plugin for teams whose work product is an answer.** Every ticket
follows the same five phases, every result is re-run and signed off before it ships, and every
finished ticket is filed where the next person or agent can find it.

> **Quick start:** run the two commands in [Get started](#get-started), restart Claude Code, then
> run `/ticketwright:setup`. On another agent, see [Other coding agents](#other-coding-agents).

## Mission

**Ticketwright empowers a team to do a high volume of analysis without letting quality slide, on whatever tools they already use.**

## Vision

**Any new or experienced member can pick up any analysis and be productive the same day, because the team's past work is written down and organized, and AI can trace it.**

**This is for you if:**

- ✅ you're an analytics, BI, ops or reporting team closing many tickets a week
- ✅ you want every number re-run and signed off before it leaves
- ✅ you want past work to surface when a similar ticket arrives
- ✅ you want to keep your tracker, warehouse, chat and drive
- ❌ you ship software features, or want an agent that posts on its own

## What it builds: a team brain

Every ticket lands in one folder with its business context, written assumptions, QC verdict and
deliverables. An auto-maintained catalog (`tickets/INDEX.md`) and object map (`tickets/OBJECTS.md`)
make that history searchable by people and agents, so `/ticket` opens new work with the closest
prior work already ranked. Details: [docs/how-it-works.md](docs/how-it-works.md).

## The lifecycle is the map

![The Ticketwright lifecycle. The team brain (tickets/, INDEX.md, OBJECTS.md) feeds the closest prior work into five phases: 1 Open the work (/ticket), 2 Do the work (/build), 3 Quality-check (/review), 4 Deliver (/ship) and 5 Announce (/ship). You approve the plan, sign off the numbers, and say go ahead before anything is sent. Each shipped ticket is filed back into the brain with its assumptions and QC verdict. Hooks ask first before destructive warehouse SQL, a push with no approving review, or a raw transcript being committed or backed up.](https://raw.githubusercontent.com/kyle-chalmers/ticketwright/main/docs/images/lifecycle.png)

Quality checking has no slot of its own: `/review` borrows the warehouse to re-run your queries,
then a person signs off. Skills speak to tool slots, never to a vendor, so swapping a tool is one
config line and one adapter file:

![Skills (/ticket, /build, /review, /ship) call verbs such as fetch_ticket, query, backup, draft and commit. stack.yaml names which tool fills each slot, adapters map each verb to the tool's real command, and your tools do the work: tracker, warehouse, chat, docs, meetings and git.](https://raw.githubusercontent.com/kyle-chalmers/ticketwright/main/docs/images/tool-slots.png)

| Tool slot | Works with |
|---|---|
| Tracker | Jira, Azure DevOps, Linear, Asana, Monday, GitHub Issues, or none (`id_mode: slug`) |
| Warehouse | Snowflake, BigQuery, Databricks, Postgres, Redshift, Synapse, or none |
| Chat | Slack, Teams, Gmail, Outlook |
| Docs | Google Drive, SharePoint, or Dropbox/S3/Box through rclone |
| Meetings | Zoom, Fireflies, Granola, Teams, Notion (optional) |
| Git | GitHub, GitLab, Azure Repos |

Another tool is [one more adapter file](adapters/README.md).
Desktop-sync backup needs one local step: [docs/drive-mount.md](docs/drive-mount.md).

## Try it

Plain requests work too:

```text
/ticketwright:ticket TEST-130
    Open the ticket, load its context and the closest prior work, write the plan, wait for my OK.

/ticketwright:ticket --recall --object RETURNS
    Which past tickets touched the RETURNS table, and what can I reuse?

/ticketwright:review --deep
    Re-check this ticket's numbers with one independent reviewer per validation layer.

/ticketwright:ship
    Show me exactly what will be sent and where, then wait for "go ahead".

What did we learn last time someone measured late orders by region?
```

## The skills

```
/ticket <id>        opens or resumes the ticket, auto-loads its context + closest prior work,
                    writes the plan (and the spec when the plan calls for one), and waits for
                    your approval before anything is built ↓
/build              starts on your approval (subagents build the bigger tickets), runs /review,
                    asks before /ship, and replans with you when the review finds the plan was wrong
/review [--deep]    the independent QC pass /build runs for you: re-runs queries, walks the validation
                    pyramid → APPROVE / REQUEST-CHANGES; run it directly to re-check or go --deep
                    …and at the top of that pyramid, opens the deliverables in YOUR apps and waits
/ship [--go]        backup → tracker comment → chat draft → commit + PR, a HARD HALT before anything
                    external; warns, waits for a typed `ship unreviewed`, and records it when no
                    review verdict is on file
/setup              configure once, or onboard a teammate
/refresh            rebuild the catalog
/skillify           turn a recurring workflow into its own skill
```

On a plugin install, prefix each one: `/ticketwright:ticket`.

## What a working repo looks like

`/setup` writes the top half; the `tickets/` half grows as the team works.

```
your-repo/
├── AGENTS.md                  # team rules, read by people and agents alike
├── CLAUDE.md                  # one line: @AGENTS.md
├── bin/tw                     # launcher that finds the installed kit
├── .claude/config/
│   ├── stack.yaml             # which tool fills each slot, plus team policies
│   └── connections.local.yaml # your machine only (gitignored)
├── people/
│   ├── alice.yaml             # one file per teammate: identities, viewer, voice
│   └── bob.yaml
├── documentation/             # the domain knowledge pack
└── tickets/
    ├── INDEX.md               # every owner's tickets in one catalog      (auto)
    ├── OBJECTS.md             # table or view -> tickets that touched it  (auto)
    ├── graph/  objects/       # Obsidian nodes for tickets and tables     (auto)
    ├── bob/
    │   └── TEST-118/          # returns baseline, shipped last month
    └── alice/
        ├── TEST-127/          # shipped
        └── TEST-130/          # in progress, builds on bob's TEST-118
            ├── README.md              /ticket   business context, every assumption
            ├── plan.md                /ticket   the plan you approved
            ├── specs/                 /ticket   the spec, when the plan calls for one
            ├── source_materials/      /ticket   attachments, curated meeting notes
            ├── exploratory_analysis/  /build    scratch queries, kept for the record
            ├── final_deliverables/    /build    01_returns_by_region_1284rows.sql + .csv
            ├── qc_queries/            /build    numbered checks, then /review's verdict
            └── delivery-plan.yaml     /ship     who received it, and where
```

Alice's TEST-130 cites Bob's TEST-118, so her reviewer can trace the numbers back to his.

## Get started

Install project-scoped, from the root of your ticket repo, so the whole team runs one version:

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

Run `/reload-plugins` (or fully quit the app; a new chat is not a restart), then
`/ticketwright:setup`; it detects your tools and interviews you before writing anything. Steps
for the first person and for joiners: [docs/getting-started.md](docs/getting-started.md).
Upgrading: [uninstall, install, relaunch](docs/troubleshooting.md#upgrading).

### Other coding agents

The same kit installs from PyPI for Codex, Cursor, OpenCode, Cline, Devin and Antigravity:

```bash
pip install ticketwright
ticketwright init                         # copy the kit into this repo
ticketwright install --runtime codex-cli  # write the skills where your agent reads them
```

You get the skills and command-line engines. `/setup` runs in Claude Code, so elsewhere you
write the config yourself, and the guards are proven only in Claude Code. Details:
[docs/runtimes.md](docs/runtimes.md) and
[installing without the plugin](docs/getting-started.md#installing-without-the-plugin).

## Safety rails

- Destructive warehouse SQL run through a CLI asks first, even hidden in a `-f` file; verifiably
  read-only SQL runs without a prompt.
- `/ship` stops before any external post and shows exactly what it will send.
- Pushing deliverables with no approving review on file asks first.
- Committing or backing up a raw meeting transcript asks first.

Hooks fail open, never loosen your own deny rules, and see shell commands only, so SQL sent
through an MCP tool falls under that tool's permissions. All of them:
[docs/how-it-works.md](docs/how-it-works.md#hooks-in-full).

## Data and network

No telemetry, and no service of its own: Ticketwright's own code makes no network calls.
Installing fetches it from GitHub or PyPI; everything else goes through tools you configured,
under your own sign-in.

- **Your coding agent.** What the skills read (ticket text, query results, notes) goes to your
  agent's model provider under your account's terms, as does the ticket text
  `ticketwright enrich` sends to the model command you configure, and up to three older tracker
  tickets that command summarizes.
- **Your tools, named in `stack.yaml`.** `/ticket` reads the ticket and, if you say yes, searches
  your tracker's older tickets. `/build` and `/review` query the warehouse, and `/ship` backs up,
  comments, drafts the chat message (sent only on "send it") and opens a pull request.
- **Local reads.** Hooks read the repo, any `-f` SQL file a command names, your viewer and people
  config, and Claude Code's `installed_plugins.json`. They write nothing outside the repo.
- **Committed by default:** ticket folders, deliverable CSVs and voice profiles. Raw transcripts
  and `*.private.csv` files are not.

Full statement: [PRIVACY.md](PRIVACY.md).

## See it as a graph (Obsidian)

The index also writes `tickets/graph/` and `tickets/objects/`: open the repo as an Obsidian vault
to see which tickets touched which tables ([docs/obsidian.md](docs/obsidian.md)).

## Learn more

- [docs/README.md](docs/README.md): every doc, grouped by what you're trying to do
- [docs/how-it-works.md](docs/how-it-works.md): the lifecycle, voice profiles, every hook
- [docs/architecture.md](docs/architecture.md): adapters, the verb contract, adding a tool
- [docs/obsidian.md](docs/obsidian.md) and [docs/drive-mount.md](docs/drive-mount.md)
- [CONTRIBUTING.md](CONTRIBUTING.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## Support and security

Questions and bugs: [SUPPORT.md](SUPPORT.md). Vulnerabilities, privately: [SECURITY.md](SECURITY.md).
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

MIT, see [`LICENSE`](LICENSE). A [KC AI Labs](https://kclabs.ai) project by Kyle Chalmers, not
affiliated with Anthropic or any vendor named above.
