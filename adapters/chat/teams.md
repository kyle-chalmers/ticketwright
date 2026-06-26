---
seam: chat
tool: teams
transport: mcp         # a Microsoft Teams / Graph MCP, or incoming-webhook fallback
requires: [channel, default_mode, always_include]
auth: |
  A Teams MCP server (Graph) connected, OR an incoming-webhook URL per channel.
  Verify: a read-only "list channels"/"list teams" MCP call returns without error.
---

# Microsoft Teams adapter (reference for the abstraction proof)

Maps the `chat` verb contract to Teams. Same two rules as Slack: default to **draft**, and always
include `{always_include}`. Teams uses Adaptive Cards / HTML rather than Slack mrkdwn.

## verb: draft
Compose the message and **hold it for the human** (Teams has no native "draft to a channel" — stage
the Adaptive Card JSON / message text in the ticket folder as `chat_draft.json` for the human to send).

## verb: send   (ONLY on explicit "send it")
```
<teams mcp> post-message(channel={channel}, body=<HTML/Adaptive Card>)   # or POST to webhook URL
```
Hyperlink everything: `<a href="URL">text</a>` (Teams renders HTML), ticket IDs, files, PRs.
Honor `word_limits.chat`.

## verb: lookup_user
```
<teams mcp> search-users(query=<name/email>)        # → user id for the mention
```

## verb: lookup_channel
```
<teams mcp> list-channels(team=<team>)               # → channel id
```

## gotchas
- Incoming-webhook transport can post but can't @mention reliably — prefer the Graph MCP when mentions matter.
