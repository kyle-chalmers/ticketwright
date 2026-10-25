---
name: setup
description: Set up Ticketwright in a repo — detect your tools, interview in rounds (the last two skippable, each skip labeled with its cost), write the config, scaffold folders. Team modes configure the repo ((none), tool <tracker|warehouse|chat|docstore|meetings|vcs>, role, team, policies); person modes configure one person (--teammate, --voice, viewer). Also adopts existing repos.
---

<!-- emitted by ticketwright install v4.2.0 — do not hand-edit; re-run `ticketwright install --runtime antigravity` to update. -->

# /setup

> **Why this skill spells out a kit path while everything else calls `bin/tw`:** `/setup` is the
> bootstrapper. On a plugin install the project has no `bin/` until **step 5b** of Phase 3 puts one
> there, so it cannot resolve assets through the launcher it is about to install.
>
> **This exemption covers this file's body and nothing else.** The runtime substitutes the exact
> token `${CLAUDE_PLUGIN_ROOT}` into a SKILL.md body at skill launch, so the form
> `TW_KIT="${CLAUDE_PLUGIN_ROOT}"; <cmd> "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/..."`
> works *here*. It does **not** work in `scaffold.md`, `teammate.md` or `voice.md`: those are opened
> with Read, which returns raw bytes, so the token arrives verbatim, expands to empty, and silently
> points every path at `/…`. Those files use the project launcher like the rest of the kit.
>
> Never write the one-expansion `${CLAUDE_PLUGIN_ROOT:-...}` anywhere. It matches no token, so it
> reaches the shell with the variable unset on every install shape — the bug that broke every
> documented `bin/` command for months.

One skill, three jobs: **configure a repo** (run once), **add a tool later** (`/setup tool chat`),
and **onboard a person** (`/setup --teammate`). Detect first, ask last — detection produces the
facts a question depends on before that question is asked. What earns a question is decided by one
rule, not a count: **ask when a wrong or absent value would still yield a confident-looking
output; leave a commented default when it fails loudly at `verify_stack.sh` or on first use**
(see [interview.md](interview.md)). Never promise a question count.

Every mode sits on one scope axis. **TEAM-scoped** modes write the team's committed config: the
default repo-configuration mode, `tool <tracker|warehouse|chat|docstore|meetings|vcs>`, and the round re-runs
`role` / `team` / `policies`. **PERSON-scoped** modes write
one person's own config: `--teammate` (the per-person flow), `--voice`, and `viewer`. The axis is
*who the config is about*, not committed-vs-local — `--voice` is person-scoped yet writes a
committed file.

> **THE SCOPE INVARIANT — a team mode may declare that a person EXISTS. Only that person's own
> flow may declare who they are or how their machine connects.**
>
> Concretely: a team mode may create an identity-free tier-2 placeholder for a teammate — the file
> `people/<id>.yaml` (the filename is the id) holding a `display_name:` and nothing more. It must
> NEVER write another person's `identities:` list (the routing-critical field `whoami` matches
> on), never a voice-profile reference (what makes `/ship` speak as them), and never any tier-3
> value (their machine — which the person running team setup is not sitting at). Where a
> placeholder and that person's own flow disagree about them, the person's own flow wins. And be
> honest about what a placeholder does NOT buy: an identity-free stub still returns `miss` from
> `whoami`, because resolution requires an identity-map hit. Its value is narrower — a
> team-visible roster, a way to tell "this repo just upgraded" from "this person is new", and
> named candidates for the bind interview to offer on a miss.
>
> The same line protects the team file: `.claude/config/stack.yaml` is COMMITTED and SHARED, so it
> may only ever receive TIER-1 values — which tool fills each slot, which data the team reads, the
> policies, the ticket conventions. A detected MACHINE-LOCAL value — a named profile or connection
> from a tool's own local config file, a home-directory mount path — must NEVER be written here:
> it would hand every teammate one person's machine. Those belong in
> `.claude/config/connections.local.yaml` (tier 3, gitignored); a person's portable settings
> belong in `people/<id>.yaml` (tier 2). Where a verify command needs a personal value, write the
> `{token}` and leave the value to tier 3 — each adapter declares which of its keys are personal
> in its `user_keys:` frontmatter. `bash bin/verify_stack.sh` warns when a machine-local value is
> found in committed config.

