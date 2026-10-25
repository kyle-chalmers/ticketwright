---
seam: chat
tool: gmail
transport: mcp         # a Gmail MCP server ({mcp}) — draft/send tools (no contacts search on the connectors described here)
requires: [mcp, identity, default_mode]   # destination (to) + recipients are per-ticket (delivery-plan.yaml); `identity` is the team sending mailbox
channel_key: to        # THIS tool's destination key — ONE address string (a person or a distribution list), read by delivery routing
sender_key: identity   # THIS tool's sender key — routing surfaces it on the plan line and pins it in the fingerprint
user_keys: []             # tier-3 overridable: nothing here is machine-local; the sending identity is a team decision and credentials live in the MCP server's own auth
default_surface: claude-code   # the runtime the `## verb:` sections were checked on (the Gmail connector's own tool names, 2026-10-25)
surfaces: [codex-cli]          # runtimes that list this connector under other tool names: one `## Runtime surface:` section each, picked by bin/adapter_surface.py
auth: |
  The Gmail MCP server must be connected, authenticated as (or delegated to) `{identity}`.
  Verify: a read-only `mcp__{mcp}__search_threads` call returns without error (on a runtime with
  its own section below, that section's probe instead: `bin/adapter_surface.py --probe` prints it).
note: |
  THE VERB MAPPING, HONESTLY — email is not Slack, and this table does not pretend it is:
  - `draft` / `send` map DIRECTLY: Gmail has native draft objects, so draft-first is real here,
    not staged-in-a-folder.
  - `lookup_user` maps to the ADDRESS BOOK where a server has one. Neither Gmail connector this
    adapter describes exposes a contacts search, so here it is the ask-the-human fallback.
  - `lookup_channel` -> a DISTRIBUTION LIST is a STRETCH. Email has no channels: a list address is
    opaque, so resolving one proves the address exists, NOT who reads it — a channel's membership
    is inspectable, a list's is not. Treat the result as an address, never as an audience.
  - `always_include` / `default_channel` do NOT transfer cleanly to a medium with to/cc/bcc. This
    adapter's mapping: `{to}` (its `channel_key:`) is ONE primary address string, and
    `{always_include}` renders as Cc — every routed recipient VISIBLE in the header. There is
    deliberately NO bcc mapping: a hidden recipient makes the delivered audience differ from what
    every reader and every reply-all sees, and nothing here may widen an audience invisibly.
    Do not put a comma-joined address list in `{to}` — extra primary recipients belong in
    `{always_include}`, where each address is validated and printed on the /ship plan line.
  - `include_self` (a SEPARATE token, never a substitute): when true, Cc the shipper IN ADDITION
    to `{always_include}` — never instead of a stakeholder.
  A wrong email is the LEAST recoverable delivery: it cannot be unsent and cannot be re-scoped
  after the fact. So: routing comes only from the ticket's DECLARED audience, a routing failure is
  a STOP (never a fallback to another chat target), and the default is a draft a human clicks.
---

# Gmail adapter (email as a `chat` target — not a sixth seam)

Maps the `chat` verb contract to Gmail via the `mcp__{mcp}__*` tools. Same two hard rules as every
chat adapter: (1) default to **draft**, not send — the human clicks send unless they say "send it";
(2) never solo-mail a stakeholder — every message carries `{always_include}` (this target's own
list, rendered as Cc).

Mail goes out **as `{identity}`** (a person or a shared mailbox) — a team decision in committed
config, never derived from whoever happens to be shipping. This adapter declares
`sender_key: identity`, so routing surfaces the sender on the resolved plan line the human
authorizes, refuses to route a named email target with no identity at all, and pins the value in
the `resolution_fingerprint` — a post-approval config edit swapping one mailbox for another
refuses instead of quietly changing who the mail is from.

The ONE sanctioned exception to declaration-only routing is prompt 8's `--chat <target>` override:
an explicit human command (never an inference) that still routes here without a declared audience —
the CLI warns that the routing is not recorded with the ticket, and the /ship plan line says so to
the approver. Nothing else selects this target.

**`{to}` and `{always_include}` are the ROUTED resolution, not config reads** — the routed
destination and recipient list from `bin/delivery_plan.py` (`destination` / `recipients`) that
`/ship` pins. In the **default tool-only shape** the stack sets no `to`: both are authored
per-communication in the ticket's `delivery-plan.yaml` (`chat.channel:` = the address + a non-empty
`chat.recipients:`), asked at `/ship`.

