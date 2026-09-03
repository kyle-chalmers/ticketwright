# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish versioning.


## [Unreleased]

### Added
- **A prompt you can paste, for each track.** The person who most needs Ticketwright installed has
  no plugin yet, so no `/setup` and no skill to ask — and every onboarding session so far opened
  with someone improvising the words. Track 1 and Track 2 now each lead with a short prompt in a
  copyable block: hand it to an agent and it does the track. They stay short on purpose. The doctor
  already prints each fix at the moment it applies, so a prompt that restated them would be a
  second copy to drift; what they carry instead is the part no tool enforces — "this repo only, not
  globally", and, for Track 1, that the `setup` interview belongs to the person rather than to an
  agent guessing the stack from whatever is installed. The joiner prompt also ships in
  `templates/AGENTS.md.tmpl`, so it lands in every configured repo, and selftest pins the two copies
  byte-identical.

## [4.0.2] — 2026-09-03

### Added
- **`bin/plugin_doctor.py` — every install state gets a name and a fix.** Onboarding onto a repo that
  already carries the committed enablement failed in ways nothing in the kit could describe: a CLI too
  old to accept `--scope` (Claude Code 2.0.x has neither `--scope` nor `plugin list`), a marketplace
  registered with nothing installed, a global install nobody meant, an install record whose
  `installPath` was never created (the install reports success, re-running it is a no-op), and a
  "Download ZIP" folder with no `.git`. The doctor checks all of that in one command — plus `yq`, git
  identity, the update channel to update through, and whether the installed version is behind the
  marketplace catalog — and prints the fix for each, human-readable or `--json`. It runs from the
  marketplace clone before anything is installed
  (`python3 ~/.claude/plugins/marketplaces/ticketwright/bin/plugin_doctor.py`, a fork substitutes its
  own marketplace name) and through `bin/tw` afterwards. Stdlib only, no network, no writes; it never
  runs an install, and it reuses `update_notice.py` so its upgrade fix is the same string the session
  banner prints. `/setup` runs it at preflight and halts on the states nothing setup writes can fix.
- **Install prerequisites an agent can read before the plugin loads.** README Track 2 and
  `templates/AGENTS.md.tmpl` carry the same fourteen checks in the same order as the doctor, each
  tagged with a `doctor-check` marker; selftest pins the set and order against the doctor's own check
  list, so the three surfaces cannot drift.

### Fixed
- **The joiner install no longer lands at user scope.** README Track 2, `docs/troubleshooting.md` and
  the rendered `AGENTS.md` all gave the bare `claude plugin install ticketwright@ticketwright`, which
  defaults to `--scope user` — installing Ticketwright for every repo on the machine while the repo
  itself got nothing. All three now give the `--scope project` pair, run from the repository root
  (a project-scope install keys to the session's directory, claude-code#82830), with the in-app
  `/plugin install` → Project-scope route as the fallback for a CLI too old for the flag.
- **The "teammates are prompted to install" claim is gone.** It was in the README, `setup/scaffold.md`,
  `.claude/settings.json.tmpl` and `templates/AGENTS.md.tmpl`, and it is not what happens: registering
  the marketplace is not installing the plugin, and the documented behavior (Claude Code 2.1.195 and
  later report the plugin as not installed and show the install command; older builds say nothing) is
  now what those four files say.
- **"Restart" says what it means.** Every restart instruction now names `/reload-plugins` or a new
  session first, then a full quit of the Claude app (Cmd+Q, or File → Exit) if the skills are still
  absent — a new chat inside the running app is not a restart.
- **`bin/update_notice.py` recognises a `local` install row** (the desktop app writes one) and emits
  the uninstall/reinstall pair at the scope the record actually carries, instead of assuming
  `--scope project`.
- **An unbound teammate no longer writes into someone else's folder.** A `people/<id>.yaml` placeholder
  with no identities resolved to the project's `assignee_dir`, so a first ticket opened before
  `/setup --teammate` landed under another person's directory. The ticket front door now halts and
  names the fix.

### Changed
- **`/setup` preflight order:** git repo → the doctor's findings → `yq` (with the platform install
  command offered before the self-test needs it) → identity. A ZIP folder or a broken install is
  reported before setup writes anything, since nothing setup writes would repair it.

### Docs
- `docs/troubleshooting.md`: cause 2 is now "Your Claude Code CLI is too old" with per-channel update
  commands; a new cause covers an install record with no payload, including the safety conditions on
  the copy-the-clone recovery; the upgrade table gains a `local`-scope row; a new block names the three
  ways to run the doctor.

## [4.0.1] — 2026-09-02

### Fixed
- **The kit-integrity selftest passes on a plugin install.** Section 31 ran `bin/tw` from inside the
  kit's own tree and expected the kit root — right only when the kit is a git repo, so on a plugin
  install (a cache, not a repo) two assertions failed for a reason no user ever meets. The test now
  builds a git project and runs from a ticket subdirectory, which is the real scenario; `bin/tw`
  itself was already correct there.
- **A verify can no longer hang setup.** `verify_stack.sh` runs each slot's verify under a wall-clock
  cap (`VERIFY_TIMEOUT`, default 30s) and reports a timeout as "appears to need interactive auth"
  — a browser-SSO warehouse connection used to block the whole check with no output.

### Docs
- `/setup`: fall back to the current local branch when `refs/remotes/origin/HEAD` is unset (an
  unpushed repo); expect `selftest.sh` to take several minutes and judge it by exit code; on a
  remote created empty, the scaffold's first push seeds `main` and the PR flow starts with the next
  change; a slot's `mcp:` value must be the runtime's exact tool prefix (`mcp__<name>__*`).

## [4.0.0] — 2026-09-02

Breaking: `/productize` is now `/skillify`, and `templates/productized-skill/` is now
`templates/generated-skill/`. There is no alias — the old name is gone, and an older install's
retired skill directory is warned about rather than deleted. Everything else in this release is
additive: `/setup` scaffolds a human-facing README, writes `stack.yaml` first and resumes a
half-configured repo cleanly, and every rebuild hint names the plugin, pip and vendored routes.

### Changed
- **`/productize` is now `/skillify`; `templates/productized-skill/` is now `templates/generated-skill/`.**
  The policy that drives the skill has always been called `skillify_everything`, so the command name
  was the odd one out — and "productize" carried a product-shipping connotation the skill never had:
  it turns a repeated workflow into a skill, it does not ship a product. The skill directory
  (`.claude/skills/skillify/`), its `name:` frontmatter, the skeleton it stamps from, and the
  adjective in prose ("productized skill" → "generated skill") all move together. **There is no
  backwards-compatible alias** — the old name is gone. Note that `templates/AGENTS.md.tmpl` was
  already rendered into existing repos naming `/productize`, and `/refresh` does not re-render
  `AGENTS.md`: an existing repo needs `/setup role` re-run, or that one line edited by hand. See
  `docs/troubleshooting.md` for the rename map.

### Added
- **`/setup` now scaffolds a human-facing `README.md`.** Setup wrote `AGENTS.md` (the agent's rules
  file) but nothing a person landing on the repo could read in a minute. It now also renders a short
  intro (under 250 words of prose) — what this is (a ticket-driven work repo) and how work moves
  through it — from the new `templates/project-README.md.tmpl`. It's tool-agnostic (only `{{repo_name}}`
  and `{{domain}}` tokens) and **never overwrites an existing README**: if one is present (fresh or
  adopt), it renders `README.ticketwright.md` for the human to merge, mirroring the `AGENTS.ticketwright.md`
  convention. Written once, then human-owned — `/setup role` does not re-render it.

