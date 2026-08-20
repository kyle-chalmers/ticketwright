---
seam: runtime
tool: devin
aliases: windsurf, devin-desktop
transport: native
requires: []
detect_env: DEVIN_SESSION_ID, DEVIN_HOME, WINDSURF_HOME
skills_root: .devin/skills/<name>/SKILL.md
skills_format: markdown + optional YAML frontmatter (name defaults to the directory)   # re-verified 2026-08-19
session_start: yes
tool_gate: yes
subagents: yes
structured_questions: yes
gate_ask_tier: no           # PreToolUse blocks via exit 2 only; PermissionRequest is approve/block — no ask
gate_fail_mode: open        # documented design: any nonzero other than 2 is logged and does not block
subagent_isolation: documented
reads_foreign_skills: .claude/skills   # vendor-format reading is toggleable in Devin's config
global_skills_root: ~/.config/devin/skills
agents_root: .devin/agents/<name>.md
hook_wiring: unknown           # SessionStart/PreToolUse are documented; the hooks-config file location is not — wiring is manual until verified live
hook_protocol: exit-code       # PreToolUse blocks ONLY via exit 2; any other nonzero is logged and does not block (documented fail-open) — the shim exits 2 deliberately, always
hook_wiring_caveat: the hook path fails open BY DOCUMENTED DESIGN (only exit 2 blocks; any other nonzero is logged and ignored) — the shim exits 2 deliberately on every internal error.
foreign_skills_caveat: Devin's reading of other vendors' formats (including .claude/skills/) is toggleable in its config — if the skills do not appear, check that setting before reinstalling.
model_cmd: "devin -p {prompt}"
model_sandbox: unverified   # docs mention a --sandbox mode, not verified for `devin -p`
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
  frontmatter block is optional and no field is strictly required — re-verified 2026-08-19 against
  the frontmatter reference table (`name` defaults to the directory name, `description` to none).
  Skills become slash commands — the directory name is the identifier. Rules resolve from
  `AGENTS.md` / `AGENT.md` / `CLAUDE.md` at the repo root plus `.devin/rules/*.md`, and Devin
  deliberately reads other vendors' formats (`.cursor/rules/`, `.windsurf/`, `.claude/`), toggleable
  in config — so a kit-rendered `AGENTS.md` needs no translation.
- **Session start** — `SessionStart`, one of eight events, injecting through
  `hookSpecificOutput.additionalContext`. This is a direct analogue of the Claude Code hook, so the
  priming banner ports over as-is.
- **Tool gate** — `PreToolUse` blocks **only via exit code 2** (re-verified 2026-08-19). The
  `{"decision": "approve" | "block"}` stdout schema belongs to the separate **`PermissionRequest`**
  hook, not to `PreToolUse` — an earlier revision of this adapter attributed it to the wrong hook.
  A static `permissions` layer supports `allow` / `ask` / `deny` with **deny > ask > allow**
  precedence, and the default when nothing matches is to prompt.
- **Subagents** — `.devin/agents/<name>.md`, user-definable, and "each with its own context window".
  A skill can itself run as a subagent via `subagent: true`.
- **Structured questions** — an `ask_user_question` tool exists and is standardized over ACP
  elicitation. *Caveat:* it is evidenced by changelog entries rather than a reference page, so the
  exact option/multi-select schema is unverified. Prose remains the safe authoring choice.

## Gotchas

- **No `ask` tier in the hook path.** `PreToolUse` can only pass (exit 0) or block (exit 2), and
  `PermissionRequest` answers approve-or-block; the ask tier exists only in the static permissions
  config. So `db_write_requires_approval: high_risk` cannot be expressed as a hook-driven
  confirmation here — it collapses to deny-or-allow, and the installer must say which.
- **The hook fails OPEN, and this is documented rather than inferred.** Exit 0 continues, exit 2
  blocks, and any *other* nonzero code is "logged but doesn't block" (exit table confirmed verbatim
  2026-08-19). A crashing or misconfigured guard therefore stops gating silently — the guard must
  exit 2 deliberately, never merely fail.
- **Background subagents fail closed**, which is the opposite default and worth knowing: they
  inherit only already-granted permissions, cannot prompt for new ones, and anything unapproved is
  automatically denied. A `qc-reviewer` running in the background may simply be unable to re-run a
  query the main session could.
- Whether a hook decision can override a static `deny` rule is not documented.

## Metadata mapping

How the canonical source's control fields map here. Devin reads the canonical `.claude/skills/`
copy directly (toggleable in its config), which is why the installer verifies instead of emitting —
and that is also the shared-file trap: one file, many readers, and a foreign reader ignores
Claude-specific keys, so per-runtime skill metadata mapping is IMPOSSIBLE here. The losses are
stated in the install verify report, per affected skill.

| canonical field | here | how |
|---|---|---|
| `allowed-tools` (skill frontmatter) | lost | shared-file trap — Devin reads the canonical file and ignores this Claude-specific key; stated in the verify report |
| `disable-model-invocation` (skill frontmatter) | lost | shared-file trap — nothing here prevents model invocation of a user-invocable-only skill; the verify report warns per affected skill |
| `tools:` (agent definition, qc-reviewer) | mapped (unverified) | emitted into `.devin/agents/qc-reviewer.md` with `tools:` carried verbatim; whether the runtime honors it is live-verification work |
