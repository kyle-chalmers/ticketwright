---
seam: runtime
tool: cursor
transport: native
requires: []
detect_env: CURSOR_TRACE_ID, CURSOR_AGENT
skills_root: .cursor/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter (name, description, paths)
session_start: yes
tool_gate: yes
subagents: yes
structured_questions: no
gate_ask_tier: yes
gate_fail_mode: open        # documented: hooks fail open unless failClosed true is set
subagent_isolation: documented
reads_foreign_skills: .claude/skills, .codex/skills
global_skills_root: ~/.cursor/skills
model_cmd: ""
model_sandbox: n/a   # no headless model command
auth: |
  A Cursor install. No headless one-shot model command is documented.
  Verify: `command -v cursor`.
---

# Cursor runtime adapter

## Capabilities

- **Skills** — `.cursor/skills/` and `.agents/skills/` (project), `~/.cursor/skills/` (user). Cursor
  also reads `.claude/skills/` and `.codex/skills/`, so a kit installed for either of those is
  already partly visible here. Rules live in `.cursor/rules/*.mdc` — a plain `.md` file placed there
  is **ignored**. `AGENTS.md` is honoured at the project root.
- **Session start** — the `sessionStart` hook, fired when a conversation is created; it can inject
  context, so the priming banner has a home.
- **Tool gate** — `preToolUse` / `beforeShellExecution` return
  `{"permission": "allow" | "deny" | "ask"}` from `.cursor/hooks.json`. This runtime *does* have an
  `ask` tier, unlike Codex and Gemini.
- **Subagents** — `.cursor/agents/`, each with its own context window.
- **Structured questions** — `cursor/ask_question` is an ACP extension method sent to third-party
  clients (JetBrains, Neovim, Zed), not an authoring surface inside the IDE. Author interviews as
  numbered prose.

## Gotchas

- **Hooks fail OPEN by default.** `failClosed: true` must be set on the hook definition or the gate
  stops gating the moment the hook errors — and nothing surfaces that it has stopped. For
  `db_write_requires_approval` this is required configuration, not a tuning option.
- Deny reliability is reported as uneven in the wild (ignored on Windows, `ask` still executing in
  sandboxed shells, static allow-lists taking precedence). These are user reports rather than
  documented behavior, and no official acknowledgement was found — recorded so nobody reads
  "hooks can deny" as "hooks reliably deny on every platform".
- The documentation moved from `docs.cursor.com` to `cursor.com/docs`; older deep links are dead.
