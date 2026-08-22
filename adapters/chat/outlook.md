---
seam: chat
tool: outlook
transport: mcp         # an Outlook / Microsoft Graph MCP server ({mcp}) — draft/send/people tools
requires: [mcp, to, identity, default_mode, always_include]
channel_key: to        # THIS tool's destination key — ONE address string (a person or a distribution list), read by delivery routing
sender_key: identity   # THIS tool's sender key — routing surfaces it on the plan line and pins it in the fingerprint
user_keys: []             # tier-3 overridable: nothing here is machine-local; the sending identity (often a shared mailbox) is a team decision and credentials live in the MCP server's own auth
auth: |
  An Outlook / Graph MCP server connected, with Mail permissions for `{identity}`
  (a licensed user or a shared mailbox with send-as rights).
  Verify: a read-only `mcp__{mcp}__list_mail_folders` call returns without error.
note: |
  THE VERB MAPPING, HONESTLY — email is not Teams, and this table does not pretend it is:
  - `draft` / `send` map DIRECTLY: Outlook drafts are real mailbox objects, so draft-first is
    native (unlike the Teams adapter, which has to stage a file).
  - `lookup_user` maps to the ADDRESS BOOK (Graph people/users search). Close enough to be the
    same verb.
  - `lookup_channel` -> a DISTRIBUTION LIST (or M365 group address) is a STRETCH. Email has no
    channels: a list address is opaque, so resolving one proves the address exists, NOT who reads
    it — a channel's membership is inspectable, a list's is not. Treat the result as an address,
    never as an audience.
  - `always_include` / `channel` do NOT transfer cleanly to a medium with to/cc/bcc. This
    adapter's mapping: `{to}` (its `channel_key:`) is ONE primary address string, and
    `{always_include}` renders as Cc — every routed recipient VISIBLE in the header. There is
    deliberately NO bcc mapping: a hidden recipient makes the delivered audience differ from what
    every reader and every reply-all sees, and nothing here may widen an audience invisibly.
    Do not put a semicolon- or comma-joined address list in `{to}` — extra primary recipients
    belong in `{always_include}`, where each address is validated and printed on the /ship plan
    line (a `;` is refused outright by the shell-metacharacter rule).
  - `include_self` (a SEPARATE token, never a substitute): when true, Cc the shipper IN ADDITION
    to `{always_include}` — never instead of a stakeholder.
  A wrong email is the LEAST recoverable delivery: Outlook's "recall" only works inside one
  Exchange org and fails silently otherwise, so treat every send as final. Routing comes only from
  the ticket's DECLARED audience, a routing failure is a STOP (never a fallback to another chat
  target), and the default is a draft a human clicks.
---

# Outlook adapter (email as a `chat` target — not a sixth seam)

Maps the `chat` verb contract to Outlook (Microsoft Graph mail) via the `mcp__{mcp}__*` tools. Same
two hard rules as every chat adapter: (1) default to **draft**, not send — the human clicks send
unless they say "send it"; (2) never solo-mail a stakeholder — every message carries
`{always_include}` (this target's own list, rendered as Cc).

Mail goes out **as `{identity}`** (a user or a shared mailbox) — a team decision in committed
config, never derived from whoever happens to be shipping. This adapter declares
`sender_key: identity`, so routing surfaces the sender on the resolved plan line the human
authorizes, refuses to route a named email target with no identity at all, and pins the value in
the `resolution_fingerprint` — a post-approval config edit swapping one mailbox for another
refuses instead of quietly changing who the mail is from.

The ONE sanctioned exception to declaration-only routing is prompt 8's `--chat <target>` override:
an explicit human command (never an inference) that still routes here without a declared audience —
the CLI warns that the routing is not recorded with the ticket, and the /ship plan line says so to
the approver. Nothing else selects this target.

**Under named targets** (`seams.chat.targets:`), every value here belongs to the ROUTED target:
`{to}` is that target's own destination (this adapter declares `channel_key: to`, so routing reads
the right key without any skill knowing this is email) and `{always_include}` is that target's own
list — never another target's, and never a slot-level one. The routed target comes from the
ticket's `delivery-plan.yaml` `audience:` declaration (`bin/delivery_plan.py`); it is never
inferred from prose, an address's domain, or a list's name, and a routing failure never falls back
to another chat target.

## verb: draft   (the default — policy chat_default_draft, and `default_mode: draft` set explicitly)
```
mcp__{mcp}__create_draft(to=[{to}], cc=[{always_include} (+ the shipper when include_self)], subject=<[ENG-123] summary>, body=<HTML body>)
```
Body rules: Outlook renders HTML — **hyperlink everything** with `<a href="URL">text</a>`: ticket
IDs, docstore files, PRs. Honor `word_limits.chat` (<100). Name every routed recipient in the body
too (`--check-draft` reads the draft, not the API call). The draft sits in `{identity}`'s Drafts
folder for a human to open and send.

## verb: send    (ONLY on explicit "send it"/"post it" — treat every send as final)
```
mcp__{mcp}__send_mail(to=[{to}], cc=[{always_include} (+ the shipper when include_self)], subject=<[ENG-123] summary>, body=<HTML body>)
```

## verb: lookup_user
```
mcp__{mcp}__search_people(query=<name or email>)      # → address for the To/Cc lines
```

## verb: lookup_channel   (a distribution list — the STRETCH named above)
```
mcp__{mcp}__search_people(query=<list or group name>) # → the list's address, e.g. platform-updates@acme-corp.example
```
Resolving a list proves the address exists, not who reads it. When the audience matters — and for
email it always does — confirm the list's membership with its owner once, outside this kit.

## gotchas
- Exact tool names and parameters vary by Graph MCP server (some expose `sendMail`, some split
  create-draft/update-draft). Confirm once against your connected server and adjust **here**, never
  in a skill.
- A shared mailbox needs `Mail.Send.Shared` (delegated) or application send-as rights configured in
  Exchange; this adapter cannot grant them, only use them.
- External recipients may be rewritten by the org's mail hygiene (banner injection, link
  rewriting) — the delivered body is not guaranteed byte-identical to the draft.
