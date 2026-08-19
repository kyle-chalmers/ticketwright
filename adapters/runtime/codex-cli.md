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
gate_ask_tier: no           # permissionDecision "ask" is parsed but not supported yet
gate_fail_mode: unknown     # docs state the deny paths, not what a crashing hook does
subagent_isolation: unestablished   # separate agent threads documented, "own context window" is not
reads_foreign_skills: none
global_skills_root: ~/.agents/skills
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
  isolation guarantee is **unestablished**, not merely undocumented-in-passing.
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
- **What a *crashing* hook does is undocumented** — the docs state the deny paths
  (`permissionDecision: "deny"`, exit 2), not the failure behavior, so `gate_fail_mode` is declared
  `unknown` rather than assumed either way.
