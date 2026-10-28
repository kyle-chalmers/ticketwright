# Ticketwright agent reference

> The plugin internals every configured repo shares. A repo's `AGENTS.md` stays short and points
> here, one line per topic, so this file loads only when an agent needs it. It ships with the kit;
> from inside a configured repo, find it with
> `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit` (it is
> `templates/agent-reference.md` under the path that prints). Edit this file in the kit, never a
> copy.

## Reading config — always through the resolver

Config lives in THREE tiers, and only the first is committed team config:

| Tier | File | Holds |
|---|---|---|
| 1 team | `.claude/config/stack.yaml` | which tool fills each tool slot, which data the team reads, policies, ticket conventions |
| 2 person, portable | `people/<id>.yaml` (committed) | display name, identities, comms voice, file-type preferences |
| 3 person, machine | `.claude/config/connections.local.yaml` (gitignored) | named profiles/connections, local mount roots |

**Never read `stack.yaml` directly.** Raw file, raw answer: you would see the team's values and miss
every personal and machine override, which is exactly the case the tiers exist for. Read the merged
result instead — and note the resolver may report a value the raw file does not contain at all, such
as a docstore `base_path` composed from a team folder and your own mount root:

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" effective_config.py --root . --json
```

It needs no agent-specific environment variable, so this works under any harness. `provenance` names
which tier supplied each key. Exit codes: 0 ok · 3 missing · 4 malformed · 5 stale · 6 prohibited
override.

Tier 3 selects CREDENTIALS AND LOCAL PATHS ONLY. It can never change which catalog, schema,
database or target is read — two teammates must never silently read different data — and it can
never contribute a `policies:` block, so a gitignored file no one reviews cannot switch a safety
gate off. Both rules are enforced in code, not documented: a violation is rejected, not ignored.

## Database writes: what each policy level gates

How much is gated is set by `policies.db_write_requires_approval` in `.claude/config/stack.yaml`:

- `off` — nothing is gated.
- `high_risk` *(default)* — gate anything irreversible, access-changing, or unrecognized:
  `DROP`, `TRUNCATE`, `DELETE`, `UPDATE`, `MERGE`, `GRANT`/`REVOKE`, every `CREATE OR REPLACE`,
  and every `ALTER` other than `ALTER … ADD`. Plain `CREATE`, `INSERT INTO`, `ALTER … ADD`, and
  `COMMENT ON` are additive — run them without asking.
- `all` — gate every mutation, additive ones included.

Read the current value before assuming; don't hardcode one of these behaviors.

<!-- ticketwright:enforcement:begin -->
### Who enforces what, per agent runtime

How much of this protocol is *mechanical* depends on which agent runtime you are in — and a
missing hook must never silently weaken a policy, so this table is the non-silence. Cell values:
**ENFORCEMENT** = a mechanism proven in this kit's own test contract (today: the native Claude
Code hooks); **WIRED** = the documented mechanism is emitted and speaks the documented protocol,
but that the runtime honors it is live-verification work still owed — a WIRED gate is strong, not
proven, and never reads as parity with ENFORCEMENT; **GUIDANCE** = a named file or workflow
carries it and honoring it is on the agent; **NATIVE (tool-side)** = a control outside the harness
(the tool's own role / token scope / grants) verifiably carries the policy on a path the hooks
cannot see — claimable only where a read-only privilege introspection exists (today: the warehouse
tool slot), only after the adapter's "Permission posture (MCP)" probe has run its comparison rule
with the result recorded in `.claude/config/posture.local.yaml`; **UNKNOWN** = the runtime's
behavior is undocumented — never assume protection. `ticketwright install --runtime <name>` emits the wiring where one is
documented, and a live confirmation on the kit's punch list
(<https://github.com/kyle-chalmers/ticketwright/blob/main/docs/live-verification.md>) is what
upgrades a WIRED cell to ENFORCEMENT.

| Runtime | `db_write_guard` | `source_material_guard` | `review_verdict_guard` | `session_context` | `ticket_index_context` | `regenerate_ticket_index` | Unreadable hook input |
|---|---|---|---|---|---|---|---|
| Claude Code | ENFORCEMENT (native `PreToolUse` hook, `ask` tier) | ENFORCEMENT (native `PreToolUse` hook, `ask` tier) | ENFORCEMENT (native `PreToolUse` hook, `ask` tier) | ENFORCEMENT (native) | ENFORCEMENT (native) | ENFORCEMENT (native) | fails open by design (exit 0); an unreadable *policy* value still gates more (`all`) |
| Codex CLI | GUIDANCE (shim ready — wire manually, see caveat) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (fallback below) | denies, with the escape |
| Cursor | WIRED (emitted `.cursor/hooks.json`, `failClosed: true`) | WIRED (emitted, same file + `failClosed`) | WIRED (emitted, same entry + `failClosed`) | GUIDANCE (fallback below) | GUIDANCE (fallback below) | GUIDANCE (fallback below) | escalates to `ask` |
| Antigravity | WIRED (emitted `.agents/hooks.json`: `ask` / `force_ask`) | WIRED (emitted `.agents/hooks.json`: `ask`) | WIRED (emitted `.agents/hooks.json`: `ask`) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below; static-not-fresh) | WIRED (emitted `PostToolUse` entry) | escalates to `ask` |
| OpenCode | WIRED (emitted `.opencode/plugins/` throw-to-deny wrapper) | WIRED (same wrapper runs all three shell guards) | WIRED (same wrapper) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below) | denies, with the escape |
| Devin | GUIDANCE (shim ready — wire manually, see caveat) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (fallback below) | denies, with the escape |
| Cline | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (nothing is wired) |

The unreadable-input column applies within the guard's jurisdiction — a shell-like tool call —
and only while the policy is on: a payload naming a clearly non-shell tool passes untouched, and
`policies.db_write_requires_approval: off` silences the guard entirely (an explicit operator
instruction, readable without classifying anything).

`source_material_guard` has a jurisdiction limit that no runtime row captures, so state it here:
it sees **Bash**. A file written through a non-Bash tool, copied in a file manager, or uploaded by
a browser never reaches it. And its classifier matches filenames and document shape, never
**meaning** — a curated summary that quotes confidential material verbatim passes. It is a gate
against the bulk artifact, not a confidentiality review, and nothing in it replaces a person
reading the file.

`review_verdict_guard` is the review-before-ship gate at the command layer: it sees **Bash** —
`git push`, `gh pr create` / `gh pr merge`, `glab mr create` / `merge`, `az repos pr create` / `update` — finds
the ticket from the command's paths, its cwd, or the checked-out branch, and asks when that ticket
has files in `final_deliverables/` and the verdict on file (read by `bin/review_verdict.py`, the
highest-numbered `qc_queries/<n>_review_verdict.md`) is anything but APPROVE: none, SKIPPED,
REQUEST-CHANGES, AWAITING-SIGNOFF (the reviewer approved, your sign-off is pending), or unreadable. It never denies, and `hard_halt_before_external_posts: false`
silences it. A push from a git client, an IDE button, or a browser never reaches it, and it reads
the record, not the work.

`db_write_guard` has the same jurisdiction limit, so state it too: it sees **Bash** — a warehouse
CLI command in a shell payload (including SQL hidden in a `-f` file or a stdin redirect). SQL
issued through a warehouse MCP server, or any other non-Bash tool, never reaches it; on the MCP
transport the DB-write policy is guidance the agent follows, not a gate the runtime enforces.
Route warehouse WRITES through the CLI, where the gate can actually see them, and keep the MCP
path for read/exploration. What each policy can carry on the MCP path — and when NATIVE
(tool-side) may honestly be claimed — is the permission-posture table just below this block.

And a limit that precedes every runtime row: the hooks ship WITH the plugin. Until the plugin is
installed and the session restarted, every ENFORCEMENT cell above is GUIDANCE — a teammate's very
first session in this repo, exactly the one where a newcomer pokes at the warehouse, has no hooks
at all. Install first — see the "Installing this plugin" section of this repo's AGENTS.md:
`claude plugin install ticketwright@ticketwright --scope project` from the repo root. And one
privacy rule for that same onboarding window: never run bare `snow connection list` — it prints
account, user, and role into the transcript. Enumerate connection NAMES only:
`snow connection list --format JSON | python3 -c "import json,sys;[print(c['connection_name']) for c in json.load(sys.stdin)]"`.

Per-runtime caveats — the part that keeps the table honest:

- **Claude Code** — the native hooks in `.claude/hooks/` (`db_write_guard` sees SQL hidden in a
  `-f` file or a stdin redirect too). Hooks fail open by design — a hook error never blocks a
  session — but an unreadable policy value resolves to `all`, gating more, and a missing SQL
  scanner gates everything until the kit is repaired.
- **Codex CLI** — no `ask` tier, so `high_risk` collapses to **deny-with-escape**: destructive
  statements are denied with a message naming the one-shot re-approval (the
  `TICKETWRIGHT_APPROVE=once` command prefix, or the `.claude/config/approve.once` token —
  consumed on use, expires in 15 minutes); additive statements pass untouched. The shim speaks the
  documented deny protocol — wire it as
  `bash bin/tw hook_shim.py --runtime codex-cli --hook shell_guards || exit 2` (one hook covering
  all three shell guards — db-write, source-material and review-verdict; the suffix keeps
  a `bin/tw` launcher failure inside the documented deny exit; the shim itself exits only 0 or 2)
  — but the hooks-config file location is not in the kit's research, so wiring it is manual until
  verified live. Even once wired: hooks must be **trusted by hash** (installed is not armed; an
  edit re-arms the review), and Codex's own docs call hooks a guardrail, not a complete
  enforcement boundary.
- **Cursor** — the installer emits `.cursor/hooks.json` with **`failClosed: true`** — required
  configuration, not tuning: Cursor hooks fail OPEN by default, and without it the gate stops
  gating the moment the hook errors, silently. `high_risk` is expressed as `ask`. The config-file
  schema and the deny path are live-unverified (unofficial reports of uneven deny behavior exist).
- **Antigravity** — `high_risk` → `ask`; `all` → `force_ask`, which ignores cached grants (a
  remembered "yes" never covers the next destructive statement). What a **failing** hook does here
  is undocumented — UNKNOWN, never assumed to hold. No session-start event exists in the CLI, so
  the banners are workflow (below).
- **OpenCode** — no `ask` tier: `high_risk` collapses to **deny-with-escape**, delivered by the
  emitted plugin wrapper throwing from `tool.execute.before` ("throwing an error prevents the tool
  from executing"). What an entirely-failed plugin *load* does is undocumented, and whether the
  wrapper is actually loaded is live-unverified.
- **Devin** — no `ask` tier: `high_risk` collapses to **deny-with-escape**. Devin's hook path
  **fails open by documented design** (exit 0 continues, exit 2 blocks, any other nonzero is
  logged and ignored) — so the shim maps every internal error to a deliberate exit 2, never a
  stray crash. The hooks-config file location is not in the kit's research; wiring
  (`bash bin/tw hook_shim.py --runtime devin --hook shell_guards || exit 2` — one hook covering
  all three shell guards; the suffix keeps
  even a `bin/tw` launcher failure inside the one exit code Devin honors as a block) is manual
  until verified live.
- **Cline** — the policy degrades to **guidance** here, stated plainly: the hooks doc is a stub,
  whether file-based hooks fire is unverified upstream, and Cline's approval classification is
  **model-judged**, not a deterministic scanner. `ticketwright install --runtime cline` writes
  this table into `.clinerules/` so Cline users actually see it (Cline does not read AGENTS.md).

Fallbacks, named (the GUIDANCE cells above point here):

- **Session banners without a session hook** — run them at session start:
  `bash bin/tw hook_shim.py --runtime <name> --hook session_context` and the same with
  `--hook ticket_index_context`. Rules files are static; the banner output is fresh — never treat
  rules text as a substitute for the live stack + catalog summary.
- **Index auto-regen without a PostToolUse hook** — the enrich/ship flow already runs
  `bash bin/tw build_ticket_index.py` when a ticket changes, and its `--check` staleness gate
  fails a stale catalog. Freshness degrades to that pair, never to nothing.
<!-- ticketwright:enforcement:end -->

<!-- ticketwright:posture:begin -->
### Permission posture per policy — the Bash path vs the MCP path

The runtime table above answers "who enforces the hooks". This table answers a different question,
per policy: what carries the policy on each transport. On the MCP path enforcement does not
disappear — it moves into the tool's own permission controls, and each MCP-capable adapter's
"Permission posture (MCP)" section says where that control lives, what to set, and the read-only
probe that checks it (outcome recorded in gitignored `.claude/config/posture.local.yaml` at setup
time).

| Policy | Bash/CLI path | MCP path |
|---|---|---|
| `db_write_requires_approval` | ENFORCEMENT/WIRED/GUIDANCE per the runtime table above | NATIVE (tool-side) once the warehouse adapter's posture probe has verified a read-only grant set under its comparison rule (recorded in `.claude/config/posture.local.yaml`); GUIDANCE until then |
| `chat_default_draft` | GUIDANCE (skills draft by default) | GUIDANCE — the draft tools are the path; a connector's grant set cannot be introspected read-only from inside a session, so the posture record caps at `unverified` and the tool-side claim is never available on this row |
| `hard_halt_before_external_posts` | GUIDANCE (skill hard-halt) | GUIDANCE (skill hard-halt); the tracker/chat adapter's posture section names the grants that matter and where a human confirms them |

The asymmetry between the rows is the honest design, not a gap: NATIVE exists only where a
read-only privilege introspection and a written comparison rule exist (the warehouse adapters);
connector grants cannot be introspected in-session, so those cells never read stronger than what
is true.
<!-- ticketwright:posture:end -->

## The 11 policies in full (read their values from `stack.yaml` through the resolver)
1. **hard_halt_before_external_posts** — pause for human go before any tracker/chat/docstore write; the `review_verdict_guard` hook also asks before a push/PR of a ticket with deliverables that has no approved review result.
2. **db_write_requires_approval** — `off` | `high_risk` (default) | `all`; show SQL, explain, wait.
3. **chat_default_draft** — draft, don't send, unless told "send it".
4. **hyperlink_everything** — every ticket id / file / PR is a smart link.
5. **skillify_everything** — when work recurs it becomes its own skill (`/skillify`), not another copy-paste.
   **Before you end a session that worked a ticket** and did not reach `/ship`'s retro, run the
   repeat check in `.claude/skills/skillify/repeats.md` (on a plugin install, under the kit:
   `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" --kit`) and follow its four
   steps. Put the outcome in your closing message as one line: the `/skillify` suggestion, the skill
   that already does this, or nothing. Never run `/skillify` unasked.
