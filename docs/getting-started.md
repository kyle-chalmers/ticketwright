# Getting started

Everything needed to put Ticketwright into a repo and get a team onto it. The
[README](../README.md) is the two-minute overview; this page is the step-by-step.

## Install: two tracks

Two tracks — pick yours and follow it end to end. **Track 1** is for the first person bringing
Ticketwright into a repo; **Track 2** is for everyone who clones that repo afterwards. Every step
carries its own one-line check, so a stall is diagnosable instead of mysterious.

### Track 1 — Setting up a repo

**Hand it to your agent.** Paste this into a Claude Code session opened on the repo, and the
five steps below happen with you answering rather than driving:

```text
Set up Ticketwright in this repo for my whole team. Install it at project scope
from the repo root, get me to restart so the skills load, then run
/ticketwright:setup and put its questions to me rather than answering them
yourself - it's asking about my team's tools and my identity. Show me the file
list before committing anything.
```

The prompt keeps the interview yours on purpose: `setup` asks about your team's tools and who
you are, and an agent that infers those from whatever is installed on the machine writes a
confidently wrong `stack.yaml`. To drive it by hand instead, follow the steps:

**1 · Install the plugin at project scope**, from inside the repo you want to work tickets in:

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

*Check:* `claude plugin list` shows `ticketwright@ticketwright … enabled`.

That writes the repo's own `.claude/settings.json`. Both commands default to `--scope user`, so
**omit `--scope project` only if you want Ticketwright for yourself across every repo** rather
than for this repo's team. On a machine that already knows a marketplace named `ticketwright` (a
personal install, or another repo's), `marketplace add … --scope project` prints "already on disk —
declared in project settings" — expected, not an error: the cached marketplace is reused and the
project-scoped declaration still lands in this repo's settings.

**2 · Reload the plugin, or restart.** Plugin skills load at session start, so installing and
running `/setup` in the same session silently fails: the command simply doesn't exist yet. Run
`/reload-plugins` or start a new session. If the commands still do not appear, fully quit the Claude
app (Cmd+Q on macOS, File → Exit on Windows/Linux) and relaunch — a new chat is not a restart.

*Check:* `/ticketwright:setup` shows up in the new session's command list.

**3 · Run setup:**

```
/ticketwright:setup          # detects your tools, interviews you in rounds, writes the config — once per repo
/ticketwright:ticket ENG-123 # start working
```

