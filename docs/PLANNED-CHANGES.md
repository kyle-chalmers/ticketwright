# Ticketwright change prompts

NINE prompts, in build order. Run each in a fresh session from the ticketwright repo. Each is
self-contained. Do not reorder — later prompts assume earlier ones landed.

## Settled decisions — implement, do not re-open
- Per-person folders: `tickets/<name>/`.
- `tickets/` stays, hardcoded. A "ticket" here means ONE SELF-CONTAINED PIECE OF WORK, which may or
  may not correspond to an issue in a tracker; a team with no tracker still has tickets. Keep the
  word consistent across directory, docs, skill prose and brand. No rename knob.
- The machine tier selects CREDENTIALS AND LOCAL PATHS only — named connection/profile, role, local
  mount root. It may never change LOGICAL DATA SELECTION: catalog, schema, database, warehouse_id,
  target, transport. Two teammates must never silently read different data.
- Per-person portable settings live in `people/<id>.yaml`, committed, identities included. These are
  private analysis repos. Safeguard: when the flow writing identity detects a PUBLIC remote, warn
  once and offer handles instead of emails.
- A runtime is not a `seams:` entry in `stack.yaml`. See "Seams: the accurate picture" below.

## Seams: the accurate picture (earlier drafts of this document got this wrong)
Two different things have been conflated, and prompts 1 and 8 must agree:
  - `stack.yaml`'s `seams:` block documents FIVE kinds — tracker, warehouse, chat, docstore, vcs.
  - `adapters/` ships SIX seam directories. `viewer` is the sixth: it has a real two-verb contract
    (`adapters/README.md` § viewer), `bin/selftest.sh` asserts `viewer) echo 2`, and
    `docs/architecture.md` names it — but it is per-user and gitignored, so it is deliberately not a
    `stack.yaml` seam.
So "five keys, no others" in `.claude/config/stack.schema.md` is already false as written. Prompt 8
fixes that language. Prompt 1 must NOT try to preserve it.
A runtime still does not belong in `stack.yaml`: seams there are things the PROJECT depends on and
the team shares, resolved per-repo. A runtime is which agent a given person is running right now —
per-machine, not per-project. It lives in `adapters/runtime/*.md` plus an installer flag.

## ⚠ THE SELFTEST TRAP — read before any prompt that adds an adapter, a verb, or edits docs
`bin/selftest.sh` treats DOCUMENTATION AS A TESTED ARTIFACT. Its own comment notes this was learned
by adding the `viewer` seam. Specifically:
  - It derives the adapter count and seam count from the tree and requires `docs/architecture.md` to
    contain `**<N> adapters**` and `ROADMAP.md` to contain `- <N> adapters across <M> seams`.
  - It requires every shipped adapter to be listed in `adapters/README.md` § "Adapters shipped".
  - It asserts per-seam verb counts by EXACT EQUALITY (`tracker) echo 6`, `warehouse) echo 3`,
    `chat) echo 4`, `docstore) echo 2`, `vcs) echo 4`, `viewer) echo 2`), checked against
    `grep -c '^## verb:'` in every adapter file.
  - It requires `seam:` and `tool:` frontmatter in the first lines of every `adapters/*/*.md`.
  - It requires certain literal tokens to survive in prose, e.g. `id_mode` in `README.md`,
    `stack.schema.md`, `docs/ticket-index.md` and `docs/troubleshooting.md`.
So "keep selftest green" is NOT a free constraint. Any prompt that adds an adapter, adds a verb, or
restructures README/architecture MUST update those counts and preserve those tokens IN THE SAME
CHANGE. Where a prompt below hits this, it says so explicitly.

## Standing constraints
- `bin/selftest.sh` must pass. It is at 338 cases as of this writing and the count SHOULD grow —
  never treat a number as the target, and see the trap above.
- Existing `stack.yaml` files in the wild must keep working. A new required key that breaks shipped
  example configs is a regression, not a stricter rule.
- Any new CLI takes `--root <path>` and must not require `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PROJECT_DIR`,
  or any other Claude-specific environment variable.
- LINE NUMBERS IN THIS DOCUMENT MAY DRIFT. They were taken from a slightly older tree. Treat every
  `file:line` as a hint; locate by the quoted string, not the number.

## Do not rebuild
`.claude/skills/review/SKILL.md` layer ⑤ already interviews for viewer config just-in-time at the
review gate and writes `.claude/config/viewer.local.yaml`; `bin/handoff.sh` stays silent when
unconfigured. That flow is correct and must keep working — note this constrains prompt 4's
"sole writer" rule, which is scoped accordingly there.

## How to run this set

Work in WAVES. Inside a wave, sessions run concurrently in separate worktrees; between waves,
everything merges first. The constraint is file collision, not sequence for its own sake: prompts 1,
6 and 9 all touch the adapter/seam counts in `ROADMAP.md` and `docs/architecture.md`; 2 and 8 both
own the resolver; 4 and 6 both touch `.claude/skills/setup/`; 5 and 8 both edit
`.claude/skills/ship/SKILL.md`.

| Wave | Runs concurrently | Effort | Why it is safe together |
|---|---|---|---|
| A | 1, 2, 6-item-2 | high, high, medium | Three independent foundations. See the ownership split below. |
| B | 3 | high | Needs tier 3 from prompt 2. |
| C | 4, 5 | high, high | 4 owns `skills/setup/`; 5 owns `skills/ticket|ship|review|spec-and-build`. Disjoint. |
| D | 8-step-1, 6-item-1 | high, medium | 8 edits `ship/SKILL.md` only after 5 has merged. 6-item-1 needs 4's wording. |
| E | 9 | medium | LAST of the docs-touchers — 1, 6 and 8 must have settled the counts. |
| F | 7 | high | Needs 1 plus everything 2-5 settled. Split further on arrival. |

