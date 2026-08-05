# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish versioning.

## [Unreleased]

Skills can now **resolve a warehouse target**, so the multi-target seam released in 3.4.0 is usable
end to end — and a repo with **no ticketing system at all** can use the kit. Tool-agnostic and
stdlib-only; no version bump here.

Upgrade note: reinstall and relaunch **before** editing `stack.yaml`. Bundled hook changes don't reach
an installed copy via autoUpdate (claude-code #52218), and an un-relaunched session reads a new config
with old hooks — the display readers degrade to showing the first warehouse target rather than
breaking, but `bin/verify_stack.sh` will flag the seam until you relaunch.

### Added — human review handoff (the `viewer` seam)

Every pause in the kit used to guard a side effect *leaving* the machine. This one guards the
opposite: it stops so a person can **look at what was just produced**, in an application that can
actually render it, before a verdict is written. `/review` layer ⑤ was named "Human sign-off" but
only ever printed "flag for the human" — now it opens the deliverables and waits.

- **New optional seam `viewer`** (verbs `open`, `reveal`) with three adapters —
  `adapters/viewer/{macos-open,xdg-open,windows-start}.md`. Cross-platform is "pick the adapter for
  your OS", the same one-file contribution model as every other seam.
- **New policy `human_review_handoff`**: `off` | `review` (default) | `all`. The repo decides
  *when* a gate fires. Under `all`, `spec-and-build` also hands over generated SQL before its first
  warehouse run and CSVs after export.
- **Per-user app routing, gitignored.** Which app opens a `.sql` is a personal choice, so it is
  *not* in `stack.yaml`: `.claude/config/viewer.local.yaml` → a user-level file covering all your
  repos → a team-wide `seams.viewer` block, first hit wins. `/setup viewer` runs the interview;
  `/setup --teammate` now includes it, so each person answers for themselves.
  Reference: `.claude/config/viewer.example.yaml`.
- **New engine `bin/handoff.sh`** resolves routes deterministically, batches files sharing a route
  into one launch, and owns the rails: never launches under CI, `TICKETWRIGHT_NO_OPEN=1`, or with
  no desktop session; never opens a path outside the project; degrades soft when `yq` is missing;
  silent no-op when nothing is configured. `--dry-run` prints resolved commands without launching.

Enforcement is prose, like `hard_halt_before_external_posts` — analysis work has no fixed enough
shape for a hook to gate it without getting in the way, and nothing auto-opens on file writes.
Existing installs are unaffected: no viewer config means nothing opens and no behavior changes.

### Added
- **Skills resolve a warehouse target.** `adapters/README.md` gains a canonical
  `## Multi-target seams` section — the five-step resolution order, the `-- warehouse-target:` header
  convention, one-file-one-target, the CSV exception, dev-target resolution, and why cross-target
  joins are out of scope. Every skill and agent points at it rather than restating it. `/review` and
  `qc-reviewer` now resolve the dialect lint and the re-run **per file**, since a ticket spanning two
  targets has no single answer at ticket scope and re-running one target's SQL on another is not a
  reproduction. `--warehouse <name>` is accepted by `/ticket`, `/review`, `/spec-and-build` and
  `/refresh context`; the spec and ticket README record the target(s).
- **Wrong-warehouse guard.** `db_write_guard` prompts when the invoked CLI doesn't match the target a
  `.sql` declares in its leading `-- warehouse-target:` comment — **including for read-only SQL**,
  because a read against the wrong warehouse returns plausible wrong numbers rather than erroring.
  Deliberately conservative: it resolves the target's CLI with a stdlib scan and stays silent on
  anything it can't read confidently (a flow mapping for the whole `targets:` value, a target defined
  by a YAML alias), because a false prompt is worse than a missed one — prompts people learn to
  dismiss stop working. The authoritative check is the `/review` Should-fix finding, which needs no
  YAML parsing and is the only half that runs under agents other than Claude Code.
- **Trackerless work — `project.id_mode: slug` + a `local` tracker adapter.** A repo with no
  ticketing system can now use ticketwright: set `id_mode: slug` and a folder under
  `tickets/<owner>/` named however you name it becomes the ticket, with its `README.md` holding what
  a tracker would otherwise store. `adapters/tracker/local.md` implements the full six-verb tracker
  contract against that folder, so **`/ticket` and `/ship` are unchanged** — they keep calling
  `fetch_ticket` / `create_ticket` / `transition` / `comment` / `search` / `download_attachments` and
  never learn there is no API. Worked config: `.claude/config/stack.example.solo.yaml` (no tracker,
  and no chat or docstore either). `keyed` remains the default and is byte-identical: `INDEX.md`,
  `OBJECTS.md` and the graph notes match the previous release exactly.

  Three behaviours are worth knowing before adopting it. **Cross-references become explicit** — in
  slug mode only a `[[wiki-link]]` counts, never prose, because a folder name is free to be an
  ordinary phrase (`data-quality`) and matching prose would turn stray words into `OBJECTS.md` rows
  and graph edges. **The folder name is the id**, so renaming it renames the ticket everywhere and
  the character set is restricted to stay valid as a git branch and a filename. **`key_prefix`
  becomes optional**, and the session banner and statusline then label the workspace by its
  directory rather than printing `?-tickets`.

