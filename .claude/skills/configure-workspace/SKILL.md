---
name: configure-workspace
description: Initial setup for a new ticket-work repo — detect tooling, interview to map each seam to a tool, write stack.yaml, render AGENTS.md, scaffold the repo, generate the AI-layer index, verify connectivity.
argument-hint: (none) — run once when bootstrapping a repo
allowed-tools: [Read, Write, Edit, Bash, Glob, AskUserQuestion]
---

# /configure-workspace

The **initial configure**. Turns a bare repo into a working "AI layer": picks the concrete tools for
each seam, writes the config the other skills read, renders the global-rules file, and scaffolds the
folder conventions. Run once per repo (re-run to reconfigure).

## Phase 1 — Detect what's available
1. **CLIs:** `!for c in snow acli gh glab bq databricks yq jq git; do command -v $c >/dev/null && echo "✓ $c" || echo "– $c"; done`
2. **MCP servers:** note which relevant servers are connected this session (tracker: atlassian /
   asana / monday / linear; chat: slack / teams; warehouse MCPs). Use these as the *detected*
   options to pre-fill the interview.
3. **Existing config:** if `.claude/config/stack.yaml` already exists, read it and offer to edit
   rather than overwrite.

## Phase 2 — Interview (one AskUserQuestion round per undecided seam)
For each seam (tracker, warehouse, chat, docstore, vcs) ask which tool fills it — **pre-selecting the
detected option**. Then gather the project facts: `key_prefix`, `assignee_dir`, `default_epic`
(or null), `terminal_status`, and each chosen tool's required config keys (per that adapter's
`requires:` frontmatter — e.g. Jira `site`; Snowflake `default_warehouse`/`pii_role`/`dev_db`; Slack
`default_channel`/`always_include`; docstore `base_path`). Confirm the 9 policies (defaults shown).
Honor `reduce_assumptions` — ask, don't guess; allow "no warehouse" for non-data repos.

## Phase 3 — Write the config
4. Compose `.claude/config/stack.yaml` per `stack.schema.md`: `project`, `seams` (each with `tool`,
   `adapter` path, `transport`, `verify`, tool keys), `policies`. For any chosen tool whose adapter
   is still a `status: stub`, tell the user they must finish that adapter's verb sections.

## Phase 4 — Scaffold the repo
5. **Global rules:** render `templates/AGENTS.md.tmpl` → `AGENTS.md` (tokens from `stack.yaml`:
   tool names, key_prefix, terminal_status, word limits, policies). This is the always-loaded tier.
6. **Hooks + settings (policy enforcement):** render `.claude/settings.json.tmpl` → `.claude/settings.json`,
   keeping the `hooks` block (PreToolUse `db_write_guard.py`; SessionStart `session_context.py` +
   `ticket_index_context.py`; PostToolUse `regenerate_ticket_index.py`) and the statusline; then
   append the chosen warehouse/tracker/vcs read-only CLI allows to
   `permissions.allow` (e.g. `Bash(<warehouse_cli> …:*)`). The `db_write_guard` hook makes
   `db_write_requires_approval` mechanical — it asks before any destructive warehouse statement, even
   one hidden in a `-f` file. Confirm `.claude/hooks/` and `.claude/statusline.sh` came across.
7. **Folders:** create `tickets/{assignee_dir}/`, `documentation/`, `resources/`, `specs/`, and (if
   desired) `ci/` + `.gitignore`. If the chosen tracker adapter ships an attachment-download helper,
   copy it into `resources/`.
8. **AI-layer index:** generate `documentation/AI_LAYER_INDEX.md` — a discoverable inventory of the
   installed skills, the `prime-*` commands, the `qc-reviewer` agent, the hooks, and the adapters in
   use (so humans + agents can find them). Keep it one line each.
9. **Ticket index:** seed an empty store `tickets/index_data.json` (`{"schema_version": 1, "tickets": []}`)
   and run `!python3 bin/build_ticket_index.py` to write the initial `tickets/INDEX.md`. From here it
   self-maintains (PostToolUse regen on folder changes; SessionStart surfacing; curated summaries at
   close). Bootstrap an existing backlog with `/build-ticket-index --all`.

## Phase 5 — Verify
10. Run `!bash bin/selftest.sh` (kit integrity + hook unit tests) and `!bash bin/verify_stack.sh`
    (per-seam reachability). Report results. Unreachable seams → point at `/onboard-teammate` (auth
    steps) — don't treat as fatal at config time; a failing self-test IS fatal (the kit is broken).
11. **Report:** the chosen stack, files written, any stub adapters to finish, and the suggested first
    action (`/onboard-teammate` for a human, or `/start-ticket` to begin work).

## Generalizes
The setup implicit across a repo's `AGENTS.md`, `README` "Getting Started", and the folder
logic in `jira-ticket-setup-agent` — made explicit, tool-agnostic, and config-driven.
