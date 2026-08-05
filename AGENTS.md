# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding agents when working in
this repository. (`CLAUDE.md` is a one-line `@AGENTS.md` import so Claude Code loads these rules.)

This is the **development repo for Ticketwright itself** — the tool-agnostic AI layer for
ticket-driven work repos. Do not confuse it with a repo that *uses* Ticketwright: here you are
editing the plugin/kit, not working tickets. It's a public OSS repo on the personal `kyle-chalmers`
GitHub account (see PAT routing in `~/.claude/CLAUDE.md`), shipped two ways from one source tree:

- a **Claude Code plugin** (`.claude-plugin/`), and
- a **PyPI package** (`ticketwright/`) whose wheel bundles the kit under `ticketwright/_kit/`.

## Commands

```bash
bash bin/selftest.sh                       # THE gate — kit integrity + hook/engine unit tests. Run before and after any change.
python3 bin/build_ticket_index.py --check  # staleness gate: INDEX.md/OBJECTS.md must be in sync (CI enforces)
bash bin/verify_stack.sh <stack.yaml> --dry-run   # prove every seam resolves to an adapter (no network)
claude plugin validate . --strict          # plugin + marketplace manifest validation (CI runs this)
python3 -m build                           # build the sdist + wheel (needs the `dev` extra: pip install -e ".[dev]")
```

`selftest.sh` is authoritative and self-contained: read-only, no network, no credentials, bash 3.2-safe.
It needs `yq` and `python3` only. It is organized into ~23 numbered sections (config resolution, adapter
verb coverage, tool-name isolation, every hook, the index/recall engines, the render gate, the Obsidian
graph layer, version sync, …). **When you change behavior, add or update the matching numbered section** —
a green selftest is the contract this kit ships on. It must print `0 failed`.

There is no separate lint/format step; correctness is enforced by selftest assertions.

## Architecture — the essential model

Full contributor map: `docs/architecture.md`. The load-bearing ideas:

**Seams + adapters + a verb contract.** A *seam* is a tool slot: `tracker`, `warehouse`, `chat`,
`docstore`, `vcs`. Three layers wire it:
1. `.claude/config/stack.yaml` — names which tool fills each seam, plus project facts and the 9
   `policies`. Schema in `.claude/config/stack.schema.md`; three worked examples ship
   (`stack.yaml` + `stack.example.*.yaml`) and selftest runs skills against all three.
2. `adapters/<seam>/<tool>.md` — maps the abstract **verbs** (`fetch_ticket`, `query`, `draft`,
   `backup`, `commit`, …) to that tool's concrete commands. Contract + per-seam verb counts in
   `adapters/README.md`.
3. `bin/verify_stack.sh` — pings each seam's read-only `verify` before use.

**THE GOLDEN RULE: skills/commands are tool-agnostic.** Anything in `.claude/skills/` (or
`.claude/commands/`) is written **once against verbs** and must never *invoke* a concrete tool — no
`acli`/`snow`/`gh`/`psql`/`mcp__*` calls in orchestration. Tool specifics live only in adapters +
`stack.yaml`. Selftest section 3 greps for leaks and fails on one. Two sanctioned exceptions: the
CLI-**detection** probe in `setup`, and the self-lint line in `productize`. Naming a tool in
illustrative prose is fine; calling one is not. If a new tool requires a skill edit, the abstraction
is leaking — flag it.

**Adding a tool** (the common contribution): copy the closest adapter in the same seam, keep the
frontmatter (`seam`, `tool`, `transport`, `requires`, `auth`), implement **every** verb section the
seam's contract lists, point a `stack.yaml` seam at it with a read-only `verify`, then run
`verify_stack.sh` + `selftest.sh`. No skill edits.

**Deterministic engines, no vector store.** Catalog rendering and prior-art recall are plain stdlib
Python the model *calls*, not prose it approximates. Recall is lexical + structural (object match ×4,
tag ×3, cross-ref +5, keyword ×1, IDF down-weighting, recency tiebreak). Engines:
`build_ticket_index.py` (renders `tickets/INDEX.md` + `OBJECTS.md` + the Obsidian graph layer),
`recall.py`, `ingest_index_records.py`, `enrich_ticket.py`.

**Hooks are the only Claude-Code-specific layer** (declared in `.claude-plugin/plugin.json`,
mirrored into `.claude/settings.json` for non-plugin installs). All are Python stdlib-only, make no
network calls, never write outside the repo, and **fail open** — a hook error never blocks a session;
a guard only ever *adds* a confirmation. Each is repo-gated (zero output outside a configured repo):
- `db_write_guard.py` (PreToolUse/Bash) — asks before destructive warehouse SQL, *including SQL
  hidden in a `-f` file or stdin redirect*; read-only SELECT/DESCRIBE/SHOW pass through.
- `regenerate_ticket_index.py` (PostToolUse/Write·Edit) — re-renders the index when a ticket changes.
- `session_context.py` + `ticket_index_context.py` (SessionStart) — prime the stack + catalog banner.

## Hard constraints

- **Zero runtime dependencies.** The package is stdlib-only by design (`dependencies = []`). Do not
  add a runtime dep. Tooling for the kit is stdlib Python + `yq`/`jq` + standard CLIs.
- **Version has ONE source of truth: `ticketwright/__init__.py`.** `pyproject.toml` reads it
  dynamically; `.claude-plugin/plugin.json` and `marketplace.json` must match it. A release bumps all
  three in lockstep — selftest section 16 asserts they agree. `autoUpdate` re-installs teammates only
  when the *version* moves, so day-to-day commits to `main` must NOT bump it; version bumps belong to
  tagged release commits.
- **The repo root is the source; the wheel bundles copies.** `pyproject.toml` force-includes `bin/`,
  `.claude/*`, `adapters/`, `templates/` into `ticketwright/_kit/`. Don't move kit files into the
  package dir — keep the layout the plugin and `cp -r`/`ticketwright init` installs expect. Scripts
  and hooks must resolve sibling files from their own kit dir (`__file__`/`CLAUDE_PLUGIN_ROOT`),
  never the project root (selftest section 20 guards this — it's a class of real install bugs).
- **This is a PUBLIC kit — no org-specific content.** No employer names, real ticket IDs, business
  vocabulary, secrets, or PII in tracked files. `tickets/index_data.json` is a per-install private
  store (gitignored); anything tracked must be fixture-only (`ENG-`/`DEMO-`/`TEST-`/`SAMPLE-`).
  Selftest sections 13, 14, and 20 enforce this.
- **The `AGENTS.md` / `CLAUDE.md` under `templates/` are user-repo scaffolds**, rendered by
  `bin/render.sh` from `.tmpl` files — not this repo's own config. Don't hand-edit rendered output;
  edit the `.tmpl`. `templates/CLAUDE.md.tmpl` must stay exactly one line: `@AGENTS.md`.

## Conventions

- Conventional-commit titles (`feat:`/`fix:`/`docs:`…). Update `docs/` and `README.md` when behavior
  changes; keep `CHANGELOG.md` current for anything user-facing.
- Skill/command/adapter frontmatter must be valid, parseable YAML with a `description` — a broken
  flow-node silently drops all metadata when loaded as a plugin (selftest section 14 checks this).
- The v1 command names (`/start-ticket`, `/qc-review`, …) were retired in v3; the surface is 7 skills
  (`setup`, `ticket`, `spec-and-build`, `review`, `ship`, `productize`, `refresh`). Don't reintroduce
  the old aliases (selftest section 14b fails on them).
