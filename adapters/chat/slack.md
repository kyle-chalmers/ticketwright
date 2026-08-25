---
seam: chat
tool: slack
transport: mcp         # MCP ({mcp}) tools only
requires: [mcp]        # stack.yaml seams.chat.{mcp, default_channel, default_mode, always_include}
channel_key: default_channel   # THIS tool's destination key — read by delivery routing, never guessed by a skill
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  The `slack` MCP server must be connected. Verify with a read-only search.
  Verify: a `mcp__{mcp}__slack_search_channels` call returns without error.
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

**Under named targets** (`seams.chat.targets:`), every value below belongs to the ROUTED target:
`{default_channel}` is that target's own channel (this adapter declares `channel_key:
default_channel`, so routing reads the right key without any skill knowing this is Slack), and
`{always_include}` is that target's own list — never another target's, and never a slot-level one.
The routed target comes from the ticket's `delivery-plan.yaml` `audience:` declaration
(`bin/delivery_plan.py`); it is never inferred from a channel name or from the message text, and a
routing failure never falls back to another channel.

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
mcp__{mcp}__slack_search_channels(query=<any channel name>)   # read-only
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
`[text](URL)` — ticket IDs (`[ENG-123](https://<site>/browse/ENG-123)`), doc files, PRs. Honor `word_limits.chat` (<100).
Include `{always_include}` mentions. Resolve mentions/channels via the lookups below.

## verb: send    (ONLY on explicit "send it"/"post it")
```
mcp__{mcp}__slack_send_message(channel_id=<id>, message=<body>)
```

## verb: lookup_user
```
mcp__{mcp}__slack_search_users(query=<name or email>)   # → user ID for <@ID> mentions
```

## verb: lookup_channel
```
mcp__{mcp}__slack_search_channels(query=<name>)          # → channel ID
```
Existing group DMs can be reused by searching; new multi-person DMs must be created in the UI first.

## gotchas
- The `mcp__{mcp}__*` tools take **standard Markdown** — use `[text](URL)` links, not Slack `<URL|text>` mrkdwn.
- Exact parameter names vary by Slack MCP server; this adapter targets one exposing `channel_id` + `message`. If yours differs, adjust here (not in the skills).
- Tag the stakeholders the channel context calls for, but `{always_include}` is non-negotiable.
