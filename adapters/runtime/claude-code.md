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
question_tool: AskUserQuestion
question_limits: max_questions=4 max_options=4   # the tool's own caps; it always adds a free-text "Other"
plan_mode: native          # plan mode (Shift+Tab / the planning tool): only its own plan file is writable inside it; LEAVE it before writing ticket artifacts — leaving it is the approval
gate_ask_tier: yes
gate_fail_mode: open        # hooks fail open by design: a hook error never blocks a session
subagent_isolation: documented
reads_foreign_skills: none
global_skills_root: ~/.claude/skills
agents_root: .claude/agents/<name>.md   # native — this IS the canonical copy; the installer emits nothing
hook_wiring: native            # the plugin manifest / .claude/settings.json already wire all four hooks; the installer emits nothing
hook_protocol: claude-json     # PreToolUse permissionDecision deny|allow|ask — the native hooks speak it themselves; hook_shim refuses this runtime
model_cmd: 'claude -p --model {model} --tools "" --strict-mcp-config'
model_sandbox: tools-withheld   # --tools "" verified live on Claude Code 2.1.310 (a one-word reply, no tool use, a planted file token not leaked); --strict-mcp-config loading no MCP server rests on claude --help only
model_default: sonnet
model_fast: haiku   # the cheaper model for a one-line job; only this model_cmd has a {model} slot to fill
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
  an interview must never be authored inside one. `/setup`, `/ticket` (owner choice, plan assumptions, plan approval) and
  `/skillify` ask with it, reading its name from this file's `question_tool` key.

## Gotchas

- **The headless model command runs with no tools at all, on purpose.** Writing a one-line catalog
  summary needs no tools, and the prompt carries a ticket README or an older tracker ticket, which is
  text someone outside the repo wrote. Argv construction stops shell injection; withholding every tool is
  what stops that text from talking an agent into reading files, searching the web or calling a
  configured MCP server. `--tools ""` disables every built-in tool (a deny list such as
  `--disallowedTools Bash,Write,Edit,WebFetch` left Read, Grep, Glob and WebSearch available), and
  `--strict-mcp-config` with no `--mcp-config` should load no MCP server. What was checked, on Claude
  Code 2.1.310: `--tools ""` live (a one-word reply, no tool use, and a planted file's token not
  leaked, where the old deny list let it be read). `--strict-mcp-config` rests on what `claude --help`
  says (it uses only the servers named by `--mcp-config`) and has not been run against a live MCP
  server. The `""` is one empty argument, and the template reader passes it through as one empty argv
  element.
- **`model_cmd` deliberately has NO `{prompt}` token, so the prompt goes on stdin.**
  `--tools` is variadic (`<tools...>`), so a trailing prompt argument could be swallowed as more tool
  names, which fails the call outright and turns README words into tool names. Do not "fix" this by
  appending `{prompt}`.
- Hooks are the one Claude-Code-specific layer in the kit. They fail open by design — a hook error
  never blocks a session, and a guard only ever *adds* a confirmation.
- `${CLAUDE_PLUGIN_ROOT}` is set for plugin-provided hooks and commands, not universally in every
  shell. Nothing may *require* it; `bin/tw` treats it as a hint and falls through when it is absent.

## Metadata mapping

How the canonical source's control fields map here when `bin/emit_runtime.py` installs the kit.
This is the reference runtime: the canonical files ARE the installed files, so nothing is
translated and nothing can be lost in translation.

| canonical field | here | how |
|---|---|---|
| `allowed-tools` (skill frontmatter) | native | the canonical `.claude/skills/` file is the installed file — honored as written |
| `disable-model-invocation` (skill frontmatter) | native | honored as written |
| `tools:` (agent definition, qc-reviewer) | native | `.claude/agents/qc-reviewer.md` is the canonical copy — nothing emitted |
