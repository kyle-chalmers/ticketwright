# Scaffold details — what `/setup` writes into a fresh repo

## Global rules (`AGENTS.md`)
Render `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/AGENTS.md.tmpl` → `AGENTS.md` (tokens
from `stack.yaml`: tool names, key_prefix, terminal_status, word limits, policies). Fill
`{{role_focus}}` from `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/roles/<role>.md` using
`project.role` (`generalist` unless the user changed it), and `{{domain}}` from `project.domain`
(`data analysis` unless the user changed it — any short phrase works: "ops analysis",
"research", "reporting"). This is the always-loaded tier —
keep it the rendered template; repo-specific rules get added by humans over time.

**The stack table's adapter column takes WHOLE-PATH tokens** — `{{tracker_adapter}}`,
`{{warehouse_adapter}}`, `{{chat_adapter}}`, `{{docstore_adapter}}`, `{{vcs_adapter}}` — never a
path you compose around the tool name (`bin/render.sh` is a flat substitution pass with no
conditionals, so an absent tool slot would render a broken path). Pass each pair like this:

- **Configured slot:** the tool name and the backticked adapter path, e.g. `chat_tool=slack` +
  ``chat_adapter=`adapters/chat/slack.md` ``.
- **Absent slot** (warehouse chosen as *none*; chat/docstore not yet added): pass `<slot>_tool=—`
  and an adapter value naming the enabling command, e.g.
  ``chat_adapter=*(not configured — run `/setup tool chat` to add one)*`` (same shape for
  `warehouse`/`docstore`). Tracker and VCS are always chosen in the interview (tracker *none*
  selects the `local` adapter), so they go absent only in a hand-edited config — render the same
  note with plain `/setup` as the command (there is no `/setup tool tracker|vcs` mode).

These absent-slot values are **render-time display values only** — they go into the rendered
`AGENTS.md`, never into `stack.yaml`, where an absent tool slot stays omitted (or a commented
block) per `stack.schema.md`.

**`{{analysis_tools}}` follows the same always-pass rule** (flat substitution, no conditionals):
pass the `project.analysis_tools` list as a comma-separated phrase, e.g.
`analysis_tools=notebooks, spreadsheets`. When the list is empty or the round was skipped, pass a
display value — `analysis_tools=none declared (add project.analysis_tools in stack.yaml, or run
/setup role)` — never an empty string and never a leftover token.

Also write `CLAUDE.md` from `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/CLAUDE.md.tmpl` — a
one-line `@AGENTS.md` import so **Claude Code** auto-loads these rules (it reads `CLAUDE.md`; other
agents read `AGENTS.md` directly). Keep it to that single import line.

## Hooks + settings (`.claude/settings.json`)
Render `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/.claude/settings.json.tmpl` → `.claude/settings.json`.
**The `hooks` block is install-mode-dependent:**
- **Plugin install** (`${CLAUDE_PLUGIN_ROOT}` set): `.claude-plugin/plugin.json` already wires the
  kit's hooks from the plugin dir — **OMIT the `hooks` block** here, or they double-fire (double
  db-write prompts, double index regen). Keep `permissions` + `statusLine`.
- **Vendored install** (`cp -r`, no `${CLAUDE_PLUGIN_ROOT}`): **keep the `hooks` block** — nothing
  else wires it: `db_write_guard.py` (PreToolUse) makes `db_write_requires_approval` mechanical;
  `session_context.py` + `ticket_index_context.py` (SessionStart) prime the stack + ticket catalog;
  `regenerate_ticket_index.py` (PostToolUse) keeps `tickets/INDEX.md` fresh on folder changes.

**On a plugin install, also commit a project-scoped enablement.** A plugin can't set its own install
scope — the *repo* opts in. Merge these two keys
into the rendered `.claude/settings.json` so the plugin is enabled *for this repo* (committed →
travels with the repo; teammates who open and trust it are prompted to install it; it survives the
original author leaving) and refreshes
itself:

```json
{
  "extraKnownMarketplaces": {
    "ticketwright": {
      "source": { "source": "git", "url": "https://github.com/kyle-chalmers/ticketwright.git" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "ticketwright@ticketwright": true
  }
}
```

The source is an explicit `https://…git` URL, not the `owner/repo` shorthand — the shorthand can
resolve to SSH and fail for users without GitHub SSH keys, whereas the URL clones over HTTPS via the
git credential helper. A fork edits just this URL. `source: "git"` is the discriminator
`claude plugin marketplace add <https://…git>` writes itself — `git` and `url` are *different*
marketplace source types, so don't substitute one for the other.

**Merge — never overwrite.** The repo often already carries this block, because the documented install
is `claude plugin marketplace add … --scope project` + `claude plugin install … --scope project`, which
writes everything above *except* `autoUpdate`. So:

- Merge **into** `extraKnownMarketplaces` and `enabledPlugins`; never replace either map wholesale —
  unrelated marketplaces and plugins in those maps must survive untouched.
- If a `ticketwright` marketplace entry already exists, **keep its `source` exactly as written**. A fork
  will have edited that URL, and rewriting it silently repoints the fork at upstream.
- Add `autoUpdate: true` only when the key is **absent**. An explicit `false` is a deliberate choice —
  preserve it.
- An explicit `"ticketwright@ticketwright": false` means someone disabled the plugin on purpose. Leave it
  as-is and say so in the setup summary rather than flipping it back.
- **Absent ⇒ create.** If `extraKnownMarketplaces`, `enabledPlugins`, the `ticketwright` entry, or its
  `source` object is missing, write it from the block above. "Merge" never means "skip".
- **Malformed ⇒ repair and say so.** If a key is present but the wrong type (e.g. `source` is a bare
  string, `autoUpdate` is `"true"`, `enabledPlugins.ticketwright@ticketwright` is not a boolean), replace
  that key with the correct value and name the repair in the setup summary. Don't silently work around it,
  and don't abort the whole scaffold over one bad key.

`autoUpdate` re-installs **only when the plugin's version string changes** — i.e. only on a formal
release (the release commit bumps `plugin.json`/`marketplace.json`/`__init__.py` in lockstep and tags
`v*`). Between releases, ordinary commits to the default branch leave the version untouched, so
teammates are never pulled onto un-released mid-flight work. The refresh itself is not guaranteed for
git-sourced marketplaces (see the upstream caveat in `ROADMAP.md`); `claude plugin marketplace update
ticketwright` is the manual pull. Do **not** add these keys on a vendored
(`cp -r`/pip) install — there's no marketplace to enable from; the kit is already in-repo.

Then append the chosen warehouse/tracker/vcs **read-only** CLI allows to `permissions.allow` (e.g.
`Bash(<warehouse_cli> …:*)`). **Statusline:** the template's `statusLine.command` is the
project-relative `.claude/statusline.sh`, so on a plugin install **copy
`${CLAUDE_PLUGIN_ROOT}/.claude/statusline.sh` → `.claude/statusline.sh`** so it resolves (on a
vendored install it's already there).

## Folders + `.gitignore`
Create `tickets/{assignee_dir}/`, `documentation/`, `resources/`, `specs/` (and `ci/` if wanted).
Render `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/gitignore.tmpl` → `.gitignore` (merge if
one exists). Deliverable exports (`final_deliverables/*.csv` etc.) are **committed by default** so
results live with the ticket and show in the PR; PII/customer data opts out via a `*.private.csv`
name or a `private/` subfolder (both gitignored). If the tracker adapter ships an attachment-download
helper, copy it into `resources/`.

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

That renderer also writes the Obsidian graph layer (`tickets/graph/` + `tickets/objects/`) when
`project.graph_notes` is on (the default), committed alongside `INDEX.md`/`OBJECTS.md`. It then seeds
`.obsidian/graph.json` (unless `project.graph_config: false`) with the tickets↔objects filter + color
groups so the Graph view opens ready-to-read — create/merge-only, so it never clobbers a user's manual
graph tweaks.
