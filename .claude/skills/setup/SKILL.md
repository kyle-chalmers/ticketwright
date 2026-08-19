---
name: setup
description: Set up Ticketwright in a repo — detect your tools, ask at most 5 questions, write the config, scaffold folders. Also onboards a teammate (--teammate), builds a per-person comms voice profile (--voice), and adopts existing repos.
argument-hint: "(none) | --teammate [name] | --voice [name] | <seam-to-add: chat|docstore|warehouse|viewer>"
allowed-tools: [Read, Write, Edit, Bash, Glob, AskUserQuestion]
disable-model-invocation: true
---

# /setup

One skill, three jobs: **configure a repo** (run once), **add a tool later** (`/setup chat`), and
**onboard a person** (`/setup --teammate`). Detect first, ask last: the goal is a working setup
after **at most 5 questions**.

## Mode: `--teammate` — onboard a person to an already-configured repo
Follow [teammate.md](teammate.md): install checklist → per-tool auth walk-through → verify →
read-the-map → guided first-ticket dry run. Requires an existing `stack.yaml`. When
`project.voice_profiles` is configured, offer the `--voice` step at the end so the new person's
comms sound like them from their first ship.

## Mode: `--voice` — build or refine a person's comms voice profile
Follow [voice.md](voice.md): identify the person → wire `project.voice_profiles` → render the seed
from `templates/voice-profile.md.tmpl` → interview (≤5 questions) → optionally learn from short
approved exemplars → save. `/ship` then drafts in that voice, within the hard comms rails. Requires
an existing `stack.yaml`. (This is a first-class mode, **not** a seam — `voice` is never a
`seams.*` entry.)

## Mode: `<seam>` — add one tool to an existing config
E.g. `/setup chat`. Detect candidates for just that seam, ask one question, add the seam block to
`stack.yaml`, verify it, and re-render `AGENTS.md`. Nothing else changes.

## Mode: `viewer` — which apps open *your* deliverables (per-user, not the repo's)
The only seam that is **not** written to `stack.yaml`: which app opens a `.sql` is a personal
choice, so it lives in a gitignored per-user file and each teammate answers for themselves. Ask:

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
3. **Existing state:** if `.claude/config/stack.yaml` exists → offer to edit, don't overwrite.
   If the repo already has ticket folders, an index, or custom `.claude/commands` → this is an
   **existing repo**: switch to [adopt.md](adopt.md) (map onto what's there; write MIGRATION.md).

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
Everything else ships as a **commented default** the user can edit later: chat + docstore seams
(add via `/setup chat` / `/setup docstore`), `default_epic`, `terminal_status` (default `Done`),
word limits, role (`generalist`), and all 10 policies at their defaults. Each chosen tool's required
keys (per its adapter's `requires:` frontmatter): take the detected value where possible; otherwise
include the key commented with a `# TODO` and keep going — `verify` will point at it.

### Phase 3 — Write & scaffold
4. Compose `.claude/config/stack.yaml` per `stack.schema.md` (chosen seams live; optional seams as
   commented blocks; the 10 policies with a one-line "when to change this" comment each). Warn if a
   chosen adapter is `status: stub`.
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
     which config was checked). An unreachable seam is **not** fatal at setup time; print its
     adapter's auth notes as the fix.
7. **Report:** name which check is which (selftest = kit integrity; verify_stack = *your* seams), then
   the chosen stack, files written, any `# TODO` keys or stub adapters, and the next step —
   `/ticket <id>` to start work, or `/setup --teammate` for a new person.
8. **Offer to commit the scaffold.** What setup just wrote (`.claude/config/stack.yaml`, `AGENTS.md`,
   `CLAUDE.md`, `.claude/settings.json`, `.gitignore`, `documentation/AI_LAYER_INDEX.md`, the seeded `tickets/`
   index — plus, on a vendored install, the kit itself) is untracked; if it isn't committed, a later
   ticket PR references rules/adapters absent from the repo's history. Offer a commit (e.g.
   `chore: initialize ticketwright workspace`). First flag that `stack.yaml` may hold internal
   identifiers (tracker site, warehouse project/dataset) — config, not secrets, but worth a glance
   before committing to a public repo.
