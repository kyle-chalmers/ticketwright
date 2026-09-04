---
name: setup
description: Set up Ticketwright in a repo — detect your tools, interview in rounds (the last two skippable, each skip labeled with its cost), write the config, scaffold folders. Team modes configure the repo ((none), tool <tracker|warehouse|chat|docstore|meetings|vcs>, role, team, policies); person modes configure one person (--teammate, --voice, viewer). Also adopts existing repos.
---

<!-- emitted by ticketwright install v4.0.3 — do not hand-edit; re-run `ticketwright install --runtime codex-cli` to update. -->

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

**Every interview in this skill is prose — team modes included.** State questions as prose the
person answers in chat: runtimes that render structured options show chips, every other runtime
shows a numbered list, and the interview means the same thing everywhere. Never author a question
as a structured tool-call payload.

## Ensure the launcher — run this FIRST in every mode, before opening any reference file
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
round 4 for chat/docstore/meetings, round 4's VCS question for vcs — including the slot's
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

### Phase 1 — Detect (no questions yet)
0. **Preflight — the ways a run is doomed before it starts.** Both probes are read-only and cheap;
   run them before anything else, because neither failure is fixable by anything this skill writes.
   - **Is this a clone?** `!git rev-parse --show-toplevel` — a non-zero exit means there is no
     repository here. **Halt**, and say why: "There is no `.git` in this folder. If it came from a
     Download-ZIP button (the folder name usually ends in `-main`), Ticketwright cannot branch,
     commit, or open a PR from it, and no config would fix that. Clone the repo instead —
     `git clone <the repository's URL>` — then re-run `/setup` inside the clone."
   - **Is the kit installed and usable here?**
     `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; python3 "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/plugin_doctor.py" --json` — one
     read-only pass over the install prerequisites (it never installs anything, and makes no
     network call). Report **every** finding that is not `ok`, each with its `fix` lines
     **verbatim**: they are exact commands, and a paraphrased command is one nobody can run.
     A `fail` on any of these three is a **halt**, because nothing setup writes reaches the cause:
     - `scope_supported` — the agent CLI is too old to install a plugin for one repo; the fix names
       both the in-session install route and the update command for how it was installed;
     - `repo_install` — nothing is installed for this repository;
     - `install_payload` — the install record points at a directory that does not exist.
     Everything else (`warn`, `unknown`, a global-only install, a stale catalog) is reported and
     the run continues. On a non-plugin install — a vendored kit, a pip install — the install
     checks answer `unknown`: that is the expected answer there, not a failure. If the script is
     absent (an older kit copy), say so in one line and carry on.
   - **`yq`** — when `yq_present` is not `ok`, Phase 4's kit-integrity check cannot run at all.
     Print the platform install command the doctor gives, and **offer to run it now**, while it is
     still cheap — not at the moment the check fails. Say in the same breath what that check costs:
     it runs 1,200+ assertions over several minutes, longer than a typical tool timeout, so give it
     the background or a raised timeout and judge it by its **exit code**, never by whether the
     tail of its output looks green.
   Identity routing is unchanged: it happens at step 4 below.
