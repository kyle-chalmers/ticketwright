<!-- emitted by ticketwright install v3.5.0 — do not hand-edit; re-run `ticketwright install --runtime cline` to update. -->

# Ticketwright enforcement — what is mechanical here

### Who enforces what, per agent runtime

How much of this protocol is *mechanical* depends on which agent runtime you are in — and a
missing hook must never silently weaken a policy, so this table is the non-silence. Cell values:
**ENFORCEMENT** = a mechanism proven in this kit's own test contract (today: the native Claude
Code hooks); **WIRED** = the documented mechanism is emitted and speaks the documented protocol,
but that the runtime honors it is live-verification work still owed — a WIRED gate is strong, not
proven, and never reads as parity with ENFORCEMENT; **GUIDANCE** = a named file or workflow
carries it and honoring it is on the agent; **UNKNOWN** = the runtime's behavior is undocumented —
never assume protection. `ticketwright install --runtime <name>` emits the wiring where one is
documented, and a live confirmation on the kit's punch list
(<https://github.com/kyle-chalmers/ticketwright/blob/main/docs/live-verification.md>) is what
upgrades a WIRED cell to ENFORCEMENT.

| Runtime | `db_write_guard` | `session_context` | `ticket_index_context` | `regenerate_ticket_index` | Unreadable hook input |
|---|---|---|---|---|---|
| Claude Code | ENFORCEMENT (native `PreToolUse` hook, `ask` tier) | ENFORCEMENT (native) | ENFORCEMENT (native) | ENFORCEMENT (native) | fails open by design (exit 0); an unreadable *policy* value still gates more (`all`) |
| Codex CLI | GUIDANCE (shim ready — wire manually, see caveat) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (fallback below) | denies, with the escape |
| Cursor | WIRED (emitted `.cursor/hooks.json`, `failClosed: true`) | GUIDANCE (fallback below) | GUIDANCE (fallback below) | GUIDANCE (fallback below) | escalates to `ask` |
| Antigravity | WIRED (emitted `.agents/hooks.json`: `ask` / `force_ask`) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below; static-not-fresh) | WIRED (emitted `PostToolUse` entry) | escalates to `ask` |
| OpenCode | WIRED (emitted `.opencode/plugins/` throw-to-deny wrapper) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below; static-not-fresh) | GUIDANCE (fallback below) | denies, with the escape |
| Devin | GUIDANCE (shim ready — wire manually, see caveat) | GUIDANCE (shim ready — wire manually) | GUIDANCE (shim ready — wire manually) | GUIDANCE (fallback below) | denies, with the escape |
| Cline | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (hooks unverified upstream) | UNKNOWN (nothing is wired) |

The unreadable-input column applies within the guard's jurisdiction — a shell-like tool call —
and only while the policy is on: a payload naming a clearly non-shell tool passes untouched, and
`policies.db_write_requires_approval: off` silences the guard entirely (an explicit operator
instruction, readable without classifying anything).

Per-runtime caveats — the part that keeps the table honest:

- **Claude Code** — the native hooks in `.claude/hooks/` (`db_write_guard` sees SQL hidden in a
  `-f` file or a stdin redirect too). Hooks fail open by design — a hook error never blocks a
  session — but an unreadable policy value resolves to `all`, gating more, and a missing SQL
  scanner gates everything until the kit is repaired.
- **Codex CLI** — no `ask` tier, so `high_risk` collapses to **deny-with-escape**: destructive
  statements are denied with a message naming the one-shot re-approval (the
  `TICKETWRIGHT_APPROVE=once` command prefix, or the `.claude/config/approve.once` token —
  consumed on use, expires in 15 minutes); additive statements pass untouched. The shim speaks the
  documented deny protocol — wire it as
  `bash bin/tw hook_shim.py --runtime codex-cli --hook db_write_guard || exit 2` (the suffix keeps
  a `bin/tw` launcher failure inside the documented deny exit; the shim itself exits only 0 or 2)
  — but the hooks-config file location is not in the kit's research, so wiring it is manual until
  verified live. Even once wired: hooks must be **trusted by hash** (installed is not armed; an
  edit re-arms the review), and Codex's own docs call hooks a guardrail, not a complete
  enforcement boundary.
- **Cursor** — the installer emits `.cursor/hooks.json` with **`failClosed: true`** — required
  configuration, not tuning: Cursor hooks fail OPEN by default, and without it the gate stops
  gating the moment the hook errors, silently. `high_risk` is expressed as `ask`. The config-file
  schema and the deny path are live-unverified (unofficial reports of uneven deny behavior exist).
- **Antigravity** — `high_risk` → `ask`; `all` → `force_ask`, which ignores cached grants (a
  remembered "yes" never covers the next destructive statement). What a **failing** hook does here
  is undocumented — UNKNOWN, never assumed to hold. No session-start event exists in the CLI, so
  the banners are workflow (below).
- **OpenCode** — no `ask` tier: `high_risk` collapses to **deny-with-escape**, delivered by the
  emitted plugin wrapper throwing from `tool.execute.before` ("throwing an error prevents the tool
  from executing"). What an entirely-failed plugin *load* does is undocumented, and whether the
  wrapper is actually loaded is live-unverified.
- **Devin** — no `ask` tier: `high_risk` collapses to **deny-with-escape**. Devin's hook path
  **fails open by documented design** (exit 0 continues, exit 2 blocks, any other nonzero is
  logged and ignored) — so the shim maps every internal error to a deliberate exit 2, never a
  stray crash. The hooks-config file location is not in the kit's research; wiring
  (`bash bin/tw hook_shim.py --runtime devin --hook db_write_guard || exit 2` — the suffix keeps
  even a `bin/tw` launcher failure inside the one exit code Devin honors as a block) is manual
  until verified live.
- **Cline** — the policy degrades to **guidance** here, stated plainly: the hooks doc is a stub,
  whether file-based hooks fire is unverified upstream, and Cline's approval classification is
  **model-judged**, not a deterministic scanner. `ticketwright install --runtime cline` writes
  this table into `.clinerules/` so Cline users actually see it (Cline does not read AGENTS.md).

Fallbacks, named (the GUIDANCE cells above point here):

- **Session banners without a session hook** — run them at session start:
  `bash bin/tw hook_shim.py --runtime <name> --hook session_context` and the same with
  `--hook ticket_index_context`. Rules files are static; the banner output is fresh — never treat
  rules text as a substitute for the live stack + catalog summary.
- **Index auto-regen without a PostToolUse hook** — the enrich/ship flow already runs
  `bash bin/tw build_ticket_index.py` when a ticket changes, and its `--check` staleness gate
  fails a stale catalog. Freshness degrades to that pair, never to nothing.