**Under named targets** (`seams.chat.targets:`), every value here belongs to the ROUTED target:
`{to}` is that target's own destination (this adapter declares `channel_key: to`, so routing reads
the right key without any skill knowing this is email) and `{always_include}` is that target's own
list — never another target's, and never a slot-level one. The routed target comes from the
ticket's `delivery-plan.yaml` `audience:` declaration (`bin/delivery_plan.py`); it is never
inferred from prose, an address's domain, or a list's name, and a routing failure never falls back
to another chat target.

## Permission posture (MCP)

### Native control
The connector's **OAuth grant** (Gmail scopes: read-only vs compose vs send) and **which tools the
server exposes**. Gmail drafts are native mailbox objects, so the draft tool (`create_draft`) is
the path that expresses `default_mode: draft` + `chat_default_draft`, and the send tool
(`send_message`) is the thing being gated. An official connector's grant is set at its OAuth
consent; a CLI-configured server in its config file; a homegrown server with its owner (forward
the suggestion).

### Recommended setting (by policy)
Prefer a grant that **excludes send** where the connector offers one (compose-without-send is a
real Gmail scope shape) — then a draft in `{identity}`'s Drafts folder is the strongest thing this
path can produce, and `chat_default_draft` holds by construction. An email cannot be unsent, so
this is the seam where the narrower grant matters most.

### Read-only probe
The read call the auth block already names — it proves reachability and which tools exist:
```
mcp__{mcp}__search_threads(query=<a recent subject>)   # read-only
```
**What it cannot prove, stated plainly:** the connector's grant set is NOT introspectable
read-only from inside the session, so the posture record caps at `status: unverified` and the
draft/send policies remain GUIDANCE on this path. Confirm the actual grant in the connector's own
settings surface (the OAuth consent / server config / its owner) — record the outcome in
gitignored `.claude/config/posture.local.yaml`.

## verb: draft   (the default — policy chat_default_draft, and `default_mode: draft` set explicitly)
```
mcp__{mcp}__create_draft(to=["{to}"], cc=[{always_include} (+ the shipper when include_self)], subject=<[TEST-123] summary>, body=<plain-text body>, htmlBody=<the same body as HTML>)
```
Body rules: `body` is plain text (no Markdown); `htmlBody` carries the linked version:
**hyperlink everything** with `<a href>`: ticket IDs (`https://<site>/browse/TEST-123`), docstore
files, PRs. Honor `word_limits.chat` (<100). Name every routed recipient in the body too
(`--check-draft` reads the draft, not the API call). The draft sits in `{identity}`'s Drafts
folder for a human to open and send. The tool also takes `bcc`; never pass it.

## verb: send    (ONLY on explicit "send it"/"post it" — an email cannot be unsent)
```
mcp__{mcp}__send_message(draftId=<the reviewed draft's id>)       # sends exactly what the human reviewed
mcp__{mcp}__send_message(to=["{to}"], cc=[{always_include} (+ the shipper when include_self)], subject=<[TEST-123] summary>, body=<plain-text body>, htmlBody=<the same body as HTML>)   # no draft exists
```
When a draft was reviewed, send it by id so what goes out is exactly what the human read. The tool
also takes `bcc`; never pass it.

## verb: lookup_user
The Gmail connector exposes no contacts search (its tool list has none, checked 2026-10-25), so
this verb is the manual fallback: **ask the human for the exact address** for the To/Cc lines.
Never infer an address from a name, and never search the mailbox to find one. A different Gmail
server that does offer a contacts search is a different tool: give it its own adapter.

