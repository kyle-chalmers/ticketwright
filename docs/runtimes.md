# Runtimes — what each agent harness can actually do

Ticketwright is written once and meant to run under any coding agent. That claim is only honest if
someone has checked what each harness genuinely supports, so this page records the research behind
`adapters/runtime/*.md`.

**All findings were taken from official documentation on 2026-08-18.** These tools ship weekly; treat
every row as "true on that date" and re-check before relying on it. Where the public docs are silent
or contradictory, this page says so rather than guessing — an honest *unclear* is more useful than a
confident wrong answer, because the capability that matters most here is a safety gate.

**Re-verified 2026-08-19**, before wave F2 encoded the load-bearing rows as machine-readable adapter
frontmatter (see "The matrix, machine-readable" below). The gating picture held; three claims did
not, and each correction is marked inline at its bullet with the new access date: Devin's
approve/block stdout schema belongs to its separate `PermissionRequest` hook, not `PreToolUse`
(which blocks only via exit 2); OpenCode subagents are marked `mode: "subagent"` (invoked by
`@`-mention or the Task tool), not `subtask: true`; and Cline **does** document a global skills
path (`~/.cline/skills/` on macOS/Linux), which this page previously omitted. One planned
correction did **not** survive contact with its source and is recorded here so nobody re-applies
it: Devin skill frontmatter was reported as requiring `name` + `description`, but the cited
frontmatter reference table lists both with defaults (`name` → the directory name, `description` →
none), so the original "optional" reading stands. Bullets without a re-verified date carry the
original 2026-08-18 one.

**Two of the seven changed identity during this research**, which is itself a finding worth
recording: Google retired the standalone **Gemini CLI** on 2026-06-18 and consolidated on
**Antigravity** (`agy`), and Cognition renamed **Windsurf** to **Devin**. Both are documented under
their current names, with the old names kept as installer aliases, because a person types what they
have installed.

## Why these five axes

| Axis | What it decides for this kit |
|---|---|
| **Skills location + format** | where an installer must emit (PROMPT 7) |
| **Session-start callback** | whether `session_context` / `ticket_index_context` can exist at all |
| **Pre-execution tool gate** | whether `db_write_requires_approval` is **mechanical** or **guidance** |
| **Subagents** | whether `qc-reviewer` is an independent second context, or degrades to an inline pass |
| **Structured questions** | whether an interview can be a picker, or must be authored as numbered prose |

The third axis is the load-bearing one. `db_write_guard.py` is currently the *only* mechanical
enforcement of `db_write_requires_approval`; everywhere it cannot run, the policy degrades to the
skill-level hard-halts, which is guidance a model can forget.

## The short answer

The assumption this kit was built on — that hooks are a Claude Code exclusive and everywhere else
degrades to trust — **is out of date.** Five of the seven runtimes expose a programmable
pre-execution gate that can deny a call. What differs is not *whether* they gate, but how the gate
fails and whether it can escalate to a human instead of a flat refusal.

That distinction matters more than the yes/no. A gate that fails **open** on a malformed hook, or
that cannot ask a human and can only deny, is not the same safety property as one that fails closed
and supports an `ask` tier — and a table that collapses them into "✅ hooks" would misrepresent the
protection a team is getting.

## Capability matrix

