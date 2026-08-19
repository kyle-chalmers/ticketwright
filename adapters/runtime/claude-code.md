---
seam: runtime
tool: claude-code
transport: native
requires: []
detect_env: CLAUDE_PLUGIN_ROOT, CLAUDE_PROJECT_DIR, CLAUDECODE, CLAUDE_CODE_ENTRYPOINT
skills_root: .claude/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter
session_start: yes
tool_gate: yes
subagents: yes
structured_questions: yes
gate_ask_tier: yes
gate_fail_mode: open        # hooks fail open by design: a hook error never blocks a session
subagent_isolation: documented
reads_foreign_skills: none
global_skills_root: ~/.claude/skills
model_cmd: "claude -p --model {model} --disallowedTools Bash,Write,Edit,WebFetch"
model_sandbox: tools-withheld   # verified against `claude --help`: --disallowedTools is honored
model_default: sonnet
auth: |
  None beyond an authenticated Claude Code install.
  Verify: `command -v claude`.
---

# Claude Code runtime adapter

The reference runtime — everything in the kit was built against it, so this file is the yardstick the
other six are measured by rather than a port.

**`runtime` is an adapter directory, not a `stack.yaml` seam.** A seam is something the PROJECT
depends on and the team shares, resolved per repo. Which agent a person happens to be running is
per-machine, so it is never written to committed config. Runtime adapters therefore declare
capabilities and carry no `## verb:` sections — see `adapters/README.md` § Runtime adapters.

## Capabilities

- **Skills** — `.claude/skills/<name>/SKILL.md` (project), `~/.claude/skills/` (personal),
  `<plugin>/skills/` (plugin install). Custom commands are merged into skills; a legacy
  `.claude/commands/<name>.md` still produces `/<name>`.
- **Session start** — the `SessionStart` hook, which is how `session_context.py` and
  `ticket_index_context.py` prime a session.
- **Tool gate** — `PreToolUse` returns `deny` / `allow` / **`ask`**, or blocks unconditionally with
  exit 2. The `ask` tier is what makes `db_write_requires_approval` a *confirmation* here. Cursor
  and Antigravity offer an `ask` from a pre-tool hook too (see `docs/runtimes.md`); Codex CLI,
  OpenCode and Devin do not, which is why the policy's `high_risk` middle setting needs an explicit,
  surfaced collapse decision on those three.
- **Subagents** — `.claude/agents/*.md`, each with its own context window. This is what makes
  `/review --deep`'s `qc-reviewer` a genuinely independent second pass.
- **Structured questions** — the `AskUserQuestion` tool. Note it is unavailable inside subagents, so
  an interview must never be authored inside one.

## Gotchas

- **The enrichment command withholds the mutating and network tools on purpose.** Writing a one-line
  catalog summary needs no tools at all, and the prompt carries a ticket README — tracker-sourced text
  on most installs. Argv construction stops shell injection; withholding the tools is what stops that
  text from talking an agent into using them.
- **`model_cmd` deliberately has NO `{prompt}` token, so the prompt goes on stdin.**
  `--disallowedTools` is variadic (`<tools...>`), so a trailing prompt argument is swallowed as more
  deny-rule values — which fails the call outright and turns README words into permission rules. Do
  not "fix" this by appending `{prompt}`.
- Hooks are the one Claude-Code-specific layer in the kit. They fail open by design — a hook error
  never blocks a session, and a guard only ever *adds* a confirmation.
- `${CLAUDE_PLUGIN_ROOT}` is set for plugin-provided hooks and commands, not universally in every
  shell. Nothing may *require* it; `bin/tw` treats it as a hint and falls through when it is absent.
