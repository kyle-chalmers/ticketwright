# PROMPT — MCP permission posture: advisory enforcement for the transport hooks cannot see

STATUS: DRAFT for maintainer review. Not scheduled. Written 2026-08-24, the day four teammates
onboarded and the db_write_guard's Bash-only jurisdiction was documented (see the 3.7.1 batch).
Direction set by the maintainer in that session: on the MCP path, enforcement does not disappear —
it moves into the tool's own permission controls — so the kit should ADVISE where it cannot hook.
This document is SELF-CONTAINED.

## Why

`db_write_guard` (and every shell guard) sees **Bash** — a warehouse MCP call never reaches it,
and the 3.7.1 batch made that limit explicit everywhere it was previously implied away. But
`transport: mcp` is a legal seam configuration, both shipped warehouse adapters advertise the MCP
path, and real teams connect through desktop connectors, official MCP servers, and homegrown ones.
Telling those teams "route writes through the CLI" is a rule they must remember; it is not a gate.

The observation this spec builds on: **most MCP-connected tools carry their own permission
controls** — a Snowflake connection has a role, a Databricks token has a scope, an OAuth connector
asked for specific grants, a chat server exposes draft-mode tools. When the harness cannot enforce
a policy, the next best thing is not prose in a skill — it is making the TOOL's native control
carry the policy, and making the kit check and say so. Tiebreaker 6: safety gates get more
visible, never more convenient; where a runtime cannot enforce mechanically, say so plainly.

Also in scope from the same direction: the kit adapts to HOW the person connected (official
connector, CLI, someone's homegrown server) instead of demanding one shape. A server the kit
cannot configure still gets a posture check — and a suggested change addressed to whoever owns it.

## Deliverable 1 — a `## Permission posture (MCP)` section in every mcp/both-transport adapter

Per adapter, three things, in the adapter's own voice:
1. **Where the native control lives** for the MCP path (the connection's role; the token's scope;
   the connector's OAuth grants; the server's own config file).
2. **The recommended setting given the team's policies** — written against the policy names, not
   restated rules. Examples of the shape (illustrative, adapters own the specifics):
   - `warehouse/snowflake.md`: with `db_write_requires_approval` on, the MCP connection should use
     a read-only role, so the policy holds by construction on the path the guard cannot see;
     writes go through the CLI, where it can. A homegrown server gets the same posture as a
     suggestion to its owner ("pin this connection's role").
   - `warehouse/databricks.md`: scope the MCP path's token/warehouse ACL to read.
   - `chat/*.md`: the draft-mode tools are the native control; `default_mode: draft` +
     `chat_default_draft` already express the policy — the posture section says which tool names
     are the draft path and that send-tools are the thing being gated.
   - `tracker/*.md`: external posts are already gated by `hard_halt_before_external_posts` at the
     skill layer; the posture section names the connector grants that matter (create vs read).
3. **A read-only probe** that checks the posture from inside a session (e.g. the warehouse's
   current-role query via the MCP; a chat read call). Never a mutation, never a bare enumeration
   that prints secrets (the names-only precedent from the snowflake adapter holds).

The GOLDEN RULE is untouched: skills never name a tool. The setup flow renders "check this slot's
native controls" and the CONTENT comes from the adapter section, exactly like verbs and auth.

## Deliverable 2 — setup advises when a seam resolves to MCP transport

- In `/setup` (tool rounds) and `/setup --teammate` (verification step): for each seam whose
  transport includes `mcp`, surface the adapter's posture — the control, the recommended setting,
  the probe — and record the probe's outcome next to the reachability check the 3.7.1 batch added.
- When the probe shows a posture the policy does not expect (a write-capable role on a
  read-advised path), the flow says so and suggests the fix — it does not block. Advisory means
  advisory: the person may own neither the server nor the grant. If they cannot change it, the
  outcome is recorded as "posture: unverified/exceeds-policy" in the setup report, not silence.
- The wording must work for all three connection shapes: official connector (settings live in the
  app), CLI-configured server (settings live in a config file), homegrown (settings live with its
  owner — produce the suggestion to forward).

## Deliverable 3 — the enforcement table gains NATIVE (tool-side)

`templates/AGENTS.md.tmpl`'s runtime table currently answers ENFORCEMENT or GUIDANCE per cell.
MCP-transport seams get a third value: **NATIVE (tool-side)** — enforcement lives in the tool's
own permission controls, pointer to the adapter's posture section, checked at setup time by the
probe. GUIDANCE keeps meaning "prose the agent follows"; NATIVE means "a control outside the
harness is configured to carry this policy, and here is when it was last checked." The emitters
(`bin/emit_runtime.py`) carry the same cell to the other runtimes' artifacts; regenerate the
`tests/emit/` fixtures.

## Deliverable 4 — selftest

- Every `transport: mcp`/`both` adapter carries the posture section (structure pin, like verb
  coverage: heading present, all three parts present).
- The section's probe line is read-only by the same standards the adapters already meet (no
  mutation verbs, no bare enumerations).
- The template's NATIVE cell text is pinned the way the jurisdiction sentences are (§48 style).
- A behavioral case: the setup flow's rendered advisory names the adapter section for a fixture
  stack with an MCP seam (run against `stack.example.*` the way skills-vs-stacks tests already do).

## Sequencing and pairing

- Pairs with the connector-identity problem (P3-A from the 3.7.1 batch): the setup flow must FIND
  the connected server before it can probe it. Desktop connectors are UUID-named and
  session-varying; only the tool-name suffix is stable. Resolve by suffix match, offer candidates,
  confirm before first use. That work can land first or together; the posture sections are useful
  prose even before probing is automatic.
- The mechanical alternative (a generic `mcp__.*` hook + adapter-declared payload JSON paths)
  stays on the shelf BEHIND this: it is Claude-Code-only, needs per-server payload knowledge, and
  the posture layer covers every runtime because the enforcement lives in the tool, not the
  harness. If it is ever built, it augments NATIVE, not replaces it.

## Acceptance

A teammate on a fresh machine, connected however they like, finishes `/setup --teammate` and can
answer three questions from the setup report alone: which slots are mechanically gated, which are
tool-side and what the tool's control is set to, and which are guidance-only — with no cell
reading stronger than what is actually true.