> **THE MODEL-INVOCATION CONFIRM GATE — `/setup` is model-invocable, in every mode.** When the
> model reaches for `/setup` on its own initiative (the user did not explicitly invoke it), it must,
> in EVERY mode — default, `tool`, `role`, `team`, `policies`, `--teammate`, `--voice`, `viewer`,
> adoption, and Bootstrap — print what it is about to write and **stop for the user's explicit
> confirmation before writing ANY file.** And regardless of who invoked it, confirm before writing or
> changing **committed team config** (`.claude/config/stack.yaml`, `AGENTS.md`, `CLAUDE.md`,
> `.claude/settings.json`, `MIGRATION.md`) or seeding **another person's `people/<id>.yaml`**. An
> explicit user invocation is its own authorization for that mode's own scoped writes (a `viewer` run
> the user asked for may write its gitignored file; a person's own `--teammate` run may write their
> own tier-2/tier-3 files) — a run the model started is not. This gate is an instruction the agent
> follows, **not** a mechanical block: no runtime enforces it, which is why it is written here where
> the agent reads it, and why the default path's Phase 3 prints the specifics.

## How setup talks to the person: every mode
The person may know nothing about Ticketwright, and may not be a programmer. Trust comes from saying
plainly what is about to happen and why, before it happens.

1. **Show the map first** (default mode), before the first probe. Use this block, in these words:
   <!-- ticketwright:user-facing:begin -->
   Setup has four steps:
   1. **Check this machine.** I look at what's installed. No questions, unless this folder isn't a git repository yet (then I ask before starting one).
   2. **Your work.** A few questions about how work reaches your team, where your data lives, and how you share results. Each one says why it's asked.
   3. **Review the plan.** I show every file I'd create. Nothing is written until you say yes.
   4. **Write and check.** I create the files, check that each tool connects, and tell you anything left to finish.
   You can stop at any point. Your team's settings aren't written until you say yes in step 3.
   <!-- ticketwright:user-facing:end -->
   The other modes open with one line instead: what this run changes, and whether it asks anything.
2. **Open and close every step with one line each.** Open: what this step does and whether it asks
   anything. Close: what got done, and what comes next.
3. **Every question explains itself.** One line on what it decides and why it matters; each option
   says what choosing it changes. A detected value is the recommended option (first, marked
   recommended, with where it came from), never the answer: the person still picks.
4. **Ask with the runtime's own question tool when it has one.** Read the runtime's capabilities:
   `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; python3 "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/kit_paths.py" --json`
   - `capabilities.structured_questions` is `yes` and `capabilities.question_tool` is not `none` →
     ask with that tool, within `capabilities.question_limits` (when that says `unknown`: one
     question per call, at most four options). Group up to the limit only questions that do not
     depend on each other's answers; ask a dependent question after the one it depends on.
   - Otherwise (`no` / `unknown`) → ask in chat as a short numbered list, **one question at a
     time**, and wait for an explicit answer before the next. A detected value is still only a
     recommendation.
   The question content is the same either way; only how it is shown changes. This skill never
   names a runtime's tool itself, the runtime's own adapter (`adapters/runtime/<name>.md`) does.
   A question tool is not available inside a subagent, so an interview never runs in one.
5. **Option rules** (both presentations):
   - Options come from detection, from the person's own words, or from the fixed choices a question
     defines. **Never invent a value** (a project key, a folder, a dataset, a channel) and offer it
     as if it existed. A typed value that detection can check is checked before it is written.
   - Offer **"None / we don't have one"** whenever absence is a real answer.
   - Use **multi-select** whenever more than one answer can be true, and add **"All of these"**
     when a multi-select has three or more options.
   - More real options than fit: show the most likely first plus a **"Show more"** option that
     pages through the rest: when it is picked, ask a follow-up question listing the next options
     (the same multi-select, with what was already picked carried over), never "type them in
     Other". "None / we don't have one" stays on the first page, never behind "Show more". Never move a detected option into the question's wording instead
     ("Postgres: type it in Other"); that hides it. Free text is always possible for a value not
     listed (the question tool's own "Other", or "or type your own" in prose).
   - A question about which tool the team uses offers every tool the kit has setup notes for in
     that slot, detected or not. Detected ones come first with what was found; an undetected one
     is labeled "not connected here yet", and choosing it adds a connect-it item to the list of
     things to finish. Never make the person type the name of a common tool the kit supports.
6. **Talk about the work, not the kit.** Questions use the person's words: tickets, data, results,
   files, the team. "Tool slot", "target", "tier", "seam" and "adapter" do not appear in a question.
   When a kit limit shapes the answer, configure around it and say in one line of the plan what was
   set up and why, never hand the person the limit as a choice to make.
7. **When the runtime refuses a command** (a sandbox that blocks creating `.git`, a credential
   store it cannot write), do not route around it: give the person the exact command to run in
   their own terminal, say what it does in one line, and wait for them to say it is done. And never
   edit the kit's own files (its setup notes, templates or scripts) during setup: everything this
   repository needs, including a connector's exact name, goes in `stack.yaml` or the machine file.
   When a connector's tools are named differently from what its setup notes expect (another
   agent's version of the same connector, say), do not rewrite the notes to match: record that
   tool as a thing to finish, naming the tool names you can see, so the mismatch is fixed once in
   the kit instead of silently in one repository.
8. **Privacy while detecting.** Setup never reads message bodies, meeting notes or file contents.
   Listing names inside someone's own space (their drive's folders, their projects) is fine after
   asking, names only. Suggestions from past usage are opt-in and counts-only
   ([interview.md](interview.md) § Suggestions from past usage).
