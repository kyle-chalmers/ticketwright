# Architecture — how Ticketwright is built

This is the contributor-facing map. Users don't need any of this; [the README](../README.md)
quickstart is enough to work tickets.

## The AI-layer model

Every repo has a **code layer** (the work) and an **AI layer** (the rules + context + workflows
that guide an agent), versioned together. The AI layer has three tiers:

| Tier | Here | Loaded |
|---|---|---|
| **Global rules** | `AGENTS.md` (rendered from `templates/AGENTS.md.tmpl`; Claude Code loads it via a one-line `CLAUDE.md` `@AGENTS.md` import) | always |
| **On-demand context** | the `documentation/` pack · `/ticket`'s priming slices · `tickets/INDEX.md` + `OBJECTS.md` | selectively |
| **Skills** | `.claude/skills/` (7) | on invocation |

The lifecycle the skills implement — plan → build → check → ship — descends from the PIV loop
(Plan → Implement → Validate) in Cole Medin's "agentic engineering" / Archon material, which also
supplied the AI-layer model and the context-engineering stance (AI fails from missing context, not
weak models).

## Seams, adapters, and the verb contract

A **seam** is a tool slot the kit needs filled: `tracker`, `warehouse`, `chat`, `docstore`, `vcs`,
and the optional `viewer`. A seam may name one tool or several **named targets** (v1: `warehouse`),
and a seam whose tool is absent can still be filled by an adapter over local files — that is how a
repo with no tracker runs unchanged. The wiring is hybrid — config names the tools, verification
proves them:

1. **`.claude/config/stack.yaml`** names which tool fills each seam + project facts + the 10
   policies. Schema: [.claude/config/stack.schema.md](../.claude/config/stack.schema.md).
2. **`adapters/<seam>/<tool>.md`** maps the abstract **verb contract** (`fetch_ticket`, `query`,
   `draft`, `backup`, `commit`, …) to that tool's concrete commands. Contract:
   [adapters/README.md](../adapters/README.md).
3. **`bin/verify_stack.sh`** pings each seam's read-only `verify` before use — reachable seams
   run, unreachable ones halt with the adapter's auth notes.

Skills are written **once against verbs** and never name a tool. Swapping a tool = edit
`stack.yaml` + point at a different adapter; **no skill changes.** Proof: six configs ship —
[`stack.yaml`](../.claude/config/stack.yaml) (Jira/Snowflake/Slack/Drive/GitHub),
[`stack.example.asana-bq.yaml`](../.claude/config/stack.example.asana-bq.yaml)
(Asana/BigQuery/Teams/SharePoint/GitLab), and
[`stack.example.azure.yaml`](../.claude/config/stack.example.azure.yaml)
(Azure DevOps/Synapse/Teams/SharePoint/Azure Repos),
[`stack.example.multi-warehouse.yaml`](../.claude/config/stack.example.multi-warehouse.yaml)
(Snowflake **+** Databricks — two targets in one seam),
[`stack.example.solo.yaml`](../.claude/config/stack.example.solo.yaml) (**no tracker**, no chat, no
docstore — the ticket folder is the tracker), and
[`stack.example.no-warehouse.yaml`](../.claude/config/stack.example.no-warehouse.yaml) (**no
warehouse** — document/report deliverables, nothing to query) — the same skills run against all six.

**Adding a tool:** write one adapter (copy the closest reference in the same seam; implement every
verb section; keep the frontmatter), add a `verify` line to your `stack.yaml` seam, run
`bash bin/verify_stack.sh`. No skill edits.

**The one seam whose config is not in `stack.yaml`:** `viewer` — which application opens a `.sql`
or a `.csv` at a review gate. Every other seam names a tool the whole team shares; this one is a
personal preference, and a committed entry could never ask a new cloner what *they* want. So the
repo decides **when** a gate fires (policy `human_review_handoff`) and each person decides **what**
it opens, in a gitignored `.claude/config/viewer.local.yaml` (or a user-level file covering all
their repos). `bin/handoff.sh` resolves the layers and owns the rails — it never launches in CI or
a headless session, never opens a path outside the project, and is a silent no-op when nothing is
configured. Details: [.claude/config/viewer.example.yaml](../.claude/config/viewer.example.yaml).

## Config is three tiers behind one resolver

`stack.yaml` is committed and shared, so a value true only on one machine does not belong in it — a
real `/setup` run put a warehouse profile name and a hardcoded verify command into it, handing every
teammate one person's machine. Config is therefore three files:

| Tier | File | Committed? | Holds |
|---|---|---|---|
| 1 team | `.claude/config/stack.yaml` | yes | which tool fills each seam, which data the team reads, the 10 policies |
| 2 person, portable | `people/<id>.yaml` | yes | display name, identities, comms voice, file-type preferences |
| 3 person, machine | `.claude/config/connections.local.yaml` | no | named profiles/connections, local mount roots |

[`bin/effective_config.py`](../bin/effective_config.py) is the single authority that merges them, and
every consumer goes through it — nothing parses `stack.yaml` on its own any more. It is a public CLI
needing no agent-specific environment variable, so it answers the same way under any harness.

**WHO is working is resolved the same way.** [`bin/whoami.py`](../bin/whoami.py) is the single
identity resolver (tier-3 `person:` → `$TICKETWRIGHT_PERSON` → the identities each person
enumerates in `people/<id>.yaml`; statuses `resolved`/`miss`/`ambiguous`/`conflict`). It never
guesses: a miss is answered by asking the person and recording the answer with
`whoami.py --bind <id>`, an ambiguity is asked about rather than ranked, and a machine pinned to
one person while git says another wins for the pin but warns naming both. `bin/resolve_user.py` is
a thin shim over it that maps the resolved person to a voice profile, kept while `/ship` still
calls it. The Claude SessionStart hook only *displays* the result ("Working as …") — it is never
the resolver or the write path. Every ticket-opening and shipping workflow (`/ticket`, `/ship`,
`/review`, `/spec-and-build`) calls it first: the resolved person is the owner new work is filed
under, and owner is part of ticket identity — the locator is `owner/id`, bare `id` while exactly
one owner has it, a hard stop when two do (see `docs/ticket-index.md` § The ticket locator).

**The scope rule is code, not documentation.** Tier 3 selects credentials and local paths; it can
never change which catalog, schema, database or target is read, and it can never contribute a
`policies:` block. Which keys are personal is declared per adapter in `user_keys:` frontmatter.
Anything outside that allowlist is **rejected**, not ignored — a gitignored file nobody reviews must
not be able to switch a safety gate off, and quietly discarding the attempt would be just as bad as
honoring it.

YAML is read by [`bin/_yamlite.py`](../bin/_yamlite.py), an explicit supported subset in stdlib
Python that fails loudly with a `file:line` rather than misreading. That is what lets the resolver
keep the kit's zero-runtime-dependency promise, and it is why `bin/verify_stack.sh` no longer
requires `yq`.

**Two deliberate exceptions.** `db_write_guard` and its `_stack` helper still read the policy
in-process. Routing them through a subprocess resolver would turn their failure mode from fail-safe
(an unreadable policy gates MORE) into fail-open, because the hook wraps everything in a blanket
"never block a session" handler. The reasoning is written at the top of `.claude/hooks/_stack.py`,
and a selftest asserts the guard still gates with the resolver deleted.

## Policy enforcement (hooks)

Policies are only as good as the agent's memory unless something enforces them. The plugin ships
Claude Code hooks (declared in `.claude-plugin/plugin.json`; `setup` also wires them into a repo's
`.claude/settings.json` for non-plugin installs):

- **`db_write_guard.py`** (PreToolUse/Bash) — makes `db_write_requires_approval` mechanical.
  The policy is a three-value enum (`off` | `high_risk` | `all`, default `high_risk`), so routine
  additive work doesn't cost a confirmation while irreversible work still does. Classification is
  **default-deny**: only plain `CREATE`, `INSERT INTO`, `ALTER … ADD`, and `COMMENT ON` count as
  additive; everything else that mutates — *including anything the scanner doesn't recognize* — is
  high-risk. It sees SQL hidden in a `-f` file or a stdin redirect, and strips comments and string
  literals first so a verb quoted as data isn't mistaken for a statement. Read-only SQL takes an
  `allow` fast-path. Under `bypassPermissions` it emits a `systemMessage` instead of asking, since
  the operator has already opted out of prompting.
  The scanner itself lives in [`bin/sql_scan.py`](../bin/sql_scan.py) (one deterministic
  implementation, shared with the non-Claude shims — logic in `bin/`, hooks as presentation); the
  hook is the Claude-protocol presenter, and `tests/guard/golden.json` pins its stdin→stdout
  behavior byte-for-byte across that boundary. One failure mode is deliberate and new with the
  split: if `bin/sql_scan.py` cannot be imported, the hook asks on **every** Bash command in the
  configured repo (naming the broken module) rather than falling into its blanket fail-open
  handler — nothing can be classified, so everything gates, visibly.
