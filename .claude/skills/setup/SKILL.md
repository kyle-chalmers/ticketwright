---
name: setup
description: Set up Ticketwright in a repo — detect your tools, ask at most 5 questions, write the config, scaffold folders. Team modes configure the repo ((none) and tool <chat|docstore|warehouse>); person modes configure one person (--teammate, --voice, viewer). Also adopts existing repos.
argument-hint: "(none) | tool <chat|docstore|warehouse> | viewer | --teammate [name] | --voice [name]"
allowed-tools: [Read, Write, Edit, Bash, Glob, AskUserQuestion]
disable-model-invocation: true
---

# /setup

> **Why this skill still spells out `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}` paths while every
> other skill calls `bin/tw`:** `/setup` is the bootstrapper. On a plugin install the project has
> no `bin/` until this skill puts one there, so it cannot resolve assets through the launcher it
> is about to install. Leave these paths as they are.

One skill, three jobs: **configure a repo** (run once), **add a tool later** (`/setup tool chat`),
and **onboard a person** (`/setup --teammate`). Detect first, ask last: the goal is a working setup
after **at most 5 questions**.

Every mode sits on one scope axis. **TEAM-scoped** modes write the team's committed config: the
default repo-configuration mode and `tool <chat|docstore|warehouse>`. **PERSON-scoped** modes write
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

**Every interview in this skill is prose — team modes included.** State questions as prose the
person answers in chat: runtimes that render structured options show chips, every other runtime
shows a numbered list, and the interview means the same thing everywhere. Never author a question
as a structured tool-call payload.

## Mode: `--teammate` — the per-person flow (person-scoped)
Follow [teammate.md](teammate.md): resolve WHO this is (`whoami`, binding on a miss) → install
checklist → per-tool auth walk-through → detect *their* machine and write their machine file →
verify, bound to the team's expected target → read-the-map → guided first-ticket dry run. Requires
an existing `stack.yaml`. Entered automatically when the repo is configured but the person is
unrecognized (Phase 1 routing below); `--teammate` stays the explicit re-run. Offer the `--voice`
step at the end so the new person's comms sound like them from their first ship.

## Mode: `--voice` — build or refine a person's comms voice profile (person-scoped)
Follow [voice.md](voice.md): identify the person → wire their `people/<id>.yaml` → render the seed
from `templates/voice-profile.md.tmpl` → interview (≤5 questions) → optionally learn from short
approved exemplars → save. `/ship` then drafts in that voice, within the hard comms rails. Requires
an existing `stack.yaml`. (This is a first-class mode, **not** a seam — `voice` is never a
`seams.*` entry.)

## Mode: `tool <chat|docstore|warehouse>` — add one tool slot to the team config (team-wide)
E.g. `/setup tool chat`. Detect candidates for just that tool slot, ask one question, add the
block to committed `stack.yaml`, verify it, and re-render `AGENTS.md`. Nothing else changes.
**Deprecated spellings:** the old `/setup chat` / `/setup docstore` / `/setup warehouse` (without
`tool`) keep working for one release — accept them, print "Note: `/setup chat` is now
`/setup tool chat`; the old spelling goes away in the next release." (substituting the slot
named), and continue as normal. The old spelling collided with person-scoped `viewer` in one
syntax while meaning the opposite scope, which is why the split exists.

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
`!bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/handoff.sh" --dry-run <any ticket file>`,
which prints the resolved commands without launching anything. Never commit this file.

## Default mode — configure the repo