9. **End on a named state** (Phase 4, step 8): **"Ready for your first ticket"**, or **"Ready, with
   N things to finish"** followed by each item and the command that finishes it.

## Start here, in the default mode: show the map before anything else
The very first thing a default-mode run outputs is the four-step map in "How setup talks to the
person" above, word for word, before the launcher command below, before the repository check and
before any question. A run that opens with a command or a question has skipped the one thing that
tells the person what setup is about to do. (Other modes open with their one line instead.)

## Ensure the launcher — run this FIRST in every mode, before opening any reference file
(After the map, in the default mode. When the folder is not a git repository yet, ask Phase 1's
repository question first and run this block once the repository exists, so a person who stops
there is left with nothing copied.)
Every reference file (`scaffold.md`, `teammate.md`, `voice.md`) and every rendered artifact invokes
kit scripts as `bash "$(git rev-parse --show-toplevel)/bin/tw" <script>`. That resolves only if the
project has the launcher. **This file's body is the one place the plugin token is substituted**, so
this is the one place that can install it. Idempotent — run it every time:

```bash
if [ ! -f "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" ]; then
  TW_KIT="${CLAUDE_PLUGIN_ROOT}"; K="${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
  mkdir -p bin && cp "$K/bin/tw" "$K/bin/kit_paths.py" bin/ && chmod +x bin/tw
fi
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit
```

**Why this is not only a Track-1 concern:** a teammate joining a repo configured by an earlier
Ticketwright finds no committed launcher, so without this step their very first `--teammate` command
fails — the same "No such file or directory" this release exists to end, arriving through a
different door. Mention the two new files when you list what to commit.

The final line must print a kit path. **If it instead says `cannot locate the ticketwright kit`, the
copy succeeded and the RESOLUTION failed** — do not read it as a bad copy. On a plugin install
`kit_paths.py` finds the kit through this repo's row in `~/.claude/plugins/installed_plugins.json`,
so the usual cause is that the plugin is not installed *for this repo at project scope*: run the
doctor's `repo_install` check (`bash "$(git rev-parse --show-toplevel)/bin/tw" plugin_doctor.py`) and
follow its fix, then re-run the line above. Stop either way rather than continuing into step 6,
whose commands all route through this launcher.

## Mode: `--teammate` — the per-person flow (person-scoped)
Follow [teammate.md](teammate.md): resolve WHO this is (`whoami`, binding on a miss) → install
checklist → per-tool auth walk-through → detect *their* machine and write their machine file →
verify, bound to the team's expected target (each MCP-transport slot also gets its permission
posture probed, compared, and recorded) → read-the-map → guided first-ticket dry run. Requires
an existing `stack.yaml`. Entered automatically when the repo is configured but the person is
unrecognized (Phase 1 routing below); `--teammate` stays the explicit re-run. Offer the `--voice`
step at the end so the new person's comms sound like them from their first ship.

## Mode: `--voice` — build or refine a person's comms voice profile (person-scoped)
Follow [voice.md](voice.md): identify the person → wire their `people/<id>.yaml` → render the seed
from `templates/voice-profile.md.tmpl` → interview (≤5 questions) → optionally learn from short
approved exemplars → save. `/ship` then drafts in that voice, within the hard comms rails. Requires
an existing `stack.yaml`. (This is a first-class mode, **not** a tool slot — `voice` is never a
`seams.*` entry.)

## Mode: `tool <tracker|warehouse|chat|docstore|meetings|vcs>` — add one tool slot to the team config (team-wide)
E.g. `/setup tool chat`. Detect candidates for just that tool slot, then run only that slot's
interview round from [interview.md](interview.md) (round 2 for tracker, round 3 for warehouse,
round 4 for chat/docstore, round 2's meetings follow-up for meetings, round 4's code-host question for vcs, including the slot's
adapter-required keys), add the block to committed `stack.yaml`, verify it, and re-render
`AGENTS.md`. Nothing else changes.
**`tracker` and `vcs` are re-entry slots too, and they are the ones people need most.** The
interview always fills them, so they are never *absent* — but they are routinely filled with the
WRONG transport detail, and until this mode accepted them there was no documented command that
repaired one. The case that forced this: a person on an MCP-only tracker whose `verify` names a CLI
they do not have, so `verify_stack` reports a healthy tracker as unreachable. `/setup tool tracker`
re-runs that slot's questions — transport, `mcp:`, `cli:`, and the read-only `verify` — against the
existing config, edit-never-overwrite. Same for `vcs`.
**Deprecated spellings:** the old `/setup chat` / `/setup docstore` / `/setup warehouse` (without
`tool`) keep working for one release — accept them, print "Note: `/setup chat` is now
`/setup tool chat`; the old spelling goes away in the next release." (substituting the slot
named), and continue as normal. The old spelling collided with person-scoped `viewer` in one
syntax while meaning the opposite scope, which is why the split exists.

