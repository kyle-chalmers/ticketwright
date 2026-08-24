# Troubleshooting

## A skill failed mid-way — how do I resume?

Just re-run it. Every skill is resume-safe by design:

- **`/ticket <id>`** detects the existing folder/branch and continues from what's done (it reads
  the README, deliverables, and git log — "resume, don't restart").
- **`/spec-and-build build`** re-loads the committed spec and picks up at the first unmet
  validation gate.
- **`/review`** is read-only; re-running it is always safe.
- **`/ship`** Phase A is idempotent (re-verify, tidy, drafts); Phase B halts before every external
  post, so a crash can't leave you half-posted — re-run and re-authorize.

## "Tool slot unreachable" / auth errors

`bin/verify_stack.sh` (run by `/setup`, and by skills at preflight) names the failing tool slot.
The fix lives in that tool's adapter: open `adapters/<seam>/<tool>.md` and follow its `auth:`
notes (CLI login, `config.toml`, MCP server connect). For a personalized walk-through, run
`/setup --teammate`. MCP-only tools need the server connected *in this session* — check `/mcp`.

- **Setup time:** an unreachable tool is a warning, not a failure — finish setup, auth later.
- **Work time:** `/ticket` offers to continue local-only if the tracker is down; the warehouse
  slice halts (guessing at schemas is worse than waiting).

## The ticket index looks stale or wrong

- `python3 bin/build_ticket_index.py --check` — tells you if `INDEX.md`/`OBJECTS.md`, or the graph
  nodes under `tickets/graph/` + `tickets/objects/`, drift from a fresh render. Fix: run it without
  `--check` (or let the PostToolUse hook do it on the next edit).
- A row marked `▱` is un-enriched (deterministic title only) — `/refresh index <id>` curates it.
- A row marked `⚠` means the README changed after enrichment — re-enrich the same way.
- **Never hand-edit `INDEX.md` or `OBJECTS.md`** — they're generated; edits are overwritten.
  Curated fields live in `tickets/index_data.json`.

## My folders aren't showing up in `INDEX.md`

Check `project.id_mode`. Under the default `keyed`, a folder is only a ticket if its name contains a
tracker key from `key_prefixes` / `key_prefix` — `signup-funnel-lift` is skipped on purpose, the same way
`scratch-*` is. If the repo has no ticketing system, that is what `id_mode: slug` is for: the folder
name becomes the id. See `stack.example.solo.yaml` for a full config.

Conversely, if a folder you meant as scratch work **is** appearing, you are in `slug` mode, where
nothing is skipped for lacking a key — move it out of `tickets/`.

## A slug ticket's related-work links are missing

In `slug` mode, cross-references come only from `[[wiki-links]]`, never from prose. Writing
"follows on from signup-funnel-lift" creates no link; `[[signup-funnel-lift]]` does. This is deliberate — a
folder name can be an ordinary phrase (`data-quality`), and matching prose would turn stray words into
catalog rows and graph edges. Note a wiki-link inside a fenced or inline code block counts as an
example, not a reference, and markdown link destinations are not consulted at all.

## The statusline or session banner shows my repo's directory name instead of a prefix

It means no `key_prefix` (or `key_prefixes`) was found in `stack.yaml` — which is expected under
`id_mode: slug`, but can also just mean a keyed repo never configured one. If the repo *is* keyed, add
the prefix: the readers check `key_prefix` first, then the first entry of `key_prefixes`, and only then
fall back to the directory name.

If instead the statusline shows only one warehouse when you configured more than one, relaunch the session:
bundled hook changes don't reach an installed copy until it is reinstalled, and an un-relaunched
session displays the first target it finds. Listing the default target first keeps that honest.

## Hooks don't seem to be running

- Plugin install: hooks are declared in the plugin manifest — check `claude plugin list` shows
  ticketwright enabled, then start a fresh session.
- Repo install (pip/vendored): hooks are wired in `.claude/settings.json` — confirm the `hooks`
  block exists (rendered from `.claude/settings.json.tmpl` by `/setup`).
- Quick test: `bash bin/selftest.sh` unit-tests all four hooks directly.

## The DB-write guard blocked something it shouldn't (or vice versa)

First check which mode you're in — `policies.db_write_requires_approval` in
`.claude/config/stack.yaml`:

| Value | Prompts on |
|---|---|
| `off` | nothing |
| `high_risk` *(default)* | `DROP`, `TRUNCATE`, `DELETE`, `UPDATE`, `MERGE`, `GRANT`/`REVOKE`, every `CREATE OR REPLACE`, every `ALTER` except `ALTER … ADD`, and anything it can't classify |
| `all` | every mutation, additive ones included |

