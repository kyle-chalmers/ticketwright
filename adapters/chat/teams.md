---
seam: chat
tool: teams
transport: mcp         # a Microsoft Teams / Graph MCP (server = {mcp}), or incoming-webhook fallback
requires: [channel, default_mode, always_include]   # + `mcp` (server name) when using the MCP transport
channel_key: channel   # THIS tool's destination key (Slack spells it `default_channel`) — read by delivery routing
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  A Teams MCP server (Graph) connected, OR an incoming-webhook URL per channel.
  Verify: a read-only "list channels"/"list teams" MCP call returns without error.
---

# Microsoft Teams adapter (reference for the abstraction proof)

Maps the `chat` verb contract to Teams. Same two rules as Slack: default to **draft**, and always
include `{always_include}` (a fixed stakeholder list — never a self-tag). Teams uses Adaptive Cards /
HTML rather than Slack mrkdwn. If `seams.chat.include_self: true`, also mention the shipper *in
addition to* `{always_include}`: resolve via `bin/resolve_user.py`, preferring the handle in their
voice-profile frontmatter for `lookup_user`, else the resolver identity.

**Under named targets** (`seams.chat.targets:`), `{channel}` and `{always_include}` are the ROUTED
target's own — never another target's, never a slot-level one. Teams spells its destination key
`channel` where Slack spells it `default_channel`, which is why this adapter declares
`channel_key: channel` and no skill has to know the difference. The routed target comes from the
ticket's `delivery-plan.yaml` `audience:` declaration (`bin/delivery_plan.py`), never from a channel
name, a label, or the message text, and a routing failure never falls back to another channel.

## Permission posture (MCP)

### Native control
The connector's **Graph permission grant** (which Teams/Graph scopes it was consented) and **which
tools the server exposes**. This adapter's draft verb already stages a file for the human (Teams
has no native channel draft), so the send tool (`post-message`) is the thing being gated —
`default_mode: draft` + `chat_default_draft` are expressed by never calling it unprompted. An
official connector's grant lives in its app/admin consent; a CLI-configured server in its config
file; a homegrown server or webhook with its owner (forward the suggestion).

### Recommended setting (by policy)
Prefer a grant that **excludes posting** where the connector offers one (read-scoped Graph
consent) — then `chat_default_draft` holds by construction. A webhook transport can ONLY post, so
on that shape the staged-draft rule above is the whole control, and the skills' hard-halt stays
the gate.

### Read-only probe
The read call the auth block already names — it proves reachability and which tools exist:
```
mcp__{mcp}__list-channels(team=<team>)   # read-only ("list teams" works the same)
```
**What it cannot prove, stated plainly:** the connector's grant set is NOT introspectable
read-only from inside the session, so the posture record caps at `status: unverified` and the
draft/send policies remain GUIDANCE on this path. Confirm the actual grant in the connector's own
settings surface (admin consent / server config / its owner) — record the outcome in gitignored
`.claude/config/posture.local.yaml`.

## verb: draft
Compose the message and **hold it for the human** (Teams has no native "draft to a channel" — stage
the Adaptive Card JSON / message text in the ticket folder as `chat_draft.json` for the human to send).

## verb: send   (ONLY on explicit "send it")
```
mcp__{mcp}__post-message(channel={channel}, body=<HTML/Adaptive Card>)   # or POST to webhook URL
```
Hyperlink everything: `<a href="URL">text</a>` (Teams renders HTML), ticket IDs, files, PRs.
Honor `word_limits.chat`.

## verb: lookup_user
```
mcp__{mcp}__search-users(query=<name/email>)        # → user id for the mention
```

## verb: lookup_channel
```
mcp__{mcp}__list-channels(team=<team>)               # → channel id
```

## gotchas
- Incoming-webhook transport can post but can't @mention reliably — prefer the Graph MCP when mentions matter.
