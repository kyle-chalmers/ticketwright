# Privacy

Ticketwright is open-source software that runs on your machine, inside your coding agent and your
git repository. It is a [KC AI Labs](https://kclabs.ai) project.

## What Ticketwright collects

Nothing. It has no telemetry, no analytics, no account, and no server. Its hooks, skills and
engines make no network calls, and nothing reports back to the project.

## What it reads and where that goes

The skills run inside your coding agent and work through the tools you name in
`.claude/config/stack.yaml`, under your own sign-in:

| Where | When | What moves |
|---|---|---|
| Your agent's model provider (Anthropic, for Claude Code) | whenever a skill runs | what the skill reads: ticket text, query results, ticket files, meeting notes you curated. Your agreement with that provider governs it |
| Your tracker | `/ticket` reads the ticket, and searches older tickets only when you say yes (read-only); `/ship` posts a comment you approved | ticket fields, a few key words from your ticket as search text, the project and cutoff date you saved in setup, any project, label, epic or person you name, and the approved comment |
| Your warehouse | `/build` and `/review` | the queries the plan calls for, and their results |
| Your docs store | `/ship` backup | the whole ticket folder, after a scan for raw source material that asks first. A backup is a copy, so gitignored files in the folder (the `comms/` drafts, `*.private.csv` exports) go too |
| Your chat tool | `/ship` | a draft message; sent only when you say "send it" |
| Your git host | `/ship` | a commit, a pushed branch and a pull request |
| The model command you configure | `ticketwright enrich`; the older-ticket search | one ticket's text, to write its index summary; and the title and description (first 600 characters) of up to three older tracker tickets, to write a one-line summary of each |

Every post to an outside tool waits for your go-ahead, and `/ship` shows the full delivery plan
first.

**The older-ticket search.** When the repo's own tickets give a weak match, `/ticket` offers to
search the tickets your team tracked before this repo existed. Nothing is searched until you pick
"Search them" or "Look somewhere specific", or ask for it yourself; setting `history_search` to
`never` in `stack.yaml` turns off the offer, not your own request. The search only reads. The
session opens the best one or two matches in full, and a separate model with every tool withheld
writes a one-line summary of the top three, with each ticket's text handed over as quoted data. Only
Claude Code has such a command: it is started with no tools and no MCP servers loaded, on a cheaper
model. [docs/runtimes.md](docs/runtimes.md#the-headless-model-command) says which of those two was
checked live and which rests on the CLI's help text. On every other runtime, Codex CLI included (its
read-only sandbox can still read files), your session's own model writes the summaries from the
titles instead. Either way the text goes to your agent's model provider, as in the first row.

That restricted command covers the summaries only. Your session's own model, with all of its tools,
reads more of the same text: the raw search results (up to 20 tickets, with their full
descriptions), recall's scored file (the top 5, with descriptions cut to 600 characters) and the top
2 tickets in full. What protects the session is the skill's instruction that tracker text is data,
never instructions, plus your runtime's normal permission prompts. No mechanism enforces either one.
The skill is told to keep only the ticket key, title and one-line summary in a committed file, never
the description, comments or attachments; no guard checks that. Details: [docs/ticket-index.md](docs/ticket-index.md#older-tickets-in-your-tracker).

**Local reads.** The hooks read files in the repo, any `-f` SQL file a command names, your viewer
and people config under `~/.config/ticketwright/`, and Claude Code's own
`installed_plugins.json` (to notice a newer release). They write nothing outside the repo.

**Installing** fetches the plugin from GitHub (Claude Code's marketplace) or the package from
PyPI. The maintainer-only image scripts in `scripts/readme_media/` fetch web fonts from Google
Fonts when re-rendering; they are not part of the kit.

## What is kept, and for how long

Ticketwright writes into your repository, and what it writes stays until you delete it:

- ticket folders, including plans, QC queries, deliverables and CSVs, committed by default so the
  team's history is searchable;
- the catalog (`tickets/index_data.json`, `tickets/INDEX.md`, `tickets/OBJECTS.md`) and the graph
  notes, committed and regenerated from those folders;
- the key, title and one-line summary of an older tracker ticket, if the ticket's plan or notes cite
  one (the skill is told to keep nothing else of it; no guard checks that), and your older-ticket settings
  (`history_search`, `history_scope`, `history_before`) in `stack.yaml`, which the whole team shares;
- `people/<id>.yaml` and voice profiles, committed by default. A voice profile is personal data, a
  writing fingerprint: to keep yours private, point your `voice.path` outside the repo, or
  gitignore it before its first commit;
- `.claude/config/*.local.yaml` (your machine's connections and viewer choices) and the `comms/`
  drafts `/ship` writes, which are gitignored.

Outside the repository, only where you choose it: `/setup` can save your viewer choices for every
repo in `~/.config/ticketwright/viewer.yaml` (that folder can also hold a cross-repo copy of your
people file), a voice profile lives wherever its `voice.path` points, and
`ticketwright install --global` writes skills into your agent's per-user folder.

The `.gitignore` that `/setup` writes keeps raw meeting transcripts out of git by default. To keep
a deliverable out of git, name it `*.private.csv` (or `.tsv`, `.xlsx`, `.parquet`), or put it in a
`private/` folder inside `final_deliverables/`. Gitignore only governs git: a `/ship` backup copies
the whole ticket folder, so a file that must not reach the docs store has to live outside it.

## Children

Ticketwright is a developer tool for adults working with their organization's data. It is not
directed at children.

## Contact

Questions about this statement: open an issue as described in [SUPPORT.md](SUPPORT.md), or report
privately through [SECURITY.md](SECURITY.md).
