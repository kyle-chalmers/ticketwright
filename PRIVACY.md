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
| Your tracker | `/ticket` reads the ticket; `/ship` posts a comment you approved | ticket fields and the approved comment |
| Your warehouse | `/build` and `/review` | the queries the plan calls for, and their results |
| Your docs store | `/ship` backup | the ticket folder, after a scan for raw source material |
| Your chat tool | `/ship` | a draft message; sent only when you say "send it" |
| Your git host | `/ship` | a commit, a pushed branch and a pull request |
| The model command you configure | `ticketwright enrich` | one ticket's text, to write its index summary |

Every post to an outside tool waits for your go-ahead, and `/ship` shows the full delivery plan
first.

**Local reads.** The hooks read files in the repo, any `-f` SQL file a command names, your viewer
and people config under `~/.config/ticketwright/`, and Claude Code's own
`installed_plugins.json` (to notice a newer release). They write nothing outside the repo.

**Installing** fetches the plugin from GitHub (Claude Code's marketplace) or the package from
PyPI. The maintainer-only image scripts in `scripts/readme_media/` fetch web fonts from Google
Fonts when re-rendering; they are not part of the kit.

## What is kept, and for how long

Everything Ticketwright writes lives in your repository and stays until you delete it:

- ticket folders, including plans, QC queries, deliverables and CSVs, committed by default so the
  team's history is searchable;
- the catalog (`tickets/index_data.json`, `tickets/INDEX.md`, `tickets/OBJECTS.md`) and the graph
  notes, committed and regenerated from those folders;
- `people/<id>.yaml` and voice profiles, committed by default. A voice profile is personal data, a
  writing fingerprint: to keep yours private, point your `voice.path` outside the repo, or
  gitignore it before its first commit;
- `.claude/config/*.local.yaml` (your machine's connections and viewer choices) and the `comms/`
  drafts `/ship` writes, which stay on your machine (both are gitignored).

The `.gitignore` that `/setup` writes keeps raw meeting transcripts out of git by default. To keep
a deliverable out, name it `*.private.csv` (or `.tsv`, `.xlsx`, `.parquet`), or put it in a
`private/` folder inside `final_deliverables/`.

## Children

Ticketwright is a developer tool for adults working with their organization's data. It is not
directed at children.

## Contact

Questions about this statement: open an issue as described in [SUPPORT.md](SUPPORT.md), or report
privately through [SECURITY.md](SECURITY.md).