### Phase 1 — Detect (no questions yet)
1. **CLIs:** `!for c in snow acli gh glab bq databricks yq jq git; do command -v $c >/dev/null && echo "✓ $c" || echo "– $c"; done`
2. **MCP servers** connected this session (tracker / chat / warehouse servers).
3. **Existing state — four routes, checked in order.** First write the boundary down: the ADOPT
   triggers are evidence of prior ticket work — ticket-looking folders, an existing index, or
   custom `.claude/commands` / `.claude/skills`. A repo whose only Ticketwright trace is
   `.claude/settings.json` (plugin enablement) is **fresh** — enablement is how the kit arrives,
   not evidence of prior work.
   1. `stack.yaml` exists but there is **no `people/` directory at all** → this repo predates
      per-person config: run the **Bootstrap** below, then return to what the person asked for.
   2. `stack.yaml` exists (and `people/` too) → resolve who is at the keyboard:
      `!python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/whoami.py" --root . --json`
      - `miss` → this is a **teammate new to this repo**: switch to [teammate.md](teammate.md)
        automatically. Editing the team's shared config must never be a new cloner's first
        offered action. (`--teammate` stays the explicit re-run.)
      - `ambiguous` → ask which of the named candidates they are (in prose), bind with
        `whoami.py --bind <id>`, then re-run the check.
      - `conflict` → surface whoami's warning verbatim and resolve the identity first — fix the
        stale side (the machine pin, or this repo's git config; step 0 of
        [teammate.md](teammate.md) walks it) before offering any team-config edit.
      - `resolved` → offer to **edit** the existing config; never overwrite it.
   3. No `stack.yaml`, and the adopt triggers above are present → an **existing repo**: switch to
      [adopt.md](adopt.md) (map onto what's there; write MIGRATION.md).
   4. None of the above → a **fresh repo**: continue to Phase 2.

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

### Phase 2 — Ask (≤ 5 questions, detected options pre-selected, defaults visible)
One AskUserQuestion round covering only:
1. **Tracker** (detected options first) — or *none*, which selects the `local` tracker: the ticket
   folder itself, for a repo with no ticketing system. Choosing it sets `id_mode: slug` and
   `ticket_url_template: null`, and skips the key-prefix question below;
2. **Warehouse** (or *none* — non-data repos are fine);
3. **VCS**;
4. **Ticket key prefix** (e.g. `ENG`) — accept the tracker's project key as the default; skip
   entirely for the `local` tracker, where the folder name is the id;
5. **Assignee folder name** (default: the user's short name).
Everything else ships as a **commented default** the user can edit later: chat + docstore tool slots
(add via `/setup tool chat` / `/setup tool docstore`), `default_epic`, `terminal_status` (default `Done`),
word limits, role (`generalist`), domain phrase (`data analysis`), and all 10 policies at their
defaults. Each chosen tool's required
keys (per its adapter's `requires:` frontmatter): take the detected value where possible; otherwise
include the key commented with a `# TODO` and keep going — `verify_stack.sh` names any unset
required key by name (a warning, not a failure), so a deferred key is reported rather than lost.

### Phase 3 — Write & scaffold
4. Compose `.claude/config/stack.yaml` per `stack.schema.md` (chosen tool slots live; optional ones as
   commented blocks; the 10 policies with a one-line "when to change this" comment each).
5. Scaffold the repo per [scaffold.md](scaffold.md): render `AGENTS.md` (+ role focus) and a one-line
   `CLAUDE.md` (`@AGENTS.md`, so Claude Code auto-loads the rules),
   `.claude/settings.json` (hooks — omitted on a plugin install — + read-only CLI allows), folders,
   `.gitignore` (deliverable CSVs committed by default; PII opts out via `*.private.csv` / a
   `private/` subfolder), the AI-layer index, and the seeded ticket index.

### Phase 4 — Verify & hand off
6. **Two distinct checks — keep them labeled as such in the report:**
   - `!bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/selftest.sh"` — **kit integrity**. It
     validates the plugin's *own bundled example* stacks, **not** your repo's config. A failure here
     is fatal.
   - `!bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/verify_stack.sh" .claude/config/stack.yaml`
     — **your repo's stack** reachability (pass the repo stack path explicitly so it's unambiguous
     which config was checked). An unreachable tool slot is **not** fatal at setup time; print its
     adapter's auth notes as the fix.
7. **Report:** name which check is which (selftest = kit integrity; verify_stack = *your* tool slots), then
   the chosen stack, files written, any `# TODO` keys, and the next step —
   `/ticket <id>` to start work, or `/setup --teammate` for a new person.
8. **Offer to commit the scaffold.** What setup just wrote (`.claude/config/stack.yaml`, `AGENTS.md`,
   `CLAUDE.md`, `.claude/settings.json`, `.gitignore`, `documentation/AI_LAYER_INDEX.md`, the seeded `tickets/`
   index — plus, on a vendored install, the kit itself) is untracked; if it isn't committed, a later
   ticket PR references rules/adapters absent from the repo's history. Offer a commit (e.g.
   `chore: initialize ticketwright workspace`). First flag that `stack.yaml` may hold internal
   identifiers (tracker site, warehouse project/dataset) — config, not secrets, but worth a glance
   before committing to a public repo.
