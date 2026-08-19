---
seam: runtime
tool: opencode
transport: native
requires: []
detect_env: OPENCODE_BIN_PATH, OPENCODE_CONFIG, OPENCODE
skills_root: .opencode/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter (name, description)
session_start: no
tool_gate: yes
subagents: yes
structured_questions: yes
model_cmd: "opencode run {prompt}"
model_sandbox: unverified   # no restriction flag verified for `opencode run`
auth: |
  An OpenCode install with a configured model provider.
  Verify: `command -v opencode`.
---

# OpenCode runtime adapter

The upstream repository moved from `sst/opencode` to `anomalyco/opencode`.

## Capabilities

- **Skills** — `.opencode/skills/<name>/SKILL.md`, and it also reads `.claude/skills/` and
  `.agents/skills/`; global at `~/.config/opencode/skills/`. Commands are markdown under
  `.opencode/commands/`. Rules resolve first-match-wins across `AGENTS.md`, `CLAUDE.md` and
  `~/.config/opencode/AGENTS.md`, so a kit-rendered `AGENTS.md` is picked up unchanged.
- **Session start** — declared **no**, and the distinction matters. A plugin can subscribe to a
  generic `event` hook and `session.created` is a documented event, but **no documented API injects
  context or instructions at session start**. A notification is not a priming banner, so the banner's
  content has to live in the always-loaded rules file here.
- **Tool gate** — the `tool.execute.before` plugin hook; throwing an error prevents the tool from
  executing. A separate static layer in `opencode.json` supports `allow` / `ask` / `deny` with
  wildcard patterns.
- **Subagents** — documented, invoked by `@`-mention or `subtask: true` on a command.
- **Structured questions** — the built-in `question` tool: a header, the question, and a list of
  options, with a free-text fallback.

## Gotchas

- **Deny only, no escalation.** A `permission.ask` hook exists in the plugin SDK types but an open
  upstream issue reports it is never triggered, so there is no reliable way to turn a policy into a
  confirmation — only into a refusal.
- **Subagent context isolation is not established.** The official pages document the mechanism but
  never state "own context window"; that phrasing appears only on unofficial mirrors. Until it is
  documented, do not promise that `qc-reviewer` is a genuinely independent context here.