### Fixed
- **Two skills silently scoped themselves to one vendor.** `review` and `refresh context` said they
  work "on Snowflake, BigQuery, Databricks" while claiming to be tool-neutral. `bin/selftest.sh` now
  fails if a warehouse product name appears in any skill, command or agent — the existing guard
  caught CLI invocations like `snow sql` but not product names in prose.
- **A slug id ending in digits no longer sorts as a ticket number.** `ticket_number()` searched for
  `-\d+` anywhere in an id, so a folder called `refi-sms-lift-2024` ranked as ticket 2024 among real
  keys, in `INDEX.md`, `OBJECTS.md`, the graph notes and `recall.py`. Numbering is now decided by the
  configured prefixes (`id_key_regex`), which also fixes a pre-existing case: a prefix containing `_`
  or `-` or leading with a digit (`ACME_US-42`, `1ENG-42`) is matched correctly. Notably
  `ingest_index_records.py` *persists* `ticket_url` into `index_data.json` and a persisted URL wins
  over a re-render, so a wrong `{number}` there had been permanent — a link to an unrelated real ticket.
- **`enrich_ticket --branch` works on a branch with no commits.** It used
  `git rev-parse --abbrev-ref HEAD`, which returns the literal string `HEAD` on an unborn branch, so a
  freshly created ticket branch could never resolve. It now prefers `git symbolic-ref`. In slug mode it
  also resolves by identity against the ids on disk rather than by tracker-key pattern, and a detached
  HEAD resolves nothing instead of guessing.
- **`selftest.sh` died mid-run on macOS system bash (3.2) while CI stayed green.** An escaped quote
  inside a python heredoc left bash 3.2 quote-unbalanced for the rest of the file — the suite
  aborted at §14, so sections 14b–24 silently never ran for anyone on stock macOS. Also fixed the
  latent `IndexError` the same line carried for an empty frontmatter value. New §20 E12 parse-checks
  every shipped `.sh` under the running bash, which catches this class where it actually bites.
- Renumbered the duplicate `hdr "21 · …"` section to `21b`.

## [3.4.1] — 2026-08-05

### Fixed — security, upgrade from 3.4.0
- **The read-only `allow` fast-path could auto-approve an arbitrary second command.**
  `is_simple_command` scanned for `;`, `&`, `|`, `<`, `>` but **not newlines**, and a newline
  separates commands exactly like `;`. So a read-only query with a second command on the next
  line was classified on the query alone and auto-approved:

  ```
  snow sql -q "SELECT 1"
  snow sql -q "DROP TABLE t"     → allow
  ```

  The guard handed out `allow` for a `DROP` — the exact outcome it exists to prevent. Newline
  and carriage return now terminate the simple-command check.
- **Only the first `-q`/`--query` payload was ever classified.** `extract_inline_sql` used
  `.search()`, so a second `-q` on the same line was invisible to the tier scan. It now reads
  every payload.
- **The fast-path now requires the warehouse CLI in command position.** `is_simple_command` is a
  lexical check, not a proof, and it masks quoted spans before scanning — so it cannot see inside
  `sh -c "…"` or `eval "…"`. Without a leading-CLI anchor an interpreter invocation that merely
  mentioned a warehouse CLI could reach `allow`. Costs a prompt on `env FOO=1 snow …`, which is
  the safe direction.

Only the `allow` fast-path was affected; the `ask` path never under-gated. Introduced in 3.4.0,
which is the only affected release. `bin/selftest.sh` §6b covers all six cases.

## [3.4.0] — 2026-08-05

Graduated DB-write permission modes: the guard stops charging a confirmation for routine additive
work while still gating anything irreversible. Ships alongside the plugin-setup commit hygiene and
adopt/install field-report fixes prepared earlier for this version. Tool-agnostic and stdlib-only.

### Changed — behavior change, read before upgrading
- **`db_write_requires_approval` is now a three-value enum**, not a boolean:
  `off` | `high_risk` | `all`, defaulting to **`high_risk`**. Legacy values still parse —
  **`true` now resolves to `high_risk`, not to `all`** — so an existing config gets the relaxed
  default without being edited. Under `high_risk` the guard asks only for irreversible,
  access-changing, or unrecognized SQL; plain `CREATE`, `INSERT INTO`, `ALTER … ADD`, and
  `COMMENT ON` run without a prompt. **To keep the old ask-on-everything behavior, set
  `db_write_requires_approval: all`.** A missing, malformed, or unrecognized value resolves to
  `all`, never to something weaker.
- **Classification is default-deny.** Only the four additive forms above are treated as additive;
  everything else that mutates is high-risk, *including SQL the scanner doesn't recognize*. The
  previous flat verb list had holes — `ALTER TABLE … MODIFY COLUMN` can change a type and truncate
  data while matching no "destructive" verb.
- **`bypassPermissions` is honored.** The guard no longer asks in that mode; it emits a
  `systemMessage` instead, so the suppression is visible. Every other permission mode still gets a
  normal `ask` — notably `dontAsk`, where suppressing would turn an allow-listed CLI into an
  unguarded destructive channel.

### Added
- **Read-only `allow` fast-path.** Verifiably read-only SQL is auto-approved instead of falling
  through to the normal permission flow. Deliberately narrow: a single simple command (no shell
  operators or command substitution), every referenced file actually read, and every statement a
  read. Anything short of that is not auto-approved.
- **`.claude/hooks/_stack.py`** — shared stack.yaml resolution and policy reading. The hooks had
  grown three mutually inconsistent root-resolution implementations; `db_write_guard` and
  `session_context` now share one.
