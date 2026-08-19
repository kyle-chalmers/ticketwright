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
  the directory. The often-cited `.clinerules/workflows/` path is absent from the current
  documentation index and appears to have been folded into skills.
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
