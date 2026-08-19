---
seam: runtime
tool: cline
transport: native
requires: []
detect_env: CLINE_DIR, CLINE_API_KEY
skills_root: .cline/skills/<name>/SKILL.md
skills_format: markdown + YAML frontmatter (name matching the directory, description)
session_start: unknown
tool_gate: unknown
subagents: no
structured_questions: unknown
gate_ask_tier: unknown      # the gate API itself is in flux; no return schema documented
gate_fail_mode: unknown
subagent_isolation: none    # subagents exist but are not user-definable — nothing to isolate for the kit
reads_foreign_skills: .claude/skills
global_skills_root: ~/.cline/skills   # documented for macOS/Linux (Windows: %USERPROFILE%\.cline\skills) — re-verified 2026-08-19
agents_root: none           # subagents exist but are not user-definable — nothing for the kit to define
foreign_skills_caveat: .claude/skills/ is one of three documented skill locations here, and Cline's docs are the least settled of the seven — re-verify discovery before relying on it.
model_cmd: ""
model_sandbox: n/a   # no headless model command
auth: |
  A Cline install (VS Code extension or SDK).
  Verify: `command -v cline`.
---

# Cline runtime adapter

The least settled of the seven. Three of its five capability rows are declared `unknown`, and that is
a finding rather than a gap in the research: Cline's hooks documentation is currently a **stub**
redirecting to an SDK surface, with no deprecation notice explaining what happened to the file-based
mechanism it replaced.

## Capabilities

- **Rules + skills** — rules in `.clinerules/` (every `.md`/`.txt` inside), global under
  `~/Documents/Cline/Rules`; workspace wins on conflict. Skills at `.cline/skills/` (recommended),
  `.clinerules/skills/`, or `.claude/skills/`, with `SKILL.md` frontmatter whose `name` must match
  the directory; global skills at `~/.cline/skills/` on macOS/Linux (re-verified 2026-08-19 — an
  earlier revision of this adapter recorded only the global *rules* path). The often-cited
  `.clinerules/workflows/` path is absent from the current documentation index and appears to have
  been folded into skills.
- **Session start** — **unknown.** A `TaskStart` file-based hook was documented in a
  2025-11 release post at `.clinerules/hooks/`; the current docs page is a stub pointing at SDK
  plugins, whose lifecycle does include `session_start` — but that is a TypeScript surface for
  embedders, not a config file the editor extension reads. Whether a file-based `TaskStart` still
  fires is not established.
- **Tool gate** — **unknown**, same split. File-based hooks returned `{"cancel": true}` to block
  (macOS and Linux only; Windows unsupported as of that post). The current SDK documentation lists
  `tool_call_before` for blocking tool calls but **does not document the return schema**.
- **Subagents** — present and each has its own context window, but **not user-definable**: there is
  no directory-based definition, Cline decides when to spawn them, and they cannot edit files.
  Declared `no` because what the kit needs is a *definable* `qc-reviewer`, and that cannot be
  expressed here — the review degrades to an inline second pass.
- **Structured questions** — `ask_followup_question` with selectable options exists in the product,
  but the current tools reference documents no parameter schema for it. Declared unknown.

## Gotchas

- **The approval classification is model-judged, not deterministic.** The model marks each command
  with a `requires_approval` flag based on the command and its arguments. That is a materially weaker
  guarantee than `db_write_guard`'s deterministic, default-deny scanner: it asks the same class of
  system that wants to run the statement whether the statement is dangerous.
- Because the gate API is in flux and the classification is model-judged, **this is the one runtime
  where `db_write_requires_approval` should be stated plainly as guidance rather than enforcement**
  until the documentation settles.

## Metadata mapping

How the canonical source's control fields map here. Cline reads the canonical `.claude/skills/`
copy directly (one of its three documented skill locations), which is why the installer verifies
instead of emitting — and that is also the shared-file trap: one file, many readers, and a foreign
reader ignores Claude-specific keys, so per-runtime skill metadata mapping is IMPOSSIBLE here. The
losses are stated in the install verify report, per affected skill.

| canonical field | here | how |
|---|---|---|
| `allowed-tools` (skill frontmatter) | lost | shared-file trap — Cline reads the canonical file and ignores this Claude-specific key; stated in the verify report |
| `disable-model-invocation` (skill frontmatter) | lost | shared-file trap — nothing here prevents model invocation of a user-invocable-only skill; the verify report warns per affected skill |
| `tools:` (agent definition, qc-reviewer) | lost | subagents are not user-definable here, so `qc-reviewer` cannot exist as an agent at all — `/review --deep` degrades to an inline same-context pass and its verdict says so; the install report states the loss |