| Runtime | Skills root | Session start | Pre-exec gate | Subagents | Structured questions |
|---|---|---|---|---|---|
| **Claude Code** | `.claude/skills/<n>/SKILL.md` | ✅ `SessionStart` | ✅ deny · allow · **ask** | ✅ own context window | ✅ `AskUserQuestion` |
| **Codex CLI** | `.agents/skills/<n>/SKILL.md` | ✅ `SessionStart` | ✅ deny · allow (**no ask**) | ✅ agent threads | ⚠ protocol-only, experimental |
| **Cursor** | `.cursor/skills/<n>/SKILL.md` | ✅ `sessionStart` | ⚠ deny · allow · ask, **fails open** | ✅ own context window | ⚠ external clients only |
| **Antigravity** | `.agents/skills/<n>/SKILL.md` | ❌ none in the CLI | ✅ deny · allow · **ask · force_ask** | ✅ own context window | ❓ docs silent |
| **OpenCode** | `.opencode/skills/<n>/SKILL.md` | ⚠ event only, no context injection | ✅ deny by throwing | ✅ mechanism documented | ✅ `question` tool |
| **Devin** | `.devin/skills/<n>/SKILL.md` | ✅ `SessionStart` | ⚠ block only, **fails open** | ✅ own context window | ⚠ schema unverified |
| **Cline** | `.cline/skills/<n>/SKILL.md` | ⚠ SDK only | ⚠ API in flux | ⚠ not user-definable | ⚠ undocumented |

✅ documented and unambiguous · ⚠ available with a caveat that changes its meaning · ❌ absent ·
❓ docs neither confirm nor deny

## The matrix, machine-readable

Since wave F2 (2026-08-19) the load-bearing rows above also live as frontmatter keys on every
`adapters/runtime/*.md`, read through `bin/kit_paths.py --json` — so installers and skills consume
declared data, never a parse of this page. The five keys, with the shipped values:

| Runtime | `gate_ask_tier` | `gate_fail_mode` ¹ | `subagent_isolation` | `reads_foreign_skills` ² | `global_skills_root` |
|---|---|---|---|---|---|
| **Claude Code** | yes | open | documented | none | `~/.claude/skills` |
| **Codex CLI** | no | unknown ³ | unestablished | none | `~/.agents/skills` |
| **Cursor** | yes | open | documented | `.claude/skills`, `.codex/skills` | `~/.cursor/skills` |
| **Antigravity** | yes | unknown | documented | none | unknown ⁴ |
| **OpenCode** | no | closed ⁵ | unestablished | `.claude/skills`, `.agents/skills` | `~/.config/opencode/skills` |
| **Devin** | no | open | documented | `.claude/skills` ⁶ | `~/.config/devin/skills` |
| **Cline** | unknown | unknown | none ⁷ | `.claude/skills` | `~/.cline/skills` ⁸ |

¹ The runtime's **native default** when a hook errors — not the installed state. Cursor is `open`
here precisely because an installer must set `failClosed: true` to compensate; the key records what
the runtime does on its own.
² What decides emit-vs-verify for an installer: where a runtime already reads the canonical
`.claude/skills/` copy, emitting a translated duplicate creates the stale-copy-silently-wins failure
mode, so the installer verifies reachability and emits nothing.
³ The docs state the deny paths, not what a crashing hook does.
⁴ Two official pages disagree on the global skills path — see the Antigravity section.
⁵ The deny mechanism *is* throwing ("throwing an error prevents the tool from executing"), so a hook
that errors denies; what an entirely-failed plugin *load* does is undocumented.
⁶ Devin's reading of other vendors' formats is toggleable in its config.
⁷ Subagents exist and are isolated, but are not user-definable — there is no kit-defined subagent to
isolate, so for the kit's purposes the answer is `none`.
⁸ macOS/Linux; Windows is `%USERPROFILE%\.cline\skills` (re-verified 2026-08-19 — this page
previously recorded only the global *rules* path, `~/Documents/Cline/Rules`).

Two rules the encoding carries, stated here so nobody re-derives them wrongly:

- **"Richer gate" and "has a session hook" are independent axes.** Antigravity has the richest gate
  researched and *no* session start; Devin has `SessionStart` and a gate that fails open *by
  documented design*. `gate_ask_tier`, `gate_fail_mode` and `session_start` therefore stay separate
  keys, and nothing may average them into a single capability score.