WAVE A OWNERSHIP SPLIT — the one overlap that needs a rule. Prompts 1 and 2 both reach
`bin/enrich_ticket.py` and both edit preflight prose in `.claude/skills/*/SKILL.md`:
  - PROMPT 1 owns `bin/enrich_ticket.py` (the `claude -p` dependency) and every ASSET-RESOLUTION call
    site (`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}` paths).
  - PROMPT 2 owns every CONFIG-READING call site and must not touch the model call in
    `enrich_ticket.py`; if it needs that file migrated to the resolver, it says so in its PR and the
    change lands in a follow-up after prompt 1 merges.
  - Prompt 6-item-2 touches only `adapters/tracker/*.md` and the `tracker) echo 6` line in
    `bin/selftest.sh` — no overlap with either.
Expect a small textual conflict between 1 and 2 in skill preflight sections. Merge prompt 1 first.

SPLIT PROMPT 6. Its two items belong in different waves: item 2 (the tracker verb) is independent and
runs in wave A; item 1 (the absent-seam token) needs prompt 4 and runs in wave D.

Each session: branch off `main`, implement, `bash bin/selftest.sh`, open a PR, merge, then start the
next. Do not begin a session whose dependency has not merged.

## MANDATORY: codex reviews the plan AND the result

Every prompt in this document carries two non-optional gates. `codex` is installed and runs
read-only from the repo root.

GATE 1 — BEFORE WRITING CODE. Write your implementation plan, then:

    codex exec --skip-git-repo-check -C . "Read docs/PLANNED-CHANGES.md for context, then review this
    implementation plan for <PROMPT N>. Verify every claim against the source and cite file:line.
    Report: factual errors; anything the plan will break that it has not accounted for, especially
    the selftest assertions on adapter counts, seam counts, per-seam verb counts and doc tokens;
    where the plan diverges from what the prompt actually asked for; and the single riskiest step.
    PLAN: <your plan>"

Resolve every finding, or state in the PR why you disagree. Do not start coding on an unreviewed plan.

GATE 2 — AFTER IMPLEMENTING, BEFORE THE PR. With the work committed on your branch:

    codex exec --skip-git-repo-check -C . "Review the diff on this branch against main for correctness
    and for compliance with <PROMPT N> in docs/PLANNED-CHANGES.md. Cite file:line. Report: bugs;
    requirements of the prompt left unimplemented; anything implemented that the prompt did not ask
    for; safety regressions, particularly to db_write_requires_approval enforcement or to any path
    that posts externally; and whether the new tests actually test the stated behavior."

Fix what it finds. Put both codex verdicts in the PR body. Treat codex as a reviewer whose findings
must be verified against source, not accepted on trust — it has been wrong before in this project.

## Two decisions made in advance — implement, do not re-open

TICKET LOCATOR GRAMMAR (prompt 5). `owner/id` is the CLI and display form ONLY. It must never become
a filename or a git ref:
  - Graph and object nodes stay FLAT FILES with the separator flattened, following the precedent
    already in `bin/build_ticket_index.py` (`object_filename()` rewrites `:` and `/` to `.`). A graph
    node becomes `<owner>.<id>.md`.
  - BRANCH NAMES STAY BARE `<id>`. `owner/id` as a branch is a trap: `/` is the git ref namespace
    separator, so `jyoung/chargeback-lift` permanently forbids a branch named `jyoung`. When a bare
    branch name is already taken, disambiguate at creation time with `<owner>-<id>` and say so.
  - A bare `[[wiki-link]]` resolves within the CURRENT owner first, then across owners; if it matches
    two owners it is an error naming both, never a guess.
  - Migration: existing bare links keep resolving, because within-owner resolution is tried first.
    No rewrite of historical links is required.

CANONICAL SOURCE LAYOUT (prompt 7). KEEP `.claude/skills/` as the source and TRANSLATE ON EMIT. Do
not move it. `pyproject.toml` force-includes six `.claude/*` paths, `.claude-plugin/plugin.json`
wires four hooks by that path, and `skills/` is already a symlink providing a neutral alias. Moving
the root is destructive across all three for no functional gain, since the installer translates to
each runtime's layout anyway.

## PROMPT 1 — Runtime foundation

Everything downstream assumes a way to find kit assets and resolve config that currently only works
under Claude Code. Establish that first. This prompt decides architecture and writes the research
down; it does NOT ship installers for every runtime (that is PROMPT 7).

Start from what already exists, not from scratch:
- The kit ALREADY ships two ways: a Claude marketplace plugin, and a PyPI package whose
  `ticketwright init` scaffolds the kit into a repo with assets bundled at `ticketwright/_kit/`
  (`ticketwright/cli.py`). Installation is therefore NOT the gap. Native invocation is.
- The canonical skill source is `.claude/skills/` — note `skills/` is a SYMLINK to it, and
  `pyproject.toml` force-includes that Claude-shaped path into the wheel.

Deliverables:

1. RESEARCH, WRITTEN DOWN as `docs/runtimes.md`. For each of Claude Code, Codex CLI, Cursor,
   OpenCode, Gemini CLI, Windsurf, Cline, establish and cite:
     - where skills/commands install, and in what file format;
     - whether it has ANY lifecycle callback (a SessionStart equivalent);
     - whether it can GATE a tool call before execution — this is the one that decides whether
       `db_write_requires_approval` can ever be mechanical off Claude Code, or whether the kit must
       say plainly that it degrades to trust;
     - whether it supports subagents (for `qc-reviewer`) or must degrade to an inline second pass;
     - whether it renders structured-option questions or only prose.
   Where a capability is absent, record the honest floor rather than a workaround.