- **`session_context.py`** (SessionStart) — primes every session with the configured stack, the
  skills, and the lifecycle.
- **`ticket_index_context.py`** (SessionStart) — surfaces the ticket catalog (counts + most recent
  tickets + a pointer to grep `tickets/INDEX.md` before starting related work).
- **`regenerate_ticket_index.py`** (PostToolUse/Write·Edit) — re-renders `tickets/INDEX.md`
  whenever a ticket folder changes.

The hook *files* above are the Claude-Code-specific presentation; the logic they present is
harness-neutral. [`bin/hook_shim.py`](../bin/hook_shim.py) adapts the same hooks to the other
runtimes' protocols (`--runtime <name> --hook <name>`, protocol selected by each runtime adapter's
`hook_protocol` frontmatter), and `ticketwright install` emits the wiring where a config location
is documented: `.cursor/hooks.json` (with `failClosed: true` — required configuration on a
fail-open-by-default runtime), `.agents/hooks.json` for Antigravity (PreToolUse guard +
PostToolUse index regen), and the `.opencode/plugins/` throw-to-deny wrapper
([`bin/opencode_tool_gate.js`](../bin/opencode_tool_gate.js)). Where the runtime has no ask tier
(codex-cli, opencode, devin), `high_risk` collapses to **deny-with-escape** — denied with a
message naming the one-shot re-approval (`TICKETWRIGHT_APPROVE=once` prefix or the
`.claude/config/approve.once` token, consumed on use) — never toward allow, and never blocking
additive work. Where even the config location is undocumented (codex-cli, devin), the installer
prints the manual wiring line instead of guessing a path. What each runtime mechanically enforces
vs. merely reads as guidance is stated per runtime × per hook in the rendered `AGENTS.md`
enforcement table (and in `.clinerules/` for Cline, whose users don't read AGENTS.md) — a missing
hook never silently weakens a policy. Whether each runtime *honors* its documented wiring is
live-verification work, tracked on the punch list ([`docs/live-verification.md`](live-verification.md),
whose honesty link `bin/selftest.sh` section 44 enforces), and the docs must not imply parity
before it is paid.

## What's inside

- **7 skills** (`.claude/skills/`): setup, ticket, spec-and-build, review, ship, productize,
  refresh — each SKILL.md is short, with depth in per-skill reference files
  (`ticket/priming.md`, `setup/adopt.md`, `productize/authoring.md`, …).
- **1 sub-agent** (`.claude/agents/`): `qc-reviewer` — the independent-context reviewer `/review`
  delegates to (one per pyramid layer in `--deep` mode). Where the runtime's adapter declares no
  user-definable subagents or an isolation posture of `none`/`unknown`, `/review` walks the same
  checklist inline and the verdict records `review_mode: inline-same-context` as the weaker check
  (`unestablished` isolation still fans out, recorded verbatim).
- **4 hooks + settings** (`.claude/hooks/`, `.claude/settings.json.tmpl`, `.claude/statusline.sh`).
- **30 adapters** (`adapters/`) across 7 directories — full verb coverage each, including a `local`
  tracker whose "API" is the ticket folder itself and three `viewer` adapters (one per OS). Six of
  those directories are tool seams; the seventh, `runtime/`, declares what each agent harness can do
  (see [runtimes.md](runtimes.md)) and carries no verbs, because it is not a tool the project calls.
- **Templates** (`templates/`): AGENTS.md (+ the one-line `CLAUDE.md` `@AGENTS.md` import), ticket
  README, plan, spec, `.gitignore` (deliverables committed by default; PII opts out via
  `*.private.csv` / a `private/` subfolder), role snippets, and the productized-skill skeleton.
- **`bin/`**: `verify_stack.sh`, `render.sh` + `render_and_validate.sh` (render gate),
  `split_and_export.sh`, `handoff.sh` (the review-gate opener),
  `selftest.sh` (the CI suite + hook unit tests), the config/identity resolvers
  (`effective_config.py`, `whoami.py` + its voice shim `resolve_user.py`), the runtime installer
  (`emit_runtime.py` + its shell convenience `install.sh` — see the next section), and the
  index/recall engines (`build_ticket_index.py`, `ingest_index_records.py`, `enrich_ticket.py`,
  `recall.py`) — all stdlib-only.
- **`ticketwright/`**: the pip package; the wheel bundles the kit under `ticketwright/_kit/` via
  `pyproject.toml` force-includes, so the repo layout is the single source.
- **`tests/`**: golden fixture trees for the installer (`tests/emit/<runtime>/`), pinned
  byte-for-byte by selftest. Repo-only — deliberately excluded from the wheel and sdist.

## Why the canonical source stays put (translate on emit)

`.claude/skills/` is the ONE canonical home of every skill, and the installer translates FROM it at
emit time — the source never moves, and no second copy is ever authoritative. This was decided, not
defaulted (see the settled decisions in [PLANNED-CHANGES](PLANNED-CHANGES.md)); the reasons matter
to anyone adopting or extending the kit:

- **Three things anchor the layout.** `pyproject.toml` force-includes the `.claude/*` paths into the
  wheel, `.claude-plugin/plugin.json` wires the hooks by their `.claude/hooks/` path, and the
  repo-root `skills/` symlink already gives other tools a neutral alias to the same files. Moving
  the source would churn all three for zero functional gain, because the installer translates to
  each runtime's layout anyway.
- **Emit only where the runtime cannot already see the canonical copy.** The split is per-runtime
  DATA (`reads_foreign_skills` / `skills_root` in `adapters/runtime/*.md` frontmatter), never a
  name in code: claude-code reads the canonical copy natively, and cursor, opencode, cline and
  devin read `.claude/skills/` directly — for all five the installer VERIFIES the canonical copy
  is reachable and emits no skills. A duplicate that exists only to be found is a duplicate that
  can go stale and silently win over the real file — that is the failure mode, and not emitting is
  the fix. The verify report also states the shared-file trap: one file, many readers, and a
  foreign reader ignores Claude-specific keys, so `allowed-tools` and `disable-model-invocation`
  are lost on those runtimes exactly as on an emit runtime lacking the primitive — warned per
  affected skill, and `--global` on them is a deliberate, explained no-op (a per-user copy would
  be a permanent stale-duplicate risk).
- **Where the runtime cannot see it, the emitted copy carries its provenance.** codex-cli and
  antigravity share one `.agents/skills/<name>/SKILL.md` emission (`name` + `description`
  frontmatter — the fields both accept) with a header naming the emitting version and the re-run
  command. Hand-copying between layouts is unsupported; the installer IS the compatibility layer,
  and it is provenance-aware — its own files are refreshed on re-run, a file it did not emit is
  never overwritten and fails the install loudly instead. `--global` emits into the adapter's
  declared `global_skills_root`, refusing where that value is `unknown` rather than guessing.
- **Safety metadata that cannot translate rides in the artifact.** A skill whose source declares
  `disable-model-invocation: true` is user-invocable-only by design; no emit runtime has that
  primitive, so the emitted file opens with a warning block saying that nothing mechanical
  prevents model invocation there. Every mapping and every loss — including the `qc-reviewer`
  agent's `tools:` line — is recorded per runtime in `adapters/runtime/<name>.md` § Metadata
  mapping; agent definitions are emitted wherever subagents are user-definable
  (`.codex/agents/*.toml`, markdown for cursor/devin/antigravity) and the loss is stated where
  they are not (cline) or the definition path is undocumented (opencode).

One implementation, three ways in: `ticketwright install` (the pip entrypoint registers
`bin/emit_runtime.py`), `bin/install.sh` (the shell convenience in the `bin/tw` launcher pattern),
or the script directly. There is deliberately no fourth install route.

## Design stances

- **No vector store.** Recall is lexical + structural (object match ×4, tag ×3, cross-ref +5,
  keyword ×1, IDF down-weighting, recency tiebreak) over a deterministic index. The
  rank → read-top-K shape scales past the point where the whole index fits in context.
- **Deterministic before model.** Catalog rendering, recall ranking, render validation, and export
  plumbing are all plain code the model *calls*, not prose the model *approximates*.
- **Degrade, don't die.** Missing seams skip their steps and name the fix (`/setup tool chat`);
  unreachable seams halt with auth notes only where proceeding blind would be wrong.
- **Out of scope (deliberately):** a heavy external knowledge-base/orchestration service
  (Archon-style retrieval over MCP). Task management is the tracker's job; orchestration is
  `/productize` + the host agent's own subagents.