- **`bin/selftest.sh` §6b** — 41 assertions across the enum (including every legacy value and the
  fail-safe fallbacks), all six permission modes, tier classification, comment/string-literal
  false positives, multi-statement priority, and the allow fast-path's guards.

- **Distribution scope settled: plugin = the product, PyPI = the standalone/vendoring installer.**
  Both channels stay, with the pip package explicitly scoped to the cases the plugin can't serve
  (vendoring into a non-Claude-Code harness, running the deterministic engines from a shell or CI)
  rather than as a second full UX. Rationale and the rejected alternatives are recorded in
  [`ROADMAP.md`](ROADMAP.md). The real problem was drift, not cost — PyPI served 3.2.0 while the
  repo ran 3.3.0 — so the fix is structural:
  - **`bin/bump_version.sh <version>`** moves `ticketwright/__init__.py`, `.claude-plugin/plugin.json`,
    and `.claude-plugin/marketplace.json` in one command, verifies they agree, re-parses both
    manifests as JSON, and prints the tag command instead of running it (tagging publishes).
  - **CI builds and installs the wheel** (new `wheel` job, running on every PR and every push to
    `main`). `uv build` previously ran only in the publish workflow, so packaging breaks were
    invisible until release day. The job installs into a clean venv, checks `--version` against the
    source of truth, scaffolds a fresh repo with `init`, asserts the Acme `stack.yaml` did not come
    along, and checks that a re-run preserves local edits while `--force` overwrites them.
- **Multiple warehouses per repo (named targets).** `seams.warehouse` is now *either* today's single
  mapping *or* a multi-target mapping — `default: <name>` plus a `targets:` map. The presence of
  `targets:` is the discriminator (deliberately not `default:`, since other seams already use
  `default_channel` / `default_mode` / `default_branch`). Seam-level scalars are inherited by every
  target, including `tool` / `adapter` / `verify`, with a target's own key winning; inheritance is
  keyed on key *absence*, so an explicit `verify: null` still means "skip". `bin/verify_stack.sh`
  checks each target independently, marks the default with `*`, and fails closed when `default:` is
  missing or names an unknown target. Fourth worked config:
  `.claude/config/stack.example.multi-warehouse.yaml` (Snowflake + Databricks).
  **Existing single-warehouse configs need no edits** — all three shipped stacks produce
  byte-identical `verify_stack.sh`, `session_context.py`, and `statusline.sh` output.

- **`dev_target` as the canonical dev-environment key**, with each warehouse adapter declaring its
  legacy spelling in new `dev_key:` frontmatter (`dev_db` / `dev_dataset` / `dev_catalog` /
  `dev_schema`). Configs written before this keep working through that fallback.

### Fixed
- **The guard is actually repo-gated now.** It previously fell back to the kit's own shipped
  `stack.yaml`, so a globally enabled plugin enforced the worked example's policy in unrelated
  repos — contradicting the documented "zero output outside a configured repo".
- **The policy is actually read.** `db_write_requires_approval` was never parsed; it appeared only
  in the hook's docstring and its message text, so setting it `false` did nothing.
- **Fail-open is now enforced, not aspirational.** `main()` is wrapped in `except Exception`; a
  nonzero PreToolUse exit *blocks* the tool call, so an unexpected exception type previously failed
  closed.
- **Comments and string literals no longer trigger prompts** — `SELECT 'DROP TABLE x'` is a read.

- **The kit's fictional "Acme" `stack.yaml` no longer ships in the wheel.** `pyproject.toml`
  force-included `.claude/config` as a directory, so the repo's own worked example rode along and
  `ticketwright init` scaffolded it into fresh repos as if it were real config — `PRESERVE` only
  guards a file that *already* exists, which on a fresh repo it doesn't. The config dir is now
  enumerated file by file (schema + `stack.example.*.yaml` only); `/setup` writes the live
  `stack.yaml`. `selftest.sh` §16 fails if the directory mapping returns or a new config file is
  added without a force-include line.
- **`db_write_guard` no longer harvests another seam's CLI.** The `cli:` scan was an unanchored
  `re.DOTALL` regex starting at `warehouse:`, so a warehouse seam with no `cli:` of its own (only
  Snowflake requires one) that was listed *before* the tracker captured the tracker's CLI — making an
  ordinary `<tracker-cli> … create …` raise a spurious `db_write_requires_approval` prompt. The scan is
  now scoped to the warehouse seam block. It does not reproduce on any shipped stack, which all list
  `tracker` first, but nothing forbade the other order. The rewrite also stopped the scan from
  narrowing on valid YAML it previously read: non-two-space indentation, a comment before the first
  seam, anchors/tags on a key, flow mappings, and prose inside a block scalar.
- **`spec-and-build` no longer names a Snowflake-only config key.** It referenced
  `seams.warehouse.dev_db` twice inside a deliberately tool-neutral skill, so its dev-target guidance
  was simply wrong on BigQuery (`dev_dataset`), Databricks (`dev_catalog`), and
  Postgres/Redshift/Synapse (`dev_schema`). `bin/selftest.sh` now fails if any skill, command, or agent
  names a warehouse-specific dev key again.

### Also in this release — adopt/install field report (2026-07-06)

#### Added
- **`build_ticket_index.py --prune`** — drops *orphan* curated records (present in
  `tickets/index_data.json` but with no ticket folder on disk, e.g. a folder renamed/deleted after its
  record was written). Such drift was previously invisible and permanent.