2. `adapters/runtime/<name>.md` per runtime, in the kit's existing adapter format.
   THIS TRIPS THE SELFTEST TRAP — handle it head-on, do not discover it:
     - Each file needs `seam: runtime` + `tool: <name>` frontmatter, or the frontmatter check fails.
       Writing `seam: runtime` is CORRECT here and does not contradict anything: it makes runtime a
       sixth ADAPTER directory (as `viewer` already is), not a `stack.yaml` `seams:` entry.
     - Adding N runtime adapters changes the derived counts, so `docs/architecture.md`'s
       `**<N> adapters**` and `ROADMAP.md`'s `- <N> adapters across <M> seams` MUST be updated in the
       same commit, and every new adapter listed in `adapters/README.md` § "Adapters shipped".
     - Runtime adapters have no `## verb:` sections. That is fine — `verbs_expected` falls through to
       `*) echo 0` for unknown seam names. Do not invent verbs to satisfy a contract.
   Do NOT add anything to `seams:` in `stack.yaml` or to its five documented kinds.

3. A KIT-LOCATION CLI so nothing has to know it is running under Claude. Skills currently resolve
   assets via `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}` (e.g. `.claude/skills/ticket/SKILL.md:45`),
   which resolves to nothing on Codex. Provide one command that returns the kit root and the project
   root, and make every skill and script use it.

4. FIX THE HARD CLAUDE DEPENDENCY INSIDE bin/. `bin/enrich_ticket.py:72` shells out to `claude -p`.
   That is in the layer this architecture calls harness-neutral. Either make the model call pluggable
   per runtime adapter, or make the documented fallback (`bin/ingest_index_records.py`, see
   `.claude/skills/refresh/index.md:43`) the primary path with `claude -p` as a Claude-only
   optimization. Do not leave a harness-neutral script that only runs on one harness.

Success criterion: a script or skill can locate kit assets and know its runtime's capabilities
without any Claude environment variable.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 1. Put both verdicts in the PR body.

## PROMPT 2 — Three-tier config, the resolver, and the leak it fixes

`/setup` writes `.claude/config/stack.yaml` by detecting the machine of whoever runs it — but that
file is committed and shared, so machine-local identifiers leak into a team artifact. A real run
produced `profile: biprod` (a `~/.databrickscfg` profile name), `connection: <host>` (a
`~/.snowflake/config.toml` connection name), and `verify: "databricks --profile biprod current-user
me"` with the personal profile hardcoded. Fix the model and the leak together — fixing the leak alone
just moves values somewhere equally wrong.

### The three tiers
  TIER 1 — TEAM (committed): `.claude/config/stack.yaml`
      which warehouse/catalog/schema, policies, ticket conventions.
  TIER 2 — PERSON, PORTABLE: `people/<id>.yaml` (committed, in-repo)   [NEW]
      display name, identities (PROMPT 3), tracker handle, file-type handling preferences.
      `voices/<id>.md` and the `voice_profiles.map` currently living in `stack.yaml` both move here.
      MUST NOT contain a default warehouse target — target selection is team-owned.
      PRECEDENCE: a cross-repo copy at `${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/people/<id>.yaml`
      supplies defaults; the in-repo `people/<id>.yaml` overrides it key by key. Define this
      explicitly — do not leave two homes for tier 2 with no stated winner.
  TIER 3 — PERSON, MACHINE: `.claude/config/connections.local.yaml` (gitignored)   [NEW]
      named connection/profile, role, local mount root, and the top-level `person:` key (PROMPT 3).

`.claude/config/*.local.yaml` is ALREADY in the shipped gitignore template — tier 3 needs no
gitignore change. `viewer.local.yaml` currently MIXES tiers 2 and 3 — but split it CAREFULLY, because the obvious
split is wrong. `routes[].app` is machine wiring, not preference: `viewer.example.yaml` maps the same
globs to `DataGrip`/`Microsoft Excel` on macOS and `datagrip.desktop`/`libreoffice-calc.desktop` on
Linux. Committing `routes:` verbatim to tier 2 means a person's config follows them to a Linux box
and silently fails — the exact failure the split exists to prevent. The PORTABLE part is the
glob-to-CATEGORY mapping (`*.sql` -> sql-editor, `*.csv` -> spreadsheet); the machine part is which
application fills each category, plus `open_cmd`/`adapter:`.

### Scope rule — enforced in code, not documented
Tier 3 selects CREDENTIALS AND LOCAL PATHS. It must NOT override `catalog`, `schema`, `database`,
`warehouse_id`, target selection, or `transport`. Which keys are personal is declared per-adapter via
a new `user_keys:` frontmatter list, NOT hardcoded in a skill.
  - `person:` is a TIER-3 STRUCTURAL KEY owned by the resolver, not by any adapter. Carve it out of
    `user_keys` validation explicitly, or validation will reject every valid local file.
  - DO NOT use an adapter's `requires:` as the classifier. `requires:` is a minimum-capability
    declaration — Snowflake declares `requires: [cli]` yet legitimately uses shared
    `default_warehouse` / `pii_role` / dev-target settings.
  - `gdrive.base_path` is not a credential: it selects the BACKUP DESTINATION, a team decision, while
    the local mount prefix is per-user. Split it — team-level drive/folder identity in tier 1, machine
    mount root in tier 3.

### The resolver
Add `bin/effective_config.py`, the single authority merging all three tiers. NINE executables parse
`stack.yaml` independently today: `bin/verify_stack.sh`, `bin/resolve_user.py`, `bin/handoff.sh`,
`bin/build_ticket_index.py`, `bin/selftest.sh`, `.claude/hooks/session_context.py`,
`.claude/hooks/_stack.py` (an imported module), `.claude/hooks/db_write_guard.py`, and
`.claude/statusline.sh`. Migrate ALL of them. An overlay only some understand leaves production paths
on committed values while appearing to work.

