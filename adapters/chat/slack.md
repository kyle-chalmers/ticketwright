---
seam: chat
tool: slack
transport: mcp         # MCP ({mcp}) tools only
requires: [mcp]        # stack.yaml seams.chat.{mcp, default_mode}; destination + recipients are per-ticket (delivery-plan.yaml chat.channel/recipients)
channel_key: default_channel   # THIS tool's destination key — read by delivery routing, never guessed by a skill
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
default_surface: claude-code   # the runtime the `## verb:` sections were written against (Slack's own MCP tool names)
surfaces: [codex-cli]          # runtimes that list this connector under other tool names: one `## Runtime surface:` section each, picked by bin/adapter_surface.py
auth: |
  The `slack` MCP server must be connected. Verify with a read-only search.
  Verify: a `mcp__{mcp}__slack_search_channels` call returns without error (on a runtime with its
  own section below, that section's probe instead: `bin/adapter_surface.py --probe` prints it).
note: |
  MCP cannot create a brand-new multi-person DM — create it once in the Slack UI, then reuse it.
---

# Slack adapter

Maps the `chat` verb contract to Slack via the `mcp__{mcp}__*` tools. **Two hard rules:** (1) default
to *draft*, not send — the human clicks send unless they say "send it";
(2) never solo-DM a stakeholder — every message includes `{always_include}` (e.g. Alice).

`{always_include}` is a **fixed stakeholder list** (the people always CC'd) — keep it that way. It is
*not* a self-tag. If a repo also wants the shipper mentioned, set `seams.chat.include_self: true`
(a **separate** token): resolve the shipper via `bin/resolve_user.py`, prefer the handle in their
voice-profile frontmatter (written once at `/setup --voice`) for `lookup_user`, else the resolver
identity — and add that mention *in addition to* `{always_include}`. Never substitute the shipper
*for* a stakeholder.

**`{default_channel}` and `{always_include}` are the ROUTED resolution, not config reads.**
`{default_channel}` is the routed **destination** and `{always_include}` the routed **recipient
list**, both taken from `bin/delivery_plan.py`'s output (`destination` / `recipients`) that `/ship`
resolves and the fingerprint pins — the skill never reads a config key here. In the **default
tool-only shape** the stack sets no `default_channel`: the destination + recipients are authored
per-communication in the ticket's `delivery-plan.yaml` (`chat.channel:` + `chat.recipients:`), asked
at `/ship`. **Under named targets** (`seams.chat.targets:`) they are that ROUTED target's own channel
+ list, selected by the plan's `audience:` declaration — never another target's, never a slot-level
one (this adapter declares `channel_key: default_channel`, so routing reads the right key without any
skill knowing this is Slack). Either way the destination is never inferred from a channel name or the
message text, and a routing failure never falls back to another channel.

## Permission posture (MCP)

### Native control
The connector's **OAuth grant** — which scopes it was authorized with — and, in practice, **which
tools the server exposes**. The draft tools are the path that expresses `default_mode: draft` +
`chat_default_draft`: `slack_send_message_draft` is the draft path, and the send tools
(`slack_send_message`) are the thing being gated. Where the control lives depends on the
connection shape: an official connector's grant is set in its app settings; a CLI-configured
server in its config file; a homegrown server with its owner (forward the suggestion).

### Recommended setting (by policy)
Prefer a grant that **excludes send** where the connector offers one — then `chat_default_draft`
holds by construction and only a human-clicked send goes out. Where the grant bundles send, the
draft-first rule above stays the operative control, and the skills' hard-halt stays the gate.

### Read-only probe
The read call the auth block already names — it proves reachability and which tools exist:
```
mcp__{mcp}__slack_search_channels(keywords=[<any channel name>], natural_language_query="", limit=1, response_format="concise")   # read-only
```
**What it cannot prove, stated plainly:** the connector's grant set is NOT introspectable
read-only from inside the session, so the posture record caps at `status: unverified` and the
draft/send policies remain GUIDANCE on this path. Confirm the actual grant in the connector's own
settings surface (app UI / server config / its owner) — record the outcome in gitignored
`.claude/config/posture.local.yaml`.

## verb: draft   (the default — policy chat_default_draft)
```
mcp__{mcp}__slack_send_message_draft(channel_id=<id or {default_channel}>, message=<body>, thread_ts=<optional>)
```
Body rules: standard Markdown (the MCP tools accept markdown); **hyperlink everything** with
`[text](URL)` — ticket IDs (`[TEST-123](https://<site>/browse/TEST-123)`), doc files, PRs. Honor `word_limits.chat` (<100).
Include `{always_include}` mentions. Resolve mentions/channels via the lookups below.

## verb: send    (ONLY on explicit "send it"/"post it")
```
mcp__{mcp}__slack_send_message(channel_id=<id>, message=<body>)
```

## verb: lookup_user
```
mcp__{mcp}__slack_search_users(keywords=[<name or email>], natural_language_query="", response_format="concise")   # → user ID for <@ID> mentions, and a DM's channel_id
```

## verb: lookup_channel
```
mcp__{mcp}__slack_search_channels(keywords=[<name>], natural_language_query="", response_format="concise")   # → channel ID
```
Existing group DMs can be reused by searching; new multi-person DMs must be created in the UI first.

## gotchas
- Slack's tools take **standard Markdown** on every agent: use `[text](URL)` links, not Slack
  `<URL|text>` mrkdwn.
- Checked against Slack's own hosted connector (the one claude.ai and the Claude apps connect),
  observed 2026-10-26 from the connector's tool declarations in a Claude Code session: draft and
  send take `channel_id` + `message` (+ optional `thread_ts`), and both search tools take
  `keywords` (a list of single words or quoted phrases, all must match) plus a required
  `natural_language_query` (pass `""` for a plain lookup), not `query`. A self-hosted Slack MCP
  server can spell these differently; this adapter targets the hosted one.
- **A DM is a `channel_id` too:** pass the person's user id (from `lookup_user`) as `channel_id`.
  A group DM must already exist (find it with `lookup_channel`); the connector cannot create one.
- **One draft per channel.** `slack_send_message_draft` answers `attached_draft_exists` when the
  person already has a draft there; say so and ask them to send or delete it, never overwrite it.
- The hosted connector **cannot post to Slack Connect (externally shared) channels**. A ticket
  whose audience lives in one goes out another way; say so at `/ship` rather than failing at send.
- Tool names differ by agent: Codex CLI adds a `slack_` app prefix (in its own section of this file).
  `bin/adapter_surface.py --adapter adapters/chat/slack.md` picks the right section for the agent
  running now. A name missing from your session's tool list is a gap to report so the kit can
  record it, never a local edit here or in a skill.
- Tag the people the routed plan names; `{always_include}` is non-negotiable when the target has
  one. A per-ticket post to a channel (`chat.kind: channel`) may name nobody: the channel is the
  audience.

## Runtime surface: codex-cli

server: codex_apps

Codex CLI reaches Slack through the ChatGPT Slack app: every tool sits under the one server
`codex_apps`, and the app adds a `slack_` prefix to Slack's own tool names, so
`slack_send_message_draft` arrives as `slack_slack_send_message_draft`. The argument shapes are
Slack's own. Both search tools take `keywords`, a list of single words or quoted phrases, and an
empty list is refused as invalid (observed 2026-10-24, with the connector's own tool declarations,
in a Codex CLI session). The rules of the default sections hold unchanged here: draft first,
every message names `{always_include}`, and the destination is the routed one, never a channel
guessed from its name.

### verb: draft
```
mcp__codex_apps__slack_slack_send_message_draft(channel_id=<id or {default_channel}>, message=<body>, thread_ts=<optional>)
```
Body rules, the same on every runtime: standard Markdown, **hyperlink everything** with
`[text](URL)` (ticket IDs, doc files, PRs), honor `word_limits.chat` (<100), and include the
`{always_include}` mentions. The draft lands in the person's Slack "Drafts & Sent" unsent.

### verb: send
ONLY on explicit "send it"/"post it".
```
mcp__codex_apps__slack_slack_send_message(channel_id=<id>, message=<body>)
```

### verb: lookup_user
```
mcp__codex_apps__slack_slack_search_users(keywords=[<name or email>], natural_language_query="", response_format="concise")   # → user ID for <@ID> mentions
```

### verb: lookup_channel
```
mcp__codex_apps__slack_slack_search_channels(keywords=[<name>], natural_language_query="", response_format="concise")   # → channel ID
```
Private channels need `channel_types="public_channel,private_channel"`. New multi-person DMs
still have to be created in the Slack UI first.

### Permission posture on this runtime
The control is the Slack app's connection for the signed-in ChatGPT account: which workspace it
reaches and whether its grant includes send. The grant is NOT introspectable from inside the
session, so the posture record caps at `status: unverified` exactly as above; confirm it where the
app was connected and record the outcome in `.claude/config/posture.local.yaml`.

### Read-only probe
```
mcp__codex_apps__slack_slack_list_workspaces(limit=1)                                                     # read-only: the connected workspace
mcp__codex_apps__slack_slack_search_channels(keywords=[<any channel name>], natural_language_query="", limit=1, response_format="concise")   # read-only
```
