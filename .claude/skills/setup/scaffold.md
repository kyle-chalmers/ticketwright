# Scaffold details — what `/setup` writes into a fresh repo

Write order is fixed in SKILL.md Phase 3: `.claude/config/stack.yaml` first, `.claude/settings.json`
second, then everything below (all of it renders from or presumes `stack.yaml`). The sections here
are grouped by artifact, not by order.

## Global rules (`AGENTS.md`)
Render `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/AGENTS.md.tmpl` → `AGENTS.md` (tokens
from `stack.yaml`: tool names, key_prefix, terminal_status, word limits, policies). Fill
`{{role_focus}}` from `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/roles/<role>.md` using
`project.role` (`generalist` unless the user changed it), and `{{domain}}` from `project.domain`
(`data analysis` unless the user changed it — any short phrase works: "ops analysis",
"research", "reporting"). This is the always-loaded tier —
keep it the rendered template; repo-specific rules get added by humans over time.

**The stack table's adapter column takes WHOLE-PATH tokens** — `{{tracker_adapter}}`,
`{{warehouse_adapter}}`, `{{chat_adapter}}`, `{{docstore_adapter}}`, `{{meetings_adapter}}`,
`{{vcs_adapter}}` — never a
path you compose around the tool name (`bin/render.sh` is a flat substitution pass with no
conditionals, so an absent tool slot would render a broken path). Pass each pair like this:

- **Configured slot:** the tool name and the backticked adapter path, e.g. `chat_tool=slack` +
  ``chat_adapter=`adapters/chat/slack.md` ``.
- **Absent slot** (warehouse chosen as *none*; chat/docstore/meetings not yet added): pass
  `<slot>_tool=—`
  and an adapter value naming the enabling command, e.g.
  ``chat_adapter=*(not configured — run `/setup tool chat` to add one)*`` (same shape for
  `warehouse`/`docstore`/`meetings`, e.g. `meetings_tool=—` +
  ``meetings_adapter=*(not configured — run `/setup tool meetings` to add one)*``). Tracker and
  VCS are always chosen in the interview (tracker *none*
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

## Human-facing README (`README.md`)
`AGENTS.md` is the *agent's* front door; a human landing on the repo needs one too. Render
`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/templates/project-README.md.tmpl` → a short intro
(under 250 words of prose) to what this is — a ticket-driven work repo — and how work moves through
it. Only two tokens: `{{repo_name}}` (the same value used for the `AGENTS.md` heading) and
`{{domain}}` (from `project.domain`). It names no tool slots, so it renders cleanly whatever the
stack is.

**Never overwrite an existing README** (same non-destructive rule as `AGENTS.md`):
- **No repo-root `README.md`** → render → `README.md`.
- **`README.md` already exists** → render → `README.ticketwright.md` instead, and call it out
  prominently in the setup report / punch list: *"README exists — merge `README.ticketwright.md`
  into it, then delete the sibling."* The human owns the merge.
- **`README.ticketwright.md` also already exists** → leave it untouched; report it as an existing
  merge candidate rather than regenerating over a human's in-progress merge.

This is a **one-time scaffold**: once written, the README is the human's to edit. `/setup role`
re-renders `AGENTS.md` when `domain`/`role` change but must **not** re-render the README — the
`{{domain}}` value is a snapshot at setup time, and re-rendering would clobber human edits.

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
travels with the repo; it survives the original author leaving). Registering the marketplace is not
installing the plugin — a teammate who opens and trusts the repo gets the marketplace clone, then
runs the install themselves (Track 2). It also refreshes
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

Then append the chosen warehouse/tracker/vcs **read-only** CLI allows to `permissions.allow`. Name
the read verbs, one entry each — e.g. `Bash(<cli> jobs list:*)`, `Bash(<cli> jobs get:*)`,
`Bash(<cli> current-user me:*)`, `Bash(<cli> api get:*)` — never the bare CLI (`Bash(<cli>:*)`),
which pre-approves every write that CLI can make, including the non-SQL ones the `db_write_guard`
hook never sees. **Statusline:** the template's `statusLine.command` is the
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
`ship`, `skillify`, `refresh`), the `qc-reviewer` agent, the hooks, and the adapters in use — so
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