Contract — a public CLI, not a hook helper:
  - `bin/effective_config.py --root <repo> --json`, no Claude env var required.
  - Stable JSON schema: resolved values, per-key provenance (team | person | machine | inherited),
    selected target, validation errors. Documented exit codes distinguishing missing, malformed,
    stale, and prohibited-override.
  - Correct merge for `seams.warehouse.targets.<name>`, honoring the existing inheritance rule: a
    target inherits any key it does not define, and an explicit `verify: null` means skip rather than
    fall back to the seam's command.
  - YAML PARSING — DECIDED, do not re-open. `pyproject.toml` advertises "Zero runtime dependencies —
    the kit is deliberately stdlib-only", so the resolver MUST NOT shell out to `yq`: that would make
    a shell binary a hard dependency of a pip package promising none. Define an explicit supported
    YAML subset in Python, validate input against it, and fail loudly with a pointer when a config
    uses something outside the subset. `bin/verify_stack.sh` then calls the resolver instead of `yq`,
    which also removes its current hard `command -v yq || exit 1` requirement. Context:
    `bin/verify_stack.sh:20` HARD-REQUIRES `yq` and exits without it, while
    `bin/build_ticket_index.py` uses narrow regex readers. Pick one and document it: declare `yq` a
    dependency of the resolver, or define an explicit supported YAML subset and validate against it.
    Do not silently regex-parse arbitrary YAML.
  - Update AGENTS.md so EVERY harness is told to call the resolver before acting. A model reading raw
    `stack.yaml` bypasses the overlay entirely.

### The leak fix, now expressible against the resolved model
  - A `verify:` command must never embed a MACHINE-LOCAL LITERAL. Use `{token}` interpolation where
    it needs a personal value — verified working at the multi-target level:
    `verify: "databricks --profile {profile} current-user me"`.
    This is NOT "every verify needs a token". Tokenless verifies are correct and must stay:
    `snow connection test` (`adapters/warehouse/snowflake.md:9`), `bq query --dry_run "SELECT 1"`
    (`adapters/warehouse/bigquery.md:9`) name nothing machine-specific.
  - `bin/verify_stack.sh` warns when committed `stack.yaml` holds a literal in a key declared as a
    `user_keys` key for that adapter. Key the warning on the DECLARATION, not on whether the verify
    string happens to contain some unrelated token — a literal `profile: biprod` alongside a
    `{warehouse_id}` token must still warn. Warn, never fail.
  - `/setup` writes tier-1 values only.

Tests: scope enforcement (a local file overriding `catalog` is rejected), stale fingerprint,
malformed local file, `person:` accepted without an adapter declaring it, and each of the nine
consumers reading merged rather than raw values.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 2. Put both verdicts in the PR body.

## PROMPT 3 — Resolve WHO is working, as a harness-neutral command

`bin/resolve_user.py` already resolves the current local identity deterministically — but only to a
VOICE-PROFILE id, returning nothing when `project.voice_profiles.map` is absent. The limitation is
scope, not absence. Generalize it for owner routing without making an optional, privacy-sensitive
feature a hard dependency.

FATE OF `bin/resolve_user.py`: `whoami.py` supersedes it. Keep `resolve_user.py` as a thin shim
that calls `whoami.py` and maps the result to a voice-profile id, so the voice feature keeps working
after PROMPT 2 moves `voice_profiles.map` out of `stack.yaml` — then delete the shim in a later
release. Do NOT leave two independent identity resolvers, and do NOT delete it outright while
`/ship` still calls it.

Ship it as `bin/whoami.py --root <repo> --json`, returning status `resolved` | `miss` | `ambiguous` |
`conflict`, never guessing. Skills and hooks CALL it. A Claude SessionStart hook may DISPLAY the
result; it must never be the resolver or the write path — a command hook can print text, it cannot
run an interactive question. Every ticket-opening and shipping workflow calls it first, in any
harness.

RESOLUTION ORDER (first hit wins; all matching exact):
  1. `person: <id>` in tier 3 — an explicit self-declaration on THIS machine, so a shared or oddly
     configured box is a one-time fix and git config never has to be right.
  2. `$TICKETWRIGHT_PERSON` — CI and headless.
  3. The identity map: `git config user.email` → `git config user.name` → `$USER`, matched
     case-insensitively after trimming. Case-folding and trimming are the ONLY normalization
     permitted; neither can produce a wrong person.
  4. Miss → status `miss`; the host agent runs the self-healing interview.

MANY IDENTITIES PER PERSON, enumerated not inferred — this is what removes brittleness when someone's
`$USER` is `jason` but their git email is `jason.young@company.com`:

    id: jyoung
    name: Jason Young
    identities: [jason.young@company.com, jyoung@company.com, "Jason Young", jyoung, jason]

SELF-HEALING. Do NOT add fuzzy matching — `bin/resolve_user.py` refuses name-to-folder inference on
purpose, because a wrong guess silently misfiles work or drafts comms in the wrong person's voice.
On `miss`, the host agent asks once ("I don't recognize `jason.young@company.com`. Who are you?")
then calls a separate mutation command, e.g. `bin/whoami.py --bind <id>`, appending that identity to
`people/<id>.yaml` and pinning `person: <id>` in tier 3. Next session resolves exactly, forever. The
person's own answer is authority — that is asking, not guessing.

STATUS HANDLING:
  - `ambiguous` (one identity matches two people): ASK. Never rank or pick. Same discipline
    `bin/recall.py` already applies to duplicate seed ids.
  - `conflict` (tier 3 says `jyoung`, git email maps to `kchalmers`): tier 3 still WINS —
    first-hit-wins is not weakened — but emit a one-line warning naming both. Usually a shared
    machine or a stale repo-local git config, and it must surface before work lands in a colleague's
    folder.
  - `miss`, non-interactive: resolve to NO owner. Do NOT fall back to `project.assignee_dir` —
    silently filing a new teammate's work under whoever set the repo up is the failure mode hardest
    to notice. Keep `assignee_dir` as the documented last resort only when no people map exists.