## Modes: `role` · `team` · `policies` — re-run one interview round (team-wide)
The re-entry commands for what the repo interview covers outside the tool slots — each re-runs
exactly one round of [interview.md](interview.md) against the existing config, edit-never-overwrite:
- **`/setup role`** re-runs round 5: `project.role` + `project.domain` (one question) and
  `project.analysis_tools`, then re-renders `AGENTS.md`.
- **`/setup team`** re-runs round 1's roster question: who else is on the team, writing one
  identity-free `people/<id>.yaml` placeholder per new person named (files, never folders), under
  the scope invariant above.
- **`/setup policies`** re-runs round 6: `db_write_requires_approval` and `human_review_handoff`.
Each also clears its round's `# TODO(setup)` line from `stack.yaml` once the answers are written.
These exist so a skipped round is a deferral, not a dead end — every skip's punch-list entry names
the command that finishes it. Requires an existing `stack.yaml`.

## Mode: `viewer` — which apps open *your* deliverables (person-scoped)
A re-run entry point, kept on purpose: the primary path is the just-in-time interview at the
`/review` gate, which asks these same questions the first time a handoff needs them. Which app
opens a `.sql` is a personal choice, so it lives in a gitignored per-user file and each teammate
answers for themselves — this mode never touches `stack.yaml`. Ask:

1. Which application should open `.sql` files? (or *none*)
2. Which should open `.csv` files? (or *none*)
3. This repo only, or all your ticket repos?

Then write `.claude/config/viewer.local.yaml` (this repo) or
`${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml` (all repos), copying the shape and the
platform-matching `open_cmd`/`reveal_cmd` from `.claude/config/viewer.example.yaml` and pointing
`adapter:` at the `adapters/viewer/` file for this OS. "None / don't ask again" ⇒ `enabled: false`.
Confirm with
`!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/handoff.sh" --dry-run <any ticket file>`,
which prints the resolved commands without launching anything. Never commit this file.

## Default mode — configure the repo

(The map was already printed, per "Start here" above. Then the launcher step, then Phase 1.)

### Phase 1: Check this machine (no questions unless the folder is not a repository yet)
Open with the map from "How setup talks to the person" above, then say this step's one line:
"First I'll look at what's installed on this machine. This step asks nothing unless this folder isn't
a git repository yet."

