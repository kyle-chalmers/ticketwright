---
seam: docstore
tool: gdrive
transport: cli         # filesystem copy into the mounted Google Drive (CloudStorage)
requires: [base_path]  # stack.yaml seams.docstore.base_path
auth: |
  Google Drive for Desktop must be mounted at the CloudStorage path.
  Verify: `test -d "{base_path}"`.
---

# Google Drive adapter

Maps the `docstore` verb contract to a mounted Google Drive shared drive. Backups are plain
filesystem copies; shareable links come from the file's macOS extended attribute.

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID** — saved memory).
```bash
rm -rf "{base_path}/<TICKET-ID>"*                      # clean, avoid duplicates
cp -r "<local ticket dir>" "{base_path}/<TICKET-ID> <Full Ticket Title>"
ls -la "{base_path}/<TICKET-ID> <Full Ticket Title>"   # verify
```
Requires explicit approval (external side effect) — policy `hard_halt_before_external_posts`.
Note: clean `rm`+`cp` mints **new** Drive item-ids, so any previously shared links go stale — repost.

## verb: link_for
**In:** a backed-up file path. **Out:** a shareable Drive URL (for tracker/chat smart links).
```bash
xattr -l "<gdrive file path>" | grep item-id          # NOT xattr -p (zsh eats the #S suffix)
# → build: https://drive.google.com/file/d/<ITEM_ID>
```
Item-id is blank for a few minutes after an in-place copy — wait, or use the clean rm+cp path.

## gotchas
- Stakeholder CSV *inputs/provenance* are committed to git; large *exports* go here, linked from Drive — never committed.
- Jira/Slack must link the **specific Drive file**, never a PR or folder link (saved memory).
