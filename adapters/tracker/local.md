---
seam: tracker
tool: local
transport: cli         # the filesystem — no API, no auth, no network
requires: []           # reads `project.*` only (ticket_path, ticket_subdirs, terminal_status)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  None. Verify with `test -w .` (add that as `seams.tracker.verify` in stack.yaml) — a writable
  working tree is the only precondition. Do NOT use `test -d tickets`: it fails in a brand-new
  repo, which is precisely when `create_ticket` is supposed to create that directory.
note: |
  For work that has no ticket in any tracker — self-defined analysis, a personal or team notebook
  repo. The ticket folder IS the ticket: its `README.md` holds what a tracker would otherwise store.
  Pair with `project.id_mode: slug` so the folder name is the id, and `ticket_url_template: null`
  so the index renders no external link. Every skill keeps calling the same tracker verbs, so
  nothing else in the kit changes.
---

# Local (filesystem) tracker adapter

Maps the `tracker` verb contract onto the ticket folder itself. There is no external system, so
"the ticket" is `{ticket_path}/README.md` — rendered from `templates/ticket-README.md.tmpl` like any
other ticket, and read back by these verbs.

Paths below are the rendered `project.ticket_path` (e.g. `tickets/{assignee}/{id}`). `<id>` is the
folder name in `id_mode: slug`.

## verb: fetch_ticket
**In:** id (the folder name). **Out:** title, description, status, type, epic, assignee.
```bash
cat "<ticket-dir>/README.md"
```
Read the fields out of the rendered template rather than guessing:

| Field | Where it lives |
|---|---|
| title | the `# <id>: <title>` H1 (the `<id>:` prefix is stripped by the index) |
| description | the `## Business Context` section |
| status / type / epic / assignee | the `- **Status:**` / `- **Type:**` / … bullets under `## Ticket Information` |
| links | markdown links in the body — there is no separate link field |
| attachments | the files already in `<ticket-dir>/source_materials/` (`ls`) |

A missing folder means the ticket does not exist yet — that is the signal to `create_ticket`, not
an error to report. A folder with no `README.md` is a scaffolded-but-unbriefed ticket.

## verb: create_ticket
There is no remote to create, so this establishes *intent* locally — which is the one thing a
tracker normally supplies and a bare folder does not.

**The id is not allocated for you.** Derive a slug from the summary (lowercase, spaces → `-`, drop
anything `SLUG_ID` rejects: uppercase, dots, spaces), confirm it with the user, and check it is free
under `tickets/<owner>/` before creating — an existing folder means that ticket already exists, so
resume it rather than overwrite it.
```bash
mkdir -p "<ticket-dir>"                                    # then, per project.ticket_subdirs:
for d in {ticket_subdirs}; do mkdir -p "<ticket-dir>/$d"; done
bash bin/render.sh templates/ticket-README.md.tmpl --vars <vars.env> > "<ticket-dir>/README.md"
```
**Interview the user for the brief before rendering** — what the work is, what "done" looks like,
and any known constraints — and write it into `## Business Context`. Skipping this is the failure
mode of a trackerless repo: a folder with a name and no statement of intent, which nothing
downstream can recover. Set `- **Status:**` to the project's initial state and leave `- **Link:**`
empty (there is nothing to link to).

**⚠ Never render over a README that already has content.** With a remote tracker, "create the
ticket" and "scaffold the folder" touch different artifacts, so `/ticket` does both — it creates via
this verb, then renders `ticket-README.md.tmpl` into the ticket dir during scaffolding. Here they are
the *same file*, and that second render is a plain redirect: it will replace an interviewed brief
with an unresolved `{{description}}` token. So:

```bash
[ -s "<ticket-dir>/README.md" ] || bash bin/render.sh templates/ticket-README.md.tmpl \
  --vars <vars.env> > "<ticket-dir>/README.md"
```

Render only when the file is absent or empty; otherwise treat the ticket as already created and let
`fetch_ticket` supply its fields. If a render is genuinely wanted over existing content, feed the
vars from `fetch_ticket` first so nothing is lost.

**Returns:** the id (the folder name) and the folder path in place of a URL.

## verb: transition
```bash
python3 - "$dir/README.md" "<new-status>" <<'PY'
import pathlib, re, sys
p, status = pathlib.Path(sys.argv[1]), sys.argv[2]
t = p.read_text()
# A replacement FUNCTION, not an f-string: a status is user input, and in a replacement *string*
# `\1` or `\g<1>` would expand and `\q` would raise. `count=0` so a duplicated bullet can't be left
# disagreeing with itself. No write unless something changed, so this never touches mtime for nothing.
new, n = re.subn(r"(?m)^(- \*\*Status:\*\*).*$", lambda m: f"{m.group(1)} {status}", t)
if n:
    p.write_text(new)
print(f"updated {n} Status bullet(s)" if n else "no Status bullet found")
PY
```
Map `project.terminal_status` to whatever word this project uses for done.

