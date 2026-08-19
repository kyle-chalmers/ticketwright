# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish versioning.


## Unreleased

### Added
- **`/setup`'s verbs now split by scope, and teammates are auto-routed.** Modes divide by WHO the
  config is about: team modes (the default repo configuration and the new canonical
  `/setup tool <chat|docstore|warehouse>`) write the team's committed stack; person modes
  (`--teammate`, `--voice`, `viewer`) write one person's own config. The old `/setup chat` /
  `docstore` / `warehouse` spellings keep working for one release with a deprecation note;
  `/setup viewer` stays as a person-scoped re-run entry point (the `/review`-gate interview
  remains the primary path). The scope invariant is stated by purpose at the top of the skill:
  *a team mode may declare that a person exists; only that person's own flow may declare who they
  are or how their machine connects* — so team setup may write an identity-free
  `people/<id>.yaml` placeholder (`display_name:` only), never someone else's identities, voice,
  or machine config, and a placeholder honestly still resolves as `miss` until its person binds.
  Routing now runs on `whoami`: a configured repo plus an unrecognized person auto-routes into
  teammate onboarding instead of offering the team's shared config to edit; an identity conflict
  must be resolved before any team-config edit is offered; and a repo with a stack but no
  `people/` directory gets a bootstrap that seeds the roster from `project.assignee_dir`, any
  legacy voice map, and `git log` authors — confirming existing contributors rather than
  onboarding them from zero. A repo whose only Ticketwright trace is `.claude/settings.json`
  plugin enablement is treated as fresh, never adopted.
- **The `--teammate` flow is now the per-person flow — tiers 2 and 3 are written only by a
  person's own flow** (with two named carve-outs: the `/review`-gate viewer interview, and the
  identity-free placeholders team setup may seed), and it never edits committed `stack.yaml`. It opens
  with `whoami` (binding on a miss), detects the person's machine at that moment — enumerating
  ALL named profiles/connections by NAME only, since a tool's local config can hold plaintext
  secrets — and writes `.claude/config/connections.local.yaml` as a versioned document
  (`schema_version`, `mode: defaults|overrides`, `stack_fingerprint`, `person:`), so an empty,
  half-finished, deliberately-default, or stale file are four distinguishable states. Final
  verification is bound to the team's expected target via new per-adapter evidence notes ("the
  CLI responded" is not proof), and an interactive sign-in mid-verify is narrated as a normal
  first-run outcome, not an error. The tracker project-list probe now passes a pagination flag
  (the CLI errors without one). Selftest section 34 covers the routing, the invariant's honesty
  claim, and the versioned tier-3 shape end to end.
- **`bin/whoami.py` — resolve WHO is working, on any harness.** One command answers the owner
  question with a status of `resolved`, `miss`, `ambiguous` or `conflict`, never a guess:
  tier-3 `person:` first (a one-time self-declaration for shared or oddly configured machines),
  then `$TICKETWRIGHT_PERSON` (CI/headless), then the identities each person enumerates in
  `people/<id>.yaml` (both tier-2 homes, matched exactly after trim + case-fold). A miss is
  self-healing: the host agent asks who you are and runs `whoami.py --bind <id>`, which appends
  that identity to your own `people/<id>.yaml` and pins `person:` in the machine tier — next
  session resolves exactly, forever. Binding to someone *else's* file is refused unless explicitly
  confirmed naming both people; an identity that already maps to another person is never appended
  (it could only create ambiguity). A non-interactive miss resolves to NO owner — there is no
  fallback to `project.assignee_dir`. When the identity is an email and the repo's remote is on a
  public code host, `--bind` warns once and a *derived* email is never written — the gitignored
  pin alone fixes the machine, and the warning says how to bind a handle, `$USER`, or (explicitly)
  the email itself. The Claude
  SessionStart banner now shows the result — "Working as … — new analyses go in tickets/<id>/" —
  so a wrong resolution is caught immediately.

- **Three-tier config.** `.claude/config/stack.yaml` (team, committed) is now merged with
  `people/<id>.yaml` (person, portable, committed) and `.claude/config/connections.local.yaml`
  (person + machine, gitignored) by a new resolver, `bin/effective_config.py`. It is a public CLI —
  `--json`, `--key`, `--verify-plan`, `--viewer-plan`, `--lint` — and needs no agent-specific
  environment variable, so it works under any harness. Per-key `provenance` names the tier each
  value came from.
- **`user_keys:` adapter frontmatter** declares which of a tool's keys a person may override from
  the machine tier. Adapters, not skills, own that decision.
