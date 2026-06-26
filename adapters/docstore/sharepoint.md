---
seam: docstore
tool: sharepoint
transport: cli         # OneDrive/SharePoint sync folder (filesystem), or MS Graph API
requires: [base_path]  # stack.yaml seams.docstore.{base_path, drive_id?}
auth: |
  OneDrive/SharePoint sync mounted at base_path, OR a Graph API token (Files.ReadWrite.All).
  Verify (synced): `test -d "{base_path}"`.
---

# SharePoint / OneDrive adapter

Maps the `docstore` verb contract to SharePoint/OneDrive. Two transports: the **synced folder**
(simplest — treat like a local path) or the **Graph API** (when nothing is mounted).

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID**).
```bash
# Synced transport:
rm -rf "{base_path}/<TICKET-ID>"*
cp -r "<local ticket dir>" "{base_path}/<TICKET-ID> <Full Ticket Title>"
ls -la "{base_path}/<TICKET-ID> <Full Ticket Title>"      # verify

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
- Large *exports* live here and are linked; committed git holds only inputs/provenance.
