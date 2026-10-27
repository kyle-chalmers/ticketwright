# Ticket Index

`tickets/INDEX.md` is the master catalog of **every** ticket in the repo — one row per ticket
with status, completion date, a one-line summary, topic tags, and cross-references to related
tickets. It exists so the agent (and humans) can **recall prior work before starting new work** —
"have we done this before? which object did it touch? who was the stakeholder?" — instead of
rediscovering it each time. The agent is shown a slice of it at the start of every session.

## How it works (two layers)

![How /ticket finds prior work. Each past ticket folder becomes a card: the model writes the summary, tags and links, and a scan finds the tables in the SQL. Plain code scores the new ticket, TEST-130, against every card: a shared table scores 4 (rarer tables count more), a shared tag 3, a link between the two tickets 5, and each shared word 1, up to 6. Recency only breaks ties. Here bob's TEST-118 ranks first at 9.0, so the verdict is strong. The model reads the top 2 to 4 and writes the reuse brief, and you approve the plan. When the match is weak or missing, you choose whether to search older tickets in your tracker; they are scored the same way and labeled as having no folder or QC record here. That branch is drawn as if asked for, since a strong match like this one never offers it. Once shipped, TEST-130 becomes a card too.](images/recall.png)

The system deliberately separates a **deterministic renderer** from an **LLM-authored enrichment
store**, so the catalog is reproducible and CI/pre-commit-safe while still carrying good,
human-readable summaries.

| File | Role | Authored by |
|---|---|---|
| `tickets/index_data.json` | Enrichment store: per-ticket `title`, `date`, one-line `summary`, `tags`, `cross_refs`, `objects`, plus each README's `readme_hash` at enrichment time; and `tracker_status` + `tracker_status_read`, the status as last read from the tracker. | model (refresh skill / ship step); the tracker read (`ingest_index_records.py --tracker-status`) |
| `bin/build_ticket_index.py` | **Renderer.** Discovers every ticket folder, merges the store, writes `tickets/INDEX.md` + `tickets/OBJECTS.md`. Deterministic, LLM-free, stdlib-only. | — |
| `tickets/INDEX.md` | The rendered catalog (committed; read by humans + the SessionStart hook). | generated |
| `tickets/OBJECTS.md` | Reverse index: data object → tickets that touched it (objects = enrichment ∪ a grep of each ticket's SQL). | generated |
| `bin/recall.py` | Prior-art recall: ranks prior tickets vs a seed/query by object (IDF-discounted)/tag/cross-ref/keyword overlap (lexical, stdlib). Behind `/ticket --recall`. `--eval` reports recall quality vs cross-refs (read-only, never tunes). `--repeats` lists earlier tickets that read the same tables (the skillify suggestion). | — |
| `bin/ingest_index_records.py` | Upserts records into `index_data.json`, stamping each with the live README hash. | — |
| `bin/enrich_ticket.py` | One-command close-step enricher: reads a README, has a model write the curated summary/date/tags/refs (never the status), ingests + re-renders. The model command resolves per runtime (`adapters/runtime/*.md`), so this is not Claude-only. | model (headless) |
| `bin/summarize_hits.py` | One-line summaries of the top older tracker tickets. Runs the runtime's model command only where that command withholds every tool (Claude Code, on its cheaper model); everywhere else, Codex CLI included, the session writes the lines from the titles. | model (headless) |
| `.claude/hooks/ticket_index_context.py` | SessionStart hook: prints counts + the most-recent tickets + a pointer to grep `INDEX.md`. | — |
| `.claude/hooks/regenerate_ticket_index.py` | PostToolUse (Write/Edit) hook: auto-re-renders `INDEX.md` whenever a file under `tickets/` changes — new tickets appear immediately, edited READMEs flag `⚠`. | — |

**Why split?** Regex can't write a good summary, but a model isn't reproducible and can't run in a
pre-commit gate. So the model writes summaries into `index_data.json`; the renderer only *renders*
(no model at render time) and stays byte-stable for the same on-disk state.

**Status has one source: the tracker.** The Status column shows, in order: the status `/refresh
index` last read from the tracker (through the tracker's `search` by ids), a curated status an
older kit version wrote, the ticket README's `- **Status:**` line (written from the tracker by
`/ticket`), a folder-name emoji, else `Unknown`. No model writes a status any more: a model's guess
is what showed a finished ticket as `In Review`, on a workflow that has no such status. When any
status came from the tracker, the index header says for how many tickets and the date of the oldest
read, and `build_ticket_index.py --stats` prints `status from: tracker N · readme N · …`. When the
tracker cannot be reached, the index keeps the last status it read. If the README's Status line changes
after a read (the `local` tracker writes it on every transition), the README wins, being the newer copy.

## What counts as a ticket

Depends on `project.id_mode`.

**`keyed` (default).** Any immediate sub-folder of `tickets/<owner>/` whose name contains a **tracker
key** — the prefixes come from `stack.yaml` (`key_prefixes`, else `key_prefix`; e.g. `TEST-12`).
Emoji-prefixed names like `☑️ TEST-12_thing` work too (`☑️` = done, `🛠️` = in progress — an optional
convention). Folders with **no** tracker key are treated as reference/scratch work and skipped (e.g.
`adhoc-*`, `scratch-*`, `ℹ️ notes`).

**`slug`.** For a repo with no ticketing system: any sub-folder whose whole name (after an optional
status emoji) matches `[a-z0-9][a-z0-9_-]*`, and the **name itself is the id**. Nothing is skipped for
lacking a key, so a scratch folder is either a ticket or shouldn't live under `tickets/`.

Rows key on **(owner, id)**, so the same id can appear under two owners. Two folders that reduce to
one id for one owner — `signup-lift` and `☑️ signup-lift` — are reported on stderr and the later one wins;
don't keep both.

### The ticket locator

Owner is part of a ticket's identity, and one grammar names a ticket everywhere:

- **`owner/id`** — the CLI and display form (`alice/TEST-12`, `dana/signup-funnel-lift`). A bare
  **`id`** is allowed whenever exactly one owner has it. Every engine takes it:
  `enrich_ticket.py alice/TEST-12`, `recall.py --for alice/TEST-12` (equivalent to `--owner alice`).
- **A bare id two or more owners share is a hard stop** naming every owner and the qualified
  spellings — a CLI never picks one, and never operates on all of them. (`recall.py` established
  this discipline with `--owner`; `enrich_ticket.py` exits 3 the same way instead of its old
  enrich-every-owner behavior.)
- **`owner/id` never becomes a filename or a git ref.** Files flatten the separator
  (`tickets/graph/<owner>.<id>.md`, same rewrite as object notes); **branch names stay bare `<id>`**
  — `/` is git's ref-namespace separator, so an `alice/x` branch would permanently forbid a branch
  named `alice`. When a bare branch name is already taken, the branch is created as `<owner>-<id>`
  and the skills say so.
- **A bare `[[wiki-link]]` (or bare cross-ref) resolves within the CURRENT owner first, then across
  owners.** If it matches two owners, that is an error naming both (the renderer links neither and
  says so on stderr) — never a guess. A qualified `[[owner/id]]` wiki-link is honored exactly, in
  both id modes; in keyed mode it may name a ticket with no local folder (as bare keys always
  could) when the owner is known, while a slug pair must exist. The skills follow the same order:
  the whoami-resolved person's folder first, then other owners, and a bare id two *foreign* owners
  share is the hard stop. When one skill hands a ticket to the next, it passes the **qualified**
  locator, so the next step can never re-resolve it to a different owner's ticket.
- **Migration:** existing bare links keep resolving, because within-owner resolution is tried first;
  no historical rewrite is needed. Old bare-id graph nodes (`graph/<id>.md`) are swept up by the
  renderer's normal orphan cleanup on the next render.

### Cross-references

In `keyed` mode a cross-reference is any tracker key found in a README's prose, so the index can name
a ticket that has no folder here (`blocked by TEST-999`).

In `slug` mode it is **only** a `[[wiki-link]]` naming a ticket that exists. This is not a shortcut:
a slug is free to be an ordinary phrase, so pattern-matching prose would turn stray words like
`data-quality` into `OBJECTS.md` rows and graph edges. A wiki-link inside a fenced or inline code
block is read as an example, not a reference. Markdown link destinations are deliberately not
consulted — earlier attempts at that kept leaking images, external URLs and escaped brackets.

## Configuration (in `stack.yaml`)

- `id_mode` — `keyed` (default) or `slug`; see "What counts as a ticket" above.
- `key_prefix` / `key_prefixes` — which tracker keys the index recognizes in folder names. Not
  needed under `id_mode: slug`.
- `ticket_url_template` — e.g. `https://acme.atlassian.net/browse/{id}`; how `INDEX.md`/`OBJECTS.md`
  link each ticket. `{id}` = full key (`TEST-12`); `{number}` = trailing integer (for Azure Boards /
  GitHub Issues whose native id is a bare number). Omit/`null` to drop the `↗` link.

## Prior-art recall & the object reverse-index

The index is only valuable if it's *mined*. Two capabilities turn the passive catalog into active reuse:

- **Prior-art recall** (engine `bin/recall.py`, surfaced as `/ticket --recall`) ranks prior tickets against a seed ticket (or
  `--query` / `--tags` / `--object`) by a transparent lexical score — **object match ×4, tag ×3,
  cross-ref link +5, keyword ×1**, recency as a tiebreak — then reads the top few READMEs and writes a
  *reuse brief* (what to copy, gotchas, what's different). Wired into `/ticket`'s priming + `build`
  so prior art surfaces automatically in PLAN. Lexical + stdlib (no embeddings); the rank → read-top-K
  shape is the retrieval path that scales past the point where the whole `INDEX.md` fits in context.
  A brand-new ticket has no SQL yet, so recall also reads its **text** (the seed's README, plus any
  `--text-file`: the fetched description on stdin, an attachment) and keeps the object names some
  prior ticket already touched: a qualified name in any case (`db.schema.table`, `schema.table.column`),
  or a bare name spelled the way `OBJECTS.md` spells it when that spelling has a capital letter; a
  name in backticks counts in any case. An ordinary word such as "orders" in a sentence stays a
  keyword, so a catalog spelled all in lower case needs backticks or a qualified name. The verdict line says **strong** only when the top hit shares an object few
  tickets use (its weight stayed above the floor for common objects) or a cross-ref.
- **`tickets/OBJECTS.md`** — reverse map: each data object → tickets that touched it
  (`/ticket --recall --object VW_X` queries it live). A ticket's `objects` = **enrichment** (the model names them)
  **∪** a **deterministic grep** of its `*.sql`/`*.py`, keyword-anchored (`FROM`/`JOIN`/… `schema.object`,
  so `os.path.join` isn't a false positive). Rendered + `--check`-gated alongside `INDEX.md`.
  **Known limitation:** object names are folded case-insensitively and are warehouse-blind, so
  `ANALYTICS.CUSTOMERS` on one warehouse target and `analytics.customers` on another collapse into a
  single node. Usually that is the useful reading — a same-named object in two warehouses is often a
  real cross-system relationship — but it is not a per-target index.

## Older tickets in your tracker

The index only knows tickets that have a folder in this repo. A team that tracked its work before the
repo existed has older tickets that never got one, and `/ticket` can search for them. The search is
read-only and goes through your tracker's adapter, so it works with whichever tracker you configured.
The repo's own tickets always come first: this runs after them, never instead of them, and the ranking
of the repo's own tickets is unchanged.

**When it is offered.** Each of these must hold:

- recall's `verdict:` line says `weak` (the top hit shares keywords only) or `no prior art found`.
  A `moderate`, `clear leader` or `strong` verdict never starts it.
- `project.history_search` is `ask`.
- the tracker is not `local`.

`/ticket` then asks once per ticket: **Search them**, **Skip** or **Look somewhere specific**. The last
takes one project, label, epic or person and searches only that, which is narrower and cheaper. After
Skip it does not ask again for that ticket in the session. You can also ask for the search yourself at
any time. Your own request skips the verdict test and the question, and it works when `history_search`
is `never`, but it does not skip the date check below.

**The keys.** These live under `project:` in `stack.yaml`, are team-wide (a personal or machine
file cannot set them), and are defined in `.claude/config/stack.schema.md`:

| Key | Values | What it does |
|---|---|---|
| `history_search` | `ask` (the default for any tracker but `local`) or `never` | `never` turns off the automatic offer only. Your own request still searches |
| `history_scope` | a project, team, repo or board, written the way that tracker writes its project value | Where the older tickets live. Unset means the project the tracker is already set up with |
| `history_before` | `"YYYY-MM-DD"`, in quotes | Only tickets created before this day are searched. Unset means no cutoff: every older ticket in the scope |

`/setup` asks once, as question 4a ("Did your team track work in your tracker before this repo
started?"), right after it picks the tracker project. It recommends the day ticket work in this repo
began (the first commit that touched the ticket folders, otherwise the repo's first commit), writes it
only on your yes, and lets you type a different date. A saved date that is not a real one gets one
plain line and repo-only recall, and the tracker is never contacted.

**What happens when you say yes.**

1. **Search.** The adapter's `search_history` verb takes two or three key words from the ticket, the
   scope, the cutoff, a limit of 20 and at most one filter (`project:`, `label:`, `parent:` or
   `person:`). It returns rows in one fixed shape: `key`, `fetch_id`, `title`, `description` (cut to
   600 characters), `labels`, `created`, `url` and `status`. The caller never writes a query in the
   tracker's own language, and a tracker that numbers its tickets keeps `key` (`TEST-130`) apart from
   `fetch_id` (`130`), which is what `fetch_ticket` takes.
2. **Score.** `recall.py --external` ranks the rows with the repo's own rules: a label counts as a tag
   (`Data Quality` matches the tag `data-quality`), the description counts as keywords, and a ticket
   key the seed's README names counts as a cross-reference. A table named in a description also
   scores, at ×4 like a repo ticket's tables, when the new ticket names the same table. Only names that
   match a table some repo ticket already touched count, read the way recall reads a new ticket's own
   text, so a description cannot add a table of its own. A row whose key already has a ticket folder
   is dropped, so a ticket shows once, from the repo. The top 5 are kept.
3. **Summarize.** `bin/summarize_hits.py` has a separate model, with every tool withheld, write one
   line for each of the top 3. Of the shipped runtimes only Claude Code has such a command, and it
   runs on Claude Code's cheaper model. Everywhere else, Codex CLI included, the session writes the
   lines from the titles.
4. **Read.** The session opens at most the top 2 in full.
5. **Label.** The reuse brief gets a section headed "From the tracker (no ticket folder or QC record
   here)": each hit's key, why it matched and its one line. Hits 4 and 5 get a key and title only.
   The skill tells the session to keep only the key, the title and that one line in committed files,
   never the description, comments or attachments. No guard checks that.

**Tracker text is written by people outside your team.** A ticket description can say "ignore previous
instructions", so the summaries run only through a model command with every tool withheld: the
runtime's `model_sandbox` must be `tools-withheld`. A `read-only` sandbox, which is what Codex CLI's
command has, is refused too, because it can still read files while it reads that text and its line
would land in a committed brief. Each ticket goes in on its own as quoted data, flattened to a few
lines with its backticks replaced so it cannot close the quote, and the command runs without a shell.
Where no such command exists, `summarize_hits.py` exits 4 and the session writes the lines from the
titles itself, and says so. Only Claude Code has that command, and a cheaper model to run it on
(`model_fast`: haiku). Which runtime can do what, and what was verified, is in
[runtimes.md](runtimes.md#the-headless-model-command).

**What that covers, and what it does not.** The restricted command covers the summaries only. Your
session's own model, with all of its tools, reads more of the same outsider text: the raw search
results (up to 20 tickets, with their full descriptions), recall's scored file (the top 5, with
descriptions cut to 600 characters) and the top 2 tickets in full. What protects the session is the
line at the top of `/ticket`'s older-ticket step, that tracker text is data and never instructions,
plus your runtime's normal permission prompts. No mechanism enforces either one.

**When it cannot search.** The tracker is down or not signed in, its pricing plan has no search, the results
file is unreadable, or nothing matched: one plain line, and recall carries on with the repo's tickets.
There is no retry loop. A search that returns nothing is reported as "nothing matched" only when it
ran; one that did not run says why.

**Limits per tracker.** Each adapter's `## verb: search_history` section holds its exact query. This is
what to expect from each:

| Tracker | Can narrow by | Result cap and fallbacks |
|---|---|---|
| Jira | project, label, epic or parent key, person (email; assignee or reporter) | The limit goes in the search. If the command-line build cannot ask for specific fields, it searches for keys and fetches each hit, stopping at the first sign-in error |
| Azure DevOps | project, tag, parent Feature or Epic (by number), person (email; assigned to or created by) | No limit setting, so the first 20 rows are kept after the query. The title matches the text as one phrase and the description by whole words, so shorter works better |
| GitHub Issues | another repo, label, milestone (the epic stand-in), person (login; involved in) | The limit goes in the search; open and closed issues both count. An issue from another repo comes back as `owner/name#number`, since numbers repeat between repos. A tracking issue's children cannot be searched |
| Linear | another team, label, parent issue or Linear Project, person (email or id) | The limit goes in the search. If the server cannot filter on an upper date, larger pages are fetched (at most 5), rows on or after the cutoff are dropped, and only then are 20 kept |
| Asana | project, tag, section (the epic stand-in), person (id or email) | Task search is a paid Asana feature. On a free workspace it falls back to a name-only search, reads each candidate to apply the date, scope and filter, and returns nothing with a plain note if it cannot read them |
| monday | board, tags column, board group, people column (the tags and people filters apply after the fetch) | One page of up to 100 items, matched on the item name. The date test and the 20-row cap run after the fetch, newest first. An item has no description, so summaries rest on the title. A query monday rejects as too complex returns nothing with a plain note |
| local | nothing | Returns no rows: its tickets are the repo's own, and recall already covers them |

**Out of scope.** Docs stores, chat and wikis are not searched, and tracker hits are not added to
`INDEX.md`, `OBJECTS.md` or the graph. Both are separate, later work.

## Graph layer (Obsidian)

Alongside `INDEX.md`/`OBJECTS.md`, the renderer writes an Obsidian-navigable graph layer under
`tickets/` (on by default; `project.graph_notes: false` disables it):

- `tickets/graph/<owner>.<id>.md` — one small node per ticket, keyed by **(owner, id)** so two
  owners with the same slug get two nodes instead of one merged one (its objects, the tickets it
  **builds on** as links, and a link to its README). "Builds on" links follow the ticket locator's
  resolution order — see "The ticket locator" above. A cross-reference has no direction of its own,
  so the node sorts each one by which ticket came first (the earlier completion date, then the lower
  ticket number): **Builds on** lists earlier tickets this one cites, **Built on by** lists later
  tickets that cite this one, and **Related** lists a later ticket this one mentions that does not
  cite it back. With no date or number to compare, a link stays under Builds on.
- `tickets/objects/<object>.md` — one node per data object, linking the ticket stubs that touched
  it; a shared id is labeled `owner/id`. A shorter name (`schema.table`, from a curated record)
  folds into the one longer qualified name it ends with (`db.schema.table`, from the SQL), so one
  table is one node; when two qualified names could claim it, the short name stays as written.

Object notes link the ticket stubs (so tickets cluster around shared objects) and stubs link their
cross-refs (direct build-on lines). Plain relative markdown links — the graph works in stock Obsidian
(no plugins/wikilinks) and the files render on GitHub. The layer is deterministic and `--check`-gated
like `INDEX.md`, regenerated on the same PostToolUse hook (which ignores its own `graph/`/`objects/`
output), with orphan cleanup removing nodes for deleted tickets/objects. Human `README.md` tickets are
untouched.

### Auto-configured Graph view (`.obsidian/graph.json`)

So the graph looks right the moment you open it — no manual filtering or color-grouping — the renderer
also **writes `.obsidian/graph.json`** (on by default; `project.graph_config: false` opts out
independently of the node layer). It sets:

- **Filter** `path:"tickets/graph/" OR path:"tickets/objects/"` — the Graph view shows **only** the
  tickets↔objects web (READMEs, `INDEX`/`OBJECTS`, and any other notes are hidden; clear the search
  box to see everything again — your edit is preserved, see below).
- **Color groups** — ticket nodes (`path:"tickets/graph/"`) in lime, object nodes
  (`path:"tickets/objects/"`) in coral, so the two node types read apart at a glance.

**It never clobbers your manual graph tweaks.** The renderer owns exactly those two things (keyed by
their query strings): it creates the file if missing and re-creates the filter/groups if you delete
them, but preserves every other key — forces, zoom, display toggles — and any color group you add. If
you type your own `search` filter, it's left alone. Because Obsidian rewrites this file on every
zoom/pan, it's deliberately **not** `--check`-gated (unlike the node layer). Committed by default so the
graph looks right for the whole team; per-user `.obsidian/workspace.json` is gitignored.

## Maintaining it

```bash
# Install-mode routes: plugin → `/refresh index` (`/ticketwright:refresh index`); pip → `ticketwright index`;
# the bare `python3 bin/…` forms below are for VENDORED repos (after `ticketwright init`).
python3 bin/build_ticket_index.py             # (re)render INDEX.md + OBJECTS.md from the store + folders
python3 bin/build_ticket_index.py --check     # staleness gate: exit 1 if any rendered file (both catalog files, plus the graph nodes when that layer is on) != a fresh render
python3 bin/build_ticket_index.py --stats     # coverage + health: enriched %, median summary, one-off/shared objects
python3 bin/build_ticket_index.py --recurring --min-tickets 8   # objects touched by many tickets → skillify candidates
```

**A repeated analysis, at the second instance.** `--recurring` counts tickets per object, so it
needs several tickets before a table stands out. `recall.py --for <owner>/<id> --repeats [--json]`
answers a narrower question: which earlier tickets read *exactly the same set of tables* as this
one. It compares only what each ticket's SQL reads (`from`/`join`), not the tables it writes and not
its `qc_queries/`, so two runs of one analysis match even when their output tables are named
differently. Before a ticket has SQL, its text stands in and the answer is marked `provisional`.
The output also lists project skills that may already do the work (`built_from:` naming one of
those tickets, or `read_objects:` naming the same tables) and honors the `skillify_everything`
policy. `/ticket`, `/ship`'s retro and a session's closing message read it through
`.claude/skills/skillify/repeats.md`, which has the agent confirm the deliverable shape before
suggesting `/skillify`, and never runs it unasked.

A ticket on disk but absent from `index_data.json` still appears in `INDEX.md` — the renderer falls
back to the README's H1 + first paragraph and marks the row `▱` (not yet curated). If a README
changes after enrichment, the row is marked `⚠` (summary may be stale). Neither breaks `--check`;
both are cues to re-enrich. Use **`/refresh index`** to bootstrap or re-enrich.

**Auto-regeneration.** The `PostToolUse` hook re-renders `INDEX.md` whenever the agent writes/edits
any file under `tickets/` — a new ticket shows up the moment its README is written (`▱`), and an
edited README flags `⚠`. The hook only runs the deterministic renderer (never the model), writes
only when output actually changes, and no-ops for edits outside `tickets/`.

### At ticket close

Upgrade the closed ticket's row from auto-derived to curated, then commit. One command (reads the
README, writes the summary via the runtime's model command, ingests, re-renders):

```bash
python3 bin/enrich_ticket.py TEST-123     # or --branch to use the current branch's id
python3 bin/enrich_ticket.py alice/TEST-123  # the owner/id locator, when two owners share the id
```

A bare id under multiple owners is a hard stop (exit 3) naming them — pass `owner/id` to pick one.

Then commit `tickets/INDEX.md` + `tickets/OBJECTS.md` + `tickets/index_data.json` with the ticket,
plus `tickets/graph/` + `tickets/objects/` when `project.graph_notes` is on (`--check` gates the
rendered files, graph nodes included; the curated store is an input, so it isn't gated). An agent closing the
ticket already has full context and may instead write the record itself and pipe it to
`bin/ingest_index_records.py --from-json -`; `enrich_ticket.py` is the hands-off path that also works
for a human at the terminal. This is wired into the `ship` skill.

## Why markdown, not a vector DB

At a few hundred tickets, a model reading a structured `INDEX.md` outperforms vector similarity for
recall, with zero infrastructure. If the table ever outgrows the session-start context window, the
SessionStart hook already injects only the most-recent slice and points at the full file to grep.

## Enforcement

`--check` is designed to run as a **pre-commit hook or a CI job** so `INDEX.md` can't drift from the
source. The SessionStart hook keeps the agent aware of the catalog every session, which is the
primary freshness mechanism even without CI.
