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

## "Seam unreachable" / auth errors

`bin/verify_stack.sh` (run by `/setup`, and by skills at preflight) names the failing seam. The fix
lives in that tool's adapter: open `adapters/<seam>/<tool>.md` and follow its `auth:` notes (CLI
login, `config.toml`, MCP server connect). For a personalized walk-through, run
`/setup --teammate`. MCP-only seams need the server connected *in this session* — check `/mcp`.

- **Setup time:** unreachable seams are a warning, not a failure — finish setup, auth later.
- **Work time:** `/ticket` offers to continue local-only if the tracker is down; the warehouse
  slice halts (guessing at schemas is worse than waiting).

## The ticket index looks stale or wrong

- `python3 bin/build_ticket_index.py --check` — tells you if `INDEX.md`/`OBJECTS.md` drift from a
  fresh render. Fix: run it without `--check` (or let the PostToolUse hook do it on the next edit).
- A row marked `▱` is un-enriched (deterministic title only) — `/refresh index <id>` curates it.
- A row marked `⚠` means the README changed after enrichment — re-enrich the same way.
- **Never hand-edit `INDEX.md` or `OBJECTS.md`** — they're generated; edits are overwritten.
  Curated fields live in `tickets/index_data.json`.

## Hooks don't seem to be running

- Plugin install: hooks are declared in the plugin manifest — check `claude plugin list` shows
  ticketwright enabled, then start a fresh session.
- Repo install (pip/vendored): hooks are wired in `.claude/settings.json` — confirm the `hooks`
  block exists (rendered from `.claude/settings.json.tmpl` by `/setup`).
- Quick test: `bash bin/selftest.sh` unit-tests all four hooks directly.

## The DB-write guard blocked something it shouldn't (or vice versa)

The guard asks before destructive statements (including inside `-f` files and stdin redirects) and
passes read-only ones. If a legitimate write keeps prompting, that's by design — answer once per
statement. If it *missed* a destructive pattern for your warehouse CLI, that's a bug worth filing
(include the exact command shape).

## Upgrading

| Install method | Upgrade | Notes |
|---|---|---|
| Claude Code plugin | `claude plugin update ticketwright` | v1 command names keep working via aliases through v2.x |
| pip | `pip install --upgrade ticketwright`, then `ticketwright init` in the repo | `init` preserves your `stack.yaml` and never overwrites edited files without asking |
| vendored `cp -r` (legacy) | re-copy from a fresh clone | no tracking — consider switching to the plugin |

**v1 → v2 rename map:** `configure-workspace`+`onboard-teammate` → `setup` ·
`start-ticket`+`prime-*`+`recall` → `ticket` · `qc-review` → `review` · `deliver-ticket` → `ship` ·
`productize-workflow` → `productize` · `build-ticket-index`+`build-context-pack` → `refresh`.
The old names route automatically in v2 and are removed in v3.

## Something else went wrong

`bash bin/selftest.sh` runs the kit's full 95-check suite (config parsing, adapter coverage,
frontmatter, hooks, render gate, index/recall engines) and pinpoints what's broken. If the
self-test is green but a skill misbehaves, the issue is usually `stack.yaml` (wrong key, stub
adapter) — `bash bin/verify_stack.sh` narrows it to a seam.
