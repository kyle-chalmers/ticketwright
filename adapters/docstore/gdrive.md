---
seam: docstore
tool: gdrive
transport: cli         # filesystem copy into the mounted Google Drive (CloudStorage)
requires: [drive_folder]  # stack.yaml seams.docstore.drive_folder (+ tier-3 mount_root)
destination_key: drive_folder   # the TEAM-owned destination key routing compares targets on (mount_root is machine-local)
user_keys: [mount_root]   # tier-3 overridable: the local CloudStorage mount prefix. `drive_folder` (which destination) is a team decision
auth: |
  Google Drive for Desktop must be mounted at the CloudStorage path.
  Verify: `test -d "{base_path}"`.
  Not installed, or no mount available (e.g. Linux)? Install steps per OS, the `mount_root` tier
  split, and the mountless `rclone` alternative: <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>.
---

# Google Drive adapter

Maps the `docstore` verb contract to a mounted Google Drive shared drive. Backups are plain
filesystem copies; shareable links come from the file's macOS extended attribute.

**Under named targets** (`seams.docstore.targets:`), `{base_path}` is the ROUTED target's own
destination, chosen from the ticket `delivery-plan.yaml`'s `classification:` declaration
(`bin/delivery_plan.py`) — never inferred from a folder name. `backup` records the target it used,
and `link_for` is called against **that same target**, so a link can never be minted from a
different store than the copy. The target's `sharing_scope:` is a DECLARATION: this adapter verifies
that the mount exists (`test -d`) and never inspects the folder's real sharing ACL, so a correctly
routed file is not evidence that the destination's permissions match the declared scope.

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID** — recommended convention).
```bash
dest="{base_path}/<TICKET-ID> <Full Ticket Title>"
rm -rf "$dest"                       # remove ONLY this exact destination (never a wildcard like <ID>*)
cp -r "<local ticket dir>" "$dest"
ls -la "$dest"                       # verify
```
Requires explicit approval (external side effect) — policy `hard_halt_before_external_posts`.
**Never** `rm -rf "<ID>"*` — a prefix glob also matches `<ID>0`, `<ID>1234`, etc. If a prior backup
used a different title, `ls "{base_path}"` and remove that one exact path by name.
Note: clean `rm`+`cp` mints **new** Drive item-ids, so any previously shared links go stale — repost.

## verb: link_for
**In:** a backed-up file path. **Out:** a shareable Drive URL (for tracker/chat smart links).
```bash
xattr -l "<gdrive file path>" | grep item-id          # NOT xattr -p (zsh eats the #S suffix)
# → build: https://drive.google.com/file/d/<ITEM_ID>
```
Item-id is blank for a few minutes after an in-place copy — wait, or use the clean rm+cp path.

## gotchas
- Deliverables (incl. export CSVs) commit with the ticket by default — this docstore is for durable external sharing / smart links. Keep PII exports out of git via a `*.private.csv` name or a `final_deliverables/**/private/` subfolder, and back those up here instead.
- Jira/Slack must link the **specific Drive file**, never a PR or folder link (recommended convention).