- **`unknown` and `none` are legal, permanent values.** Forcing a yes/no where the docs are silent
  manufactures a confident wrong answer. An unrecognized runtime floors per key —
  `gate_ask_tier` / `gate_fail_mode` / `subagent_isolation` / `global_skills_root` to `unknown`,
  `reads_foreign_skills` to `none`, the boolean rows to `no` — and every consumer must treat
  `unknown` as the never-optimistic case. Each `unknown` or `unverified` value here is owed a live
  re-check (the wave-F2 punch list, `docs/live-verification.md`, once U6 lands).

---

## Claude Code

- **Skills** — `.claude/skills/<name>/SKILL.md` (project), `~/.claude/skills/` (personal),
  `<plugin>/skills/` (plugin). Markdown + YAML frontmatter. Custom commands have been merged into
  skills; a legacy `.claude/commands/deploy.md` still produces `/deploy`.
- **Session start** — `SessionStart` ("when a session begins or resumes"), one of 31 hook events.
- **Pre-execution gate** — `PreToolUse` returns
  `permissionDecision: "deny" | "allow" | "ask"`; exit code 2 blocks unconditionally. The **`ask`
  tier is what this kit's guard actually uses** — it turns a policy into a confirmation rather than a
  refusal. Cursor and Antigravity also offer an `ask` from a pre-tool hook; Codex, OpenCode and Devin
  do not.
- **Subagents** — `.claude/agents/*.md`. "Each subagent runs in its own context window."
- **Structured questions** — `AskUserQuestion`, 1–4 questions × 2–4 options. Not available inside
  subagents spawned via the Agent tool.