MUTATION AUTHORIZATION: a person may bind identities to their OWN `people/<id>.yaml` only. Binding an
identity to someone else's file requires explicit confirmation naming both people. On concurrent
edits, re-read before writing and append rather than rewriting the file.

PRIVACY: identities are committed by default (these are private analysis repos). When `--bind`
detects a PUBLIC remote, warn ONCE and offer a handle or `$USER` instead of an email. Also correct
`.claude/skills/setup/voice.md` (the line reading "to keep one private, gitignore `voices/<id>.md`"), which currently suggests gitignoring a committed file as a
privacy measure — that does nothing once git tracks it.

DISPLAY, so a wrong resolution is caught immediately: one line — "Working as Jason Young (jyoung) —
new analyses go in tickets/jyoung/ unless told otherwise."

Tests: each resolution tier, self-healing miss, ambiguity, machine-vs-git conflict, non-interactive
miss, cross-person bind refusal.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 3. Put both verdicts in the PR body.

## PROMPT 4 — Split /setup's verbs by scope, and auto-route teammates

Depends on PROMPT 3 (`whoami`) and PROMPT 2 (tier files).

`/setup` has five modes dividing along a scope axis nobody has named. The axis is NOT
committed-vs-local — `--voice` is person-scoped yet writes committed files. It is TEAM vs PERSON:

  TEAM-scoped   → writes team config:    default (configure repo), `<seam>` (e.g. `/setup chat`)
  PERSON-scoped → writes person config:  `--teammate`, `--voice`, `viewer`

(a) SCOPE COLLISION. `/setup chat` and `/setup viewer` share one syntax and mean opposite things —
the docs concede "viewer — the only seam that is NOT written to stack.yaml". Split:
  - `/setup tool <chat|docstore|warehouse>` — team-wide, writes committed `stack.yaml`.
  - personal config folds into the per-person flow, not a `/setup <word>` verb.
  - `/setup viewer` SPECIFICALLY: keep it working as a re-run entry point. The just-in-time interview
    at the `/review` gate stays the primary path (see "Do not rebuild"), and `teammate.md` still
    points at it. Do not delete this verb; only stop describing it as a "seam" mode alongside the
    team-wide tool verbs.
  - Old spellings keep working for one release with a deprecation line.
  - `/setup tool chat` is now the CANONICAL wording. THIS PROMPT OWNS IT; prompt 6 consumes it.
    Update every reference in the skills and docs here.
  - "Seam" is internal architecture vocabulary and must never appear in a user-facing question,
    option label, or error message.

(b) A PERSON-SCOPED MODE WRITES TEAM CONFIG. `--voice` puts `project.voice_profiles.map` — a person's
work email and name — into committed `stack.yaml`. Move it to `people/<id>.yaml` per PROMPT 2.

(c) WRONG DEFAULT BRANCH FOR A NEW CLONER. Phase 1 currently says: if `stack.yaml` exists → "offer to
edit, don't overwrite". New rule: if `stack.yaml` exists AND `bin/whoami.py` returns `miss`, this is
a TEAMMATE — route to `teammate.md` automatically. Editing the team's shared config must never be a
new cloner's first offered action. `--teammate` remains an explicit re-run.

Make the per-person flow the SOLE writer of tiers 2 and 3; it must never edit committed `stack.yaml`.
It must:
  - Detect the person's tools AT THAT MOMENT, not reuse repo-setup-time detection. When probing
    Databricks, enumerate every profile in `~/.databrickscfg` rather than trusting the default — a
    real run had an expired refresh token on DEFAULT while another profile worked fine, which reads
    as "Databricks unavailable".
  - Write tier 3 as a VERSIONED document: `schema_version`, a mode of `defaults` or `overrides`, and
    a fingerprint of the committed stack it was completed against. File existence alone cannot
    distinguish empty, half-finished, "I chose team defaults", or stale-after-the-stack-changed.
  - Finish with verification bound to the EXPECTED target: assert the account/workspace identity
    matches what committed `stack.yaml` names. "The CLI responded" is not proof the person reached
    the right warehouse.
  - Author every question as PROSE INSTRUCTIONS, not an `AskUserQuestion` tool-call payload, so other
    runtimes render a numbered list and the interview means the same thing everywhere.

State the invariant at the top of `.claude/skills/setup/SKILL.md` and enforce it: team verbs write
team config, person verbs write person config, no mode writes both.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 4. Put both verdicts in the PR body.

## PROMPT 5 — Make owner part of ticket identity

Depends on PROMPT 3. Owner is not currently part of a ticket's identity; making it so touches lookup,
the graph, cross-references, branch names, and CLI UX across every skill.

Already works: `bin/build_ticket_index.py` discovers owners generically by walking `tickets/<owner>/`
one level down and keys rows by `(owner, id)`.

What breaks:
- Graph aggregation keys by BARE id (`bin/build_ticket_index.py:669-724`), so two owners with the
  same slug collapse into one node with merged owners and objects. `id_mode: slug` makes this likely
  — two people both writing `chargeback-lift`.
- Object backlinks key the same way, so owner-qualifying graph FILENAMES alone does not fix it.
- `bin/enrich_ticket.py` enriches EVERY owner folder matching an id.
- `/ticket`, `/ship`, `/review`, and `/spec-and-build` all take an unqualified `<id>` and render
  `project.ticket_path`, so none can safely resume or ship another analyst's work. Branch names are
  also bare `<id>`.

