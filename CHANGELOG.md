# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish versioning.

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