- **Multi-location README locator.** The renderer now finds a ticket's README at the ticket root, then
  in any configured `project.ticket_subdirs` (e.g. `final_deliverables/`), then the nearest `README*.md`
  within bounded depth — so a repo whose README convention isn't "root `README.md`" is no longer
  falsely reported un-enriched, and the `INDEX.md` link points at the README's real path.
- **`--stats` surfaces drift** — now reports **orphan records** and tickets with **no README anywhere**
  (a real gap, distinct from "README not at root," which the locator now resolves).
- **`bin/selftest.sh` §23** — fixtures for the nested-README locator and the orphan-record
  `--stats`/`--prune` path.

#### Fixed
- **Marketplace source clones over HTTPS.** The committed `extraKnownMarketplaces` block and the
  Quickstart command now use an explicit `https://…git` **`url`** source instead of the `owner/repo` /
  `github` shorthand, which could resolve to SSH and fail (`git@github.com: Permission denied`) for
  anyone without GitHub SSH keys. HTTPS clones via the git credential helper (keychain /
  `gh auth login`), matching how the rest of git already authenticates.
- **SessionStart vs `--stats` count drift** — the ticket-index hook now flags when the curated store
  holds more records than there are folders on disk and points at `/refresh index --prune`.
- **Retired stale `/recall` command references** — the standalone `/recall` command folded into
  `/ticket --recall` back in v2, but several live docs still showed the old form. Updated
  `docs/ticket-index.md`, the `bin/recall.py` docstring, and `ROADMAP.md` to `/ticket --recall`
  (CHANGELOG history left intact).

#### Changed
- **Plugin-setup files get their own commit — never folded into a ticket.** `/ship` now isolates
  repo-setup / AI-layer files (`.claude/settings.json`, seeded `AGENTS.md`/`CLAUDE.md`,
  `documentation/AI_LAYER_INDEX.md`, `.gitignore`, `.claude/statusline.sh`) into a separate
  `chore(plugins):` commit on the ticket's branch, so the ticket PR stays one clean merge. The rule is
  documented in the rendered `AGENTS.md` too, so every session and teammate follows it, not just `/ship`.
- **`/refresh index` scope is explicit.** `--all` now means "cover every ticket **but skip already
  enriched + fresh** ones" (the bootstrap scope); a new `--force`/`--reenrich-all` is the rare full
  rewrite. Default stays the un-enriched/stale set. Curated summaries are never rewritten silently.
- **Setup Phase 4 labels its two checks** — `selftest.sh` = kit integrity (validates the plugin's own
  bundled example stacks); `verify_stack.sh .claude/config/stack.yaml` = *your repo's* seam
  reachability. Removes the "did it check my config or the kit's?" ambiguity.

## [3.3.0] — 2026-07-09

Makes the Obsidian graph **look right the moment you open it**. The graph layer already generated the
tickets↔objects node web, but the README-hiding filter and the tickets-vs-objects coloring were
documented as *manual* steps you had to type into Obsidian's UI — so an unconfigured vault opened as an
undifferentiated blob dominated by per-ticket READMEs. Now the renderer configures the Graph view for
you.

### Added
- **Auto-configured Obsidian Graph view (`.obsidian/graph.json`).** Alongside the node layer,
  `build_ticket_index.py` now writes `.obsidian/graph.json` with a positive filter
  (`path:"tickets/graph/" OR path:"tickets/objects/"`) so the Graph view opens on **only** the
  tickets↔objects web (READMEs, `INDEX`/`OBJECTS`, and other notes hidden), plus two color groups —
  ticket nodes lime, object nodes coral (the kclabs.ai brand palette). Zero manual setup.
- **Non-clobber write policy.** The renderer owns exactly the `search` filter and its two color groups
  (keyed by their query strings): it creates the file if missing and re-creates those pieces if you
  delete them, but preserves every other key — forces, zoom, display toggles — and any color group you
  add; a custom `search` you type is left alone. Keyed off constant query strings, so no state file.
  Deliberately **not** `--check`-gated (Obsidian rewrites the file on every zoom/pan).
- **`project.graph_config` config field** (bool, default `true`) — an independent opt-out for writing
  `.obsidian/graph.json` that keeps the node layer. Ignored when `graph_notes` is `false`.
- **`.gitignore`** now commits the shared graph config and ignores per-user `.obsidian/workspace*.json`.
- **`bin/selftest.sh` §22** covers create-if-missing, non-clobber merge (user forces + custom filter +
  custom color group preserved), empty-value fill, re-create-on-delete, the `graph_config: false`
  opt-out, and that an unparseable file is never overwritten.

## [3.2.0] — 2026-07-06

Makes a plugin install **project-scoped by default** — the *repo* commits the enablement (a plugin
can't set its own install scope), so it travels with the repo and every teammate who opens the repo is
prompted to install it (no marketplace to add or config to write), staying current across the team.

### Added
- **Project-scoped enablement is the default on plugin installs.** On a plugin install, `/setup` now
  also writes an `extraKnownMarketplaces` (ticketwright github source, `autoUpdate: true`) +
  `enabledPlugins` (`ticketwright@ticketwright`) block into the repo's committed
  `.claude/settings.json`. It's the *repo* opting in at project scope (a plugin can't set its own install scope): teammates who
  open and trust the repo are prompted to install it — that repo only — and it keeps working after the
  person who set it up moves on. `autoUpdate` re-installs
  **only on a formal release**: Claude Code refreshes when the version string changes, and the version
  only moves in a tagged release commit, so ordinary `main` commits never pull teammates onto
  un-released work. Not written on vendored (`cp -r`/pip) installs — there's no marketplace to enable
  from. README documents it as the recommended team install; `scaffold.md` + the `settings.json.tmpl`
  `_README` carry the rationale.