0. **Preflight — the ways a run is doomed before it starts.** Both probes are read-only and cheap;
   run them before anything else.
   - **Is this a repository?** `!git rev-parse --show-toplevel`: a non-zero exit means there is
     no `.git` here. Ticketwright branches, commits and opens pull requests, so it needs one. Do
     **not** halt: ask, with these three options (the first is the recommended one only when the
     folder is empty apart from the plugin's own `.claude/settings.json`):
     1. **Start a new repository here**: "I'll run `git init` in this folder. Nothing is shared
        anywhere until you add a remote."
     2. **I'll clone my team's existing repository**: "Stop here; clone it with
        `git clone <the repository's URL>`, then run `/setup` inside the clone."
     3. **Stop**: nothing is changed.
     On option 1: run `git init`, then ask once whether to connect a remote now. Creating a new
     remote repository (for example on a code host) is an outward-facing action: only on its own
     explicit yes, **private** unless the person says otherwise, and never as part of another
     answer. "Not now" is a fine answer; the first push can come later.
     Keep the ZIP case visible: if the folder name ends in `-main` or holds files but no `.git`
     (files other than the kit's own install, which `ticketwright init` or the plugin put there), say
     "If this folder came from a Download-ZIP button, it has no history to branch from, clone the
     repository instead (`git clone <the repository's URL>`) and run `/setup` there," and offer
     option 2 first.
   - **Is the kit installed and usable here?**
     `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; python3 "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/plugin_doctor.py" --json` — one
     read-only pass over the install prerequisites (it never installs anything, and makes no
     network call). Report **every** finding that is not `ok`, each with its `fix` lines
     **verbatim**: they are exact commands, and a paraphrased command is one nobody can run.
     A `fail` on any of these three is a **halt**, because nothing setup writes reaches the cause:
     - `scope_supported` — the agent CLI is too old to install a plugin for one repo; the fix names
       both the in-session install route and the update command for how it was installed;
     - `repo_install` — nothing is installed for this repository;
     - `install_payload`: the install record points at a directory that does not exist, or the
       payload is missing files setup needs (this is the install-completeness check Phase 4 relies
       on).
     Everything else (`warn`, `unknown`, a global-only install, a stale catalog) is reported and
     the run continues. On a non-plugin install (a vendored kit, a pip install) the install
     checks answer `unknown`: that is the expected answer there, not a failure, so leave those
     out of what you tell the person instead of listing them. If the script is
     absent (an older kit copy), say so in one line and carry on.
   - **`yq`**: needed only by the kit's full self-check (`bin/selftest.sh`), which setup no longer
     runs by default (Phase 4). When `yq_present` is not `ok` on a vendored or edited kit, print the
     platform install command the doctor gives and offer to run it now; on a plugin install, mention
     it once and move on.
   Identity routing is unchanged: it happens at step 4 below.
1. **CLIs and machine facts, in one probe:**
   `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; python3 "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/setup_detect.py" --json`
   reports the command-line tools on PATH, the git facts (repository, branch, origin **host** only,
   default branch and where that answer came from, whether a git name and email are set), the
   synced-drive folders (names and paths of the mount roots, never their contents), Obsidian, and
   the analysis apps installed here. Use its answers; do not re-probe by hand, and never state a
   fact it did not report (a "no synced drive" claim needs this probe's empty `mounts` list behind
   it). If the script is absent (an older kit), fall back to the CLI probe below and say the other
   facts are unknown:
   `!for c in snow acli gh glab bq databricks yq jq git rclone; do command -v $c >/dev/null && echo "✓ $c" || echo "– $c"; done`
   **No git name or email?** When the probe reports `name_set` or `email_set` false, ask before
   round 1 (they are what identity and every commit use): "Git doesn't know your name or email on
   this machine yet. What should your commits show?", offering the name and address detection saw
   elsewhere plus free text. Set them for this repository only (`git config user.name "<name>"`,
   `git config user.email "<email>"`), the same fix [teammate.md](teammate.md) step 0.5 uses.
2. **MCP servers** connected this session (tracker / chat / warehouse / docs / meeting servers):
   the one thing a shell probe cannot see. List them by the name the person would recognize.
3. **What the facts mean (probes, not questions).**
   - **Origin:** `origin_public_host` decides the roster privacy warning (phrased "if this repo is
     public", never "it is", visibility cannot be checked offline), and the origin host is the
     VCS answer round 4 confirms instead of asking. The default branch comes from
     `refs/remotes/origin/HEAD` when there is one; on a repo nothing has been pushed to yet the probe
     reports the current branch and says so, confirm it rather than stating it.
   - **Obsidian:** never a question; `graph_notes`/`graph_config` already default correctly; this
     only decides which one-liner the Phase-4 report prints (step 8).
   - **Docstore mount roots:** REPORT-ONLY. A cloud-storage mount root is a machine-local
     (tier-3) value: display what was found and route it to the person flow
     (`.claude/config/connections.local.yaml`, [teammate.md](teammate.md) steps 3–4). Writing it
     into committed `stack.yaml` is exactly the leak the tier split exists to prevent.
     Found **no** mount and the configured docstore expects one? Do not ask — print the guide as its
     full GitHub URL, <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>, which covers installing the mount per OS and the mountless `rclone`
     adapter. Never a bare `docs/` path: `docs/` does not ship in the PyPI package.
   - **Names only, here too:** report profile/connection/mount *names* and paths — never echo a
     tool config file's contents anywhere; those files can hold plaintext secrets.
   **After step 4 below, close this step with this list**: print it as a bulleted list, one line
   per area, filled in with what the probes found. Not a one-sentence summary ("I've mapped out your
   tools: …"), and not a raw tool inventory:
   ```text
   Here's what I found on this machine:
   - Work comes from: <the trackers and request sources found>
   - Data lives in: <the warehouses found, and whether each is signed in>
   - Results go out through: <the chat and email connections found>
   - Files are kept in: <synced drive folders found, or none>
   Next, a few questions about how your team works.
   ```
4. **Existing state — five routes, checked in order.** First write the boundary down: the ADOPT
   triggers are evidence of prior ticket work — ticket-looking folders, an existing index, or
   custom `.claude/commands` / `.claude/skills`. A repo whose only Ticketwright trace is
   `.claude/settings.json` (plugin enablement) is **fresh** — enablement is how the kit arrives,
   not evidence of prior work.
   1. `stack.yaml` exists but there is **no `AGENTS.md`** → a Phase-3 halt left half-done (the config
      was written or hand-created; the scaffold never ran). Checked FIRST, before the Bootstrap
      route, because a hand-created recovery has no `people/` yet either. Write whatever of step 5
      is still missing (`.claude/settings.json`, and the round-1 machine pin if it was refused),
      then resume at step 6.
   2. `stack.yaml` exists but there is **no `people/` directory at all** → this repo predates
      per-person config: run the **Bootstrap** below, then return to what the person asked for.
   3. `stack.yaml` exists (and `people/` too) → resolve who is at the keyboard:
      `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; python3 "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/whoami.py" --root . --json`
      - `miss` → this is a **teammate new to this repo**: switch to [teammate.md](teammate.md)
        automatically. Editing the team's shared config must never be a new cloner's first
        offered action. (`--teammate` stays the explicit re-run.)
      - `ambiguous` → ask which of the named candidates they are (per the question rules above), bind with
        `whoami.py --bind <id>`, then re-run the check.
      - `conflict` → surface whoami's warning verbatim and resolve the identity first — fix the
        stale side (the machine pin, or this repo's git config; step 0 of
        [teammate.md](teammate.md) walks it) before offering any team-config edit.
      - `resolved` → offer to **edit** the existing config; never overwrite it (the half-done case is
        route 1 above, so it never reaches this branch).
   4. No `stack.yaml`, and the adopt triggers above are present → an **existing repo**: switch to
      [adopt.md](adopt.md) (map onto what's there; write MIGRATION.md).
   5. None of the above → a **fresh repo**: continue to Phase 2.

### Bootstrap — a configured repo that predates `people/`
Immediately after an upgrade, `people/<id>.yaml` exists for nobody, so `whoami` returns `miss` for
the whole team — including whoever configured the repo — and the teammate route above would treat
every existing contributor as brand new. Seed the roster from what the repo already knows, and
confirm rather than onboard:
1. **Collect candidates** from `project.assignee_dir`, any legacy `project.voice_profiles.map`
   entries, existing `tickets/<owner>/` folders, and recent `git log` authors. Author names and
   emails are DISPLAY HINTS for the confirmation only — choosing an id is each person's own job.
2. **Confirm with the person:** "This repo has work by <display hints>. Which of these are current
   teammates — and which one is you?" An id must be a plain identifier (letters, digits, dot,
   dash, underscore): it names `people/<id>.yaml` and `tickets/<id>/`.
3. **For each confirmed teammate who is not present**, write the identity-free placeholder the
   scope invariant allows: `people/<id>.yaml` containing `display_name:` only — never their
   `identities:`, voice, or any machine value. Say plainly that a placeholder still resolves as
   `miss` until that person's own first run binds their identities.
4. **The person at the keyboard** is the one answer available now: run
   `whoami.py --bind <their id>` (their own answer is authority) and show the one-line
   "Working as …" confirmation.
This is what distinguishes "this repo just upgraded" (seed, confirm, carry on with what they
asked for) from "this person is new" (the teammate route above).

### Phase 2: Your work (questions; detected answers recommended, defaults visible)
Open with one line: "Now a few questions about how your team works. Each says why it's asked, and
nothing is written yet." Then run the interview in [interview.md](interview.md), following the
question rules in "How setup talks to the person" above. Six rounds, cut by whether skipping is
survivable: **rounds 1–4 always run** (who · how work reaches you, where the one intake question
covers the tracker, email, meeting notes and chat, and writes `project.intake` · where the data
lives · how results are shared and where files are kept), **rounds 5–6 are individually skippable** (how you work · house rules), the skip
offered at that round's header and labeled with its cost — never as a global "take defaults for
the rest". What earns a question is the rule at the top of this file, not a count. Every chosen
adapter's required keys are asked; "I'll fill it in later" writes the key as a `# TODO` and keeps
going — `verify_stack.sh` names any unset required key on every run (a warning, not a failure),
so a deferred key is reported rather than lost. A skipped round is written down twice — a
`# TODO(setup)` line in `stack.yaml` and a punch-list entry in the Phase-4 report — each naming
its re-entry command (`/setup role` for round 5, `/setup policies` for round 6; later,
`/setup team` adds teammates and `/setup tool <tracker|warehouse|chat|docstore|meetings|vcs>` adds a declined slot).
Everything the interview does not ask ships as a **commented default** the user can edit later:
`default_epic`, word limits, the other eight policies — each with its "when to change this" note.

**Check the draft before showing the plan.** Compose the draft `stack.yaml` and the draft machine
file (`connections.local.yaml`: the person pin plus any profile, connection or mount values) in the
session's scratch space, never in the repo, and run:
`!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/setup_draft_check.sh" <draft stack.yaml> <draft connections.local.yaml>`
It copies both into a throwaway repository and runs the tool check there without contacting any
tool, so a refused character in a folder name, a missing destination or an unset required key shows
up now, while it is still a question, instead of after the files are written. For each problem it
reports, go back to the question that produced the value and ask again in plain words (for example:
"Folder names can't contain `&`. Use 'Sales and Ops Tickets' instead?"). Unreachable tools are not
problems here: nothing is contacted yet. Phase 3 starts only when the draft check has no ✗ lines
other than ones the person chose to leave for later.

### Phase 3 — Write & scaffold (HARD HALT → confirm the plan before the first write)
This is the default path's instance of the **model-invocation confirm gate** above — the fresh-repo
path writes the most (committed team config + scaffold), so its plan is the most detailed. **Print
the resolved setup plan, then stop and wait for the user — nothing is written until they confirm.**
The human authorizes THE PLAN, not merely the idea of setup. Open with one line: "Here's everything
I'd set up. Nothing is written until you say yes." The plan names:
- **what they told you → what gets configured**, as a short table in their words (for example
  "You share results by email and Slack → both are set up; you pick who gets each result when you
  ship it"), with any tool left for later and the command that adds it;
- the result of the draft check (clean, or the items the person chose to finish later);
- every file this phase will create **or change** — `.claude/config/stack.yaml`, `AGENTS.md`,
  `CLAUDE.md`, the human-facing `README.md` (or `README.ticketwright.md` if a README already
  exists — never overwritten), `.claude/settings.json`, `.gitignore`, the AI-layer index, the
  seeded ticket index;
- on a repo that already has config, exactly *what* would change — `role`/`team`/`policies` are
  **edit-never-overwrite** (see above), so name the specific keys being edited and never present a
  whole-file overwrite as the plan.

Only on explicit confirmation, execute — **source of truth first, derived files after**:
5. Write `.claude/config/stack.yaml` per `stack.schema.md` (chosen tool slots live; optional ones as
   commented blocks; the 10 policies with a one-line "when to change this" comment each) as the
   FIRST write, then `.claude/settings.json` per [scaffold.md](scaffold.md) (hooks — omitted on a
   plugin install — + read-only CLI allows). Step 6 renders FROM `stack.yaml`, and some runtimes
   refuse every write under `.claude/` in a non-interactive run — a categorical path guard (the
   refusal calls the file "sensitive") that no allow rule lifts. **If the `stack.yaml` write is
   refused, STOP: scaffold nothing else** — an `AGENTS.md` describing a stack that does not exist on
   disk is worse than an empty repo. Report the refusal text verbatim; that the runtime's `.claude/`
   guard is the cause, not a Ticketwright error; the two ways forward — approve the prompt in an
   interactive session, or create the `.claude/` files by hand from the printed plan (print their
   full contents on request); and that everything else is written on the next confirm. Never route
   around the guard.
5b. **Confirm the launcher is in the project, and add it to what gets committed.** The
   "Ensure the launcher" preflight above already installed `bin/tw` + `bin/kit_paths.py` (it runs
   first in every mode and is idempotent — do NOT re-run a bare `cp` here: on a vendored or `init`
   install the kit root IS the project root, so `cp "$K/bin/tw" bin/` is a file onto itself, which
   exits 1 and would halt the scaffold on the one install shape that already worked). Just verify
   and carry both files into step 9's commit list:

   ```bash
   bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit
   ```

   *Check:* that prints a kit path. If it errors, stop — step 6 renders commands that all route
   through this launcher.
6. Scaffold the rest per [scaffold.md](scaffold.md): render `AGENTS.md` (+ role focus) and a one-line
   `CLAUDE.md` (`@AGENTS.md`, so Claude Code auto-loads the rules), the human-facing `README.md`
   (rendered to `README.ticketwright.md` instead if a README already exists — never overwritten),
   folders, `.gitignore` (deliverable CSVs committed by default; PII opts out via `*.private.csv` / a
   `private/` subfolder), the AI-layer index, and the seeded ticket index.
   Note that the round-1 `whoami --bind` machine pin (`.claude/config/connections.local.yaml`) sits
   under the same guard: in a headless run that refusal lands during the interview, before this
   halt — record it and list the pin with the deferred `.claude/` files rather than stopping there.

### Phase 4 — Verify & hand off
7. **Check that each tool connects, and say which check is which.** Open with one line: "Now I'll
   check that each of your tools answers."
   - **The kit itself was already checked** in Phase 1: the doctor's `install_payload` confirmed the
     installed plugin has every file setup and the first ticket open. That is a completeness check,
     not a content check; the released kit is tested before it ships. The kit's full self-check,
     `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/selftest.sh"`
     (1,400+ assertions, several minutes, needs `yq`), is **not** run by default. Offer it only on
     a vendored or edited kit; when it runs, run it in the background or with a raised timeout and
     judge it by its exit code, never by whether the tail of its output looks green.
   - `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/verify_stack.sh" .claude/config/stack.yaml`
     — **your repo's stack** reachability (pass the repo stack path explicitly so it's unambiguous
     which config was checked). An unreachable tool slot is **not** fatal at setup time; print its
     adapter's auth notes as the fix.
   - **…and the posture pointers that check prints (advisory, never blocking):** verify_stack
     emits a `▸ <slot> ... connects through MCP` line (`also connects` when the slot has a terminal route too) for every tool slot whose resolved transport includes MCP,
     naming that adapter's "Permission posture (MCP)" section. For each pointer: run the read-only
     probe that `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" adapter_surface.py --adapter <path> --probe`
     prints (the probe written for this agent's tool names), apply the adapter's comparison rule, and record the outcome in
     the report AND in the gitignored record file `.claude/config/posture.local.yaml`
     ([teammate.md](teammate.md) step 5 defines the three outcome words and the record shape;
     `matches` is writable only when the adapter's comparison rule held). Chat/tracker slots
     always record the introspection cap — a connector's grant set cannot be read from inside a
     session — with a pointer to where a human confirms the grant. A posture the policy does not
     expect is reported and recorded, not a stop.
8. **Report, ending on a named state.** Lead with the state: **"Ready for your first ticket"** when
   every tool connected (or was deliberately left for later), or **"Ready, with N things to
   finish"** followed by each item, in plain words, with the exact command or step that finishes
   it. Then say which check was which (the install check = the kit's files; the tool check = *your*
   tools), the chosen stack, files written, and any `# TODO` keys. Include, when they apply:
   - **The punch list** — one entry per skipped round, each naming its re-entry command
     (`/setup role` for round 5, `/setup policies` for round 6). Deferring must be trackable;
     "took defaults" must never be indistinguishable from "chose".
   - **`project.assignee_dir`, in one line — what the key is for, not a warning.** It is the
     last-resort owner subdir under `tickets/` for a repo with no `people/` roster. Once a roster
     exists, the owner of new work is whoever `whoami` resolves, and a person it does not
     recognize is a stop (`/setup --teammate`) rather than a fall-back to this key — so say that,
     and never describe it as something setup is refusing to touch.
   - **Email, when round 4 set it up:** say plainly that email goes out as **drafts only**, from
     the sending identity chosen in round 4, to whoever is chosen for each result at `/ship`, and
     that nothing sends until the person says send. A repo still carrying an older commented
     `seams.chat.targets.email` block (configured but not yet activated) gets interview.md's offer
     to activate it as a per-ticket target; the standing-destination alternative is
     `stack.example.multi-audience.yaml`.
   - **Obsidian — one line, never a question.** Detected: "this repo already opens as an Obsidian
     vault — the graph layer is in `tickets/graph/` + `tickets/objects/`." Not detected: the graph
     layer still renders; print the guide as its full GitHub URL —
     <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/obsidian.md> — never as a bare
     `docs/obsidian.md` path, because `docs/` does not ship in the PyPI package, so on a pip
     install that relative path points at nothing.
   Then the next step — `/ticket <id>` to start work, or `/setup --teammate` for a new person.
9. **Offer to commit the scaffold, even when some items are still to finish** (a pending login or a
   tracker project someone still has to create is not a reason to leave the scaffold uncommitted). What setup just wrote (`.claude/config/stack.yaml`, `AGENTS.md`,
   `CLAUDE.md`, `.claude/settings.json`, `.gitignore`, `documentation/AI_LAYER_INDEX.md`, the seeded `tickets/`
   index, **`bin/tw` + `bin/kit_paths.py`** — plus, on a vendored install, the kit itself) is untracked;
   **the launcher pair is not optional**: every command in `AGENTS.md` and every reference file routes
   through it, so a clone without those two files gives the next teammate "No such file or directory"
   on their first command; if it isn't committed, a later
   ticket PR references rules/adapters absent from the repo's history. Offer a commit (e.g.
   `chore: initialize ticketwright workspace`). First flag that `stack.yaml` may hold internal
   identifiers (tracker site, warehouse project/dataset) — config, not secrets, but worth a glance
   before committing to a public repo. On a remote created empty (no default branch yet), this
   first push seeds `main` directly — there is nothing to open a PR against — and the PR flow
   starts with the next change; say so rather than colliding with a never-push-to-main rule.