**Know which status the catalog actually reads.** `tickets/INDEX.md` does *not* read this bullet:
it takes a curated status from `tickets/index_data.json` if present, else a leading **status emoji on
the folder name**, else `Unknown`. So:

- the README bullet is the human-readable record, and what `fetch_ticket` returns;
- `☑️ ` / `🛠️ ` prefixed on the folder name is what an *uncurated* index renders;
- `/ship`'s enrich step writes `index_data.json`, which wins over both.

Renaming the folder to add an emoji is a real directory rename — it changes paths and the id the
index derives. **Ask first**, and prefer letting enrich set the status.

## verb: comment
Append a dated entry under a `## Log` heading, creating the heading the first time:
```bash
python3 - "$dir/README.md" "$(date +%F)" "<body>" <<'PY'
import pathlib, re, sys
p, day, body = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
t = p.read_text().rstrip("\n")
# Anchor the heading test to a line start, and ignore fenced blocks — a `## Log` written inside a
# code sample is documentation, not this ticket's log, and matching it would append the entry into
# unrelated content. Substring matching also missed a README that *opens* with `## Log`.
scan = re.sub(r"(?ms)^([ \t]*)(`{3,}|~{3,}).*?(?:^[ \t]*\2[ \t]*$|\Z)", "", t)
if not re.search(r"(?m)^##+ Log\s*$", scan):
    t += "\n\n## Log"
p.write_text(f"{t}\n\n**{day}** — {body}\n")
PY
```
Entries append at end of file, so keep `## Log` as the **last** section of the README — otherwise a
new entry lands after whatever follows it.
Honor `word_limits.tracker_comment` so the log stays scannable. Unlike a real tracker there is no
audience but the repo, so nothing is published — but this is still the ticket's durable history, so
write it for someone reading months later.

## verb: search
```bash
grep -i "<query>" tickets/INDEX.md                          # the catalog: id, title, summary, status
grep -ril "<query>" tickets/*/*/README.md                   # fall back to full text when the
                                                            # catalog has no summary yet
```
**In:** query, limit. **Out:** `{id, summary, status}` per hit — take them from the matched
`INDEX.md` row (which already carries all three) rather than returning raw grep lines, and cap the
results at the caller's limit (`| head -<n>`).

`tickets/INDEX.md` is generated by `bin/build_ticket_index.py`, so it is only as fresh as the last
render — re-run it (or rely on the PostToolUse hook) before trusting a negative result. For ranked
prior-art search, `bin/recall.py` is better than either grep.

## verb: download_attachments
Nothing to download: there is no remote holding files. Report that plainly and point the human at
`<ticket-dir>/source_materials/` to drop files in by hand — a silent no-op would read as "there were
no attachments", which is a different claim.

## verb: rank_projects_by_activity
**Unsupported — there is no account container to rank.** The ticket folder *is* the tracker, so
there are no sibling projects, teams, or boards to compare and nothing an activity scan could
choose between. Return `unsupported` with that reason; the caller skips the ranking silently and
asks as it would have anyway.

This is a different claim from `unavailable`, which means a rankable tracker refused the scan (auth,
permissions, plan tier) and is worth a line to the human. Nothing is broken here, so nothing is
reported.

In practice the verb is also unreachable: choosing *no tracker* selects this adapter, which pairs
with `id_mode: slug` — the folder name is the id, so there is no key prefix for a ranking to
pre-fill. Documented for contract coverage, not for use.

## gotchas
- **No ids are allocated for you.** The folder name is the id, so it must be unique per owner and
  stable — renaming it renames the ticket everywhere. Use `id_mode: slug`, which also constrains the
  name to something safe as a git branch and a filename.
- **Set `ticket_url_template: null`.** With no external system there is nothing to link to, and the
  index correctly renders no `↗` when the template is absent.
- **Nothing is ever published.** `/ship`'s `hard_halt_before_external_posts` still applies to chat
  and docstore, but tracker writes here are local file edits — so review them like code, in the diff,
  rather than expecting an approval prompt before a post.
- **Two folders can reduce to one id** (`signup-lift` and `☑️ signup-lift`). The index warns on stderr
  and keeps the later one; don't keep both.