- **`bin/_yamlite.py`**, a stdlib YAML reader for an explicit supported subset that fails loudly
  with a `file:line` instead of misreading. The kit's zero-runtime-dependency promise is intact.

- **Owner is part of ticket identity, named by one locator.** `owner/id` (e.g. `alice/ENG-12`) is
  the CLI and display form everywhere — `enrich_ticket.py`, `recall.py --for`, and the `/ticket`,
  `/ship`, `/review`, `/spec-and-build` skills — with a bare `id` allowed while exactly one owner
  has it. A bare id two owners share is a **hard stop naming both**, never a guess: `recall.py`
  already refused to pick, and `enrich_ticket.py` now exits 3 instead of enriching every matching
  owner's folder. The locator never becomes a filename or a git ref: graph nodes flatten it
  (`tickets/graph/<owner>.<id>.md`) and **branch names stay bare `<id>`** — a taken name is
  disambiguated at creation as `<owner>-<id>`, and said aloud.
- **The skills resolve WHO before rendering any ticket path.** Every ticket-opening and shipping
  workflow now runs `bin/whoami.py` first, shows its one-line "Working as …" display, and files
  new work under the resolved person. `project.assignee_dir` survives only as the documented last
  resort when no people map exists; a `miss` with a people map runs the one-question `--bind`
  interview instead.

### Changed
- **Graph nodes and object backlinks key by (owner, id).** Two owners with the same slug used to
  collapse into one merged graph node with pooled objects and backlinks; each now gets its own node,
  and object notes / `OBJECTS.md` label a shared id as `owner/id`. Bare `[[wiki-links]]` keep
  resolving — current owner first, then across owners; a two-owner match renders as text with a
  stderr error naming both. Qualified `[[owner/id]]` wiki-links are honored exactly, in both id
  modes. Old bare-id node files are removed by the normal orphan cleanup on the next render.
- **`bin/resolve_user.py` is now a thin shim over `whoami.py`** that maps the resolved person to a
  voice-profile id (kept while `/ship` calls it; scheduled for removal in a later release). Two
  behavioral refinements ride along: the legacy `project.voice_profiles` fallback is now per
  person — one teammate migrating to a tier-2 `voice:` block no longer switches the legacy map off
  for everyone else — and an identity enumerated by two people resolves to *nothing* rather than
  silently picking whichever file was read last. The two tier-2 homes now merge key by key (the
  in-repo `identities:` list replaces the cross-repo one when both are set), matching
  `effective_config.py`.
- **`bin/effective_config.py` asks `whoami.py` who the person is**, which also aligns the
  resolution order: a tier-3 `person:` pin now beats `$TICKETWRIGHT_PERSON`, and a person
  *without* a voice block now resolves for tier-2 selection.
- **`bin/verify_stack.sh` and `bin/handoff.sh` no longer require `yq`.** `verify_stack.sh` used to
  exit 1 without it.
- **`/setup` writes tier-1 values only.** A detected machine-local value — a named profile or
  connection, a home-directory mount path — no longer lands in committed team config.
- **Docstore paths split**: team-owned `drive_folder` (tier 1) + per-machine `mount_root` (tier 3),
  composed into `{base_path}` by the resolver. Adapter verb bodies are unchanged, and a literal
  `base_path:` still works (with a warning).
- **Viewer config splits** into a portable half (globs → categories, in `people/<id>.yaml`) and a
  machine half (categories → applications, in `connections.local.yaml`). An existing
  `viewer.local.yaml` still wins, so nothing changes for anyone who has one.
- **The comms-voice identity map moves to `people/<id>.yaml`.** The legacy
  `project.voice_profiles` block in `stack.yaml` is still read, with a one-time warning — upgrading
  never silently loses voice resolution.

### Fixed
- An absent tool slot no longer renders broken markdown in the scaffolded `AGENTS.md`. The stack
  table used to compose adapter paths around the tool name (`adapters/chat/<tool>.md`), so a repo
  with no chat tool rendered a broken path; the template language is a flat substitution pass, so
  no conditional could fix it there. Every adapter cell now takes a whole-path token
  (`{{tracker_adapter}}`, `{{chat_adapter}}`, `{{docstore_adapter}}`, `{{vcs_adapter}}` — the
  existing `{{warehouse_adapter}}` precedent): a configured slot passes the adapter path, an
  absent one passes a note naming the enabling command (`/setup tool chat`). These absent-slot
  values are render-time display values only, never written to `stack.yaml`.
  `.claude/skills/setup/scaffold.md` now spells out both cases; selftest section 36 pins them.
