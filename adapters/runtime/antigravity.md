---
seam: runtime
tool: antigravity
aliases: gemini-cli
transport: native
requires: []
detect_env: ANTIGRAVITY_CLI, ANTIGRAVITY_HOME, AGY_SESSION_ID
skills_root: .agents/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter (description required, name optional)
session_start: no
tool_gate: yes
subagents: yes
structured_questions: unknown
model_cmd: "agy -p {prompt}"
model_sandbox: unverified   # docs describe a commandExecutionPolicy for subagents, not a verified CLI flag for `agy -p`
auth: |
  An authenticated Antigravity CLI install (`agy`).
  Verify: `command -v agy`.
---

# Antigravity runtime adapter (Google)

> **This replaced Gemini CLI.** Google consolidated its developer tooling under the Antigravity
> brand at I/O on 2026-05-19 and **retired the standalone Gemini CLI on 2026-06-18** for individual,
> free and AI Pro/Ultra users. The CLI is a Go rewrite invoked as **`agy`**, separate from the
> Antigravity desktop app but sharing its agent harness.
>
> **`gemini-cli` is accepted as an alias** so `--runtime gemini-cli` keeps working. One real
> exception is worth knowing: organizations on a **Gemini Code Assist Standard or Enterprise
> license retain the legacy Gemini CLI**, so a team on that channel is genuinely still running the
> old tool — it is not simply out of date.

## Capabilities

- **Skills** — `SKILL.md`, not the old TOML commands. Project skills live at
  `<workspace>/.agents/skills/<name>/SKILL.md`; `description` is required and `name` defaults to the
  folder. Subagents at `.agents/agents/`, hooks at `.agents/hooks.json`, plugins at
  `.agents/plugins/`. `AGENTS.md` and `GEMINI.md` are both still parsed as rules, so a
  kit-rendered `AGENTS.md` is picked up unchanged. `agy plugin import gemini` converts legacy
  Gemini extensions into skills.
- **Session start** — **none in the CLI.** The hook system exposes exactly five events:
  `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`. `PreInvocation` fires
  before each model call — that is per-turn, **not** a session lifecycle event, and must not be
  treated as a `SessionStart` equivalent. The priming banner has no home here; its content belongs
  in the always-loaded rules file. (The separate Antigravity *SDK* does have session-start hooks,
  but that is a different product from `agy`.)
- **Tool gate** — the richest of any runtime researched. `PreToolUse` returns a `decision` of
  `allow`, `deny`, **`ask`**, **`force_ask`** (always prompts, ignoring cached permissions), or
  `deny_unless_prior_grant`. A static rule engine sits underneath it with strict
  **Deny > Ask > Allow** precedence.
- **Subagents** — `.agents/agents/<name>.md`, user-definable, and the isolation is explicit: a
  subagent "does not inherit the parent's existing conversation history (context window), starting
  with a clean slate." `qc-reviewer` keeps its independence here.
- **Structured questions** — **unknown** for the CLI. A question panel demonstrably exists in the
  desktop app, but no CLI tool for it is documented and no authoring surface is described. Author
  interviews as numbered prose.

## Gotchas

- **This is the one runtime that can express `db_write_requires_approval` more precisely than the
  kit currently asks for.** `ask` maps directly onto the guard's confirmation, and `force_ask` can
  defeat a cached approval — worth using for the `all` policy setting, where a remembered "yes"
  should not silently cover the next destructive statement.
- **Hook failure behavior is undocumented.** Neither the hooks page nor the permissions reference
  states what happens when a hook errors or exceeds its 30-second default timeout. Changelog
  entries about hooks no longer stalling the agent imply timeout leads to an error and the turn
  proceeds — i.e. fail-open — but that is inference, not documentation. **Do not assume the gate
  holds when the hook breaks** until this is confirmed.
- Two official pages disagree on the *global* skills/plugins path
  (`~/.gemini/config/skills/` vs `~/.gemini/antigravity-cli/skills/`). Project-level paths are
  consistent; prefer them until this settles.
- Whether `.gemini/commands/*.toml` is still read at runtime is not documented — migration converts
  them, which is not the same as continued support.