6. **reduce_assumptions** — ask before building; still document every assumption in the ticket README.
7. **commit_plan_before_implement** — `/ticket` commits the plan (and the spec) before `/build` runs (blame-free retry).
8. **system_evolution** — a failure fixes the AI layer (rule/context/command/adapter), not just the ticket.
9. **deterministic_outputs** — explicit `ORDER BY` on exports; generated skills ship golden-replay diffs.
10. **human_review_handoff** — `off` | `review` (default) | `all`; open the deliverables in the
    human's own apps and **wait for sign-off** before the verdict. Which apps is per-user and
    gitignored (`.claude/config/viewer.local.yaml`); run
    `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" handoff.sh <paths>`. Every other
    pause guards something leaving the machine — this one makes sure a person actually saw the
    output. If no viewer config exists, say so once and carry on; never block on it.
11. **ship_merges_pr** — `true` (default): after the go-ahead, `/ship` asks once more and then
    squash-merges the pull request, stopping with the reason if protection or checks block it.
    `false`: the team merges by hand, and the ticket is not moved to its final status by `/ship`.

## Git: repo-setup files get their own commit
Repo-setup and AI-layer files get their own commit, never folded into a ticket's feature commit.
These belong to the *repo's* plugin setup, not to any one ticket: `.claude/settings.json`,
`.claude/config/stack.yaml`, `.claude/statusline.sh`, `AGENTS.md`/`CLAUDE.md`,
`documentation/AI_LAYER_INDEX.md`, and `.gitignore`. When `/setup` or a plugin `autoUpdate` leaves
any of them dirty while a ticket is in flight, give them a separate `chore(plugins): …` commit **on
the same branch as the ticket** — a distinct commit (clean history, easy revert) that rides the
ticket's **one** PR, so there's never a second PR to merge. (A standalone setup change with no ticket
open is its own small PR to the default branch.) The enablement travels with the repo, and
registering the marketplace is not installing the plugin — a teammate who opens and trusts the repo
gets the marketplace clone, then runs the install themselves (Track 2). Personal / machine-local
config stays gitignored and is never committed: `.claude/settings.local.json`,
`.claude/worktrees/`.

## Installing the plugin

The install checklist, with every check the doctor runs and its fix, lives in
<https://github.com/kyle-chalmers/ticketwright/blob/main/docs/getting-started.md>, and the doctor
prints the same checks with the fix for each:
`python3 ~/.claude/plugins/marketplaces/ticketwright/bin/plugin_doctor.py` before the plugin is
installed, `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" plugin_doctor.py`
after. More states and their recoveries:
<https://github.com/kyle-chalmers/ticketwright/blob/main/docs/troubleshooting.md>.