### Fixed
- **`/setup` writes `stack.yaml` first and stops cleanly when the runtime refuses it.** Phase 3 used
  to compose `.claude/config/stack.yaml` and the scaffold in one sweep. On a brand-new empty repo
  under a headless run whose runtime refuses every write beneath `.claude/` (a categorical path guard
  no allow rule lifts non-interactively), setup had already written `AGENTS.md`, `CLAUDE.md`,
  `README.md`, `.gitignore`, `people/*.yaml`, the AI-layer index and the seeded ticket index before
  the refusal landed — leaving an `AGENTS.md` that describes a stack absent from disk and no source
  of truth. The order is now `stack.yaml` → `.claude/settings.json` → the derived scaffold (which
  renders FROM `stack.yaml`), and a refused `stack.yaml` write halts the whole scaffold and reports
  the refusal text, the cause, and the two ways forward (approve the prompt interactively, or
  hand-create the `.claude/` files from the printed plan); everything else is written on the next
  confirm, and a re-run that finds `stack.yaml` without `AGENTS.md` resumes the scaffold instead of
  offering an edit — that route is checked before the Bootstrap route (a hand-created recovery has no
  `people/` yet), and it first writes whatever of `.claude/` is still missing (`settings.json`, the
  round-1 machine pin) before rendering. `scaffold.md` also now says to allow a CLI's named read verbs (`jobs list`,
  `jobs get`, `current-user me`, `api get`), never the bare CLI.
- **The generated `tickets/INDEX.md` and `OBJECTS.md` headers no longer point plugin users at a script
  that isn't there.** Both headers said "Re-run `python3 bin/build_ticket_index.py`". On a plugin install
  the repo has no `bin/` (the engines live in the plugin cache and the skills resolve them), so a fresh
  plugin user following the hint got "No such file or directory". The hint now names the skill first —
  `/refresh index` (`/ticketwright:refresh index` on a plugin install) — then `ticketwright index` for pip
  installs, and the script path only for vendored repos; the `--prune`/`--check` messages and
  `docs/ticket-index.md` / `docs/troubleshooting.md` carry the same three routes. Selftest section 10 pins the new header on both files.

### Docs
- **README: headless / agent-driven setup.** A new Track 1 subsection says plainly that `/setup` under
  `claude -p` is a two-turn flow — the plan turn halts at the confirm gate by design, and the confirm
  is a second turn with `--continue` — and that a non-interactive runtime refuses every write under
  `.claude/` (a categorical sensitive-file guard no allow rule lifts), so `stack.yaml`,
  `settings.json`, `statusline.sh` and the two gitignored `*.local.yaml` records need an interactive
  approval or a person writing them from the printed plan, while everything outside `.claude/`
  scaffolds headlessly. It names `--strict-mcp-config` as the way to keep MCP out of a headless run.
- **README: install-block accuracy.** The Track 1 install note now says that on a machine that already
  knows a `ticketwright` marketplace, `marketplace add … --scope project` prints "already on disk —
  declared in project settings" — expected, not an error. The finished-file example notes that the
  `owner/repo` shorthand writes `{"source": "github", "repo": …}` where the `https://…git` form writes
  `{"source": "git", "url": …}`; both are valid, and setup's merge keeps whichever exists.


## [3.9.0] — 2026-08-31