Sources (accessed 2026-08-18): [skills](https://code.claude.com/docs/en/skills) ·
[hooks](https://code.claude.com/docs/en/hooks) ·
[sub-agents](https://code.claude.com/docs/en/sub-agents) ·
[permission modes](https://code.claude.com/docs/en/permission-modes)

## Codex CLI

- **Skills** — `.agents/skills/` (repo, repo root, or parent) and `$HOME/.agents/skills`, plus
  `/etc/codex/skills` for admins. Note the directory is `.agents/`, **not** `.codex/`. `SKILL.md`
  needs `name` + `description`. Invoked with **`$skill-name`, not `/skill-name`**. Custom prompts are
  deprecated in favour of skills. Instructions layer through `AGENTS.md` root-first.
- **Session start** — `SessionStart`, with a matcher on `startup` / `resume` / `clear` / `compact`;
  injects via `hookSpecificOutput.additionalContext`.
- **Pre-execution gate** — `PreToolUse` denies via
  `{"hookSpecificOutput": {"permissionDecision": "deny", …}}` or exit 2. **Three caveats that change
  what this is worth:** `permissionDecision: "ask"` is "parsed but not supported yet", so a hook can
  refuse but cannot raise a confirmation (the separate `PermissionRequest` hook covers approvals);
  the docs say to "treat tool hooks as a useful guardrail, not a complete enforcement boundary", and
  some tool paths opt out entirely; and a non-managed hook must be **reviewed and trusted by hash**
  before it runs, so shipping a hook is not the same as having it active.
- **Subagents** — `.codex/agents/*.toml`, spawned via `spawn_agent`. The docs describe separate agent
  threads returning summaries; they do not state "own context window" as a spec line.
- **Structured questions** — the closest analogue, `tool/requestUserInput`, is an **experimental
  app-server protocol method** for host clients. *Docs unclear:* no authorable CLI-side equivalent of
  `AskUserQuestion` is documented, so treat interviews here as prose.

Sources (accessed 2026-08-18): [hooks](https://learn.chatgpt.com/docs/hooks) ·
[skills](https://learn.chatgpt.com/docs/build-skills) ·
[subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents) ·
[approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security)

## Cursor

- **Skills** — `.cursor/skills/` and `.agents/skills/` (project), `~/.cursor/skills/` (user), and it
  also reads `.claude/skills/` and `.codex/skills/`. Rules are `.cursor/rules/*.mdc` — a plain `.md`
  there is **ignored**. `AGENTS.md` works at the project root. `.cursor/commands/*.md` is
  legacy-but-supported; a built-in `/migrate-to-skills` converts them.
- **Session start** — `sessionStart`, "fires when a composer conversation is created", and can inject
  context.
- **Pre-execution gate** — `preToolUse` / `beforeShellExecution` return
  `{"permission": "allow" | "deny" | "ask"}`. **Hooks fail OPEN by default** — you must set
  `failClosed: true` on the definition to block on hook failure. For a policy like
  `db_write_requires_approval`, the default is therefore the wrong way round, and any installer
  wiring this must set `failClosed`. *Reliability note, from forum reports rather than docs:* several
  users report the deny path behaving unevenly (ignored on Windows, `ask` still executing in
  sandboxed shells, a static allow-list taking precedence). Not officially acknowledged; recorded
  because "hooks can deny" should not be read as "hooks reliably deny everywhere".
- **Subagents** — `.cursor/agents/`. "Each subagent has its own context window."
- **Structured questions** — `cursor/ask_question` is an **ACP extension method** Cursor sends to
  third-party clients (JetBrains, Neovim, Zed). *Docs unclear:* no documented way for a skill author
  to trigger the picker inside the IDE.

Note: the docs moved from `docs.cursor.com` to `cursor.com/docs`; older deep links are dead.

Sources (accessed 2026-08-18): [hooks](https://cursor.com/docs/hooks) · [rules](https://cursor.com/docs/rules) ·
[skills](https://cursor.com/docs/context/commands) · [subagents](https://cursor.com/docs/subagents)

## Antigravity (Google)

**Gemini CLI is gone.** Google consolidated its developer tooling under the Antigravity brand at I/O
on 2026-05-19 and stopped serving the standalone Gemini CLI and the Gemini Code Assist IDE extensions
on **2026-06-18** for individual, free and AI Pro/Ultra users. The replacement is a Go rewrite invoked
as **`agy`**, a separate binary from the Antigravity desktop app but sharing its agent harness.
**One real exception:** organizations on a Gemini Code Assist Standard or Enterprise license keep the
legacy Gemini CLI, so a team on that channel is genuinely still running the old tool.

- **Skills** — `SKILL.md`, replacing the old TOML commands. Project skills at
  `<workspace>/.agents/skills/<name>/SKILL.md` (`description` required, `name` defaults to the
  folder); subagents at `.agents/agents/`, hooks at `.agents/hooks.json`, plugins at
  `.agents/plugins/`. Both `AGENTS.md` and `GEMINI.md` are still parsed as rules, so a kit-rendered
  `AGENTS.md` needs no translation. `agy plugin import gemini` converts legacy extensions.
- **Session start** — **none in the CLI.** The hook system exposes exactly five events: `PreToolUse`,
  `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`. `PreInvocation` fires before each model
  call, which is per-turn rather than per-session, and must not be mistaken for a `SessionStart`
  equivalent. The separate Antigravity *SDK* does have session-start hooks, but that is a different
  product from `agy`.
- **Pre-execution gate** — the richest researched here. `PreToolUse` returns a `decision` of `allow`,
  `deny`, **`ask`**, **`force_ask`** ("always prompts, ignoring cached permissions"), or
  `deny_unless_prior_grant`. Underneath sits a static rule engine with strict
  **Deny > Ask > Allow** precedence.
- **Subagents** — `.agents/agents/<name>.md`, user-definable, with explicit isolation: a subagent
  "does not inherit the parent's existing conversation history (context window), starting with a
  clean slate."
- **Structured questions** — ❓ *docs silent for the CLI.* A question panel exists in the desktop app
  per its changelog, but no CLI tool or authoring surface is documented.

*Not established:* hook failure behavior. Neither the hooks page nor the permissions reference states
what happens when a hook errors or exceeds its 30-second default timeout. Changelog entries about
hooks no longer stalling the agent suggest fail-open, but that is inference and is recorded as
unknown. Two official pages also disagree on the *global* skills path
(`~/.gemini/config/skills/` vs `~/.gemini/antigravity-cli/skills/`).

Sources (accessed 2026-08-18): [hooks](https://antigravity.google/docs/hooks) ·
[skills](https://antigravity.google/docs/skills/) ·
[subagents](https://antigravity.google/docs/subagents/) ·
[CLI permissions](https://antigravity.google/docs/cli/permissions/) ·
[Gemini CLI transition](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)

## OpenCode

The repository moved from `sst/opencode` to `anomalyco/opencode`.

- **Skills** — `.opencode/skills/<name>/SKILL.md`, and it also reads `.claude/skills/` and
  `.agents/skills/`; global at `~/.config/opencode/skills/`. Commands are markdown in
  `.opencode/commands/`. Rules resolve first-match-wins across `AGENTS.md`, `CLAUDE.md`,
  `~/.config/opencode/AGENTS.md`.
- **Session start** — *partial.* A plugin can subscribe to a generic `event` hook, and
  `session.created` is a documented event. But **no documented API injects context/instructions at
  session start** — the only context-mutating hooks are `experimental.session.compacting` and the TUI
  `tui.prompt.append`. So a session-start *notification* exists; a `session_context` equivalent does
  not. Treat the banner as unavailable here.
- **Pre-execution gate** — `tool.execute.before`; "throwing an error prevents the tool from
  executing." That is a hard deny. *Caveat:* a `permission.ask` hook exists in the SDK types but
  [issue #7006](https://github.com/anomalyco/opencode/issues/7006) (open since 2026-01-05, still
  open as of 2026-08-19) reports it is never triggered, so there is no documented way to escalate to
  a confirmation rather than refuse.
  A separate static layer (`permission` in `opencode.json`) supports `allow` / `ask` / `deny` with
  wildcards.
- **Subagents** — documented: an agent is marked `mode: "subagent"` and invoked by `@`-mention or
  via the Task tool (re-verified 2026-08-19 — an earlier revision of this page said `subtask: true`
  on a command; that key does not exist). *Docs unclear:* the official pages never state "own
  context window"; that phrasing appears only on unofficial mirrors, so the isolation guarantee is
  not established.
- **Structured questions** — built-in `question` tool: header, question text, and a list of options,
  with a custom-answer fallback.

Sources (accessed 2026-08-18; agents re-verified 2026-08-19): [skills](https://opencode.ai/docs/skills) ·
[plugins](https://opencode.ai/docs/plugins/) ·
[permissions](https://opencode.ai/docs/permissions/) · [agents](https://opencode.ai/docs/agents/) ·
[tools](https://opencode.ai/docs/tools/)

## Devin (formerly Windsurf)

**Windsurf is now Devin.** Cognition rebranded on **2026-06-02** and `docs.windsurf.com/*` redirects
to `docs.devin.ai/*`. The legacy **Cascade** agent has been superseded by **Devin Local**, described
as "our next-generation agent harness, shared with Devin CLI". This section describes Devin Local,
which is what a current install runs; `.windsurf/` paths survive as backward-compatible fallbacks.

*If you are still on Cascade*, two rows differ sharply: it has **no** session-start hook (its earliest
event, `pre_user_prompt`, is per-prompt) and **no** subagents at all — which was a stated motivation
for the rewrite.

- **Skills** — `.devin/skills/<name>/SKILL.md` (project), `~/.config/devin/skills/` (user). The
  frontmatter block is optional and no field is strictly required — re-verified 2026-08-19 against
  the frontmatter reference table (`name` defaults to the directory name, `description` to none; a
  planned correction claiming both were required did not match the cited page and was not applied).
  Skills become slash commands, the directory name being the identifier. Rules come from `AGENTS.md` / `AGENT.md` / `CLAUDE.md` at the
  repo root plus `.devin/rules/*.md`, and Devin deliberately reads other vendors' formats
  (`.cursor/rules/`, `.windsurf/`, `.claude/`), toggleable in config.
- **Session start** — `SessionStart`, one of eight events, injecting via
  `hookSpecificOutput.additionalContext`. A direct analogue of the Claude Code hook, so the priming
  banner ports across unchanged.
- **Pre-execution gate** — `PreToolUse` blocks **only via exit code 2**; the
  `{"decision": "approve" | "block"}` stdout schema belongs to the separate **`PermissionRequest`**
  hook (re-verified 2026-08-19 — an earlier revision of this page attributed that schema to
  `PreToolUse`). The exit table is documented: 0 continues, 2 blocks, and any other nonzero is
  logged and does not block. A static `permissions` layer offers `allow` / `ask` / `deny` with
  **deny > ask > allow** precedence, defaulting to a prompt when nothing matches.
- **Subagents** — `.devin/agents/<name>.md`, user-definable, "each with its own context window". A
  skill can itself run as a subagent via `subagent: true`.
- **Structured questions** — an `ask_user_question` tool exists, standardized over ACP elicitation.
  *Caveat:* evidenced by changelog entries rather than a reference page, so its option/multi-select
  schema is unverified.

Sources (accessed 2026-08-18; hooks and skills re-verified 2026-08-19):
[hooks](https://docs.devin.ai/cli/extensibility/hooks/overview) ·
[lifecycle hooks](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks) ·
[skills](https://docs.devin.ai/cli/extensibility/skills/creating-skills) ·
[subagents](https://docs.devin.ai/cli/subagents) ·
[permissions](https://docs.devin.ai/cli/reference/permissions) ·
[Devin Local](https://docs.devin.ai/desktop/devin-local)

## Cline

Cline is the least settled of the seven, and the write-up reflects that rather than smoothing it over.

- **Rules + skills** — rules in `.clinerules/` (all `.md`/`.txt` inside), global under
  `~/Documents/Cline/Rules`; workspace wins on conflict. Skills at `.cline/skills/` (recommended),
  `.clinerules/skills/`, or `.claude/skills/`; global skills at `~/.cline/skills/` on macOS/Linux
  (re-verified 2026-08-19 — this page previously recorded only the global rules path); `SKILL.md`
  frontmatter `name` (must match the directory) + `description`. *Docs unclear:* the widely-cited `.clinerules/workflows/` path is
  absent from the current docs index and appears to have been folded into skills.
- **Session start** — ⚠ **conflicted.** A v3.36 blog (2025-11-06) documents file-based hooks including
  `TaskStart`, at `.clinerules/hooks/`. The current docs page for hooks is a **stub** redirecting to
  SDK Plugins, whose lifecycle does include `session_start` — but that is a TypeScript SDK surface
  for embedders, not a config file the IDE extension reads. No deprecation notice was found either
  way, so whether a file-based `TaskStart` still fires is **not established**.
- **Pre-execution gate** — ⚠ same split. File-based hooks returned `{"cancel": true}` to block
  (macOS/Linux only — Windows unsupported as of that post). The current SDK docs list
  `tool_call_before` for "audit or block tool calls" but **do not document the return schema**; a
  blog example shows `{ skip: true, reason }`. Also worth knowing: Cline's approval classification is
  **model-judged**, not a static list — "the model marks each command with a `requires_approval`
  flag". A safety gate that depends on an LLM's own judgment of its own command is a weaker guarantee
  than a deterministic scanner, which is exactly what `db_write_guard` is.
- **Subagents** — present, each with "its own prompt and context window", but **not user-definable**:
  there is no directory-based definition, Cline decides when to spawn them, and they cannot edit
  files. So `qc-reviewer` cannot be expressed as a Cline subagent; it degrades to an inline pass.
  Marked experimental.
- **Structured questions** — `ask_followup_question` with selectable `options` exists in the product,
  but the current tools reference documents only `ask_question` with no parameter schema; the
  `options` shape is confirmed only from a repo issue. Multi-select is an open request.

Sources (accessed 2026-08-18; skills re-verified 2026-08-19): [rules](https://docs.cline.bot/customization/cline-rules) ·
[skills](https://docs.cline.bot/customization/skills) ·
[SDK plugins](https://docs.cline.bot/sdk/plugins) ·
[auto-approve](https://docs.cline.bot/features/auto-approve) ·
[subagents](https://docs.cline.bot/features/subagents) ·
[v3.36 hooks](https://cline.bot/blog/cline-v3-36-hooks)

---

## What this means for the kit

**`db_write_requires_approval` is mechanically enforceable well beyond Claude Code** — Codex CLI,
Cursor, Antigravity, OpenCode and Devin all expose a pre-execution deny. PROMPT 7 should wire
`db_write_guard` into each rather than declaring the policy guidance-only off Claude. But the
rendered `AGENTS.md` must state the *specific* limitation per runtime, because none of these is a
like-for-like replacement:

- **`high_risk` needs an `ask` tier, and only three runtimes have one.** This is the sharpest finding
  on this page, because `high_risk` is the policy's **default**. The enum is
  `off` | `high_risk` | `all`, and the middle setting exists precisely to ask for the irreversible
  while letting additive work run. Claude Code, Cursor and Antigravity can express that from a hook.
  Codex, OpenCode and Devin cannot, so on those three the default value has **no native expression**
  and must collapse — and both collapses are bad in different ways:
    - *Collapse toward deny* and additive statements start getting blocked. That trains people to
      turn the guard off, which is worse than never having had one.
    - *Collapse toward allow* and the protection is simply gone while `stack.yaml` still reads
      `high_risk` — a user believing they have a gate they do not have.
  So an installer must not choose silently. It has to state which collapse a given runtime got **and
  surface that to the user**, because the failure mode of getting this wrong is invisible until a
  destructive statement has already run.
- **Antigravity can express it more precisely than the kit currently asks for.** Its `force_ask`
  always prompts, ignoring cached permissions — the right primitive for the `all` setting, where a
  remembered "yes" should not silently cover the next destructive statement.
- **Cursor fails open unless `failClosed: true` is set.** Required configuration, not a footnote: omit
  it and the gate stops gating the moment the hook errors, with nothing surfacing that it stopped.
- **Devin fails open by documented design.** Exit 0 continues, exit 2 blocks, and any *other* nonzero
  code is "logged but doesn't block" — so the guard must exit 2 deliberately and must never merely
  crash.
- **Codex requires the hook to be trusted by hash**, so installing the guard is not the same as being
  protected by it, and any edit re-arms the review. Its own docs also decline to call it an
  enforcement boundary.
- **Antigravity's hook failure behavior is undocumented.** Recorded as unknown rather than assumed
  fail-open; confirm before relying on the gate holding when a hook breaks.
- **Cline is unverified — its hooks doc is a stub** pointing at an SDK surface, and its approval
  classification is model-judged rather than deterministic. It is the one runtime where the honest
  statement is that the policy degrades to guidance.

**The priming banner has no home on Antigravity or OpenCode.** Antigravity's CLI has no session-start
event at all (`PreInvocation` is per-turn), and OpenCode can observe `session.created` but has no
documented way to inject context. On both, the banner's content belongs in the always-loaded rules
file. Codex, Cursor and Devin all have a genuine `SessionStart` with context injection.

**`qc-reviewer` cannot be a user-defined subagent on Cline**, and context isolation is unestablished
on OpenCode and Codex. Where an independent second context cannot be guaranteed, the review says so
mechanically: `/review` probes `subagents` + `subagent_isolation` through the kit CLI and records
`review_mode` (plus the isolation posture, verbatim) in the verdict — a same-context pass is a
weaker check than the validation pyramid assumes, and the record states it. Antigravity, Cursor
and Devin all document their own context window, so the deep review ports cleanly there.

**Two runtimes changed identity mid-research**, which is the strongest argument for keeping this page
dated and re-checking it: Gemini CLI was retired outright, and Windsurf was renamed. Both old names
survive only as installer aliases.
