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

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID**).
```bash
# Synced transport:
dest="{base_path}/<TICKET-ID> <Full Ticket Title>"
rm -rf "$dest"                       # remove ONLY this exact destination (never a wildcard like <ID>*)
cp -r "<local ticket dir>" "$dest"
ls -la "$dest"                       # verify

# Graph transport (per file):
#   PUT https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/<path>/<file>:/content
```
External side effect ⇒ policy `hard_halt_before_external_posts` (approval first).

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