## verb: lookup_channel   (a distribution list — the STRETCH named above)
No contacts search here either (see `lookup_user`): ask the human for the list's exact address,
e.g. team-updates@acme.example. Even a looked-up list proves only that the address exists, not
who reads it. When the audience matters (and for email it always does), confirm the list's
membership with its owner once, outside this kit.

## gotchas
- Tool names and argument shapes differ by agent: Codex CLI lists Gmail as a different connector
  under other names (its section is below). `bin/adapter_surface.py --adapter adapters/chat/gmail.md`
  picks the right section for the agent running now. A name missing from your session's tool list
  is a gap to report so the kit can record it, never a local edit to this file: an edited copy
  silently drifts from the kit on the next upgrade.
- Threading: replies need the prior message's thread id — a fresh draft starts a fresh thread,
  which is usually right for a per-ticket update.
- A Gmail alias or delegated mailbox must be configured server-side; this adapter cannot grant
  send-as rights, only use them.

## Runtime surface: codex-cli

server: codex_apps

Codex CLI reaches Gmail through the ChatGPT Gmail app: every tool sits under the one server
`codex_apps` with a `gmail_` prefix, and it is a different connector from the one the verb
sections above describe, so the argument shapes differ as well: `to` and `cc` are strings, the
body is a MIME `payload`, and there is a `from_address`. Observed 2026-10-24 from the connector's
own tool declarations in a Codex CLI session. The rules of the default sections hold unchanged
here: draft first, `{always_include}` as visible Cc, no bcc mapping, `{to}` is ONE address, and a
routing failure never falls back.

### verb: draft
```
mcp__codex_apps__gmail_create_draft(to="{to}", cc="<{always_include} (+ the shipper when include_self), comma-joined>", from_address="{identity}", subject="<[TEST-123] summary>", payload={"mime_type": "text/html", "body": {"content": <body as HTML>}})
```
Body rules, the same on every runtime: **hyperlink everything** with `<a href>`, honor
`word_limits.chat` (<100), and name every routed recipient in the body (`--check-draft` reads the
draft). `from_address` pins the sender to `{identity}`. If the connector refuses it, STOP and
report; never retry without it, because that sends as whoever the app is signed in as. The tool
also takes `bcc`; never pass it.

### verb: send
ONLY on explicit "send it"/"post it": an email cannot be unsent.
```
mcp__codex_apps__gmail_send_email(to="{to}", cc="<{always_include} (+ the shipper when include_self), comma-joined>", from_address="{identity}", subject="<[TEST-123] summary>", payload={"mime_type": "text/html", "body": {"content": <body as HTML>}})
```
When a draft was reviewed, send exactly that body and recipient list, character for character: the
human approved the draft, not a new message. (The connector also lists a `gmail_send_draft` tool;
its arguments were not captured, so check its declaration in the session before using it.)
`from_address` pins the sender to `{identity}`. If the connector refuses it, STOP and report;
never retry without it, because that sends as whoever the app is signed in as. The tool also takes
`bcc`; never pass it.

### verb: lookup_user
No contacts tool on this connector either (its tool list has none). Manual fallback: ask the human
for the exact address. Never infer one from a name, and never search the mailbox to find one.

### verb: lookup_channel
The same fallback: ask for the list's exact address, and confirm its membership with its owner
(the STRETCH above).

### Permission posture on this runtime
The control is the Gmail app's connection for the signed-in ChatGPT account: which account it is
signed in as, and whether its grant includes send. That grant is NOT introspectable from inside
the session, so the posture record caps at `status: unverified` exactly as above; confirm it where
the app was connected and record the outcome in `.claude/config/posture.local.yaml`.

### Read-only probe
```
mcp__codex_apps__gmail_get_profile({})                                          # read-only: the signed-in account
mcp__codex_apps__gmail_search_emails(query="<a recent subject>", max_results=1)   # read-only
```
Compare the profile's address with `{identity}`: a different account means mail would go out as
someone else unless the connector accepts `from_address`.
