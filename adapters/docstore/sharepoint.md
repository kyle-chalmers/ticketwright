---
seam: docstore
tool: sharepoint
transport: cli         # OneDrive/SharePoint sync folder (filesystem), or MS Graph API
requires: [drive_folder]  # stack.yaml seams.docstore.{drive_folder, drive_id?} (+ tier-3 mount_root)
destination_key: drive_folder   # the TEAM-owned destination key routing compares targets on (mount_root is machine-local)
user_keys: [mount_root]   # tier-3 overridable: the local sync-folder prefix. `drive_folder` (which destination) is a team decision
auth: |
  OneDrive/SharePoint sync mounted at base_path, OR a Graph API token (Files.ReadWrite.All).
  Verify (synced): `test -d "{base_path}"`.
  OneDrive client not installed, or no mount available? Install steps per OS and the `mount_root`
  tier split: <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>.
---

# SharePoint / OneDrive adapter

Maps the `docstore` verb contract to SharePoint/OneDrive. Two transports: the **synced folder**
(simplest — treat like a local path) or the **Graph API** (when nothing is mounted).

**Under named targets** (`seams.docstore.targets:`), `{base_path}` is the ROUTED target's own
destination, chosen from the ticket `delivery-plan.yaml`'s `classification:` declaration
(`bin/delivery_plan.py`) — never inferred from a folder name. `backup` records the target it used
and `link_for` runs against **that same target**, so a shareable link can never come from a
different store than the copy. `sharing_scope:` is a DECLARATION: this adapter checks that the sync
folder exists, never the library's real permissions.

## verb: list_folders
**In:** a parent folder (empty for the top of the library). **Out:** folder names, one per line,
never a file name. Read-only, and still asked first: it looks inside someone's drive.
```bash
# Synced transport:
parent="{mount_root}/<folder the person picked, or nothing for the top>"
find "$parent" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | sed 's|.*/||' | LC_ALL=C sort

# Graph transport: GET /drives/{drive_id}/root:/<path>:/children?$select=name,folder
#   keep ONLY items that carry a `folder` facet; print their `name`, drop every other item unread.
```
Never list a library with a plain `ls`: it prints file names too. Setup's folder question calls this
verb and nothing else.

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID**).
```bash
# Synced transport:
dest="{base_path}/<TICKET-ID> <Full Ticket Title>"
rm -rf "$dest"                       # remove ONLY this exact destination (never a wildcard like <ID>*)
mkdir -p "$dest"
rsync -r --exclude '/comms/' "<local ticket dir>/" "$dest/"   # unsent drafts stay local
ls -la "$dest"                       # verify; no comms/ folder

# Graph transport (per file):
#   PUT https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/<path>/<file>:/content
```
External side effect ⇒ policy `hard_halt_before_external_posts` (approval first). The Graph
transport uploads per file: skip every path under `comms/`.

**`comms/` stays out of the backup.** It holds `/ship`'s unsent tracker and chat drafts, which are
gitignored so unsent wording never leaves the machine; a folder copy would carry them to a shared
drive all the same. `rsync` skips the folder before anything reaches the synced mount, so the sync
client never sees it. With no `rsync` on the machine (Git Bash on Windows), use
`cp -r "<local ticket dir>" "$dest" && rm -rf "$dest/comms"` and say plainly that the sync client
may upload the drafts for the moment before the delete.

## verb: link_for
**In:** a backed-up file. **Out:** a shareable URL for tracker/chat smart links.
```
# Synced: derive the web URL from the SharePoint library's sync-path → URL mapping.
# Graph:  POST /drives/{drive_id}/items/{item-id}/createLink  { "type": "view", "scope": "organization" }
#         → response.link.webUrl
```

## gotchas
- Sync can lag — confirm the file appears in the library before generating a link.
- Org sharing policy may force "people in your org only"; pick the `scope` your stakeholders can open.
- Deliverables commit with the ticket by default — use this docstore for durable external sharing / smart links; PII exports opt out of git (`*.private.csv` or a `final_deliverables/**/private/` subfolder) and get backed up here instead.
