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
gate_ask_tier: no           # permission.ask exists in SDK types but never fires (open upstream issue)
gate_fail_mode: closed      # a thrown error prevents execution — deny IS the error path; see gotchas
subagent_isolation: unestablished   # "own context window" appears only on unofficial mirrors
reads_foreign_skills: .claude/skills, .agents/skills
global_skills_root: ~/.config/opencode/skills
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
- **Subagents** — documented: an agent is marked with `mode: "subagent"` and invoked by `@`-mention
  or via the Task tool (re-verified 2026-08-19; an earlier revision of this adapter said
  `subtask: true` on a command — that key does not exist).
- **Structured questions** — the built-in `question` tool: a header, the question, and a list of
  options, with a free-text fallback.

## Gotchas

- **Deny only, no escalation.** A `permission.ask` hook exists in the plugin SDK types but an open
  upstream issue reports it is never triggered (still open as of 2026-08-19), so there is no
  reliable way to turn a policy into a confirmation — only into a refusal.
- **`gate_fail_mode: closed` covers a thrown error, on the documented reading.** The deny mechanism
  *is* throwing — "throwing an error prevents the tool from executing" — so a hook that errors
  denies rather than waves the call through. What the docs do NOT state is what happens when the
  plugin fails to *load* at all; that boundary is untested and belongs to the live punch list.
- **Subagent context isolation is not established.** The official pages document the mechanism but
  never state "own context window"; that phrasing appears only on unofficial mirrors. Until it is
  documented, do not promise that `qc-reviewer` is a genuinely independent context here.
