---
seam: chat
tool: slack
transport: mcp         # mcp__slack__* only (legacy zsh helpers removed)
requires: [mcp]        # stack.yaml seams.chat.{mcp, default_channel, default_mode, always_include}
auth: |
  The `slack` MCP server must be connected. Verify with a read-only search.
  Verify: a `mcp__slack__slack_search_channels` call returns without error.
note: |
  MCP cannot create a brand-new multi-person DM — create it once in the Slack UI, then reuse it.
---

# Slack adapter

Maps the `chat` verb contract to Slack via the `mcp__slack__*` tools. **Two hard rules from saved
memory:** (1) default to *draft*, not send — the human clicks send unless they say "send it";
(2) never solo-DM a stakeholder — every message includes `{always_include}` (e.g. Kyle).

## verb: draft   (the default — policy chat_default_draft)
```
mcp__slack__slack_send_message_draft(channel=<id or {default_channel}>, text=<body>)
```
Body rules: plain-text Slack format; **hyperlink everything** with `<URL|text>` — ticket IDs
(`<https://<site>/browse/DI-XXXX|DI-XXXX>`), GDrive files, PRs. Honor `word_limits.chat` (<100).
Include `{always_include}` mentions. Resolve mentions/channels via the lookups below.

## verb: send    (ONLY on explicit "send it"/"post it")
```
mcp__slack__slack_send_message(channel=<id>, text=<body>)
```

## verb: lookup_user
```
mcp__slack__slack_search_users(query=<name or email>)   # → user ID for <@ID> mentions
```

## verb: lookup_channel
```
mcp__slack__slack_search_channels(query=<name>)          # → channel ID
```
Existing group DMs can be reused by searching; new multi-person DMs must be created in the UI first.

## gotchas
- Smart links only render with `<URL|text>`; bare URLs read as raw text.
- Tag the stakeholders the channel context calls for, but `{always_include}` is non-negotiable.