- **`bin/selftest.sh` §21** asserts the enablement block is documented, is valid JSON, targets the
  real marketplace repo, and is release-gated (`autoUpdate`).

## [3.1.0] — 2026-07-06

Hardening release from two real end-to-end runs (a `/setup` session and a full analysis ticket). Fixes
the plugin/pip install path bugs those runs surfaced, de-hardcodes the shipped adapters for a clean
first run on any stack, adds a SQL-portability guardrail, and flips the deliverable-CSV default to
commit-by-default with a PII opt-out. Also adds an **Obsidian graph layer** for browsing the ticket
archive as a knowledge graph.

### Fixed
- **Kit-root vs project-root resolution** (the class behind a `/ship` crash on plugin/pip installs).
  `bin/enrich_ticket.py` resolved its sibling scripts off the project dir (`repo_root() / "bin"`),
  which doesn't exist when the kit and project diverge — now resolved from the script's own kit dir.
  The two SessionStart/PostToolUse index hooks imported the renderer from the project's `bin/` (silent
  fail-open on a plugin install) — now from `${CLAUDE_PLUGIN_ROOT}` / the hook's own kit dir.
  `bin/verify_stack.sh` resolved adapters off the stack.yaml location (the project) — now off the kit
  (`${CLAUDE_PLUGIN_ROOT}`, else the script's dir), with a project fallback for repo-vendored adapters.
- **Self-maintaining index went stale on ticket creation.** `/ticket` scaffolds via Bash, which the
  `Write|Edit` PostToolUse hook never sees, so a new ticket didn't appear in `INDEX.md` until a manual
  run. `/ticket` now renders the index as its final scaffold step; `build_ticket_index.py` also gained
  a `git rev-parse --show-toplevel` fallback for by-hand runs without `CLAUDE_PROJECT_DIR`.

### Changed
- **Deliverable exports are committed by default.** The old `.gitignore` blanket-ignored
  `**/final_deliverables/*.csv` (+ `.tsv`/`.xlsx`/`.parquet`), so results silently never reached git or
  the PR. Now they're committed; PII/customer data opts out via a `*.private.csv` name or a `private/`
  subfolder (both gitignored). `/ship` lists the deliverable files and asks you to confirm none carry
  PII before committing. To restore the strict "docstore only" default, uncomment the four blanket
  rules in the rendered `.gitignore` (documented in-file).
- **Adapters de-hardcoded for a clean first run on any stack.** MCP server names now use the `{mcp}`
  token from `stack.yaml` (was `mcp__atlassian__…` / `mcp__slack__…` / `mcp__plugin_productivity_*__…`);
  the Jira and Azure DevOps `verify` no longer depend on the nullable `default_epic`; removed
  org-specific Jira issue-type / mandatory-Epic / terminal-state content; `--parent` is now conditional
  on `default_epic` being set. Added `mcp` to the asana/linear/monday adapter `requires`.
- **`/setup` is install-mode aware.** On a plugin install it omits the settings.json `hooks` block
  (`plugin.json` already wires them — duplicating double-fired), copies `statusline.sh` into the repo
  so the statusline resolves, and offers to commit the scaffold at the end (so a later ticket PR
  doesn't reference rules/adapters absent from history).
- Ticket scaffolding no longer creates `.gitkeep` placeholders in subdirs that fill during build.
- **Renamed the `commandify_everything` policy → `skillify_everything`**, completing the v2/v3
  commands→skills shift: recurring work becomes a `/productize` **skill the agent can invoke itself**,
  not a command a human must issue. Behavior is unchanged; update the key in an existing `stack.yaml`.
- Spelled out **KISS (Keep It Simple, Stupid)** and **YAGNI (You Aren't Gonna Need It)** in the
  always-loaded rules so a human reviewer knows exactly what they mean.

### Added
- **Obsidian graph layer.** `build_ticket_index.py` now also generates `tickets/graph/<id>.md`
  (a node per ticket) and `tickets/objects/<object>.md` (a node per data object), so the repo opens as
  an Obsidian vault: object clusters show every ticket that touched a table, and cross-refs show as
  direct build-on lines. Plain markdown (no plugins/wikilinks), auto-maintained on the index hook, on
  by default (`project.graph_notes: false` to disable). README convention untouched.
- **Portable-params guardrail (CTE vs session `DECLARE`).** BigQuery/Snowflake/Synapse `dialect_notes`,
  the `/review` dialect-lint tier, and `/spec-and-build` now steer to a `WITH params AS (…) … CROSS
  JOIN params` row — a `DECLARE` script pollutes `--format csv` exports and breaks in single-statement
  JDBC/ODBC clients (DataGrip/Simba).
- **CSV deliverables use ASCII punctuation only.** Em/en dashes, smart quotes, and ellipsis characters
  render as mojibake in Excel and many CSV viewers, so the always-loaded rules (`AGENTS.md`) and the
  `/review` output-format check now steer cell values to plain ASCII (`-`, or "to" for ranges).
- **Scaffolds a one-line `CLAUDE.md` (`@AGENTS.md`)** so Claude Code auto-loads the always-loaded
  rules (it reads `CLAUDE.md`; other agents read `AGENTS.md`). `AGENTS.md` now also points at
  `tickets/INDEX.md` / `OBJECTS.md`, putting the reuse-prior-work habit in the always-loaded tier.
- **`bin/selftest.sh` §20** (path resolution + adapter hygiene) locks each fix above; §19 updated for
  the new CSV default. Suite is at **119 checks**.

## [3.0.0] — 2026-07-04

Breaking: removed the 12 deprecated v1 alias stubs. The v2.0 release kept the old command names
(`/start-ticket`, `/qc-review`, …) working as thin routers to their v2 skills, with a documented
"removed in v3" lifecycle. That removal is this release. No engine, adapter, template, or skill
behavior changed — purely the scheduled drop of the compatibility layer.

### Removed
- **12 v1 alias stubs** (`.claude/commands/`). Use the v2 names instead:
  `start-ticket` / `prime-ticket` / `prime-domain` / `prime-warehouse` / `recall` → **`/ticket`**
  (`--recall` for standalone lookups) · `qc-review` → **`/review`** · `deliver-ticket` →
  **`/ship`** · `configure-workspace` / `onboard-teammate` → **`/setup`** (`--teammate`) ·
  `productize-workflow` → **`/productize`** · `build-ticket-index` / `build-context-pack` →
  **`/refresh`** (`index` / `context` / `all`). Full map: `docs/troubleshooting.md`.

### Changed
- `bin/selftest.sh` check 14b now asserts the 12 stubs are absent (was: asserts all present).
- `.claude/hooks/session_context.py` dropped the now-unneeded deprecated-alias filter.

## [2.0.0] — 2026-07-01

The UX release: **13 invokables → 7 skills**, one front door, ≤5-question setup, plain language on
every user-facing surface. No engine changes — `bin/`, adapters, hooks, and templates carry over;
this is a surface-area consolidation.

### Changed — the rename map (v1 → v2)
| v1 | v2 |
|---|---|
| `configure-workspace` + `onboard-teammate` | **`setup`** (one skill; `--teammate` mode; adds single seams via `/setup chat` etc.) |
| `start-ticket` + `prime-ticket` + `prime-warehouse` + `prime-domain` + `recall` | **`ticket`** (the front door — priming + recall now run automatically; `--recall` for standalone lookups; `--worktree` for isolation) |
| `qc-review` | **`review`** |
| `deliver-ticket` | **`ship`** |
| `productize-workflow` | **`productize`** |
| `build-ticket-index` + `build-context-pack` | **`refresh`** (`index` / `context` / `all` modes) |
| `spec-and-build` | unchanged |

All 12 v1 names still work as deprecated alias stubs (`.claude/commands/`); they will be removed
in v3.

### Added
- **Adopt mode** (`skills/setup/adopt.md`) — `/setup` on a repo with existing ticket history maps
  onto the observed layout instead of scaffolding, classifies custom commands as
  shadows/extends/unrelated against the plugin's skills, and writes a `MIGRATION.md` checklist.
  Existing `AGENTS.md` is never overwritten (renders to `AGENTS.ticketwright.md` for manual merge).
- **≤5-question setup** — detection first (CLIs, MCP servers, repo layout); only tracker,
  warehouse, VCS, key prefix, and assignee dir are asked. Chat/docstore, policies, word limits,
  and role ship as commented defaults in `stack.yaml`, editable later.
- **Graceful degradation** — `/ticket` continues local-only when the tracker is down; `/ship`
  skips chat/docstore artifacts when unconfigured and names the enabler instead of blocking.
- **`/ticket --worktree`** — worktree isolation as a first-class option (upstreamed from
  production usage).
- **Richer assumption categories** in `templates/ticket-README.md.tmpl` (Business Definition,
  Status/Population Filter, Data Interpretation, Scope/Time Window, Methodology, Source Selection,
  Output Format — upstreamed from production usage).
- **Docs:** `docs/architecture.md` (the AI-layer model, seams/verb contract — moved out of the
  README, which is now a 5-minute quickstart) and `docs/troubleshooting.md` (resume paths, auth
  fixes, upgrade table, the v1→v2 rename map).
- **Self-test 14b** — asserts the 7-skill surface, no stray v1 folders, and all 12 alias stubs.

### Changed (language)
- User-facing jargon retired: "PIV loop" → **plan → build → check → ship**; "seams" stays in
  contributor docs only. `session_context` hook, `AGENTS.md.tmpl`, adapters, and templates updated.
- Skill descriptions rewritten to lead with the trigger use-case; long skills split into
  SKILL.md + reference files (`ticket/priming.md`, `productize/authoring.md`,
  `refresh/index.md` + `refresh/context-pack.md`, `setup/{scaffold,teammate,adopt}.md`).

## [1.3.2] — 2026-06-30

Author-time hardening for `/productize-workflow`, surfaced by dogfooding a productized quarterly pull
in the wild. Six generalizable defect classes, all stdlib-only and tool-agnostic.

### Added
- **`bin/render_and_validate.sh`** — a render gate wrapping `render.sh` that catches the two authoring
  defects that caused a hard compile failure and a silent wrong-result run:
  - **No token inside a SQL comment.** The renderer expands tokens everywhere; a multi-line value
    (e.g. a 75-row `VALUES` list) spills past the `--` and the continuation rows become bare SQL.
    The gate **errors** on any `{{token}}` in a `--` / `/* */` comment.
  - **Quote SQL string/date literals in the template.** `SET d = {{asof}}` renders to `= 2026-06-30`,
    read as arithmetic (=1990), not a date — silent wrong results. The gate **warns** on an unquoted
    token adjacent to `=`/`<=`/… (errors under `--strict`).
  - Post-render it asserts **zero leftover tokens** and **balanced single-quotes / parens**.
- **`bin/split_and_export.sh`** — the export-phase helper multi-deliverable skills kept re-improvising:
  splits one multi-`SELECT` file (delimited by `-- Query N` markers) into N runnable files — each
  carrying the shared `USE …`/`SET …` preamble — and `--run` executes each via *your* warehouse verb;
  `--strip-only` robustly drops the multi-statement CLI preamble (through the last
  `Statement executed successfully.`, then leading blanks, or `--header` to anchor on a known row).
- **`templates/gitignore.tmpl`** — shipped by `/configure-workspace`, with the **anchored**
  `**/final_deliverables/*.csv` rule. The un-anchored `final_deliverables/*.csv` matches only a
  top-level dir and silently commits every *nested* ticket export — a PII leak. Enforces
  *exports → docstore, not git* while keeping deliverable SQL / READMEs tracked.

### Changed
- **`/productize-workflow`** documents the two SQL-template authoring rules, wires the render gate and
  the export helper into the stamped phases, and adds a runbook note: **heavy/long pulls run in the
  background, not the foreground** (they exceed the 2-minute foreground limit), with a warning when a
  phase is expected to be slow.
- **Productized-skill template** (`SKILL.md.tmpl`, `sql/step.sql.tmpl`, `sql/qc.sql.tmpl`) now models
  both rules: params described in prose (no tokens in comments), literals quoted in the template, and
  Phase 1/3 route through the two helpers. The shipped SQL templates pass their own gate under `--strict`.
- **Snowflake adapter** points the preamble-strip note at the robust `split_and_export.sh --strip-only`.
- Self-test grows to **95 checks** (§17 render gate, §18 export helpers, §19 gitignore anchoring),
  still on stock macOS **bash 3.2**.

## [1.3.1] — 2026-06-30

`pip install ticketwright`.

### Added
- **PyPI distribution** via GitHub Trusted Publishing (OIDC, no tokens) — `.github/workflows/publish.yml`
  fires on a `v*` tag, builds with `uv`, verifies tag == version, uploads via `pypa/gh-action-pypi-publish`.
- **`ticketwright` CLI** (zero runtime deps, stdlib-only): `init` scaffolds the kit into a repo (a
  versioned, upgrade-safe `cp -r` that preserves existing per-repo config), and `recall` / `index` /
  `enrich` run the bundled tools against `$PWD` standalone (no Claude Code needed).
- The kit assets are bundled into the wheel under `ticketwright/_kit/` via hatchling `force-include`,
  so the Claude Code **plugin** and `cp -r` paths (which reference `bin/` at the repo root) are unchanged.
- Setup + release flow documented in [`docs/pypi-setup.md`](docs/pypi-setup.md).

## [1.3.0] — 2026-06-28

Fold the best of the earlier `crank-tickets`/GDD experiment into Ticketwright (now the canonical line),
and make it installable as a Claude Code plugin.

### Added
- **Role-mode templates** (`templates/roles/{generalist,analyst,engineer,scientist}.md`) — `configure-workspace`
  asks the team's persona, stores `project.role`, and fills a `{{role_focus}}` block in the rendered
  `AGENTS.md` so the rules emphasize that role's deliverables + QC focus.
- **`ROADMAP.md`** — versioned plan; next up is plugin packaging + the tracker `id_mode` contract.
- **Self-test §14/§15 — scrub + structure + manifest**: generic secret/PII scan, every command/skill
  has a `description`, every adapter declares `seam` + `tool`, plugin manifest valid + symlinks resolve
  + declared hook scripts present (runs in CI). Self-test now 79 checks.
- **Plugin packaging** — Ticketwright is now an installable **Claude Code plugin**
  (`.claude-plugin/plugin.json` + `marketplace.json`): `claude plugin install ticketwright@ticketwright`
  instead of `cp -r`. Components auto-discover via top-level `commands`/`skills`/`agents` symlinks into
  `.claude/` (the loader rejects custom `.claude/` paths in the manifest); hooks are declared in the
  manifest with `${CLAUDE_PLUGIN_ROOT}`; bin/ scripts are referenced dual-mode
  (`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/…`) so the vendored `cp -r` install still works
  unchanged. Plugin commands are namespaced (`/ticketwright:recall`); per-repo config still via
  `/configure-workspace`. Validated end-to-end with `claude plugin validate` + install + `details`.

## [1.2.0] — 2026-06-27

Sharpen recall and make the index observable — informed by dogfooding against a 139-ticket archive and
a two-AI (Codex + agent panel) improvement review. Everything stays stdlib-only and tool-agnostic.

### Added
- **`recall.py --eval [--sweep]`** — read-only recall-quality diagnostic: holds out each ticket's curated
  cross-refs and reports MRR / P@1 / P@3 / recall@5 (the cross-ref signal is excluded from scoring to
  avoid label leakage). Never auto-tunes; the `4/3/5/1` weights stay hand-set. `--sweep` shows weight
  sensitivity for a human to read.
- **IDF object down-weighting** in recall scoring — a ubiquitous object (e.g. one touched by 55 tickets)
  contributes less than a rare shared one. Discount-only (floor 0.4), tuned via `--eval` to a strict
  Pareto gain (MRR .550→.571, P@1 .408→.421, P@3 .618→.671, recall@5 .462→.494). Flat `W_OBJECT` stays
  the ceiling, so the transparent-weights stance holds.
- **Advisory verdict line + `--min-score`** on recall — a scale-free "strong / clear-leader / weak /
  none" read so PLAN can decide whether to open candidates (advisory, never an auto-skip).
- **`build_ticket_index.py --recurring [--min-tickets N]`** — ranks objects touched by many tickets over
  a long date span; surfaces productize candidates (feeds the productize-workflow loop).
- **`build_ticket_index.py --stats` health metrics** — enrichment %, median summary length,
  under-enriched count (no tags+objects), one-off vs shared object counts, oldest stale ticket.
- **Scale-aware `OBJECTS.md`** — above ~150 distinct objects, single-ticket objects collapse into a
  compact appendix so the shared-object table stays scannable (full data preserved).

### Changed
- **Ingest is now the validation trust boundary** — `ingest_index_records.py` drops malformed dates,
  filters bare (dot-less) object names, and coerces tags to kebab-case (deduped, capped). Both the enrich
  path and the build-ticket-index skill funnel through it, so one guard covers both.
- Self-test grows to 71 checks (IDF ranking, `--eval` smoke, `--recurring`, ingest validators).

### Removed
- Plural-folding in the recall tokenizer (it had been prototyped) — `--eval` showed it regresses P@1/MRR,
  so it was dropped rather than shipped. (The harness earning its keep by killing a feature.)

## [1.1.0] — 2026-06-27

Make the ticket index *active*.

### Added
- **Prior-art recall** — `bin/recall.py` ranks prior tickets against a seed/query by a transparent
  lexical score (object ×4, tag ×3, cross-ref +5, keyword ×1; recency tiebreak), exposed as the
  `/recall` command and auto-wired into `/prime-ticket` + `spec-and-build` so reuse surfaces in PLAN.
  Lexical + stdlib (no embeddings); rank → read-top-K scales past the index's context limit.
- **Object reverse-index** — `tickets/OBJECTS.md` (object → tickets), with each ticket's `objects`
  from enrichment ∪ a keyword-anchored grep of its SQL. `/recall --object VW_X` for live lookup.
- **Deep QC** — `qc-review --deep` spawns an adversarial panel (one reviewer per pyramid layer) and
  verifies every finding against the deliverable before it counts, then synthesizes one verdict.

### Changed
- The `PostToolUse` hook and `--check` gate now keep `OBJECTS.md` in sync alongside `INDEX.md`.
- Self-test grows to 67 checks (recall ranking, reverse lookup + leaf match, OBJECTS.md render + gate,
  Python-import exclusion, multi-owner seed disambiguation, privacy guard).

### Security
- The ticket-index store (`tickets/index_data.json`) is **per-install private business data**, so it is
  now gitignored in the kit itself — a real store can't be committed upstream by accident. The schema is
  shipped as `tickets/index_data.example.json` (fixture ids only), and self-test §12 fails if a tracked
  store ever carries non-fixture (`ENG-`/`DEMO-`/`TEST-`/`SAMPLE-`) ticket ids.

## [1.0.0] — 2026-06-25

Initial public release.

### Added
- **AI layer**: 9 skills (configure-workspace, onboard-teammate, start-ticket,
  spec-and-build, qc-review, deliver-ticket, productize-workflow, build-context-pack,
  build-ticket-index), 3 prime commands, and a `qc-reviewer` sub-agent — the PIV loop
  (Plan → Implement → Validate) made explicit.
- **Tool-agnostic config + adapters**: one `stack.yaml` maps five seams (tracker, warehouse,
  chat, docstore, vcs) to concrete tools via 19 thin per-tool adapters; skills never name a tool.
  Trackers: Jira, Azure DevOps, Linear, Asana, Monday, GitHub Issues. Warehouses: Snowflake,
  BigQuery, Databricks, Postgres, Redshift, Synapse/Azure SQL. Three worked configs ship
  (Jira/Snowflake/Slack/Drive/GitHub, Asana/BigQuery/Teams/SharePoint/GitLab, and
  Azure DevOps/Synapse/Teams/SharePoint/Azure Repos).
- **Policy enforcement hooks** (Claude Code): `db_write_guard` (mechanical approval before
  destructive warehouse statements), `session_context` (session priming), `ticket_index_context`
  (SessionStart catalog surfacing), `regenerate_ticket_index` (PostToolUse auto-regen).
- **Self-maintaining ticket index**: `tickets/INDEX.md` — a deterministic, byte-stable renderer
  (`bin/build_ticket_index.py`, `--check` gate) over a model-authored store (`tickets/index_data.json`),
  surfaced at session start and auto-regenerated on ticket-folder changes via hooks; curated at
  ticket close (`bin/enrich_ticket.py` / the `build-ticket-index` skill).
- **Templates** (AGENTS.md, ticket README, plan, spec, productized-skill skeleton) and a kit
  **self-test** (`bin/selftest.sh`) covering config parsing, adapter verb coverage, tool-name
  isolation, frontmatter validity, token rendering, and hook unit tests.
