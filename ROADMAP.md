# Ticketwright Roadmap

> What's next for the kit. Subject to change; issues and PRs welcome. The principle that gates every
> item: stay **lightweight** (stdlib-only Python, bash-3.2-safe, no embeddings / vector DB / servers)
> and **tool-agnostic** (skills never name a tool; seams swap via one adapter file).

## Where we are — v1.2 (June 2026)

The ticket index is **active**, not just browsable, and observable.

- **Prior-art recall** (`/ticket --recall`, engine `bin/recall.py`) with **IDF object down-weighting** (eval-tuned),
  an advisory verdict line, and a read-only **`--eval`** recall-quality diagnostic.
- **Object reverse-index** (`tickets/OBJECTS.md`), scale-aware above ~150 objects.
- **Deep QC** (`review --deep`) — adversarial reviewer panel.
- **Index observability** — `--recurring` (productize candidates) and `--stats` health metrics.
- **Ingest validation** trust boundary; **privacy guard** (the per-install store can't be committed).
- 32 adapters across 7 seams; 7 worked stacks; **300+-check self-test**; GitHub Actions CI.
  (Six of those directories are tool seams with verb contracts; the seventh, `runtime/`, declares
  agent-harness capabilities and is deliberately not a `stack.yaml` seam. The count's wording is
  pinned by a self-test assertion — see `docs/runtimes.md`.)

Lineage: Ticketwright is the canonical evolution of earlier prototypes — the advanced *engine*
(recall, objects, deep-QC, eval, adapters, hooks) with their *distribution* ideas
(plugin packaging, role modes) folded in here.

## Shipped — v1.3 (distribution)

- **Plugin packaging** — installable as a Claude Code plugin (`.claude-plugin/plugin.json` +
  `marketplace.json`): `claude plugin install ticketwright@ticketwright`. Components auto-discover via
  top-level symlinks into `.claude/`; bin/ scripts dual-mode (`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}`)
  so the vendored `cp -r` install still works. Validated with `claude plugin validate` + install.
- **Role-mode AGENTS.md** (generalist / analyst / engineer / scientist) — `/setup`
  tailors the rendered rules to the team's persona via short role-focus snippets.
- **CI scrub + structure + manifest checks** — self-test §14/§15 (79 checks total).

## Shipped — v1.3.2 (author-time hardening)

Hardened by exercising a productized recurring pull end-to-end. All stdlib-only, tool-agnostic; none changes
the lightweight stance.

- **Render gate** (`bin/render_and_validate.sh`) for `/productize` — errors on a `{{token}}`
  inside a SQL comment (a multi-line value would break out of the `--`), warns on an unquoted SQL
  string/date literal (`= {{asof}}` reads as arithmetic), and asserts zero leftover tokens + balanced
  quotes/parens on the rendered SQL.
- **Export helper** (`bin/split_and_export.sh`) — robust multi-statement-preamble strip + split a
  multi-`SELECT` file on `-- Query N` markers into N runnable, preamble-carrying files.
- **gitignore template** — deliverables commit with the ticket by default (results show in the PR);
  PII/customer data opts out via a `*.private.csv` name or a `private/` subfolder. *(3.1.0 flipped
  this from the earlier "all exports gitignored" default.)*
- Runbook note: heavy/long pulls run in the background. Self-test now **109 checks** (§17–§20).

## Shipped — v1.4 (more than one warehouse; no tracker at all)

Two limits in the seam abstraction, both surfaced by the same question: what if my setup isn't
one-Jira-one-Snowflake?

- **Multi-target warehouse seam** — `seams.warehouse` is now *either* a single mapping or
  `default:` + a `targets:` map. Targets inherit seam-level scalars (including `tool`/`adapter`/
  `verify`) so two targets on one account share nearly everything; `verify_stack.sh` checks each and
  fails closed on a missing or dangling `default:`. Skills resolve the active target per
  `adapters/README.md` § Multi-target seams, and a `.sql` names its own target in a
  `-- warehouse-target:` header. Existing single-warehouse configs are byte-identical.
- **Trackerless work** — `project.id_mode: slug` makes a folder name the ticket id, and
  `adapters/tracker/local.md` implements the tracker verbs against the ticket folder itself, so
  `/ticket` and `/ship` run unchanged with no ticketing system. Cross-references in slug mode are
  `[[wiki-links]]` only, because a folder name can be an ordinary phrase.
- **`dev_target`** is the canonical dev-environment key, with each warehouse adapter declaring its
  legacy spelling in `dev_key:` frontmatter.
- **Two bugfixes surfaced by review**, both latent before this work: `db_write_guard` could harvest
  another seam's CLI and raise a spurious approval prompt on an ordinary tracker command, and
  `spec-and-build` named a Snowflake-only config key inside a deliberately tool-neutral skill.
- **Wrong-warehouse guard** — the hook prompts when the invoked CLI doesn't match the SQL's declared
  target, including for reads. `/review` is the authoritative half (no YAML parsing, and it works
  under agents where hooks don't run); the hook is the earlier, best-effort one.
- Two worked configs added: `stack.example.multi-warehouse.yaml`, `stack.example.solo.yaml`.

Deferred out of this work, deliberately:

- **Multi-target for the other four seams.** `verify_stack.sh` handles the shape generically, but no
  skill resolves targets for tracker/chat/docstore/vcs and nothing tests it — so the mechanism is
  documented and only `warehouse` is promised.
- **Target-qualified object index.** `OBJECTS.md` folds object names case-insensitively and is
  warehouse-blind, so the same name on two targets collapses to one node. Often that is the useful
  reading; qualifying it bumps `index_data.json`'s schema across four call sites for a rare collision.
- **Per-target policy overrides** (e.g. write-approval on prod but not a sandbox) — this needs a
  policy-scoping vocabulary the kit doesn't have, and relaxing a *safety* policy deserves its own design.

## Field report — deferred (from adopt sessions)

Surfaced by early install sessions (2026-07-06); the highest-value, lowest-risk fixes landed in the
[core bundle](CHANGELOG.md) (HTTPS marketplace source, multi-location README locator, orphan
`--prune`, verify labeling, `--all`/`--force`). These remain — each issue-ready and named by the
artifact it touches:

- **Per-user chat identity** — *(resolver + token landed with voice profiles)* `bin/resolve_user.py`
  resolves the shipper offline (`git config user.email` → `user.name` → `$USER`, via an explicit
  `stack.yaml` map), and `seams.chat.include_self` adds the shipper's mention *alongside* the fixed
  `always_include` stakeholder list rather than overloading it. Remaining polish: per-tool mention
  resolution and a `/setup` prompt to seed `include_self`. *(adapters/chat/{slack,teams}.md +
  stack.schema.md)*
- **`/ship` handles an existing/draft PR** — the `open_pr` verb assumes `gh pr create`; it should
  `gh pr list --head` first and edit + `gh pr ready` when a PR (especially a draft) already exists.
  *(adapters/vcs/{github,gitlab,azure-repos}.md)*
- **Announce the graph layer on adopt** — a first render over a large backlog can add hundreds of
  `tickets/graph/` + `tickets/objects/` files that regenerate on every ticket change. Announce the
  file count (and offer an opt-out) during adopt / `refresh index`. *(setup/adopt.md, refresh/index.md)*
- **Config-driven co-author trailer** — the `Co-Authored-By` line is hardcoded (with a model name that
  ages) in three vcs adapters; make it a `project`/vcs-seam field so every skill emits the same, correct
  trailer. *(adapters/vcs/*.md, stack.schema.md)*
- **Detect `terminal_status`** — adopt defaults it to `Done`; offer to detect the real terminal state
  from the tracker workflow or the most-common status among already-shipped folders. *(setup/adopt.md)*
- **Full count reconciliation** — beyond the `--prune` pointer, make the SessionStart hook and `--stats`
  agree on one basis when store and disk diverge. *(hooks/ticket_index_context.py)*
- **Nits** — `verify: null` prints `⚠`; use a distinct glyph for "MCP-only, not shell-verifiable." An
  adopted repo's `resources/*.py` vs the plugin's `bin/` doc-references should reconcile.
  *(verify_stack.sh, MIGRATION template)*
- **Out of scope here (sibling `git-ship` skill, not this repo)** — squash-merge branch cleanup edges
  (`git branch -D` after a squash; stash/restore an unrelated dirty tree before `checkout main`), and
  its stale co-author trailer.
- **Upstream caveat to verify** — GitHub-repo marketplaces reportedly don't always `autoUpdate`
  (anthropics/claude-code#44276); confirm the "self-updates on release" promise holds, else document the
  manual `/plugin marketplace update`.

## Next — v1.4+ (harden the tracker contract)

Surfaced by a two-AI (Codex + agent-panel) review as the top *coverage* gaps — the abstraction is
solid for keyed trackers (Jira/Linear) and good-with-caveats for integer/label ones:

- **Tracker `id_mode` contract** — `slug` **shipped** (a folder name can be the id, for repos with no
  tracker); `keyed | integer | gid` + a normalizer still open, so integer trackers (Azure
  Boards, GitHub Issues) stop being a silent abstraction leak (bare number for the CLI, `KEY-123` for
  branches/folders/index). *The single highest-value contract fix.*
- **Semantic adapter lint** — verify each adapter's token references resolve and required frontmatter is
  present (today the self-test checks verb *shape*, not correctness).
- **Executable `download_attachments`** — ship a real per-adapter snippet or a declared manual fallback
  (today several are prose "curl each URL"; the Jira helper is described but not shipped).
- **First-class `transition` state resolution** — a command to enumerate a tracker's workflow states
  instead of "resolve the done state from the project."

## New trackers (each ≈ one adapter file)

YouTrack / Plane (key-prefix → copy Linear/Jira) · Shortcut (integer → copy GitHub Issues) ·
ClickUp / Height (label-status → copy Monday) · Trello (list-as-status → copy Asana).

## Ecosystem hardening — deferred (from the 2026-07 family-wide pass)

Identified while cross-pollinating lessons across the plugin family (jobwright, streamsnow,
ai-data-security); apply here first since ticketwright is the design ancestor:

- **Skill trigger evals.** None of the family tests that skills actually *trigger* on the
  phrases their descriptions promise. The official skill-creator plugin ships an eval harness
  (isolated runs, should/should-not-trigger hit rates, description tuning); a headless
  `claude -p` activation harness is the community pattern. Descriptions across all four
  plugins total ~6.6k chars (audited 2026-07-15) — inside the ~15k skill-list budget, but the
  budget is shared with everything else a user installs, so keep descriptions keyword-dense.
- **Community marketplace submission** (`claude-plugins-community`): the biggest
  trust+discovery lever — auto-registered distribution plus Anthropic's security scanning.
  Pre-checks: version files in lockstep (already enforced), no file access outside the plugin
  dir, hooks documented (README "Hooks, in full" section shipped 2026-07-15).
- **Multi-harness install docs** (Cursor/Codex/Copilot CLI) — what the widest-adopted skill
  packs do; the Agent Skills spec makes skills increasingly portable. Half the mechanism exists:
  `ticketwright init` vendors the kit's files into any repo, harness-agnostic. The gap is
  **setup** — `/setup` is what renders `stack.yaml` and `AGENTS.md`, and it only runs in Claude
  Code, so a Cursor/Codex user today gets the files and no rendered config. Closing this needs a
  harness-agnostic setup path (a `ticketwright setup` that asks the questions `/setup` asks), not
  just docs.
- **Distribution scope — settled 2026-08-04.** Both channels stay, with distinct jobs: the
  **plugin is the product** (skills, hooks, project-scoped enablement, updates); **PyPI is the
  standalone/vendoring installer** for the multi-harness and CI cases above — explicitly *not*
  a second full UX. Deleting PyPI was considered and rejected: it would drop the only
  non-Claude-Code install path while leaving the kit-root/project-root branching in place
  (that branching serves *vendoring*, which predates pip), and the wheel force-includes the
  same kit rather than maintaining a parallel implementation. What made the channel a liability
  was drift, not cost — PyPI sat on 3.2.0 while the repo ran 3.3.0, so pip users were served
  month-old skill prose. Fixed structurally: `bin/bump_version.sh` moves all three version files
  at once, and CI now builds + installs the wheel on every PR and every push to `main`, instead
  of only at tag time.
- **autoUpdate hook caveat** to carry in every release note: bundled hook changes do not reach
  installed copies via autoUpdate (claude-code #52218) — reinstall + relaunch.

## Deliberately out of scope

Embeddings / vector retrieval (lexical rank→read-top-K scales to ~500 tickets), weight auto-tuning
(`--eval` showed the hand-set `4/3/5/1` weights are robust — a tuner would overfit and erode
transparency), and a standalone knowledge-base/orchestration service.

**Joining data across warehouses.** Routing a query to the right target is the kit's job; being a
query engine is not. Moving rows between warehouses is a write subject to
`db_write_requires_approval`, the extract side is a governance call the kit has no vocabulary for
(`pii_role` is per-target), and a hand-rolled bridge breaks `deterministic_outputs`. A team that
needs it already has federation configured in the warehouse, where the federated objects are
reachable from one target. Supported shape: two single-target queries → two exports → an explicit
local combine step whose reconciliation is a validation gate.
