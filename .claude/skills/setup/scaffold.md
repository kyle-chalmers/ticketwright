# Scaffold details — what `/setup` writes into a fresh repo

## Global rules (`AGENTS.md`)
Render `templates/AGENTS.md.tmpl` → `AGENTS.md` (tokens from `stack.yaml`: tool names, key_prefix,
terminal_status, word limits, policies). Fill `{{role_focus}}` from `templates/roles/<role>.md`
using `project.role` (`generalist` unless the user changed it). This is the always-loaded tier —
keep it the rendered template; repo-specific rules get added by humans over time.

## Hooks + settings (`.claude/settings.json`)
Render `.claude/settings.json.tmpl` → `.claude/settings.json`, keeping the `hooks` block:
- **PreToolUse** `db_write_guard.py` — makes `db_write_requires_approval` mechanical: asks before
  any destructive warehouse statement, even one hidden in a `-f` file;
- **SessionStart** `session_context.py` + `ticket_index_context.py` — primes each session with the
  stack + the ticket catalog;
- **PostToolUse** `regenerate_ticket_index.py` — keeps `tickets/INDEX.md` fresh on folder changes;
plus the statusline. Then append the chosen warehouse/tracker/vcs **read-only** CLI allows to
`permissions.allow` (e.g. `Bash(<warehouse_cli> …:*)`). Confirm `.claude/hooks/` and
`.claude/statusline.sh` are present (plugin installs run them from `${CLAUDE_PLUGIN_ROOT}`).

## Folders + `.gitignore`
Create `tickets/{assignee_dir}/`, `documentation/`, `resources/`, `specs/` (and `ci/` if wanted).
Render `templates/gitignore.tmpl` → `.gitignore` (merge if one exists). It ships the **anchored**
`**/final_deliverables/*.csv` rule so ticket exports (customer data) can't be silently committed at
any depth — *exports go to the docstore, not git*. If the tracker adapter ships an
attachment-download helper, copy it into `resources/`.

## AI-layer index (`documentation/AI_LAYER_INDEX.md`)
A one-line-each inventory of the installed skills (`setup`, `ticket`, `spec-and-build`, `review`,
`ship`, `productize`, `refresh`), the `qc-reviewer` agent, the hooks, and the adapters in use — so
humans and agents can find what exists.

## Ticket index
Seed an empty curated store — `tickets/index_data.json` with
`{"schema_version": 1, "tickets": []}` — then run
`python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/build_ticket_index.py"` to write the
initial `tickets/INDEX.md`. From here it self-maintains (PostToolUse regen on folder changes,
SessionStart surfacing, curated summaries at ship time). An existing backlog gets bootstrapped with
`/refresh index --all`.
