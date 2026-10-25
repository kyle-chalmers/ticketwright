---
seam: runtime
tool: codex-cli
transport: native
requires: []
detect_env: CODEX_HOME, CODEX_SANDBOX, CODEX_SANDBOX_NETWORK_DISABLED
skills_root: .agents/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter (name, description)
session_start: yes
tool_gate: yes
subagents: yes
structured_questions: no
question_tool: none
question_limits: none   # no structured question tool a skill can call: ask in prose
plan_mode: native          # /plan or Shift+Tab collaboration mode: read-only, drafts a plan, writes nothing until approved (openai/codex plan mode, 2026-09-11)
gate_ask_tier: no           # permissionDecision "ask" is parsed but not supported yet
gate_fail_mode: unknown     # docs state the deny paths, not what a crashing hook does
subagent_isolation: unestablished   # separate agent threads documented, "own context window" is not
reads_foreign_skills: none
global_skills_root: ~/.agents/skills
agents_root: .codex/agents/<name>.toml  # note: agents live under .codex/, unlike skills (.agents/)
hook_wiring: unknown           # the events and deny protocol are documented; the hooks-CONFIG file location is not — wiring is manual until U6 #1 establishes it live
hook_protocol: codex-json      # PreToolUse deny via hookSpecificOutput.permissionDecision (ask parsed but unsupported) or exit 2
hook_wiring_caveat: hooks must be reviewed and trusted BY HASH before they run — installed is not armed, and an edit re-arms the review; Codex's own docs call hooks a guardrail, not a complete enforcement boundary.
model_cmd: "codex exec --sandbox read-only --skip-git-repo-check {prompt}"
model_sandbox: read-only   # verified against `codex exec --help`: --sandbox read-only
auth: |
  An authenticated Codex CLI install.
  Verify: `command -v codex`.
---

# Codex CLI runtime adapter

## Capabilities

- **Skills** — `.agents/skills/<name>/SKILL.md`, searched at the repo, repo root and parent, plus
  `$HOME/.agents/skills` and `/etc/codex/skills`. The directory is `.agents/`, **not `.codex/`**.
  Skills are invoked with **`$name`, not `/name`**. Custom prompts are deprecated in favour of
  skills. Repo instructions layer through `AGENTS.md`, root-first.
- **Session start** — `SessionStart`, with a matcher on `startup` / `resume` / `clear` / `compact`;
  injects through `hookSpecificOutput.additionalContext`.
- **Tool gate** — `PreToolUse` denies via
  `{"hookSpecificOutput": {"permissionDecision": "deny"}}` or exit 2. Read the gotchas before
  treating this as parity with Claude Code.
- **Subagents** — `.codex/agents/*.toml`, spawned via `spawn_agent`. The docs describe separate
  agent threads returning summaries; they never state "own context window" as a spec line, so the
  isolation guarantee is **unestablished**, not merely undocumented-in-passing. A standalone role
  file must define `name` (what `spawn_agent` calls the role), `description` and
  `developer_instructions` (the agent's instructions); every other top-level key must be one
  Codex's config schema knows. The emitter writes exactly those three keys.
- **Structured questions** — none available to a skill author. `tool/requestUserInput` exists but is
  an experimental app-server protocol method for host clients, so **author every interview as a
  numbered prose list**.

## Gotchas

- **The enrichment command is sandboxed read-only on purpose.** `model_cmd` pins
  `--sandbox read-only` because the prompt it receives is a ticket README, which on most installs was
  fetched from a tracker — text someone outside the repo wrote. Building it as argv stops shell
  injection, but nothing stops that text from *instructing* an agent that can use tools. Do not drop
  the flag, and never replace it with `--dangerously-bypass-approvals-and-sandbox`.
- **No `ask` tier.** `permissionDecision: "ask"` is parsed but not supported, so a hook can refuse or
  permit but cannot raise a confirmation. `db_write_requires_approval: high_risk` has no native
  expression — it must collapse to deny-or-allow, and the installer must say which.
- **Installing a hook is not the same as being protected by it.** A non-managed hook must be reviewed
  and trusted *by hash* before it runs, and any edit re-arms that review.
- The vendor's own documentation declines to call this an enforcement boundary, and some tool paths
  opt out of the hook path entirely. Treat it as a strong guardrail, not a guarantee.
- **An emitted agent is not a loaded agent.** Codex skips a role file that breaks its schema and
  says so only as an `Ignoring malformed agent role definition` warning in the session's event
  stream, and `/review` then has no `qc-reviewer` role to spawn. Before 2026-10-25 the emitter
  wrote `instructions` and no `name`, and Codex 0.162 dropped the file that way. Codex also reads
  a project's `.codex/agents/` only once the project is trusted: in an untrusted project the role
  is absent with no warning at all (both observed on codex-cli 0.162.0, 2026-10-25,
  `docs/live-verification.md` entry 13).
- **The role inherits the parent's sandbox.** A custom agent runs with the parent session's
  sandbox, approvals and MCP servers; the docs say its instructions "don't create a separate
  read-only sandbox". The `features.*` keys can switch off a whole capability (shell, apps,
  plugins, memories, permission requests), but the reviewer needs the shell to re-run queries,
  so none of them yields read-only.
- **What a *crashing* hook does is undocumented** — the docs state the deny paths
  (`permissionDecision: "deny"`, exit 2), not the failure behavior, so `gate_fail_mode` is declared
  `unknown` rather than assumed either way.

## Metadata mapping

How the canonical source's control fields map here when `bin/emit_runtime.py` emits the kit into
`.agents/skills/`. A `lost` entry is never silent: it is named in the install report, and for
user-invocable-only skills it is restated inside the emitted artifact itself.

| canonical field | here | how |
|---|---|---|
| `allowed-tools` (skill frontmatter) | lost | this skill format carries only `name` + `description` — no per-skill tool restriction exists; named in the install report |
| `disable-model-invocation` (skill frontmatter) | lost | no equivalent field — the skill is emitted anyway, with a topmost warning block stating that model invocation is not mechanically prevented here |
| `tools:` (agent definition, qc-reviewer) | lost | a Codex custom agent inherits the parent session's sandbox and permissions, and no field of the `.codex/agents/*.toml` format narrows it to a tool list (the `features.*` switches remove whole capabilities, including the shell the reviewer needs); restated as a comment and inside `developer_instructions` in the emitted file. The file itself (`name`, `description`, `developer_instructions`) loads and is offered as a spawnable role on codex-cli 0.162.0 (observed 2026-10-25, live-verification entry 13) |
