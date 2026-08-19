---
seam: runtime
tool: devin
aliases: windsurf, devin-desktop
transport: native
requires: []
detect_env: DEVIN_SESSION_ID, DEVIN_HOME, WINDSURF_HOME
skills_root: .devin/skills/<name>/SKILL.md
skills_format: markdown + optional YAML frontmatter (no required field)
session_start: yes
tool_gate: yes
subagents: yes
structured_questions: yes
model_cmd: "devin -p {prompt}"
auth: |
  A Devin install (`devin` CLI, or the `devin-desktop` app).
  Verify: `command -v devin`.
---

# Devin runtime adapter (formerly Windsurf)

> **Windsurf was renamed to Devin.** Cognition rebranded on 2026-06-02 and `docs.windsurf.com/*`
> now redirects to `docs.devin.ai/*`. The legacy **Cascade** agent has been superseded by
> **Devin Local**, "our next-generation agent harness, shared with Devin CLI". This adapter
> describes **Devin Local**, which is what a current install runs.
>
> **`windsurf` and `devin-desktop` are accepted as aliases.** `.windsurf/` paths still work as
> backward-compatible fallbacks, so an older repo keeps resolving.
>
> If you are on the legacy Cascade agent, two rows below do not apply to you: Cascade has **no**
> session-start hook (its earliest event is per-prompt) and **no** subagents at all.

## Capabilities

- **Skills** — `.devin/skills/<name>/SKILL.md` (project), `~/.config/devin/skills/` (user). The
  frontmatter block is optional and no field is strictly required; `name` defaults to the directory.
  Skills become slash commands — the directory name is the identifier. Rules resolve from
  `AGENTS.md` / `AGENT.md` / `CLAUDE.md` at the repo root plus `.devin/rules/*.md`, and Devin
  deliberately reads other vendors' formats (`.cursor/rules/`, `.windsurf/`, `.claude/`), toggleable
  in config — so a kit-rendered `AGENTS.md` needs no translation.
- **Session start** — `SessionStart`, one of eight events, injecting through
  `hookSpecificOutput.additionalContext`. This is a direct analogue of the Claude Code hook, so the
  priming banner ports over as-is.
- **Tool gate** — `PreToolUse` returns `{"decision": "approve" | "block"}` on stdout, or exit 2 to
  block. A static `permissions` layer supports `allow` / `ask` / `deny` with **deny > ask > allow**
  precedence, and the default when nothing matches is to prompt.
- **Subagents** — `.devin/agents/<name>.md`, user-definable, and "each with its own context window".
  A skill can itself run as a subagent via `subagent: true`.
- **Structured questions** — an `ask_user_question` tool exists and is standardized over ACP
  elicitation. *Caveat:* it is evidenced by changelog entries rather than a reference page, so the
  exact option/multi-select schema is unverified. Prose remains the safe authoring choice.

## Gotchas

- **No `ask` tier in the hook path.** The gate is approve-or-block only; the ask tier exists only in
  the static permissions config. So `db_write_requires_approval: high_risk` cannot be expressed as a
  hook-driven confirmation here — it collapses to deny-or-allow, and the installer must say which.
- **The hook fails OPEN, and this is documented rather than inferred.** Exit 0 continues, exit 2
  blocks, and any *other* nonzero code is "logged but doesn't block". A crashing or misconfigured
  guard therefore stops gating silently — the guard must exit 2 deliberately, never merely fail.
- **Background subagents fail closed**, which is the opposite default and worth knowing: they
  inherit only already-granted permissions, cannot prompt for new ones, and anything unapproved is
  automatically denied. A `qc-reviewer` running in the background may simply be unable to re-run a
  query the main session could.
- Whether a hook decision can override a static `deny` rule is not documented.