1. **CLIs:** `!for c in snow acli gh glab bq databricks yq jq git rclone; do command -v $c >/dev/null && echo "✓ $c" || echo "– $c"; done`
2. **MCP servers** connected this session (tracker / chat / warehouse servers).
3. **Repo facts — probes, not questions.**
   - **Origin:** read the `origin` remote URL — one probe, two facts: whether the remote sits on
     a **public code host** (the same offline heuristic `whoami --bind` uses — true visibility
     cannot be checked without a network call, so round 1's roster warning is phrased "if this
     repo is public", never "it is") and the VCS host round 4
     confirms instead of asking. The default branch comes from
     `git symbolic-ref refs/remotes/origin/HEAD` — **not** `git symbolic-ref HEAD`, which reports
     whatever branch happens to be checked out and would misconfigure any setup run from a
     feature branch. On a repo nothing has been pushed to yet that probe exits 128 ("not a
     symbolic ref") — fall back to the current local branch and confirm it in prose; never leave the
     agent to improvise on a failed probe.
   - **Obsidian:** installed or not (e.g. `command -v obsidian`, or the OS application folder).
     Never a question — `graph_notes`/`graph_config` already default correctly; this only decides
     which one-liner the Phase-4 report prints (step 8).
   - **Docstore mount roots:** REPORT-ONLY. A cloud-storage mount root is a machine-local
     (tier-3) value: display what was found and route it to the person flow
     (`.claude/config/connections.local.yaml`, [teammate.md](teammate.md) steps 3–4). Writing it
     into committed `stack.yaml` is exactly the leak the tier split exists to prevent.
     Found **no** mount and the configured docstore expects one? Do not ask — print the guide as its
     full GitHub URL, <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>, which covers installing the mount per OS and the mountless `rclone`
     adapter. Never a bare `docs/` path: `docs/` does not ship in the PyPI package.
   - **Names only, here too:** report profile/connection/mount *names* and paths — never echo a
     tool config file's contents anywhere; those files can hold plaintext secrets.
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
      - `ambiguous` → ask which of the named candidates they are (in prose), bind with
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
2. **Confirm in prose:** "This repo has work by <display hints>. Which of these are current
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

### Phase 2 — Interview, in rounds (detected answers pre-selected, defaults visible)
Run the interview in [interview.md](interview.md). Six rounds, cut by whether skipping is
survivable: **rounds 1–4 always run** (who · where work comes from · where the data lives · where
work goes — round 4's one intake/delivery question covers email *and* whether an AI notetaker
carries work in, which writes `meetings` into `project.intake`), **rounds 5–6 are individually skippable** (how you work · house rules), the skip
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

### Phase 3 — Write & scaffold (HARD HALT → confirm the plan before the first write)
This is the default path's instance of the **model-invocation confirm gate** above — the fresh-repo
path writes the most (committed team config + scaffold), so its plan is the most detailed. **Print
the resolved setup plan, then stop and wait for the user — nothing is written until they confirm.**
The human authorizes THE PLAN, not merely the idea of setup. The plan names:
- the tool slot resolved for each seam (and any left as a commented default);
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
7. **Two distinct checks — keep them labeled as such in the report:**
   - `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/selftest.sh"` — **kit integrity**. It
     validates the plugin's *own bundled example* stacks, **not** your repo's config. A failure here
     is fatal. It runs 1,200+ assertions and takes several minutes — longer than a typical
     tool timeout, so run it in the background or with a raised timeout, and judge it by its exit
     code (non-zero on any failure), not by whether the tail of its output looks green.
   - `!TW_KIT="${CLAUDE_PLUGIN_ROOT}"; bash "${TW_KIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/verify_stack.sh" .claude/config/stack.yaml`
     — **your repo's stack** reachability (pass the repo stack path explicitly so it's unambiguous
     which config was checked). An unreachable tool slot is **not** fatal at setup time; print its
     adapter's auth notes as the fix.
   - **…and the posture pointers that check prints (advisory, never blocking):** verify_stack
     emits a `▸ posture[<slot>]` line for every tool slot whose resolved transport includes MCP,
     naming that adapter's "Permission posture (MCP)" section. For each pointer: run the section's
     read-only probe in-session, apply the adapter's comparison rule, and record the outcome in
     the report AND in the gitignored record file `.claude/config/posture.local.yaml`
     ([teammate.md](teammate.md) step 5 defines the three outcome words and the record shape;
     `matches` is writable only when the adapter's comparison rule held). Chat/tracker slots
     always record the introspection cap — a connector's grant set cannot be read from inside a
     session — with a pointer to where a human confirms the grant. A posture the policy does not
     expect is reported and recorded, not a stop.
8. **Report:** name which check is which (selftest = kit integrity; verify_stack = *your* tool slots), then
   the chosen stack, files written, and any `# TODO` keys. Include, when they apply:
   - **The punch list** — one entry per skipped round, each naming its re-entry command
     (`/setup role` for round 5, `/setup policies` for round 6). Deferring must be trackable;
     "took defaults" must never be indistinguishable from "chose".
   - **`project.assignee_dir`, in one line — what the key is for, not a warning.** It is the
     last-resort owner subdir under `tickets/` for a repo with no `people/` roster. Once a roster
     exists, the owner of new work is whoever `whoami` resolves, and a person it does not
     recognize is a stop (`/setup --teammate`) rather than a fall-back to this key — so say that,
     and never describe it as something setup is refusing to touch.
   - **Email, when round 4 recorded delivery:** say plainly that email is **configured but not
     yet activated** — the commented target block holds the answers, and nothing will send until
     someone deliberately activates it: convert the chat slot to `targets:` form with a declared
     audience on EVERY target (worked example: `stack.example.multi-audience.yaml`; the email
     adapters ship as `adapters/chat/gmail.md` / `adapters/chat/outlook.md`).
   - **Obsidian — one line, never a question.** Detected: "this repo already opens as an Obsidian
     vault — the graph layer is in `tickets/graph/` + `tickets/objects/`." Not detected: the graph
     layer still renders; print the guide as its full GitHub URL —
     <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/obsidian.md> — never as a bare
     `docs/obsidian.md` path, because `docs/` does not ship in the PyPI package, so on a pip
     install that relative path points at nothing.
   Then the next step — `/ticket <id>` to start work, or `/setup --teammate` for a new person.
9. **Offer to commit the scaffold.** What setup just wrote (`.claude/config/stack.yaml`, `AGENTS.md`,
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