- `/setup` no longer promises to "warn if a chosen adapter is `status: stub`" — no adapter carries
  a `status:` key and the frontmatter contract never listed one, so the warning could never fire.
  The first real stub adapter should introduce the mechanism along with itself.
- `/setup --voice` and the README suggested gitignoring `voices/<id>.md` to keep a profile
  private — which does nothing once git already tracks the file. Both now say to point
  `voice.path` outside the repo, or gitignore the path *before* its first commit.
- The productized-skill template still gated its voice pass on `project.voice_profiles` being set —
  a condition that is permanently false in a migrated repo. It now gates on the resolution.
- `bin/verify_stack.sh` silently accepted a `targets:` block with a missing or invalid `default:`.
  A shell field-splitting bug (TAB is IFS whitespace, so runs of empty fields collapsed) shifted the
  error message out of the variable that reported it, and a hard failure read as a pass.
- A tokenized `verify:` with no value configured used to run with the literal `{token}` still in the
  command. It is now skipped with a pointer to the key to set.

### Security
- A person or machine config file can never contribute a `policies:` block. Tier 3 is gitignored and
  unreviewed; being able to set `db_write_requires_approval: off` there would disable the kit's
  safety gates with nothing in code review to catch it. Such a block is **rejected**, not ignored.
- Tier 3 can never change which catalog, schema, database or target is read.

## [Unreleased]

### Fixed
- **`verify_stack.sh` now actually checks adapter-required keys.** `/setup` has always told you an
  unfilled key could be left as a `# TODO` because "`verify` will point at it" — but nothing read
  the adapter's `requires:` frontmatter. Only the seam's `verify` command ran, so a key was caught
  only if that command happened to name it. Three ways this went wrong: Jira `requires: [site, cli]`
  but verifies with `{key_prefix}`, so an unset `site` reported **✓ reachable**; an MCP seam with
  `verify: null` checked nothing at all; and an unset key that *was* referenced interpolated to a
  literal `{base_path}`, failing with a message about a missing directory rather than a missing
  setting. `verify_stack.sh` now reads `requires:` and names each unset key. It **warns rather than
  fails** — an unfilled key is a setup-time TODO, not an unreachable tool, and failing would reject
  configs written before this check existed. All six shipped example configs verify clean.

### Added
- **Seventh `tracker` verb — `rank_projects_by_activity`.** Setup could adopt a tracker project
  because its *name* matched the repo, with no signal about whether anyone still works there. The
  tracker contract can now rank an account's containers (Jira project / Azure Boards project /
  GitHub repo / Linear team / Asana project / monday board) by items updated in a lookback window,
  returning `{id, name, activity, last_activity, signal}`. It is a **bootstrap** verb: it needs auth
  plus an account-level `scope` only, never the per-project keys the choice is about to fill, and it
  runs outside the seam preflight. Read-only, and it produces a default a human confirms — never an
  automatic selection. All seven tracker adapters implement it; `local` returns `unsupported`
  (nothing to rank) and adapters blocked by auth, scope, or plan tier return `unavailable` + a
  reason, which the caller surfaces rather than swallowing. Which config key a chosen container
  fills is declared per-adapter in new `container_key:` frontmatter, following the `dev_key:`
  precedent — it is not universal (Jira fills `project.key_prefix`, Azure Boards
  `seams.tracker.project`). No skill calls it yet.
- **Per-person comms voice profiles** — opt-in `project.voice_profiles` in `stack.yaml`. When set,
  `/ship` resolves the shipper (`bin/resolve_user.py`, offline, explicit identity→id map) and phrases
  the tracker comment / chat / PR draft to match their `voices/<id>.md` — *within* the hard comms
  rails (word limits, hyperlinking, business-first segmentation, the include-list), which a
  comms-lint step `/ship` runs *before* the voice pass so style can never breach them. Build/refine
  a profile with `/setup --voice`. Fail-open: unset field / map miss / missing profile ⇒ drafting is
  unchanged. Profiles are personal data, committed by default (gitignore to keep private).
- **Gated voice refinement** — `/ship` persists the initial vs approved comms drafts under a
  gitignored `comms/` and, in Phase C, *proposes* profile updates from the diff (you approve each;
  never silent). Kept separate from the `system_evolution` retro.
- **`seams.chat.include_self`** — optional self-mention token resolved via `bin/resolve_user.py`,
  *in addition to* the fixed `always_include` stakeholder list (never overloads it).
- **No-warehouse worked example** — `stack.example.no-warehouse.yaml`: a team whose deliverables are
  documents, models, or reports simply omits the `warehouse` seam. Selftest asserts the seam is
  genuinely absent and runs the config through the full example matrix (now 6 worked stacks).