`setup` also handles repos that **already have** ticket history — it maps onto your existing
layout instead of scaffolding, and writes a `MIGRATION.md` checklist (see
[Adopting an existing repo](#adopting-an-existing-repo)).

*Check:* `.claude/config/stack.yaml` exists, and the tool-slot verifier names each slot — ask your
agent to "run verify_stack" (on a plugin install the script lives in the plugin, and the skills
resolve it; in a vendored or pip repo you can run `bash bin/verify_stack.sh` directly).

**4 · Turn on the catalog refresh, and know that upgrades are manual.** Add one key by hand to the
`"ticketwright"` marketplace entry in `.claude/settings.json` (no CLI flag sets this one):

```json
"autoUpdate": true
```

`/ticketwright:setup` adds that key for you if you'd rather not hand-edit; see
[Project-scoped by default](#project-scoped-by-default) for the finished file.

**`autoUpdate` does not deliver plugin updates.** It refreshes the marketplace catalog on session
start and stops there: Claude Code does not re-install the plugin from the refreshed catalog, so a
new release reaches every teammate's machine without being swapped in. This is a known upstream gap
([claude-code#61854](https://github.com/anthropics/claude-code/issues/61854),
[#52218](https://github.com/anthropics/claude-code/issues/52218),
[#49410](https://github.com/anthropics/claude-code/issues/49410),
[#17361](https://github.com/anthropics/claude-code/issues/17361)), and it was reproduced here: a
machine whose marketplace clone had advanced to a newer release still ran the older installed
version. Sessions announce it rather than leaving it silent: when the catalog is ahead of what this
repo is running, the session-start banner ends with one line naming both versions and the command
pair below.

Upgrading is three steps, run from the repo: uninstall, install, then relaunch.

```bash
claude plugin uninstall ticketwright@ticketwright --scope project && claude plugin install ticketwright@ticketwright --scope project
```

Then run `/reload-plugins`, or fully quit the Claude app and relaunch; a new chat is not a restart.
(The pair may reorder keys in `.claude/settings.json`; the content is identical, so `git checkout`
the file if you want zero diff.)

**5 · Commit the scaffold** (`/setup` offers to), and Ticketwright travels with the repo.

*Check:* the committed files include `.claude/settings.json`, `.claude/config/stack.yaml`, and
`AGENTS.md`.

**What teammates will then see:** opening (and trusting) the repo registers the marketplace from
the committed `.claude/settings.json` and primes the session banner — and then they follow
Track 2, because registration is not installation (the fact Track 2 opens with).

#### Headless / agent-driven setup

`/setup` runs under `claude -p` too, and it is **two turns by design**. The first turn detects,
interviews (defaults where nobody answers) and prints the plan, then halts at the confirm gate — that
stop is the gate working, not a hang; nothing is written until a person has seen the plan. The
confirm is a second turn: `claude -p --continue "yes, write it"`. One limit is the runtime's, not
Ticketwright's: a non-interactive Claude Code refuses every write under `.claude/` — a categorical
sensitive-file guard that `permissions.allow` rules do not lift — so `.claude/config/stack.yaml`,
`.claude/settings.json`, `.claude/statusline.sh` and the gitignored `connections.local.yaml` /
`posture.local.yaml` need either an interactive approval or a person writing them from the printed
plan (setup prints their full contents on request). Setup writes `stack.yaml` first and stops when
that write is refused, so a headless run never leaves an `AGENTS.md` describing a stack that isn't on
disk; with `stack.yaml` in place, a re-run recognizes the half-finished repo and scaffolds everything
outside `.claude/` headlessly. Add `--strict-mcp-config` (with no `--mcp-config`) to keep MCP out of
the run, so detection reflects the CLIs on the machine rather than whichever servers it happens to
have connected. One more `.claude/` write happens earlier than the plan: round 1 of the interview pins your identity into
`.claude/config/connections.local.yaml` (`whoami --bind`), so in a headless run that refusal shows up
during the interview — setup records it and lists the pin with the other deferred `.claude/` files.

### Track 2 — Joining a configured repo

Someone already ran Track 1 and committed the result; you just cloned. One fact up front, because
it is the step people lose an afternoon to: the repo's committed `.claude/settings.json`
(`enabledPlugins` + `extraKnownMarketplaces`) **registers and clones the marketplace on session
start, but does NOT install the plugin.** Verified live: a teammate's `installed_plugins.json`
stayed `{}` across restarts until the manual install in step 2. Skip step 2 and
`/ticketwright:setup` is not a command that exists.

**Hand it to your agent.** Paste this into a Claude Code session opened on the repo — it works
the checklist below for you, in order:

```text
Install the Ticketwright plugin for this repo. Start with:
python3 ~/.claude/plugins/marketplaces/ticketwright/bin/plugin_doctor.py
Follow its fixes in order. I want it installed for this repo only, not globally.
If a check fails in a way its fix doesn't cover, stop and tell me instead of
working around it. When it's clean, tell me how to restart.
```

The prompt stays short because the doctor carries the detail: every check prints its own fix,
so there is one copy of each instruction rather than two that drift. The rest of this track is
what that prompt makes happen — read on to drive it yourself, or when an agent gets stuck.

#### If you are the agent helping someone install — read this first

One command answers most of what follows. The marketplace clone lands on disk as soon as the person
opens and trusts the repo — before anything is installed — so this runs at the moment nothing else
does:

```bash
python3 ~/.claude/plugins/marketplaces/ticketwright/bin/plugin_doctor.py
```

That path names the `ticketwright` marketplace; a fork substitutes its own marketplace name. The
doctor prints one line per check below, with the fix for each, and takes `--json` for a
machine-readable report. Once the plugin is installed the same checks run as
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" plugin_doctor.py` (the launcher `/setup` commits into the repo).

The checks, in the order the doctor runs them:

1. **A clone, not a downloaded ZIP.** <!-- doctor-check: git_clone -->
   `ls -d .git`. A "Download ZIP" folder (named `<repo>-main`, no `.git`) cannot branch, commit, or
   open a PR. Fix: `git clone <repo url>` and work in the clone.
2. **You are at the repository root.** <!-- doctor-check: cwd_is_root -->
   `git rev-parse --show-toplevel` matches your working directory. A project-scope install keys to
   the session's directory rather than the repo root
   ([claude-code#82830](https://github.com/anthropics/claude-code/issues/82830)), so run both
   install commands from the root.
3. **The `claude` CLI is on PATH.** <!-- doctor-check: claude_on_path -->
   `command -v claude`. Missing: install Claude Code and reopen the terminal. The in-app route
   below needs no terminal at all.
4. **Which version that CLI is.** <!-- doctor-check: claude_version -->
   `claude --version`. Reported, not judged: from Claude Code 2.1.195 the app itself reports a
   repo's plugin as not installed and shows the install command; older builds say nothing, which is
   why this checklist exists.
5. **That CLI understands `--scope`.** <!-- doctor-check: scope_supported -->
   `claude plugin install --help` mentions `--scope`. If it does not, the CLI is too old for either
   install command — use the in-app route below, then update it.
6. **How that CLI was installed.** <!-- doctor-check: install_channel -->
   `readlink -f "$(command -v claude)"` says which channel to update through: native installer →
   `claude update`; npm or nvm → `npm install -g @anthropic-ai/claude-code@latest`; Homebrew →
   `brew upgrade claude-code`. An nvm `claude` earlier on PATH shadows a native one; `claude doctor`
   lists conflicting installs.
7. **The marketplace is registered.** <!-- doctor-check: marketplace_registered -->
   A `ticketwright` entry in `~/.claude/plugins/known_marketplaces.json` whose `installLocation`
   exists on disk. Missing: the first command of the pair below.
8. **Your user settings do not declare a different source for it.** <!-- doctor-check: marketplace_source -->
   If `~/.claude/settings.json` declares a `ticketwright` marketplace with a different source (most
   often the GitHub shorthand, `{"source": "github", ...}`, from an older install), the git-URL
   `marketplace add` in the pair below fails with "its network source differs from the one declared for it in
   settings". Fix: set that entry's `source` to `{"source": "git", "url": "https://….git"}` with the
   URL you install from, or delete the user-level entry, then run the add again.
9. **This repo has an install record.** <!-- doctor-check: repo_install -->
   A row in `~/.claude/plugins/installed_plugins.json` whose `projectPath` is this repo.
   Registration never creates one. Fix: the pair below, from the repository root, then restart.
10. **The install record points at files that exist.** <!-- doctor-check: install_payload -->
    The recorded `installPath` holds a `.claude-plugin/plugin.json`. Seen on Claude Code 2.0.22:
    install prints "Successfully installed" and the directory is never created, so re-running install
    is a no-op. Fix: update the CLI, then
    `claude plugin uninstall ticketwright@ticketwright --scope <the recorded scope>` and install
    again; if uninstall answers "not found", copy the marketplace clone into the recorded path;
    recipe in [`docs/troubleshooting.md`](troubleshooting.md).
11. **No machine-wide install nobody meant.** <!-- doctor-check: user_install -->
    A row with `scope: "user"` turns Ticketwright on for every repo on the machine. If you meant
    this repo only: `claude plugin uninstall ticketwright@ticketwright --scope user`, then the pair
    below.
12. **The installed version matches the marketplace catalog.** <!-- doctor-check: catalog_current -->
    Behind means a tagged release has not been picked up; the fix is the uninstall-and-install pair
    the session banner names, at the scope the install record carries.
13. **`yq` is installed.** <!-- doctor-check: yq_present -->
    `command -v yq`. Needed only by `bin/selftest.sh`, where its absence fails a dozen-plus checks
    from one cause. macOS: `brew install yq`. Linux: your distribution's package. Windows:
    `winget install MikeFarah.yq`.
14. **Git identity is set.** <!-- doctor-check: git_identity -->
    `git config --get user.name` and `git config --get user.email`. Unset, the first commit fails:
    `git config user.name "…"` and `git config user.email "…"`.
15. **Restart the right way.** <!-- doctor-check: restart -->
    Printed whenever an install check above is not clean. Run `/reload-plugins` or start a new
    session. If the skills still do not appear, fully quit the Claude app (Cmd+Q on macOS,
    File → Exit on Windows/Linux) and relaunch. A new chat inside the running app is not a restart.

The install itself is two commands, run from the repository root:

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

When the repo's committed settings already registered the marketplace, the first command prints
"already on disk — declared in project settings" — expected, not an error. **No terminal, or a CLI
that rejects `--scope`?** Run `/plugin install ticketwright@ticketwright` in the session and choose
**Project** scope, or use **+ → Plugins → Add plugin** in the desktop app; both run in the app's own
engine. Then update the CLI (check 6).

*Verify:* `claude plugin list` shows `ticketwright@ticketwright … enabled`, and
`/ticketwright:setup` appears in the next session's command list. `bin/selftest.sh` takes several
minutes — judge it by its exit code, not by how long it has been running. Anything still
unexplained: [`docs/troubleshooting.md`](troubleshooting.md).

**1 · `git clone` the repo and open it in Claude Code** (trust the workspace when prompted). Use a
clone, not GitHub's "Download ZIP" — a `<repo>-main` folder with no `.git` cannot branch, commit, or
open a PR.

*Check:* `.claude/config/stack.yaml` exists — that's the team config Track 1 committed.

**2 · Install the plugin explicitly**, from the repository root:

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

Both commands default to `--scope user`, which would install Ticketwright for every repo on your
machine instead of this one. The marketplace is usually registered already from the committed
settings, so the first command prints "already on disk — declared in project settings" — expected,
not an error. If your CLI rejects `--scope`, it is too old: run `/plugin install
ticketwright@ticketwright` in the session and choose **Project** scope (or use **+ → Plugins → Add
plugin** in the desktop app), then update the CLI — see the checklist above.

*Check:* `claude plugin list` shows `ticketwright@ticketwright … enabled`. If your CLI answers
`unknown command 'list'` or `unknown option '--scope'`, it is too old — Claude Code 2.0.x has
neither; see the checklist above.

**3 · Reload the plugin, or restart.** Plugin skills load at session start; installing and running
`/setup` in the same session silently fails. Run `/reload-plugins` or start a new session. If the
commands still do not appear, fully quit the Claude app (Cmd+Q on macOS, File → Exit on
Windows/Linux) and relaunch — a new chat is not a restart.

*Check:* `/ticketwright:setup` shows up in the new session's command list.

**4 · Onboard yourself:**

```
/ticketwright:setup --teammate
```

It walks you through your `people/<id>.yaml`, your machine-local
`.claude/config/connections.local.yaml`, and auth for each tool the team's config actually uses.

*Check:* ask your agent to "run verify_stack". Slots with a shell verify should report reachable
(an unreachable one prints its auth fix; finishing onboarding first and authing later is fine).
MCP-only slots — a chat tool connected through a desktop connector, say — cannot be checked from
the shell and show as unverified; `/ticketwright:setup --teammate` probes those in-session instead.
Slots whose transport includes MCP also get a **permission-posture** pointer line: on that path the
tool's own role / token scope / grant is the control, the adapter's "Permission posture (MCP)"
section says what to set and how to probe it read-only, and setup records the outcome in
gitignored `.claude/config/posture.local.yaml`.

#### What you need installed (derived from the stack, not a fixed list)

The CLIs a teammate needs depend on which tool slots the team's `stack.yaml` fills — there is no
universal list. `snow` matters only if the warehouse is Snowflake, `gh` only if vcs is GitHub, and
so on. The verifier run above names anything missing, and each tool's install and auth notes
live in its adapter (`adapters/<seam>/<tool>.md`). On macOS the common ones are a Homebrew line
each:

```bash
brew install yq jq          # every stack: the kit's own tooling
brew install gh             # only if vcs is GitHub
brew install glab           # only if vcs is GitLab
brew install snowflake-cli  # only if the warehouse is Snowflake (the `snow` CLI)
```

Windows equivalents exist (`winget install …` covers most of these), but Windows onboarding is
untested — expect to translate paths and shell syntax yourself rather than assume parity.

## What setup does

### What `setup` actually does

It runs once per repo, and **detects before it asks** — detection produces the facts each question
depends on, and a question exists only where a wrong or missing value would fail *silently* (a dead
catalog link, a generic persona, a message with no stakeholders). Anything that fails loudly at
verification or first use ships as a commented default instead.

**What it looks at first, before asking you anything:**

- **Which CLIs are on your PATH** — `snow`, `acli`, `gh`, `glab`, `bq`, `databricks`, `yq`, `jq`, `git` —
  to pre-select the tools you already have.
- **Which MCP servers are connected** in the session (tracker / chat / warehouse).
- **What's already in the repo** — an existing `.claude/config/stack.yaml` (it offers to edit and never
  overwrites), or existing ticket folders and indexes, which switch it into adopt mode.
- **Who you are.** On a repo that's already configured, an unrecognized person is routed straight
  into teammate onboarding — a new cloner is never offered the team's shared config as their first
  action.

Config is three tiers: `.claude/config/stack.yaml` is the **team's** committed answer,
`people/<id>.yaml` holds each person's portable settings, and `.claude/config/connections.local.yaml`
holds the per-machine ones and is gitignored. `bin/effective_config.py` merges them — read that, not
the raw file. The machine tier can supply credentials and local paths; it can never change which data
gets read, and never a policy.

**Work that arrives from a meeting.** `project.intake` names where work comes from — `tracker`,
`email`, `chat`, `meetings`. Meeting notes arrive as a file in the ticket's `source_materials/`,
named `YYYY-MM-DD-<slug>-meeting.md`: the **committed, curated form**, trimmed to decisions and
action items. Raw full transcripts are a different matter — they are the most PII-dense thing a
ticket folder holds, so they stay out of git by default, and a guard asks before one is committed
or copied into a docstore backup. It reads filenames and document shape, **not meaning**, so it
catches the bulk artifact and does not pretend to be a confidentiality review.

**What it then asks — in rounds, detected answers pre-selected.** Four rounds always run: **who**
(you, confirmed from identity resolution, and who else is on the team), **where work comes from**
(tracker or *none*, key prefix, the tracker's "done" state, how catalog rows link back), **where
the data lives** (warehouse or *none*, its required keys, a dev target), and **where work goes**
(git host confirmed from `origin`, docstore, chat and its stakeholder include-list, and one
question covering email intake and delivery plus whether an AI notetaker carries work in). Two
more are individually skippable, each skip labeled with its cost — **how you work** (role,
domain, analysis tools) and **house rules** (the two
policies whose defaults most often differ by team). A skipped round becomes a `# TODO` in the
config plus a punch-list entry naming the command that finishes it later (`/setup role`,
`/setup policies`). The other eight policies ship as commented defaults you can edit any time.

**What it writes:**

- **`.claude/config/stack.yaml`** — your chosen tool slots live (the config key is `seams:` — "tool
  slot" is the same thing, internally called a seam), optional ones as commented blocks, each
  policy with a one-line "when to change this" note.
- **`autoUpdate: true` on the marketplace entry** — the one key no CLI flag can set, so running `setup`
  is how the catalog refresh gets turned on at all (it refreshes the catalog only; upgrading the
  plugin is still uninstall, install, relaunch, as in Track 1 step 4). It *merges*: an existing entry keeps the `source` you have
  (forks edit that URL), and a deliberate `false` is left alone.
- **`AGENTS.md`** (rules, tuned to your role) and a one-line **`CLAUDE.md`** that imports it.
- **`.claude/settings.json`** — read-only CLI allows, plus the hooks on a vendored install (omitted on a
  plugin install, where `plugin.json` already wires them).
- **Folders + `.gitignore`** — `tickets/<you>/`, `documentation/`, `resources/`; deliverable
  CSVs committed by default, PII opting out via `*.private.csv` or a `private/` folder.
- **The AI-layer index and a seeded ticket index.**

**Then it verifies and hands off:** two clearly-labelled checks — `selftest.sh` for kit integrity and
`verify_stack.sh` for whether *your* tools are actually reachable (an unreachable tool isn't fatal at
setup time; it prints the auth fix) — then offers to commit the scaffold, since an uncommitted setup
means later ticket PRs reference rules that aren't in the repo's history.

### Project-scoped by default

A plugin can't set its own install scope — the **repo** does. `--scope project` writes the enablement
into the repo's `.claude/settings.json`, so it travels *with the repo*, and it keeps working after
the person who set it up moves on. Registering the marketplace is not installing the plugin — a
teammate who opens and trusts the repo gets the marketplace clone, then runs the install themselves
(Track 2). Commit the file. This is what the two Track 1
install commands produce, plus the one key they don't write:

```json
{
  "extraKnownMarketplaces": {
    "ticketwright": {
      "source": { "source": "git", "url": "https://github.com/kyle-chalmers/ticketwright.git" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "ticketwright@ticketwright": true }
}
```

Three details in that block are deliberate:

- **The source is an explicit `https://…git` URL**, not the `owner/repo` shorthand. The shorthand can
  resolve to SSH and fail for anyone without GitHub SSH keys; the URL clones over HTTPS through your
  existing git credential helper (keychain / `gh auth login`). A fork edits just this one URL.
- **`source: "git"` is the discriminator `claude plugin marketplace add` writes** for an `https://…git`
  URL — that `source` object is copied from the CLI's own output rather than hand-authored. (`git` and
  `url` are *different* marketplace source types; don't swap one for the other. If someone ran the
  shorthand instead — `claude plugin marketplace add owner/repo` — the CLI writes
  `{"source": "github", "repo": "owner/repo"}`; both forms are valid, and setup's merge keeps whichever
  one is already there rather than rewriting it.)
- **`autoUpdate` is scoped to formal releases, and refreshes the catalog only.** The version only
  moves in a tagged release commit, so day-to-day commits to `main` never put teammates onto
  un-released work. Neither install command writes this key (no flag sets it); `/ticketwright:setup`
  adds it, or add it by hand. It refreshes the marketplace *catalog* and does not upgrade the
  installed plugin: that takes uninstall, install and relaunch (Track 1 step 4 has the commands, and
  `claude plugin marketplace update ticketwright` refreshes the catalog by hand).

Installing without `--scope project` puts Ticketwright in your own `~/.claude/settings.json` instead —
right for personal, cross-repo use, but your teammates get nothing. Use the committed block when you
want the whole team on it.


## Adopting an existing repo

Already have years of ticket folders and your own conventions? Run `/setup`. It:

- **detects your existing layout** and maps onto it rather than scaffolding over it
- **infers the config from evidence** — folders, CI, installed CLIs, MCP servers
- **classifies your custom commands** against the plugin's skills as *shadows / extends / unrelated*
- **writes a `MIGRATION.md` checklist** instead of overwriting anything

Adoption is incremental: run one real ticket through `/ticket → /build → /ship` before you delete
anything custom.

## Installing without the plugin

The plugin above is the primary channel and the one to use with Claude Code. The pip package
covers the two cases it can't: vendoring the kit's files into a repo, and running the
deterministic engines from a shell or CI.

```bash
pip install ticketwright                 # zero runtime dependencies; stdlib only
ticketwright init                        # vendor the kit into a repo (no plugin required)
ticketwright install --runtime codex-cli # translate the skills for a non-Claude runtime
ticketwright recall --for ENG-123        # prior-art ranking      — no Claude Code needed
ticketwright index --stats               # catalog coverage       — no Claude Code needed
ticketwright enrich ENG-123              # curated index summary  — needs a model CLI on PATH
```

- **`recall` and `index`** are pure stdlib and run anywhere.
- **`enrich`** calls a model headlessly. Which command it runs is resolved per runtime from
  `adapters/runtime/<name>.md` (`--model-cmd` overrides it), falling back to `claude -p`. A runtime
  that documents no headless command says so and points at the agent-neutral ingest path instead.
- **`init`** copies the kit's files — skills, agents, hooks, adapters, templates, `bin/` — and
  preserves your edits on re-runs (`--force` to overwrite).
- **`install --runtime <name>`** is the compatibility layer between the canonical `.claude/skills/`
  source and each runtime's own layout (`bin/install.sh` is the same command for a vendored
  install), covering all seven runtimes and driven by each runtime adapter's declared
  capabilities, never a name baked into code. Where the runtime already reads the canonical copy
  it VERIFIES and emits no skills — `--runtime claude-code` natively (the Claude Code path is
  unchanged), and cursor/opencode/cline/devin because they read `.claude/skills/` directly; the
  printed report states what that shared file cannot carry for a foreign reader (`allowed-tools` is
  a Claude-specific key those runtimes ignore, warned per affected skill). Where the runtime cannot
  see the canonical copy it EMITS a translated copy: codex-cli and antigravity share one
  `.agents/skills/<name>/SKILL.md` emission, each file stamped with a provenance header —
  hand-copying skill files between layouts is unsupported, because a stale duplicate silently
  winning over the canonical copy is the failure mode the installer exists to prevent; re-run it to
  update (a file the installer did not emit is never overwritten — the install fails loudly
  instead). All seven skills are model-invocable; the three that take durable or external action
  confirm before it: `/ship` **stops before any external post**, and `/setup` and `/skillify`
  **stop before writing committed config or a new skill**, via an in-body HARD HALT — an instruction
  the agent follows on every runtime, stated plainly as a convention rather than a mechanical block
  (unlike the Claude-only `disable-model-invocation` frontmatter flag they used to carry, which only
  Claude Code enforced). That flag remains supported (and is emitted with a topmost warning block on
  foreign runtimes) for any future skill that must never be model-invoked at all; no skill ships
  gated today. Every other metadata loss is recorded per
  runtime in `adapters/runtime/<name>.md` § Metadata mapping. The
  `qc-reviewer` agent definition is emitted wherever subagents are user-definable
  (`.codex/agents/*.toml`; markdown for cursor/devin/antigravity); where they are not (cline) or
  the definition path is undocumented (opencode), the report says so. `--global` emits into the
  runtime's declared per-user skills root and REFUSES where that root is unknown (antigravity —
  its documented sources disagree) rather than guessing a path. The install also wires the
  **DB-write guard** where the runtime documents a home for it — `.cursor/hooks.json` (with
  `failClosed: true`, required configuration), `.agents/hooks.json` for antigravity, a
  throw-to-deny plugin under `.opencode/plugins/` — all fronting one scanner
  (`bin/sql_scan.py`) through `bin/hook_shim.py`. Runtimes with no `ask` tier get the
  `high_risk` policy as **deny-with-escape** (the deny names a one-shot re-approval), and the
  report says so at install time; where even the hooks-config location is undocumented
  (codex-cli, devin) the installer prints the manual wiring line instead of guessing. What is
  ENFORCEMENT (proven — the native Claude hooks) vs WIRED (emitted, live confirmation owed) vs
  GUIDANCE vs UNKNOWN per runtime × per hook is stated in the rendered
  `AGENTS.md` enforcement table (and emitted into `.clinerules/` for cline). The MCP transport,
  which no shell hook can see, gets its own per-policy posture table right below that one:
  enforcement moves into the tool's own permission controls, and **NATIVE (tool-side)** is
  claimable only after a warehouse adapter's read-only posture probe has verified the grant set
  under its written comparison rule (outcome recorded in gitignored
  `.claude/config/posture.local.yaml`).

**`init` is a file copy, not a working setup.** It deliberately writes no `stack.yaml` and no
`AGENTS.md` — `/setup` renders both from evidence in your repo, and `/setup` runs in Claude Code.
On another harness you get the skill files (translated by `install` where needed) but still have to
render the config yourself. A harness-agnostic setup path is on the [roadmap](../ROADMAP.md), not
shipped — don't read this section as "Ticketwright runs anywhere today."

## Publishing

CI runs the full self-test on every push; PyPI publishing is OIDC Trusted Publishing (no stored
tokens) — see [docs/pypi-setup.md](pypi-setup.md).