**Too many prompts?** If routine `CREATE`/`INSERT` work is prompting, you're probably on `all` (or
on a legacy config whose value doesn't parse — anything unrecognized deliberately falls back to
`all`). Set `high_risk` explicitly. If a *specific* statement keeps prompting under `high_risk`, the
scanner didn't recognize it: classification is default-deny, so unknown SQL is treated as high-risk
by design. Worth filing with the exact statement so the additive allowlist can grow.

**Still prompting in `bypassPermissions`?** The guard suppresses its own prompt there and prints a
`systemMessage` instead. If you still get a dialog, something else is producing it — another
PreToolUse hook (when more than one matches, the most restrictive wins), or an `ask` rule in your
`permissions` settings, which `bypassPermissions` explicitly does not skip. Check for a second
`Bash` hook at user scope before blaming this one.

**Missed something destructive?** That's a bug worth filing — include the exact command shape. Note
the guard only sees commands that invoke a *configured* warehouse CLI, and it is repo-gated: with no
project `stack.yaml` it does nothing at all.

## Upgrading

| Install method | Upgrade | Notes |
|---|---|---|
| Claude Code plugin (project scope) | the committed `autoUpdate` is meant to pick up each tagged release | not guaranteed for git-sourced marketplaces — to pull manually: `claude plugin marketplace update ticketwright`, or `claude plugin update ticketwright --scope project` |
| Claude Code plugin (user scope) | `claude plugin update ticketwright` | defaults to `--scope user`, matching a no-`--scope` install |
| pip | `pip install --upgrade ticketwright`, then `ticketwright init` in the repo | `init` preserves your `stack.yaml` and never overwrites edited files without asking |
| vendored `cp -r` (legacy) | re-copy from a fresh clone | no tracking — consider switching to the plugin |

**Installed at the wrong scope?** Both `claude plugin marketplace add` and `claude plugin install`
default to `--scope user`, so leaving the flag off installs Ticketwright into your own
`~/.claude/settings.json` — nothing lands in the repo and teammates get nothing. Symptom: the repo has
no `.claude/settings.json` (or one with no `extraKnownMarketplaces`), and `claude plugin list` reports
scope `user`. To move it, uninstall at user scope and reinstall at project scope from inside the repo:

```bash
claude plugin uninstall ticketwright@ticketwright --scope user
claude plugin marketplace remove ticketwright --scope user
```

```bash
claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git --scope project
claude plugin install ticketwright@ticketwright --scope project
```

Pass `--scope user` to `marketplace remove` explicitly — with no `--scope` it drops the declaration from
**every** scope, including other repos' project-scoped ones. Then commit the repo's
`.claude/settings.json`.

**v1 → v2 rename map:** `configure-workspace`+`onboard-teammate` → `setup` ·
`start-ticket`+`prime-*`+`recall` → `ticket` · `qc-review` → `review` · `deliver-ticket` → `ship` ·
`productize-workflow` → `productize` · `build-ticket-index`+`build-context-pack` → `refresh`.
The old names routed automatically through v2.x as deprecated aliases; they were removed in v3.0.0.

## Something else went wrong

`bash bin/selftest.sh` runs the kit's full 200+-check suite (config parsing, adapter coverage,
frontmatter, hooks, render gate, index/recall engines) and pinpoints what's broken. If the
self-test is green but a skill misbehaves, the issue is usually `stack.yaml` (wrong key, stub
adapter) — `bash bin/verify_stack.sh` narrows it to a tool slot.


## Config resolves to something you did not expect

Read the merged answer rather than guessing which file won:

```bash
python3 bin/effective_config.py --root . --json
```

`provenance` names the tier behind every key (`team`, `person`, `machine`, `inherited`) and its
source file. `errors` explains anything refused. Exit codes: `3` no `stack.yaml`, `4` a config
outside the supported YAML subset (the message names the line and the rule), `5` the machine file
was completed against an older team stack, `6` a person/machine file tried to set something
team-owned — a data-selection key such as `catalog`, or a `policies:` block, both of which are
rejected rather than ignored.

`python3 bin/effective_config.py --root . --lint` lists machine-local values sitting in committed
config. `bash bin/verify_stack.sh` prints the same warnings alongside tool reachability.

**A verify command printed `skipped: unresolved {token}`** — that is correct, not a bug: the command
needs a personal value and no `.claude/config/connections.local.yaml` supplies it. Set the key there.
The alternative, running the command with a literal `{token}` in it, reads as broken authentication
and wastes far more time.