DEFINE ONE UNIVERSAL TICKET LOCATOR FIRST, then apply it everywhere — graph nodes, object backlinks,
recall, branch naming, and all four skills must agree on identity, or they will disagree in ways that
only show up months later. Specify:
  - the locator grammar (e.g. `owner/id`, with bare `id` allowed when unambiguous);
  - what a bare `[[wiki-link]]` means when two owners have that slug;
  - a migration for repos whose existing links are all bare.

Follow the precedent already here: `bin/recall.py` requires `--owner` to disambiguate duplicate seed
ids. Ambiguity is a hard stop, never a guess. New work defaults to the PROMPT 3 resolved person.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 5. Put both verdicts in the PR body.

## PROMPT 6 — Two fixes (NOT both small, and NOT independent — read the notes)

1. `templates/AGENTS.md.tmpl` composes adapter paths from the tool name, so a deliberately
   unconfigured seam renders broken markdown like `adapters/chat/— *(none; /setup chat)*.md`.
   DO NOT try to add a conditional to the template: `bin/render.sh` renders via a flat
   `perl -pe s/{{key}}/value/g` pass, so the TEMPLATE LANGUAGE has no conditional — a
   "seam absent" branch is not expressible there. (The script has bash `if`s for its own argument
   parsing; that is not a template construct.)
   The kit already solved this for one seam — `warehouse` passes a WHOLE-PATH token
   (`{{warehouse_adapter}}`) instead of composing `adapters/warehouse/{{warehouse_tool}}.md`.
   Do the same for tracker, chat, docstore and vcs, so an absent seam supplies a token that renders
   the enabling command (`/setup tool chat`) rather than a broken path.
   Three files change, not one: the template, `.claude/skills/setup/scaffold.md` (which tells the
   agent which tokens to pass and currently says nothing about absent seams), and the `vars.env`
   fixture in `bin/selftest.sh` that feeds the zero-leftover-token check.
   Depends on PROMPT 4 for the canonical `/setup tool chat` wording.

2. `/setup` asks for a tracker and a ticket key prefix but never checks whether the corresponding
   project is ALIVE. In a real run the Jira project whose name matched the repo best had exactly one
   issue ever, still in Backlog, while two others had 100+ updates in 90 days.
   Add this as a TRACKER ADAPTER VERB — `rank_projects_by_activity` — not a JQL branch inside the
   skill. THIS IS NOT A SMALL FIX AND IT TRIPS THE SELFTEST TRAP: `bin/selftest.sh` asserts
   `tracker) echo 6` by EXACT EQUALITY against `grep -c '^## verb:'` for all seven tracker adapters
   (jira, azure-devops, linear, asana, monday, github-issues, local). DEFAULT DECISION: implement the
   verb in ALL seven adapters and raise the expected count to 7 — an adapter that cannot rank
   documents the verb and returns "unsupported", which is what the fallback needs anyway. Do not
   weaken the equality check to a required-set; that removes a real guardrail. JQL is Jira-specific and embedding it in `/setup` violates the kit's tool-agnostic rule
   (`docs/architecture.md:38-52`). Define the verb's input/output contract, implement it for the
   adapters that can support it, and define the fallback where a tracker cannot expose activity:
   skip the ranking silently and ask as today.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 6. Put both verdicts in the PR body.

## PROMPT 7 — Runtime completion

Depends on PROMPT 1 (research + adapters + kit-location CLI) and on PROMPTS 2–5 having settled
canonical behavior. Now make it actually installable and runnable elsewhere.

1. INSTALLER: `bin/install.sh --runtime <name> [--global|--local]`, emitting runtime-native artifacts
   from the canonical source. Claude Code keeps its plugin manifest; Codex gets `SKILL.md` files at
   its skills root; others per their PROMPT 1 adapter. Document that hand-copying is unsupported —
   the installer IS the compatibility layer. Reconcile with the existing `ticketwright init` PyPI
   path rather than adding a competing third install route.

2. CANONICAL SOURCE LAYOUT. The source is `.claude/skills/` with `skills/` a symlink, and
   `pyproject.toml` force-includes that Claude-shaped path. Decide whether to move it to a neutral
   root or keep it and translate on emit — and record why.

3. PORT SKILL METADATA. Frontmatter is Claude-specific: `allowed-tools`, `disable-model-invocation`,
   and the `tools:` field in `.claude/agents/qc-reviewer.md`. Map each to its per-runtime equivalent,
   or document what is lost. Note `disable-model-invocation` has real safety meaning for `ship`,
   `setup` and `productize` — if a runtime cannot express "user-invocable only", say so rather than
   silently making those model-invocable.

4. DEGRADE THE HOOKS HONESTLY. The four hooks do real work: `db_write_guard` (the ONLY mechanical
   enforcement of `db_write_requires_approval`), `session_context`, `ticket_index_context`,
   `regenerate_ticket_index`. Per PROMPT 1's research, for each runtime:
     - re-express each hook as a CLI the workflow calls at the equivalent point;
     - where the runtime CAN gate a tool call, wire `db_write_guard` into it;
     - where it cannot, state plainly in that runtime's rendered AGENTS.md that
       `db_write_requires_approval` is GUIDANCE, not enforcement. The kit already draws this
       distinction — extend it rather than implying parity.
     - A missing hook must never SILENTLY weaken a safety policy.

5. SUBAGENT DEGRADATION. `/review --deep` fans out `qc-reviewer` subagents. Where a runtime has no
   subagent primitive, define the inline fallback and state that it is a weaker check — a
   same-context review is not the independent second pass the validation pyramid assumes.

Success criterion: a Codex CLI user can install the kit, run setup, open an analysis, review it, and
ship it without hand-editing a file — and the Claude Code path is unchanged.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 7. Put both verdicts in the PR body.

## PROMPT 8 — Let a capability hold more than one tool

Real teams have Jira AND Linear, Slack for external AND Teams for internal, Drive AND Dropbox,
Snowflake AND Databricks AND Postgres. Today only `warehouse` supports named targets.