### Changed
- **All seven skills are now model-invocable; `/setup`, `/ship`, `/productize` confirm before acting
  instead of being un-invokable.** Those three carried `disable-model-invocation: true`, so the model
  could never reach for them — a person had to remember to type the slash command every time. That
  flag is also **Claude-Code-only**: it is silently dropped on every emit runtime (codex, cursor,
  devin, …), which is the whole reason the installer bolts a "user-invocable only" warning block onto
  the emitted copies. The fix replaces the coarse, non-portable flag with a portable **in-body HARD
  HALT** that confirms before the durable/external action — an instruction the agent follows on every
  runtime, visible in the transcript, and stated plainly as a convention rather than a mechanical
  block (no runtime enforces it, unlike the flag on Claude Code). `/ship` gains a model-initiation gate
  **before Phase A** (a model-initiated run confirms before Phase A tidies deliverable files and
  refreshes the committed ticket-index entry — an explicit user invocation authorizes Phase A as
  before) and keeps its Phase B "stop and wait" gate before any **external post**.
  `/productize` gains one before it stamps a brand-new skill folder. `/setup` gains a top-level
  model-invocation gate covering **every mode** — default, `tool`, `role`, `team`, `policies`,
  `--teammate`, `--voice`, `viewer`, adoption, Bootstrap — so a model-initiated run stops for
  confirmation before writing in any of them (an explicit user invocation still authorizes that
  mode's own scoped writes). The net behavior is what "seamless" should mean: the model recognizes
  when one of these is needed and **asks for confirmation before acting**, rather than doing nothing
  until the user drives it by hand.

  The `disable-model-invocation` mechanism itself is **retained** — still honored, still emitted with
  a warning block on foreign runtimes, now unit-covered in selftest — so a future skill that must
  *never* be model-invoked at all remains supported; no skill ships gated today. Selftest sections
  37/39/41/45 flip from asserting the gate is present to asserting all seven skills are model-invocable
  and the three side-effectful ones each carry an in-body HARD HALT; the codex-cli and antigravity
  golden fixtures are regenerated without the warning block.

- **Chat delivery is configured tool-only; the destination is decided per-communication.** Setup no
  longer asks for a standing `default_channel` or a fixed `always_include` stakeholder list — who a
  result goes to, and where, varies by who the analysis is *for*. The default single-mapping chat
  shape now names only the **tool + transport**; the destination and a non-empty recipient list are
  authored in the ticket's `delivery-plan.yaml` (`chat.channel:` + `chat.recipients:`), asked at
  `/ship`. `bin/delivery_plan.py` **halts (exit 9)** for a tool-only chat seam whose plan declares
  none — it never emits an empty channel — and the `resolution_fingerprint` pins the plan-authored
  values, so a plan edited between approval and delivery refuses (preview==execution holds). The
  `targets:` multi-audience shape is unchanged, for teams that want fixed pre-declared audiences. A
  single mapping that still sets a `default_channel` keeps working (backward compatible). The
  Teams/Gmail/Outlook adapters no longer config-`require` the destination key or `always_include`
  (those moved per-ticket; `identity`, the email sending mailbox, stays a team decision).


## [3.8.1] — 2026-08-30

### Fixed
- **`bin/selftest.sh` no longer spawns a real model CLI.** Sixteen sites run `enrich_ticket.py`,
  which `subprocess.run`s a headless model command — `claude -p …` by default. Seven reached that
  spawn and six launched a real model CLI. They were inert only because they set
  `PATH=/usr/bin:/bin`, i.e. only because nobody had installed a model CLI into `/usr/bin`: an
  accident of the machine, not a property of the suite. Because `Enriching N ticket(s)` prints
  *before* the spawn, those six assertions passed whether or not the command resolved, so on a
  machine where it did resolve the suite made a real, billable, networked model call — handing it up
  to 24KB of ticket README — and still printed ✓. CI never caught it, having no model CLI installed.
  Same broken contract as the entry below ("read-only, no network, no credentials"), in the same file.

  Every `enrich_ticket.py` run now goes through `safe_enrich()`, which supplies the same hermetic
  `PATH` that `safe_verify_stack()` already used, extended with `tee` (one test uses it as a
  stand-in model command) and now documented as excluding model CLIs too. All 16 sites are routed,
  not just the six that spawned, so the property is lintable with no per-site exemptions to rot.
  There is deliberately **no** `EN_PATH` escape hatch mirroring `VS_PATH`: an inherited one would
  silently reopen exactly this hole. §53 gains five checks — no raw invocation left in the file in
  its obvious forms, no model CLI in the hermetic `PATH`, a conditional cross-check that installed
  ones do not resolve
  inside it, a behavioral tripwire that puts a logging stub for all six model CLIs early on the
  *ambient* `PATH` and proves nothing is spawned, and an assertion that every shipped runtime
  `model_cmd` names a bare command, since an absolute path would satisfy the basename allowlist and
  defeat the `PATH`. Two limits are stated rather than implied: absolute-path commands escape, and
  the text lint cannot survive indirection — the tripwire is the guard that can. Fixing this also
  exposed a test that was passing vacuously: §31's built-in-fallback check asserted only
  `Enriching 1 ticket`, which every resolution path prints, so it now pins `[built-in default]` and
  `claude -p`. Verified by sabotage: strip the hermetic `PATH` from the helper with stubs installed
  and six sites spawn `claude` while *every pre-existing assertion still passes* — only the new
  tripwire fails. 1190 checks pass under bash 5.3 and 3.2.57 (1185 before).

- **`bin/selftest.sh` no longer runs a seam's real `verify:` command.** §32's shell-metacharacter
  test called `verify_stack.sh` *without* `--dry-run` against a copy of the shipped
  multi-warehouse example. The injection refusal it asserts is per-seam, so refusing the poisoned
  `{profile}` stopped nothing else: the run went on to `eval` `snow connection test` — which blocks
  indefinitely behind a Duo MFA push — plus `acli jira workitem search` and `gh auth status`, on the
  machine of anyone with those CLIs installed. No assertion looked at their output, so the suite
  stayed green while doing it, and CI never caught it because the runners have no warehouse CLI.
  This broke the suite's own documented contract ("read-only, no network, no credentials").

  A real `verify_stack` run now goes through `safe_verify_stack()`, which supplies a hermetic `PATH`
  built from an explicit allowlist of utilities — generalized from the sandbox that §50's rclone
  tests already used. It shadows tool CLIs by *name*, so fixture `verify:` commands still `eval`
  (deliberately — they name `true`, `touch`, and an offline stub), and an absolute path or a
  `PATH`-resetting `verify:` would still escape; the guarantee is that a bare `snow`/`acli`/`gh`
  cannot resolve. §32 gets its own fixture with inert `verify:` commands and stays non-dry-run on
  purpose, because `--dry-run` never reaches `eval` and would make its command-injection tripwire
  pass vacuously; a trailing seam now writes a marker to prove `eval` was live in that same run.
  New §53 asserts the property directly: no raw non-dry-run invocation in the file — matching a
  `bash` prefix, an `sh` prefix, and the executable in bare command position, since `verify_stack.sh`
  is `+x` and that last shape needs no interpreter at all — no tool CLI in
  the hermetic `PATH`, the rclone sandbox is that `PATH` plus exactly one stub, and — where a real
  CLI exists on the machine — that it genuinely does not resolve inside the sandbox. The guard paid
  for itself immediately: §51c's two new non-dry-run sites are inert only because the refusal fires,
  and one of them names the real `databricks` CLI — they are routed through the helper too. 1185
  checks pass under bash 5.3 and 3.2.57.

## [3.8.0] — 2026-08-27

### Added
- **MCP permission posture — advisory enforcement for the transport the hooks cannot see.** On the
  MCP path enforcement does not disappear; it moves into the tool's own permission controls, and
  the kit now says so everywhere it matters. Every `transport: mcp`/`both` adapter (all 14,
  counting the meetings slot's four MCP-path adapters that ship alongside) carries
  a `## Permission posture (MCP)` section — where the native control lives (role / token scope /
  OAuth grant, across official-connector / CLI-configured / homegrown shapes), the recommended
  setting per policy, and a read-only probe. The two warehouse adapters get a written comparison
  rule (`matches` / `exceeds-policy` / `unverified`) — Databricks' rule is cap-biased: Unity
  Catalog privileges inherit and group grants apply while the direct-grant surfaces cannot show
  that, so `matches` needs an effective-permission surface and unobservable effective privileges
  yield `unverified`. Chat/tracker connectors state plainly that a grant set cannot be
  introspected in-session and cap at `unverified`.
- **`verify_stack.sh` posture advisories.** Each seam whose *resolved* transport includes mcp
  (configured value first, adapter frontmatter as fallback) gains a
  `▸ posture[<slot>]` pointer line under its status — advisory only: counters, summary wording,
  and exit codes are unchanged.
- **Setup probes and records.** `/setup` (tool rounds) and `/setup --teammate` follow each posture
  pointer, run the adapter's read-only probe in-session, apply its comparison rule, and record the
  outcome in the report and in gitignored, display-only `.claude/config/posture.local.yaml` (never
  resolver-merged; covered by the existing `*.local.yaml` gitignore pattern).
- **The rendered AGENTS.md gains NATIVE (tool-side).** A per-policy posture table (Bash path vs
  MCP path) sits below the runtime enforcement table, between its own markers; NATIVE is claimable
  only where a read-only privilege introspection plus a written comparison rule exist (the
  warehouse slot), and only with a recorded `matches`. `bin/emit_runtime.py` appends the table to
  the `.clinerules/` honesty artifact; fixtures regenerated for cline, codex-cli, antigravity.
- **Session banner names both paths.** When a warehouse is configured and the DB-write policy is
  on, the SessionStart banner adds one line: hook-gated on Bash, advisory on a provable MCP path —
  an unknown transport never claims MCP.
- Selftest §51b (posture structure, fence-scoped probe hygiene, table honesty pins) and §51c
  (advisory behavior through every verify_stack terminal state + the banner matrix).

- **The `meetings` tool slot** — the sixth verb-contract slot, shipped after the new-slot bar was
  re-judged YES on all four legs (written judgment, codex-adjudicated; the record lives in
  `ROADMAP.md`). Optional, read-only, single-tool: a ticket references a meeting with a
  `meeting_ref: <provider>:<id>` frontmatter key in a `source_materials/` stub, and `/ticket`'s
  priming fetches the transcript **to context, never to disk**. Three verbs
  (`fetch_transcript` with `content_kind: transcript|notes`, `search_meetings`,
  `fetch_action_items` with a typed `ok|empty|no_native_export` result and per-status caller
  behavior); five launch adapters (`zoom`, `fireflies`, `granola` — local cache,
  credential-free — `teams`, `notion`), each carrying the transcript-privacy rule verbatim.
  New `bin/meeting_refs.py` makes the reference contract mechanical (exit family 0 ok · 2 usage ·
  4 malformed-or-refused; credential-bearing values refused at parse time with
  `reason: refused-credential`; no reference ⇒ `{"refs": []}` and silence — never a speculative
  fetch). `seams.meetings` is optional like docstore (worked example in
  `stack.example.multi-audience.yaml`); `/setup tool meetings` adds it later; the session banner
  always prints the slot (`meetings=—` when absent). Selftest section 51d covers the parser,
  resolver, banner, render, and the labeled structural pins.

### Fixed
- **`source_materials/private/` now actually gates what it promised.** The declared raw opt-in
  area was only ever protected for material the classifier could *read*: a binary export (a
  `.docx`/`.pdf` transcript) classified `binary`, skipped the shape test, flagged nothing, and a
  folder-wide docstore backup carried it out with no per-file approval — while the docs said that
  area "flags every `/ship` scan and copy-guard prompt". A file under `source_materials/private/`
  is now `raw_suspect` **by declaration** (the person put it there; coverage no longer depends on
  what the shape test can parse), so the scanner's exit contract and both guard paths gate it.
  Scope is exact — `source_materials/private/`, matching the gitignore pattern, not any directory
  named `private/`. Everything else is unchanged, including the honest limit that the classifier
  matches filenames and document shape, **never meaning**.

## [3.7.1] — 2026-08-25

### Fixed
- **The plugin installs again on Claude Code 2.0.x–2.1.x.** `marketplace.json` declared
  `"source": "."` (the schema requires `"./"`) and a root-level `description` some versions reject —
  both failures are *silent* on the declarative session-start path, so a fresh clone simply had no
  skills and `/setup` returned "unknown command" with no diagnostic. Found by three teammates
  onboarding on the same day. The manifest now uses `"./"` + `metadata.description`, selftest §16
  pins the installable shape, and `docs/troubleshooting.md` gains a symptom-first "slash commands
  are missing" section covering all three install failure modes (register-without-install, silent
  schema rejection, phantom installPath) plus the `settings.local.json` escape hatch.
- **`bin/selftest.sh` runs on stock macOS bash again.** bash 3.2 (`/bin/bash` on every Mac)
  mis-parses a heredoc nested inside `$( )`; six such sites in v3.6.1 grew to nine by v3.7.0+, so
  the suite died mid-file after §31 while its earlier ✓ output scrolled past — the "bash 3.2-safe"
  claim was false three releases running. All 43 heredoc-in-`$()` sites now capture via temp files,
  §52 lints the file for the forbidden shape on every platform, and CI gains a macOS job running
  the parse gate + the full suite under `/bin/bash`. 1099 checks pass under both bash 5.3 and 3.2.57.
- **`verify_stack.sh` no longer prints "All seams OK." over unverified seams.** A completely
  unauthenticated MCP-only chat seam sat under an all-green banner (observed live). The summary now
  counts three states and names the unverified seams — `3 OK, 2 unverified (chat, docstore).` —
  with distinct wording for "MCP-only: the agent must probe in-session" vs "skipped: unresolved
  {token}". Exit codes are unchanged.
- **`whoami` warnings are honest and useful.** The public-host message hedges (github.com hosts
  private org repos; visibility is unverifiable offline), the advice recommends `$USER` concretely,
  and binding an `--identity` that matches no local candidate now warns on stderr instead of
  reporting an inert bind as clean success. `_stack.py` compiles without `SyntaxWarning` under
  Python 3.12+ (it printed to stderr on every hook call).

### Changed
- **Getting started is two tracks.** The README now documents the founder path ("Setting up a
  repo") and the teammate path ("Joining a configured repo") separately, each step with its check —
  including the fact the old doc omitted: the committed `enabledPlugins`/`extraKnownMarketplaces`
  registers and clones the marketplace but does **not** install the plugin; `claude plugin install
  ticketwright@ticketwright` + a full restart come first. Prerequisites are stack-derived rather
  than a fixed list (`yq` is no longer demanded of rendered repos — nothing there uses it), and
  Windows onboarding is honestly labeled untested.
- **`db_write_guard`'s jurisdiction is stated everywhere it matters.** The guard sees **Bash** —
  SQL issued through a warehouse MCP server never reaches it, while `transport: mcp` is a legal
  warehouse configuration. The rendered AGENTS enforcement table now carries the same
  jurisdiction paragraph its sibling guard always had (test-pinned), plus a pre-install honesty
  note: hooks ship *with* the plugin, so the first, uninstalled session has no mechanical gates at
  all. Both warehouse adapters route **writes through the CLI** and keep MCP for read/exploration;
  `snowflake.md` documents the real config-file precedence chain (`SNOWFLAKE_HOME` →
  `~/.snowflake/` → macOS Application Support) and a fallback expected-target probe for repos whose
  `default_warehouse` is still an open TODO. Mechanical MCP enforcement (adapter-declared payload
  paths) is deferred to its own change.
- **Setup flow closes the gaps four onboardings found.** `teammate.md` checks git identity before
  binding (step 0.5) and makes the in-session MCP probe an explicit rule; `interview.md` offers the
  rclone mountless route when `mount_root` cannot resolve (Drive for desktop now requires IT device
  approval); the rendered settings allowlist matches the invocation shapes skills actually use
  instead of eight `bin/…` paths that never match.

### Added
- **A visible "release available" notice.** `autoUpdate: true` refreshes the marketplace *catalog*
  but does not re-install a project-scoped plugin from it
  ([claude-code#61854](https://github.com/anthropics/claude-code/issues/61854)), so a release has
  been reaching machines without being picked up and nothing said so. **`bin/update_notice.py`** is
  a stdlib-only CLI that reads three local files — the repo's `.claude/settings.json`, the installed
  plugin manifest, and the cached marketplace — and prints **one line** when the catalog is strictly
  newer, naming both versions and the uninstall+install pair. Everything else is silence: equal or
  older versions, a non-integer version segment, an explicit `autoUpdate: false` or disabled plugin,
  a missing or malformed file, and **any ambiguity** (two eligible plugins, two matching install
  records) — it never guesses a version. It never prints a filesystem path, because the manifest
  lists other repos' paths. The plugin and marketplace names are read from the repo's own settings
  (so forks and renames work) and must be ordinary identifiers — they are spliced into a command a
  person is invited to paste, so a name carrying shell metacharacters or a newline silences the
  notice instead — and since the marketplace name is a path component, `.` and `..` are refused
  outright. An install record only counts as this repo when it names the canonical path exactly or
  resolves to it strictly (absolute paths only, no lexical `..` collapsing), so a record naming a
  path that does not exist cannot be mistaken for one that does. Reads are bounded and judged on the open descriptor (`O_NONBLOCK` + `fstat`, not a
  stat of the path), so a file that grows — or a path that becomes a FIFO — mid-read can neither
  block nor make this child do unbounded work inside the session-start budget. It exits 0 always, and **does not swap the install**: a kit that
  silently replaces its own running code is worse than a stale one. When upstream closes the gap the
  versions match and the notice retires itself. `session_context.py` appends the line to the
  SessionStart banner and **fails open** — a broken, chatty or hanging CLI leaves the banner
  byte-identical. Other runtimes reach it through the launcher:
  `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" update_notice.py --root .`

## [3.7.0] — 2026-08-24

### Added
- **A docstore without a desktop mount: the `rclone` adapter.** The two shipped document stores
  both write into a desktop sync folder, which leaves anyone who cannot run a sync agent — every
  Linux user, since Google ships no Drive for Desktop client — with a bare `test -d` failure and no
  route forward. `adapters/docstore/rclone.md` fills the same slot with the same **two** verbs
  across Drive, OneDrive, Dropbox, S3 and Box, with no mount in the path. It splits the destination
  on the existing tier line: `remote_path` is the team's destination (tier 1, committed, path-only
  — never carrying a `remote:` prefix, which would double it) and the rclone `remote` NAME is
  per-machine (tier 3). No skill learned a new option; tool choice stays in `stack.yaml`.
- **`docs/drive-mount.md`** — detect and guide, never ask (the `docs/obsidian.md` precedent):
  installing Drive for Desktop or the OneDrive client, the CloudStorage mount path per OS, what
  `mount_root` means and why it is never committed, and the one-line verify. Pointed at from both
  docstore adapters' `auth:` notes and all three `/setup` surfaces by **GitHub URL**, because
  `docs/` does not ship in the wheel and a bare `docs/` path resolves to nothing on a pip install.

### Changed
- **A re-pointed personal remote can no longer redirect a delivery silently.** `_compose_paths()`
  now composes an unmounted docstore's `base_path` as `{remote}:{remote_path}`, exactly as it
  already composed `{mount_root}/{drive_folder}`, and routing substitutes the composed destination
  for any **docstore** target rather than only for `drive_folder`. The tier-3 half therefore lands
  inside the routed `destination` — so it is covered by the shell-metacharacter refusal **and** by
  `resolution_fingerprint`, and re-pointing an alias after an approval now refuses (exit 8) instead
  of delivering somewhere nobody authorized. Chat is deliberately excluded from that substitution:
  it shares the code path, and a stray `base_path` must never override a channel.
- **An adapter can no longer make its own destination personal.** The reserved-key rule is now
  *derived* from each adapter's declared `destination_key:`/`channel_key:` instead of being a fixed
  list that could only name today's keys, and `remote_path`/`base_path` join the static set. No
  shipped adapter is affected (every chat adapter declares `user_keys: []`; the mounted docstores
  declare only `mount_root`).
- **`source_material_guard` follows the backup verb to its new transport.** The guard existed to
  stop a folder-wide docstore backup carrying a raw transcript out of the repo, but it matched only
  `cp`/`rsync` — so an unmounted backup, which contains no `cp` at all, would have walked straight
  past a gate that shipped one release earlier. `rclone copy`/`copyto`/`sync`/`move`/`moveto` are
  now in its jurisdiction; read-only rclone verbs (`lsd`, `lsl`, `cat`, `about`, `listremotes`) stay
  outside it. A new copy path that a shipped privacy gate cannot see is a bypass, not a feature.
  Detection is no longer regex-only: the guard also **tokenizes** the command with `shlex`, because
  shell quoting was a one-character bypass of any pattern match — `rclone "copy" …`,
  `rclone 'copy' …`, `rclone c\opy …`, `'rclone' copy …`, `rclone -vv copy …`,
  `rclone --config=x.conf copy …`, `env VAR=1 rclone copy …` and `/usr/local/bin/rclone copy …` all
  execute a recursive copy and all now prompt. The same quoting fix covers `cp`/`rsync`, which had
  it too. The hook still fails open on an unexpected error, and still asks (never blocks).

- **A flaky selftest assertion is now deterministic.** Section 20's "handoff.sh works with yq absent
  from PATH" check grepped its output for `yq` as a bare substring, so a random `mktemp` suffix
  containing those two letters (`tmp.6FV8DYqer5`) failed the run at random. Word-bounded, it still
  catches a real `yq` dependency. Found while landing this change, unrelated to it.

### Honest limits
- `rclone link` **creates a public link**: rclone documents it as minting a URL with "no expiry, no
  password protection, accessible without account". It is authorized like the upload, never run
  implicitly, and `--expire`/`--unlink` are documented by rclone as unsupported on some backends,
  so neither is offered as a guaranteed mitigation. Where a backend cannot mint a link, the verb
  returns a manual fallback rather than a fabricated URL.
- `rclone copy` is **non-deleting, not non-destructive**: it never removes destination-only files,
  and it does overwrite a same-name file whose size or modtime differs — which is what re-running a
  backup after editing a deliverable is supposed to do. `rclone sync` is banned outright.
- Reachability is not identity. `rclone about` is not supported on every backend (S3 has no
  `About`) and `rclone lsd` can succeed against a *different* account holding the same path — on an
  object store an absent prefix lists empty and exits 0. The shipped `verify` therefore compares a
  team-pinned sentinel's exact contents (`target_sentinel`), not merely that a path lists.
- `sharing_scope` remains **declared, never inspected**, and rclone widens the blast radius: an S3
  bucket can be world-readable. The kit checks that a destination is the team's, never its ACL.
- **Meetings are an intake channel** — `project.intake` accepts `meetings` alongside `tracker`,
  `email`, and `chat`. No new tool slot and no provider connection: the transport is the one that
  already existed, a person exporting notes into the ticket's `source_materials/`. The convention
  is `YYYY-MM-DD-<slug>-meeting.md`, the **committed, curated form** — trimmed to decisions and
  action items. `/setup`'s round 4 gains **one option on its existing intake question**, not a new
  question. A `meetings` tool slot was judged against the new-slot bar and **deferred**; the four
  legs and what would flip each are recorded in `ROADMAP.md`.
- **`bin/scan_source_materials.py`** — a deterministic, stdlib classifier for a ticket's
  `source_materials/`: `curated` / `raw_suspect` / `other`. Two jobs, one implementation:
  `/ticket` priming calls `--intake` to enumerate what to read (and it omits raw transcripts, so a
  full transcript never enters context by default), and `/ship` calls it to gate. **Content beats
  filename** — a file carrying the curated name whose body is a transcript is still `raw_suspect`,
  because a convention that a rename could satisfy would not be a gate.
  `tests/source_materials/golden.json` pins the classification, including the two cases that decide
  whether the heuristic is real: a curated-named full transcript, and ordinary timestamped meeting
  notes that must **not** trip.
- **`source_material_guard`** — a PreToolUse hook (new optional policy, default `on`) that asks
  before a raw meeting transcript is **staged for commit** or **copied into a docstore backup**.
  It intercepts at the command layer, so it also covers the productized-skill path, which backs up
  and commits without ever calling `/ship`. Wired for every runtime the kit can wire: native on
  Claude Code, emitted for Cursor / Antigravity / OpenCode, shim-ready elsewhere — the enforcement
  table carries the new column per runtime.

### Changed
- **`templates/gitignore.tmpl` now ACTIVELY ignores raw transcripts** —
  `**/source_materials/*transcript*` and `**/source_materials/private/`, uncommented. The existing
  CSV-family patterns never covered markdown, which is what notetakers export. `git add -f` plus an
  explicit approval remains the opt-in.
- **`/ship` inspects `source_materials/`, not just `final_deliverables/`**, at both risk points —
  before the docstore backup and before staging. The two remedies are **not** interchangeable, and
  the skill now says so: `private/` protects git and does nothing against the adapter's `cp -r`.

### Honest limits
- The classifier matches **filenames and document shape, never meaning**. A curated summary that
  quotes confidential material verbatim classifies as `other` and passes. This is a gate against the
  bulk artifact, not a confidentiality review, and it does not replace a person reading what gets
  committed. The guard's jurisdiction is **Bash**: a file written by a non-Bash tool, copied in a
  file manager, or uploaded by a browser never reaches it.

## [3.6.1] — 2026-08-23

### Fixed
- **`/ship` stages the graph layer, not just the catalog.** The Obsidian nodes
  (`tickets/graph/`, `tickets/objects/`) come out of the same render pass as `INDEX.md`, nothing
  gitignores them, and `build_ticket_index.py --check` has always gated them — but step 8's staging
  list named only the three catalog files, so the person-facing rendering of the corpus never rode
  along with the ticket. It stayed dirty in the shipper's clone until someone noticed, and the next
  contributor's `--check` was the thing that noticed. Step 8 now stages `tickets/graph/` +
  `tickets/objects/` too, when `project.graph_notes` is on (the default). 3.6.0 documented this as
  an asymmetry to live with; it was a gap to close.
- **The same under-count everywhere else it appeared.** `/refresh`'s index mode (`SKILL.md` +
  `index.md`) and `docs/ticket-index.md` all told a reader to commit "all three" index files — the
  last describes itself as wired into the ship skill, so it has to agree with it. `bin/enrich_ticket.py`
  said it in two places of its own (the module docstring and the line it prints when it finishes),
  and it matters most there: it re-renders, so it moves the graph layer, and it is the one such
  instruction a person meets without going through a skill at all.
- **Descriptions of what the renderer writes and the gate covers**, in `/refresh index`'s opening
  summary, `/ticket`'s catalog-refresh step, and this repo's own `AGENTS.md` command list — each
  named the two catalog files and stopped there.
- **`--check`'s clean line named only what it used to compare.** It printed
  `tickets/INDEX.md + OBJECTS.md are up to date.` after comparing the graph nodes as well; it now
  names the graph layer when the layer is on, and still doesn't when `graph_notes` is off. The four
  other places that described the gate — the CLI docstring, the `--check` argparse help,
  `docs/troubleshooting.md`, and `docs/ticket-index.md`'s maintenance block — were widened the same
  way, and now draw the line the code actually draws: the gate covers the **rendered** files
  (`INDEX.md`, `OBJECTS.md`, the graph nodes), while `index_data.json` is the curated **input** to
  the render and is not gated. The old "all three, or `--check` flags drift" phrasing in `/ship`
  implied otherwise.

### Changed
- `README.md` ("See it as a graph") and `docs/architecture.md` ("One relationship model, two
  renderings") drop the stated-asymmetry paragraph for the symmetric statement: both renderings are
  staged together, and a node left out is CI drift rather than a graph only one clone can see.
  `.claude/skills/setup/scaffold.md` and `templates/gitignore.tmpl` needed no edit — they already
  described the graph layer as committed alongside the catalog, which is now true.
- **`/ship` step 8 now says the render is repo-wide.** Staging a whole rendered directory can carry
  a row or node that moved for *another* ticket, so the step asks for a look at the index diff and
  for the carried change to be named in the commit message instead of bundled in silently. This was
  already true of `INDEX.md` and `OBJECTS.md`; naming it is the honest half of widening the list.
- New selftest section 48 pins it from both ends. Mechanically: `--check` fails on a node deleted
  from `tickets/graph/` *and* on one deleted from `tickets/objects/` (both halves of what `/ship`
  now stages), its clean line tracks the `graph_notes` flag in both directions, and a well-formed
  curated record that changes no rendering leaves `--check` clean — the honest proof that the store
  is an input. As prose wiring: the five enumerated index-commit instructions each name the graph
  paths and the flag, none still says "all three", and the retired asymmetry cannot creep back into
  the two docs. What it pins is that enumeration, not every sentence in the repo.

## [3.6.0] — 2026-08-22

### Added
- **Email is a delivery channel: `gmail` and `outlook` chat adapters** (PROMPT 10). Email is a chat
  **target**, not a sixth tool slot — the same four verbs, the same routing, the same rules. The
  honest mapping, stated in each adapter rather than implied away: `draft`/`send` map directly
  (both products have native drafts); `lookup_user` is the address book; `lookup_channel` → a
  distribution list is a **stretch** (a list address is opaque — resolving it proves the address
  exists, not who reads it); and `always_include`/`default_channel` do not transfer cleanly to
  to/cc/bcc — the adapters' destination key `to` is ONE address string, `always_include` renders as
  **visible Cc**, and there is deliberately **no bcc mapping** (a hidden recipient would widen the
  audience invisibly). An email target declares its **own** audience and its own non-empty
  `always_include`, applied after routing, never inherited; routing comes only from the ticket's
  declared audience (never from prose, address domains, or list names) and a failure **halts — it
  never falls back to another chat target** (`--chat <target>` remains the one sanctioned,
  human-explicit, warned-as-unrecorded override). **Draft-first, precisely:** the shipped examples
  set `default_mode: draft` explicitly on every email target (an unset `default_mode` is not
  documented as meaning draft), `policies.chat_default_draft` stays honored, and — honestly — the
  send gate is `/ship`'s approval instruction plus the routed `mode`, not a runtime interlock; an
  email cannot be unsent, which is why the margin lives in the draft a human clicks. Worked
  activations of the setup interview's commented `seams.chat.targets.email` block:
  `stack.example.multi-audience.yaml` (Slack + Teams + **Gmail**, three audiences) and
  `stack.example.azure.yaml` (Teams + **Outlook**).
- **The sender is part of the approved resolution.** Chat adapters may declare `sender_key:`
  frontmatter (the email adapters name `identity` — the shared mailbox mail goes out AS, a
  committed team decision). Routing surfaces that value as `sender` on the resolved plan `/ship`
  prints, **refuses** a named email target whose identity is unset (mail must not go out as
  whoever the transport happens to be authenticated as) or shell-unsafe, and folds it into the
  `resolution_fingerprint` — a post-approval config edit swapping one mailbox for another now
  refuses exactly like a moved channel. Adapters without `sender_key:` are untouched.
- **Internal vs external delivery: `chat` and `docstore` route to named targets** (PROMPT 8,
  sequence items 2–3). A repo can now hold two chat tools and two document stores at once — Slack
  for the team and Teams for the client, an internal Drive archive and a client-facing SharePoint
  library — and each ticket says which it is for. **The audience is DECLARED, never inferred.** It
  lives in one place: the ticket's committed `delivery-plan.yaml` (`audience:` for chat,
  `classification:` for docstore), matched exactly against the value each target declares.
  `bin/delivery_plan.py` is the engine — it resolves through `bin/effective_config.py --seam/--target`
  rather than being a second resolver — and nothing anywhere reads prose, a channel name, or a label
  to guess. An absent or unmatched declaration is a **halt** listing what is configured (exit 9 / 8);
  it never falls through to `default:` or the first-listed target, because that target may be the
  external one. `/ship` resolves routing *before* drafting (so the draft carries the routed
  recipients), prints that same resolution at the approval gate, and executes from it — preview and
  execution are one resolution. `--chat <target>` overrides explicitly and says so on the plan line.
  `tracker` and `vcs` targets remain deliberately unrouted, and `/ship` still halts on them.
- **An approved delivery plan is binding.** Every routed plan line carries a
  `resolution_fingerprint` — a digest of target, tool, destination, recipients, scope and mode —
  and every routing call takes `--expect-target <name>` plus `--expect-fingerprint <hex>`, which
  `/ship` passes back after the human authorizes the plan. A changed target name refuses; so does a
  config or plan edit that keeps the name while moving the channel, the recipient list, the declared
  scope, the adapter, the destination key, or the include_self setting — the digest covers the
  facts a visible-recipient check cannot see. Preview-equals-execution is a mechanism, not a promise in prose.
- **Docstore routing is per deliverable.** A `deliverables:` row in the plan may declare its own
  `classification:` — a client-facing summary among internal working files routes to its own store,
  and the delivered row records the target that file actually went to. The `--override` escape hatch
  is **chat only**: a store belongs to a declaration that stays with the ticket, not to a flag in one
  person's shell history, and an override that contradicts a declaration says so on the plan line.
- **Routing enforces its own rules at the point of use**, not only in the verifier: a routed target
  with no stakeholder list, no valid declared `sharing_scope`, a non-string destination, or one
  relying on an inherited channel, is refused at send time even on a config nobody ran
  `verify_stack.sh` against.
- **`deliverables:` rows are schema-checked, never silently skipped.** A row whose
  `classification:` is null/empty/non-string, an unknown key (including the chat key `audience:`
  written by mix-up), or a `deliverables:` block that is not a list of rows is exit 4 — the row a
  person wrote to keep a file internal is honored or reported, never quietly overridden by the
  plan-level value. Paths are normalized before matching, so `./a.csv` and `a.csv` are one file;
  two rows naming one file (after normalization) are ambiguity and refuse rather than first-match.
  A plan that exists but is malformed reports exit 4 on every slot shape — only an ABSENT plan is
  excused on a single mapping.
  The docs now say plainly that a plan-level classification is a **folder-wide** statement.
- **A missing routing checker is a failure, not a silent skip**: `verify_stack.sh` exits 1 naming
  `bin/delivery_plan.py` when the config declares chat/docstore targets and the checker is absent —
  reporting "All seams OK" on exactly the config class those rules guard would be worse than
  failing.
- **`always_include` is now enforced in code, not prose.** `bin/verify_stack.sh` **fails** a
  multi-target chat slot whose target omits its stakeholder list, declares it empty, omits or
  duplicates its `audience`, relies on an inherited channel, collides with another target's
  destination, or carries shell metacharacters in a destination or recipient; docstore targets must
  declare a `classification` and a `sharing_scope`. Every one of those rules binds **only when
  `targets:` is present** — a single-mapping chat slot that omits `always_include` validates exactly
  as before, and all previously shipped example configs are unchanged. `/ship` can also prove a
  drafted message carries its routed list (`delivery_plan.py --check-draft`), which catches a draft
  addressed to the wrong audience's stakeholders before it is sent.
- **Seventh worked config** — `.claude/config/stack.example.multi-audience.yaml`: Jira / Snowflake /
  Slack **+** Teams / Drive **+** SharePoint / GitHub, the internal-vs-client split end to end.
- **Adapters spell their own destination key** — chat adapters carry `channel_key:` (Slack
  `default_channel`, Teams `channel`), docstore adapters `destination_key:`, following the existing
  `dev_key:` / `container_key:` pattern so no skill learns which tool it is talking to. An adapter
  key name that is not a plain config key is refused rather than guessed at.
- **Routing keys are unreachable from a per-machine file** — `audience`, `classification`,
  `sharing_scope`, `channel` and `drive_folder` join the resolver's reserved seam keys, so a
  gitignored tier-3 file can never move a message to another audience or a client file to another
  store.
- **The live-verification punch list, and a mechanical honesty linkage** (PROMPT 7 / U6 — the
  wave-F2 closer). `docs/live-verification.md` writes down every claim wave F2 parked because
  only a live external runtime can prove it: 12 entries (the U6 spec listed 11; the delta is a
  dated amendment in `docs/PLANNED-CHANGES.md`), each naming the runtime, preconditions, the
  exact steps a human with that runtime runs, what PASS looks like, and the exact edits a PASS
  triggers — including a mechanical **WIRED → ENFORCEMENT promotion protocol** (per cell, never
  per entry: the template cell, the named selftest-43 pins, the cline fixture regen, the adapter
  caveat, and a **promotion ledger** line all move in one commit). PROMPT 7's own success
  criterion is entry 1, staged honestly in two visits because the codex hooks-config location is
  unresearched: establish it live first, ship the emitter change, then run the zero-hand-edit
  lifecycle. The linkage is enforced by new selftest section 44: every `unknown`/`unverified`
  value in `adapters/runtime/*.md` frontmatter (17 today), every WIRED enforcement-table cell
  (4), every "unverified"-labeled emitted artifact, and every "(unverified)" metadata-mapping row
  must be claimed on a punch-list `Covers:` line — read from `Covers:` lines only, so prose
  cannot satisfy it — and a non-Claude ENFORCEMENT cell without a ledger line fails, so a
  promotion can never be a template edit alone. Deliberately absent: any assertion that an entry
  *passed* — the suite proves verification is owed and tracked; only a human with the runtime can
  pay it. The enforcement-table legend now links the punch list by GitHub URL (the rendered
  AGENTS.md lands in user repos and `docs/` does not ship in the wheel), and `docs/runtimes.md` /
  `docs/architecture.md` link it in-repo.
- **Hook degradation: the DB-write guard now travels beyond Claude Code** (PROMPT 7 / U3). The
  deterministic scanner moved from the Claude hook into `bin/sql_scan.py` (one implementation,
  behavior-identical — `tests/guard/golden.json` pins the Claude hook's stdin→stdout protocol
  byte-for-byte across the move, and the existing guard selftests pass unmodified), and the new
  `bin/hook_shim.py --runtime <name> --hook <name>` presents its verdicts in each runtime's own
  hook protocol, selected by new adapter frontmatter (`hook_wiring`, `hook_protocol`,
  `hook_wiring_caveat`, `rules_root`). `ticketwright install` now emits the wiring where a config
  location is documented: `.cursor/hooks.json` with **`failClosed: true` set by the installer**
  (required configuration — cursor hooks fail open by default), `.agents/hooks.json` for
  antigravity (PreToolUse guard with `ask`/`force_ask` + PostToolUse index regeneration), and a
  throw-to-deny plugin wrapper at `.opencode/plugins/` (`bin/opencode_tool_gate.js`). On runtimes
  with no ask tier (codex-cli, opencode, devin) the default `high_risk` policy has no native
  expression and **collapses to deny-with-escape** — destructive statements are denied with a
  message naming the one-shot re-approval (the `TICKETWRIGHT_APPROVE=once` command prefix, or the
  `.claude/config/approve.once` token: consumed on use, 15-minute expiry, gitignored by the
  template) while additive statements pass untouched; the collapse is surfaced on the installer's
  stdout and permanently in the new per-runtime × per-hook **enforcement table** in the rendered
  `AGENTS.md` (replacing the now-false "for every other agent it is guidance" sentence), which the
  cline install also emits into `.clinerules/` since cline users don't read AGENTS.md. The table's
  vocabulary is deliberate: ENFORCEMENT is reserved for mechanisms proven in this kit's own test
  contract (the native Claude hooks); an emitted-but-live-unverified mechanism is **WIRED**, and a
  live confirmation on the punch list is what promotes it. Malformed
  hook input is a per-runtime decision — ask on cursor/antigravity, deny-with-escape on the
  deny-only three, never a silent allow where the installer configured fail-closed — and the
  devin/opencode shim path exits **only** 0 or a deliberate 2 (devin logs-and-ignores any other
  nonzero by documented design). Where even the hooks-config location is undocumented (codex-cli,
  devin) the installer prints the exact manual wiring line instead of guessing a path. The Claude
  Code path is unchanged: the hook keeps its in-process policy read, its fail-safe-to-`all`, and
  its exit-0 contract — with one new, deliberate failure mode: if `bin/sql_scan.py` cannot be
  imported, the hook asks on every Bash command in the configured repo (naming the fix) instead
  of silently gating nothing. Whether each runtime honors its documented wiring remains
  live-verification work (the U6 punch list); nothing here claims parity before that is paid.
- **The full emission matrix: `ticketwright install --runtime <name>` now covers all seven
  runtimes** (PROMPT 7 / U2), driven entirely by adapter frontmatter — `reads_foreign_skills`
  and `skills_root` decide emit-vs-verify, `agents_root` decides agent-definition emission,
  `global_skills_root` drives `--global`; no runtime name is baked into branch logic. Where a
  runtime reads the canonical `.claude/skills/` copy directly (cursor, opencode, cline, devin) the
  installer VERIFIES it is reachable and emits no skills, printing each adapter's documented
  caveat and the shared-file trap per affected skill: a foreign reader ignores Claude-specific
  keys, so `allowed-tools` and `disable-model-invocation` are lost there exactly as on an emit
  runtime lacking the primitive — plus a duplicate scan naming any same-named copy in another
  root the runtime reads. Where it cannot (codex-cli, antigravity — one shared `.agents/skills/`
  emission), every skill is now emitted, completing the U1 deferral: a user-invocable-only skill
  (`disable-model-invocation: true`, enumerated from source frontmatter) carries a topmost
  warning block stating that nothing mechanical prevents model invocation there. Every mapping
  and loss is recorded per runtime in a new `## Metadata mapping` section on each
  `adapters/runtime/*.md`. The `qc-reviewer` agent definition is emitted wherever subagents are
  user-definable (`.codex/agents/qc-reviewer.toml`; markdown for cursor/devin/antigravity, with
  `tools:` carried verbatim as an unverified mapping); cline (not user-definable) and opencode
  (no documented definition path) get the stated loss instead of a guess. `--global` emits into
  the declared per-user root, REFUSES where it is `unknown` (antigravity — its documented sources
  disagree), and is a deliberate explained no-op on verify runtimes (a global copy would be a
  permanent stale-duplicate risk). Collision handling is provenance-aware for every artifact:
  the installer refreshes its own files on re-run and never overwrites a file it did not emit —
  the install fails loudly instead. Selftest section 41 pins the per-runtime fixture trees
  (`tests/emit/{codex-cli,antigravity,cursor,devin}/`), the warning coverage (enumerated from
  source, in the artifact on emit runtimes and in the captured report on verify runtimes), the
  verify runtimes' zero-skill-copy guarantee, and the `--global` contract; section 39's carve-out
  assertions were updated to the completed behavior.
- **The runtime installer skeleton: `ticketwright install --runtime <name>`** (also
  `bin/install.sh`, or `bin/emit_runtime.py` directly — one implementation, three ways in, never a
  competing install route). The canonical skill source stays `.claude/skills/`; the installer
  translates FROM it at emit time, and only where the runtime cannot already see the canonical
  copy: `--runtime claude-code` is VERIFY-ONLY (reports the plugin or vendored install, touches
  nothing — the Claude Code path is unchanged), `--runtime codex-cli` EMITS
  `.agents/skills/<name>/SKILL.md` per skill (`name` + `description` frontmatter, body carried
  over, provenance header naming the emitting version and the re-run command — hand-copying
  between layouts is unsupported). At this stage, skills whose source declared
  `disable-model-invocation: true` (`setup`, `ship`, `productize` — enumerated from frontmatter,
  never hardcoded) were deferred with a printed reason, a re-run removed a stale emitted copy of
  a gated skill, and other runtimes plus `--global` exited non-zero naming the unit adding them —
  all superseded within this same release by the emission-matrix entry above, which emits gated
  skills with a topmost warning block, covers all seven runtimes, wires `--global`, and
  generalizes the never-delete-a-hand-copied-file rule into provenance-aware collision handling
  for every artifact. Renamed-runtime aliases resolve through the existing adapter machinery
  (`--runtime windsurf` answers about `devin`).
  `ticketwright init` now writes a `bin/KIT_VERSION` marker so a vendored kit can stamp true
  provenance (same preserve/`--force` rule as every vendored file). Stdlib-only, takes
  `--root`, no Claude environment variable required. Selftest section 39 pins the emitted tree
  byte-for-byte against `tests/emit/codex-cli/` across all three routes, including an offline
  wheel-shaped `init` → `install` end-to-end.
- **Five machine-readable capability keys on every runtime adapter** (PROMPT 7 / U5):
  `gate_ask_tier` (can the pre-tool gate *ask* a human — the axis `tool_gate: yes` alone hides),
  `gate_fail_mode` (the runtime's NATIVE default when a hook errors — not the installed state),
  `subagent_isolation` (`documented`/`unestablished`/`none`), `reads_foreign_skills` (which
  foreign skills roots the runtime scans — drives the installer's emit-vs-verify branch), and
  `global_skills_root` (where `--global` artifacts belong, `unknown` where the docs disagree).
  `bin/kit_paths.py --json` surfaces all five, with per-key floors for an unrecognized runtime
  (booleans `no`; the enum keys `unknown`; `reads_foreign_skills` `none`) — a generic `no` is not
  a legal value for an enum, and forcing one manufactures a confident wrong answer. The
  load-bearing safety rows are pinned by selftest section 40, section 31's required-key and floor
  checks are extended, and `docs/runtimes.md` § "The matrix, machine-readable" documents the
  values with footnoted caveats — including the rule that "richer gate" and "has a session hook"
  are independent axes nothing may average into one score.
- **`/review` now records which second pass a ticket actually got, and degrades honestly where
  the runtime cannot provide one** (PROMPT 7 / U4). Before spawning anything, the skill probes
  the current runtime's declared capabilities
  through the kit CLI (`bin/tw kit_paths.py --json` — capability keys only, never a runtime name)
  and branches: `subagents: yes` + `subagent_isolation: documented` fans out `qc-reviewer` exactly
  as before and the verdict records `review_mode: independent-subagent`; isolation `unestablished`
  still fans out — the stronger check is not refused — but records the posture verbatim; subagents
  absent, isolation `none`/`unknown`, an unrecognized runtime (the never-optimistic floor), or a
  failed probe all fall back to walking the qc-reviewer checklist inline, and the verdict records
  `review_mode: inline-same-context` plus, verbatim: "A same-context review is not the independent
  second pass the validation pyramid assumes." `qc-reviewer`'s fresh-context claim is now
  conditioned on how it was run, so an inline-degraded APPROVE can no longer read identically to
  an independent-subagent one. Selftest section 42 pins the probe, the three branches, the
  verdict-record fields and the sentence (with the forbidden runtime-name list derived from
  adapter frontmatter) — structural evidence only; the live degraded run stays on the U6
  live-verification punch list.

### Fixed
- **Runtime capability matrix corrections, re-verified against vendor docs 2026-08-19** (in
  `adapters/runtime/*.md` + `docs/runtimes.md`, each marked inline with the access date): Devin's
  `{"decision": "approve"|"block"}` stdout schema belongs to its separate `PermissionRequest`
  hook — `PreToolUse` blocks only via exit code 2 (the fail-open exit table is confirmed:
  0 continues, 2 blocks, any other nonzero is logged and does not block); OpenCode subagents are
  marked `mode: "subagent"` and invoked by `@`-mention or the Task tool, not `subtask: true`;
  Cline documents a global skills path after all (`~/.cline/skills/` on macOS/Linux — previously
  only the global *rules* path was recorded); and `adapters/runtime/claude-code.md` no longer
  calls itself "the only researched runtime" with a pre-tool `ask` — Cursor and Antigravity have
  one too, as `docs/runtimes.md` already said. One planned correction was checked and NOT
  applied: Devin skill frontmatter stays optional (`name` defaults to the directory) — the cited
  frontmatter reference table contradicts the claim that `name` + `description` are required, and
  `docs/runtimes.md` records that negative finding so nobody re-applies it.
- **`/setup`'s question cap is retired, and the interview is re-cut into rounds.** The "at most 5
  questions" promise had become the binding constraint on correctness — chat and docstore never
  configured, `role`/`domain` never asked, dead `ticket_url_template` links, one person folder
  forever. No number replaces it; the rule that does: **ask when a wrong or absent value still
  yields a confident-looking output; leave a commented default when it fails loudly** at
  `verify_stack.sh` or on first use. Phase 2 now lives in `.claude/skills/setup/interview.md`:
  rounds 1–4 always run (who — including the team roster as identity-free `people/<id>.yaml`
  placeholders; where work comes from — with tracker containers ranked by
  `rank_projects_by_activity` and `terminal_status` asked plainly; where the data lives — required
  keys, `dev_target`, multi-target branch; where work goes — VCS confirmed from `origin`, docstore
  split into team folder vs machine mount root, per-adapter chat destination keys, and ONE email
  question covering intake and delivery). Rounds 5–6 (role/domain/analysis tools; the two
  behavioral policies) are individually skippable, each skip labeled with its cost and written
  down twice — a `# TODO(setup)` line in `stack.yaml` and a punch-list entry in the report — and
  the re-entry verbs now exist: `/setup role`, `/setup team`, `/setup policies`. Interviews are
  prose everywhere (`AskUserQuestion` removed from skill frontmatter and bodies; the voice
  interview's own ≤5 cap is kept — it is a deliberate scope limit on a short style interview).
- **Two new `project` keys** (both optional, both tier 1): `intake` (default `[tracker]`) records
  where work arrives — when it lists `email`/`chat`, `/ticket`'s priming step sweeps
  `source_materials/` for forwarded threads; and `analysis_tools` (default `[]`) lists what the
  team analyzes *with*, rendered into `AGENTS.md` as descriptive context — not a tool slot,
  nothing verifies or executes it, and it is never appended to any permission allowlist. Answering
  "email carries work out" records provider, sending identity and declared audience in a commented
  `seams.chat.targets.email` block — **configured but not yet wired**: no email adapter ships yet,
  and the setup report says so plainly.
- **`docs/obsidian.md`** — install, open-the-repo-as-a-vault, the two node types, and the
  `graph_notes`/`graph_config` opt-outs; linked from the README's Obsidian section and its
  further-reading list. `/setup` now detects Obsidian and prints one pointer (the GitHub URL,
  since `docs/` does not ship in the PyPI package) instead of asking anything.
- **Selftest section 38** drives the completed-interview and skipped-rounds configs through
  `verify_stack.sh` (no unset required keys; `always_include` non-empty; `ticket_url_template`,
  `dev_target`, `intake` present; the machine mount root absent from committed config), pins the
  CLI-probe exemption literal, the deprecation lines on surviving old spellings, and the re-entry
  verbs; the `include_self` documentation gate now loops over every `adapters/chat/*.md` instead
  of naming two files.

### Changed
- **The docs lead with what the kit is for** (PROMPT 9). `README.md` now opens with the team-brain
  framing — the shared ticket corpus and six concrete benefits, each tied to the mechanism that
  delivers it (curated recall via `tickets/index_data.json` + `bin/recall.py`, `tickets/OBJECTS.md`
  object memory, written assumptions, QC verdicts, `deterministic_outputs`, continuity) — and
  presents the five lifecycle phases with a slot-to-phase matrix **before** the tool-slot table;
  `docs/architecture.md` gains the same lifecycle-first structure. Phase 3 is stated precisely:
  quality checking has no tool slot of its own — it borrows the warehouse to re-verify, and under
  the default `human_review_handoff` policy gates on a person reading the output. The graph layer
  and the catalog are documented as two renderings of one relationship model (person ↔ agent), with
  the `/ship` staging asymmetry stated (`INDEX.md`/`OBJECTS.md`/`index_data.json` are staged by
  name; `tickets/graph/` + `tickets/objects/` are committed-by-default but unstaged) and multi-hop
  graph traversal recorded in `ROADMAP.md` as a future enhancement. The "tool slot" terminology
  sweep covers the remaining user-facing "seam" sites (`stack.schema.md` narrative,
  `templates/AGENTS.md.tmpl`, `templates/plan.md.tmpl`, `docs/troubleshooting.md`, two `/setup`
  reference lines); `seams:` config keys, adapter frontmatter, and contributor docs keep the
  internal name. A voice audit holds README + docs/ to plain, concrete prose; selftest section 47
  pins the mission/vision sentences, the lifecycle-before-slots ordering, the phase matrix, and
  the filler-word absence.
- `adapters/README.md` and `stack.schema.md` now count all **six** shipped worked configs
  (`stack.example.no-warehouse.yaml` was missing from both enumerations); `/setup --voice` routes
  the team-wide `seams.chat.include_self` toggle to `/setup tool chat` instead of offering to
  write team config from a person-scoped flow.
- **Target selection is now a resolver mode, and `/ship` prints the resolved plan it feeds.**
  `bin/effective_config.py --seam <name> [--target <name>]` selects one tool slot — the seam's
  `default:` target, or an explicitly named one — and emits a single JSON object with inheritance
  and the tier overlays applied (an explicit `verify: null` on a target stays a skip). An
  unresolvable name is a hard error naming the configured targets — exit `7` for an unconfigured
  slot (callers may degrade), exit `8` for an unknown target or a missing/invalid `default:`
  (always a halt, never a fallback) — and the emitted `verify` is `null` whenever a token is
  unresolved or carries shell metacharacters, so no half-interpolated or injected command string
  ever leaves the CLI. `/ship`'s Phase B now renders the RESOLVED delivery plan from that mode —
  target (rendered as `single` until named targets are routable), destination, channel, the full
  recipient list, sharing scope, the exact ordered actions — so the human authorizes the plan, not
  the word "ship"; a named-targets chat/docstore seam is a halt there, because rendering a target
  the execution steps cannot route to yet would be an authorization mismatch. The full selection
  contract and the
  persisted `delivery-plan.yaml` schema (audience, classification, chosen targets, destination,
  sharing scope) are published in `adapters/README.md` § Multi-target seams ahead of the
  chat/docstore routing release that implements them. Selftest section 37 covers the selection
  behavior end to end.

### Fixed
- **`stack.schema.md` no longer claims the five seam keys are exclusive.** The "no others" language
  was already false — an optional `viewer:` entry is documented in the same file, and runtime
  adapters exist without being `stack.yaml` entries at all. The schema now states the accurate
  picture: five tool slots with verb contracts, a generic `targets:` shape on any slot, and
  per-slot operational support stated explicitly (today only `warehouse` is routed by skills).
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