- **`project.role` and `project.domain` documented** — both now appear in `stack.schema.md` and the
  example config; `project.domain` fills the rendered `AGENTS.md`'s `{{domain}}` token ("Ticket-driven
  *data analysis* work" by default — set any phrase that names your team's work).

### Changed
- **The no-warehouse path is explicit in the skills.** `/ship` re-verifies non-query deliverables by
  their own checks; `/review` documents the claims-vs-evidence walk (layer ⑤) for repos with nothing
  to re-run; `/refresh context` builds the glossary/domain-notes pack when there is no warehouse to
  introspect. Rendered `AGENTS.md` and ticket-README templates note which sections drop out without
  a warehouse seam. Data-first framing is unchanged — the warehouse seam is simply optional in
  practice, not just in the schema.
- **Fixture vocabulary tightened.** Fixtures standardize further on the invented orders/inventory
  domain (example slugs, owner names, engine docstrings); selftest 13b's vocabulary guard covers more
  industries and vendor product names, and §20 E6 now checks ticket-key prefixes structurally.

### Fixed
- **The Quickstart now actually installs at project scope.** `claude plugin marketplace add` and
  `claude plugin install` both default to `--scope user`, so the documented commands — which passed no
  `--scope` — installed Ticketwright into the reader's own `~/.claude/settings.json`, one section above a
  heading promising "project-scoped by default". Nothing landed in the repo and teammates got nothing.
  Both Quickstart commands now pass `--scope project`, which writes the repo's `.claude/settings.json`
  directly; `/setup` no longer has to be the only route to project scope.
- **Marketplace source discriminator now matches what the CLI writes.** The committed block was
  documented as `{"source": "url", "url": "https://…ticketwright.git"}` in `README.md`,
  `setup/scaffold.md` and `.claude/settings.json.tmpl`. `git` and `url` are *different* marketplace
  source types, and `git` is what `claude plugin marketplace add` emits for an `https://…git` URL —
  confirmed by running it at both user and project scope. The HTTPS-over-SSH intent recorded under 3.4.1
  is unchanged; only the discriminator moves, so the documented `source` object is now copied from the
  CLI's output instead of hand-authored.
- **`/setup` merges the enablement instead of overwriting it.** Now that the documented install already
  writes `extraKnownMarketplaces` + `enabledPlugins`, `setup/scaffold.md` spells out the merge rules:
  never replace either map wholesale, keep an existing `ticketwright` source verbatim (a fork edits that
  URL), add `autoUpdate: true` only when absent, leave a deliberate `false` alone, and create/repair the
  keys when they're missing or malformed. Neither install command writes `autoUpdate` (no flag sets it),
  so adding that key is what `/setup` still contributes.
- **`bin/selftest.sh` §21b no longer certifies the bug it was meant to catch.** It asserted the wrong
  `"source": "url"` value, so the docs were locked to it, and its only README check was a grep for the
  word `project-scoped` — which a contradicting Quickstart passed. It now asserts both Quickstart command
  lines carry `--scope project`, parses README's enablement block (located by fence label — the first
  fence in the Quickstart is `bash`) and compares it to `scaffold.md`'s, and pins the canonical source
  value literally rather than only requiring the two files to agree.

## [3.5.0] — 2026-08-12

Two features land together. **Human review handoff** — a gate that opens a ticket's deliverables in
your own applications and waits for sign-off; the first pause in this kit that guards *seeing* the
work rather than a side effect leaving the machine. And **skills now resolve a warehouse target**,
so the multi-target seam released in 3.4.0 is usable end to end — plus a repo with **no ticketing
system at all** can use the kit. Tool-agnostic and stdlib-only.

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
  `-\d+` anywhere in an id, so a folder called `signup-funnel-lift-2024` ranked as ticket 2024 among real
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
  the Jira and Azure DevOps `verify` no longer depend on the nullable `default_epic`; adapters make
  no assumptions about custom issue types, required epics, or terminal states — those come from
  `stack.yaml`; `--parent` is now conditional on `default_epic` being set. Added `mcp` to the asana/linear/monday adapter `requires`.
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

Author-time hardening for `/productize-workflow`, surfaced by exercising a productized recurring pull
end-to-end. Six generalizable defect classes, all stdlib-only and tool-agnostic.

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

Fold the best ideas from earlier prototypes into Ticketwright (now the canonical line),
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

Sharpen recall and make the index observable — informed by benchmarking recall on a large ticket
corpus and a two-AI (Codex + agent panel) improvement review. Everything stays stdlib-only and tool-agnostic.

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