WHAT IS AND ISN'T BEING CHANGED. The five seam KINDS stay. A seam kind is a VERB CONTRACT skills
call (`tracker` = fetch_ticket/create_ticket/transition/comment/search), and adding a sixth kind
means inventing verbs and teaching every skill to call them. A sixth kind is justified only when it
has a stable tool-independent verb contract, a distinct lifecycle responsibility and safety boundary,
its own auth/verification/routing semantics, and enough common use that it isn't just an option on an
existing seam — a deployment/release-control seam might qualify; "another place to send a message"
does not, that is `chat` with two targets. What changes is the number of TOOLS per kind.

Fix the docs first: `.claude/config/stack.schema.md:59` says five keys "no others", which is already
contradicted by the optional `viewer` seam documented at `docs/architecture.md:54`. Replace the
exclusivity language with an accurate statement — these are the five kinds with verb contracts, the
`targets:` shape is generic, and operational support per kind is stated explicitly.

The verifier is already generic: `bin/verify_stack.sh:111` iterates every configured seam and
handles inheritance, target overrides, default validation and per-target verification. The SKILLS
are what assume a single mapping. Specifically: `/ticket` verifies one tracker and one vcs and
branches from `seams.vcs.default_branch`; `/ship` backs up through one docstore, comments through one
tracker, drafts to one `default_channel`, opens one PR; `/setup`'s interview has no target-routing
step; `templates/AGENTS.md.tmpl:24` renders one tool per seam; `.claude/statusline.sh:26` reads
tracker as the first `tool:`.

TARGET SELECTION IS AN EXTENSION OF `bin/effective_config.py` (PROMPT 2), NOT A SECOND BINARY.
Prompt 2's resolver already merges `seams.warehouse.targets.<name>` with inheritance; selection is
the same component's job. Add a `--seam <name> --target <name>` mode to it rather than shipping
`bin/resolve_seam_target` alongside — two binaries means two YAML parsers, two `--root` conventions,
two provenance models, and two answers to "which warehouse am I on". Precedence is documented in
`adapters/README.md`, which already has a "Resolving the active target" section to extend.
Publish the exact contract before implementing: the flags, the JSON shape, and the persisted
delivery-plan schema (audience, classification, chosen target, destination, docstore sharing scope).
A fresh agent must not have to invent safety-critical storage rules.

SEQUENCE, smallest-valuable-first. Do NOT do all five at once:
  1. Docs fix + the resolver + TARGET-AWARE APPROVAL RENDERING (below).
  2. `chat` and `docstore` — the biggest practical win (internal vs external comms, archival vs
     client delivery).
  3. `warehouse` stays as-is; it already works.
  4. DEFER `tracker` until disjoint target-owned prefixes and per-target URL templates exist.
  5. DEFER `vcs` until PR routing is bound to a specific remote.

ROUTING RULES, per kind:
  - chat: selected by an explicit declared audience in the delivery plan; `--chat <target>` may
    override before drafting. NEVER infer internal-vs-external from prose, channel names, or labels.
    On send, no silent fallback to another target.
  - docstore: selected per deliverable from a declared classification (e.g. internal_archive vs
    client_delivery). Record the chosen target alongside the delivered file so `link_for` is always
    called against the same store.
  - warehouse: unchanged — the `.sql` file names its own target in a header comment, which works
    precisely because the SQL file IS the executable artifact.
  - tracker (deferred): explicit flag, else the ticket's immutable recorded target, else a unique
    configured id-prefix match; halt on ambiguity; creation requires an explicit target unless
    exactly one is configured.
  - vcs (deferred): local operations follow the checked-out repo; PR target comes from the configured
    remote matching origin. A mirror is never an implicit second PR destination.

SAFETY — this is the part that can leak client data:
  - Each `chat` target declares its OWN audience, channel, and non-empty `always_include`. Apply that
    list AFTER routing, never inherited from another target. SCOPE THE REQUIREMENT: "non-empty" binds
    only when `targets:` is present. A single-target chat seam that omits `always_include` must keep
    validating, or every shipped example config breaks — that violates the standing constraint.
  - Say explicitly what happens to seam-level `default_channel` / `default_mode` when `targets:` is
    present: inherited by targets that do not define their own (consistent with the existing
    inheritance rule), and never used as a silent fallback when routing fails. Today it is scoped to a single
    `seams.chat.always_include` (`.claude/config/stack.schema.md:243`).
  - `/ship` currently asks one generic approval before the docstore→tracker→chat sequence
    (`.claude/skills/ship/SKILL.md:45`). Change it to print the RESOLVED PLAN — target, platform,
    destination/channel, recipient list, docstore sharing scope, exact actions — so the human
    authorizes that plan, not the word "ship". Docstore links are shareable URLs; a wrong target is
    a disclosure, not an inconvenience.

IDENTITY WARNING for whoever eventually does `tracker`: `project.key_prefixes` today only means
"recognize these folder ids" — it does NOT map an id to a tracker. Branches are bare `<id>` and
`bin/build_ticket_index.py:541` derives URLs from one project-wide template. Multi-tracker is safe
ONLY in `id_mode: keyed` with disjoint target-owned prefixes and per-target URL templates. Supporting
overlapping ids is a full identity migration where canonical identity becomes
`tracker_target + native_id`, with collision-safe folder/branch forms and target-carrying index
records. Do not pretend `key_prefixes` solves it.

---

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 8. Put both verdicts in the PR body.

## PROMPT 9 — Lead the docs with WHY, not with the seam list

The kit's own docs bury its value. `docs/architecture.md:17` states the lifecycle, then immediately
leads its next major section with seams — so a reader meets the implementation detail before the
point. Restructure README.md and docs/architecture.md to lead with what this thing is FOR.

