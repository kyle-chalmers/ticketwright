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
filesystem copies; shareable links come from the file's macOS extended attribute; folder listing
reads directory entries only.

**Under named targets** (`seams.docstore.targets:`), `{base_path}` is the ROUTED target's own
destination, chosen from the ticket `delivery-plan.yaml`'s `classification:` declaration
(`bin/delivery_plan.py`) — never inferred from a folder name. `backup` records the target it used,
and `link_for` is called against **that same target**, so a link can never be minted from a
different store than the copy. The target's `sharing_scope:` is a DECLARATION: this adapter verifies
that the mount exists (`test -d`) and never inspects the folder's real sharing ACL, so a correctly
routed file is not evidence that the destination's permissions match the declared scope.

## verb: list_folders
**In:** a parent folder inside the mount (empty for the top of the drive). **Out:** folder names,
one per line, never a file name. Read-only, and still asked first: it looks inside someone's drive.
```bash
parent="{mount_root}/<folder the person picked, or nothing for the top>"
find "$parent" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | sed 's|.*/||' | LC_ALL=C sort
```
Never list a drive with a plain `ls`: it prints file names too, and a file name can say more about
someone's work than they agreed to show. Setup's folder question calls this verb and nothing else.

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID** — recommended convention), and the
routed `destination` from `bin/delivery_plan.py`. With per-person folders on (the default) that is
`{base_path}/<person folder>`, the shipper's own folder inside the team's; with `per_person: false`
it is `{base_path}` itself. Never rebuild it by hand: the routed value is the one the person approved.
```bash
dest="{destination}/<TICKET-ID> <Full Ticket Title>"
rm -rf "$dest"                       # remove ONLY this exact destination (never a wildcard like <ID>*)
mkdir -p "$dest"
rsync -r --exclude '/comms/' "<local ticket dir>/" "$dest/"   # unsent drafts stay local
ls -la "$dest"                       # verify; no comms/ folder
```
Requires explicit approval (external side effect) — policy `hard_halt_before_external_posts`.

**The person folder on a first backup.** `mkdir -p "$dest"` creates `{destination}` too when this is
the person's first backup, and nothing else is created. Routing reports that ahead of time
(`person_folder_new: true`), so the approved plan already said so; say it again in the output, in
the words `/ship` gives. The person folder is never removed, emptied or renamed: `rm -rf` only ever
names the one exact ticket folder in `$dest`.

**`comms/` stays out of the backup.** It holds `/ship`'s unsent tracker and chat drafts, which are
gitignored so unsent wording never leaves the machine; a folder copy would carry them to a shared
drive all the same. `rsync` skips the folder before anything reaches the synced mount, so the sync
client never sees it. With no `rsync` on the machine (Git Bash on Windows), use
`cp -r "<local ticket dir>" "$dest" && rm -rf "$dest/comms"` and say plainly that the sync client
may upload the drafts for the moment before the delete.
**Never** `rm -rf "<ID>"*` — a prefix glob also matches `<ID>0`, `<ID>1234`, etc. If a prior backup
used a different title, `ls "{destination}"` and remove that one exact path by name. A backup made
before per-person folders sits in `{base_path}` itself and stays there: leave it unless the person
asks, and then remove only that one exact path.
Note: clean `rm`+`cp` mints **new** Drive item-ids, so any previously shared links go stale — repost.

## verb: link_for
**In:** a backed-up file path, inside `$dest` from `backup` (so under the person folder when that is on). **Out:** a shareable Drive URL (for tracker/chat smart links).
```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" gdrive_item_id.py "<gdrive file path>" --timeout 300
# → prints https://drive.google.com/file/d/<ITEM_ID> (a folder gets drive/folders/<ITEM_ID>)
```
The item-id is blank for a few minutes after a copy; the helper polls `xattr -l` (never
`xattr -p`, whose `#S` suffix zsh eats) until it appears. Exit 1 means it timed out: say the link
is not ready yet and leave a placeholder, never a guessed URL. Exit 2 means no such path, or not a
Mac with Drive for desktop.

## gotchas
- Deliverables (incl. export CSVs) commit with the ticket by default — this docstore is for durable external sharing / smart links. Keep PII exports out of git via a `*.private.csv` name or a `final_deliverables/**/private/` subfolder, and back those up here instead.
- Jira/Slack must link the **specific Drive file**, never a PR or folder link (recommended convention).
