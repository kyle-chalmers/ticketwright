---
name: setup
description: Set up Ticketwright in a repo — detect your tools, ask at most 5 questions, write the config, scaffold folders. Also onboards a teammate (--teammate) and adopts existing repos.
argument-hint: "(none) | --teammate [name] | <seam-to-add: chat|docstore|warehouse>"
allowed-tools: [Read, Write, Edit, Bash, Glob, AskUserQuestion]
disable-model-invocation: true
---

# /setup

One skill, three jobs: **configure a repo** (run once), **add a tool later** (`/setup chat`), and
**onboard a person** (`/setup --teammate`). Detect first, ask last: the goal is a working setup
after **at most 5 questions**.

## Mode: `--teammate` — onboard a person to an already-configured repo
Follow [teammate.md](teammate.md): install checklist → per-tool auth walk-through → verify →
read-the-map → guided first-ticket dry run. Requires an existing `stack.yaml`.

## Mode: `<seam>` — add one tool to an existing config
E.g. `/setup chat`. Detect candidates for just that seam, ask one question, add the seam block to
`stack.yaml`, verify it, and re-render `AGENTS.md`. Nothing else changes.

## Default mode — configure the repo

### Phase 1 — Detect (no questions yet)
1. **CLIs:** `!for c in snow acli gh glab bq databricks yq jq git; do command -v $c >/dev/null && echo "✓ $c" || echo "– $c"; done`
2. **MCP servers** connected this session (tracker / chat / warehouse servers).
3. **Existing state:** if `.claude/config/stack.yaml` exists → offer to edit, don't overwrite.
   If the repo already has ticket folders, an index, or custom `.claude/commands` → this is an
   **existing repo**: switch to [adopt.md](adopt.md) (map onto what's there; write MIGRATION.md).

### Phase 2 — Ask (≤ 5 questions, detected options pre-selected, defaults visible)
One AskUserQuestion round covering only:
1. **Tracker** (detected options first);
2. **Warehouse** (or *none* — non-data repos are fine);
3. **VCS**;
4. **Ticket key prefix** (e.g. `ENG`) — and accept the tracker's project key as the default;
5. **Assignee folder name** (default: the user's short name).
Everything else ships as a **commented default** the user can edit later: chat + docstore seams
(add via `/setup chat` / `/setup docstore`), `default_epic`, `terminal_status` (default `Done`),
word limits, role (`generalist`), and all 9 policies at their defaults. Each chosen tool's required
keys (per its adapter's `requires:` frontmatter): take the detected value where possible; otherwise
include the key commented with a `# TODO` and keep going — `verify` will point at it.

### Phase 3 — Write & scaffold
4. Compose `.claude/config/stack.yaml` per `stack.schema.md` (chosen seams live; optional seams as
   commented blocks; the 9 policies with a one-line "when to change this" comment each). Warn if a
   chosen adapter is `status: stub`.
5. Scaffold the repo per [scaffold.md](scaffold.md): render `AGENTS.md` (+ role focus),
   `.claude/settings.json` (hooks + read-only CLI allows), folders, `.gitignore` (with the
   anchored `**/final_deliverables/*.csv` export guard), the AI-layer index, and the seeded ticket
   index.

### Phase 4 — Verify & hand off
6. Run `!bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/selftest.sh"` (kit integrity — a failure here is fatal) and
   `!bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/verify_stack.sh"` (per-seam reachability — an unreachable seam is
   **not** fatal at setup time; print its adapter's auth notes as the fix).
7. **Report:** the chosen stack, files written, any `# TODO` keys or stub adapters, and the next
   step — `/ticket <id>` to start work, or `/setup --teammate` for a new person.