### The framing to lead with: a team brain
A ticketwright repo is a shared corpus of tickets that makes a team's past work instantly available to
both people and AI. Every analysis lands in one place with its business context, its assumptions, its
QC verdict and its deliverables, so any teammate — or any agent — can find prior work, judge whether
it applies, and reuse it instead of rebuilding it. The team becomes interchangeable parts: I can
reference your analysis, you can reference mine, and neither of us has to interrupt the other to do
it. And because the corpus is machine-readable, the assistant gets better at the team's domain the
longer the team uses it.

Concrete benefits to state, each tied to the mechanism that delivers it:
  - PRIOR-ART RECALL COMPOUNDS. `/ship`'s enrich step writes a curated summary to
    `tickets/index_data.json`, which is what `bin/recall.py` ranks against. Every shipped ticket THAT
    GETS ENRICHED makes the next search better. Be accurate about the mechanism: enrichment is a
    convenience step that can fail or be skipped, and `bin/ingest_index_records.py` is the
    agent-neutral path — so name the failure mode plainly: skip it and the corpus rots into a folder
    of SQL nobody can find.
  - OBJECT-LEVEL MEMORY. `tickets/OBJECTS.md` maps every warehouse object to the tickets that touched
    it — "has anyone used this view, and what did they learn about it?" This is the institutional
    knowledge hardest to keep in people's heads.
  - ASSUMPTIONS MAKE PRIOR WORK CITABLE. The `reduce_assumptions` policy requires assumptions in the
    ticket README (a workflow policy the skills honor, not a mechanically enforced one). Without them an old analysis is unciteable, because you cannot tell whether its
    numbers apply to your question. This is what separates a knowledge base from a file dump.
  - QC VERDICTS ARE A QUALITY SIGNAL ON THE CORPUS. `/review`'s verdict sits next to the deliverable,
    so a reader can tell validated work from exploratory work before reusing it.
  - OLD WORK IS RE-RUNNABLE, NOT JUST READABLE. `deterministic_outputs` (explicit ORDER BY, golden
    replay) means a prior analysis is executable, a stronger claim than a document.
  - CONTINUITY. When someone leaves, their reasoning survives, not just their SQL.

### The lifecycle is the primary map; seams are secondary
Lead with the phases, then show a seam-to-phase matrix — which makes clear that one seam can serve
several phases, and that "more tools" means named TARGETS inside a capability, not more capabilities:

  1. Open the work        — tracker + vcs
  2. Do the work          — warehouse / local tools
  3. Quality-check it     — NO shared external seam; this is /review plus human sign-off.
                            The viewer is a per-user helper, not a team seam.
  4. Deliver              — vcs + docstore
  5. Announce and share   — tracker + chat

Phase 3 is the one worth calling out explicitly, and word it PRECISELY. It is not that quality
checking touches nothing external — `/review` re-runs queries through the warehouse adapter, and so
does the `qc-reviewer` agent. It is that quality checking has NO SEAM OF ITS OWN. Every other phase
has a dedicated external system AVAILABLE to it: a tracker to open work, a warehouse to query, a
docstore and vcs to deliver, a chat to announce. Say "available", not "always present" — trackerless,
warehouse-less and docstore-less configurations are all supported and documented. Phase 3 borrows the warehouse to re-verify, and its actual
gate is a person reading the output — with the viewer that opens those files deliberately per-user
rather than a team seam. Do not call it simply "gitignored" — prompt 2 moves the portable half of
viewer config into committed `people/<id>.yaml` and leaves only machine wiring local.

That is why the seam list is the wrong thing to lead with: the phase this kit is proudest of does not
appear in it. Do not overstate this to "phase 3 calls no external tool" — that is false and a careful
reader will catch it.

### Before restructuring: the docs are TESTED
`bin/selftest.sh` asserts literal strings in these files. A restructure that rewrites the opener can
delete them and go red. Preserve, or update in the same change: the token `id_mode` must still appear
in `README.md`; `docs/architecture.md` must still contain `**<N> adapters**`; `ROADMAP.md` must still
contain `- <N> adapters across <M> seams` and the worked-stack count. Re-run the selftest as part of
this prompt, not after it.

### Describe the graph layer accurately — and do not undersell it
The Obsidian graph layer (`tickets/graph/`, `tickets/objects/`) and the machine-readable catalog
(`tickets/INDEX.md`, `tickets/OBJECTS.md`, `bin/recall.py`) are TWO RENDERINGS OF ONE RELATIONSHIP
MODEL, generated from the same cross-reference resolution in `bin/build_ticket_index.py`. Each is
tuned to its reader: the graph is how a PERSON sees the shape of the corpus at a glance — which
analyses cluster, which warehouse objects are load-bearing across many tickets, where the orphans
are. The catalog is how an AGENT queries the same relationships.

Write it that way. The accuracy requirement is only this: do not imply the graph is the thing that
feeds the assistant, because an agent reads the catalog, not the graph. That is a statement about
which artifact serves which reader — not a limitation, and the docs should not read like an apology.
Both are generated and stay in sync automatically. Note `/ship` currently stages `INDEX.md`,
`OBJECTS.md` and `index_data.json` but not `tickets/graph/` or `tickets/objects/` — state what is
actually committed rather than assuming symmetry, or fix the staging.

Worth recording as a genuine future enhancement rather than a current feature: the graph's link
structure is the only artifact that supports MULTI-HOP traversal — "what connects these two analyses,
two hops out, through which shared objects" — which `OBJECTS.md` cannot answer, since it holds a
single hop from object to tickets. Exposing that to agents would make the graph load-bearing for both
readers.

GATES (non-optional, see "MANDATORY: codex reviews the plan AND the result" above): run codex
on your PLAN before writing code, and on the resulting DIFF before opening the PR. Substitute
PROMPT 9. Put both verdicts in the PR body.

