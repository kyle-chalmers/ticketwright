# Backing up to a cloud drive (mount or no mount)

Ticketwright's `docstore` tool slot copies a finished ticket folder somewhere durable and returns a
shareable link. Two shipped adapters do that through a **desktop sync mount** — `gdrive` writes into
Google Drive for Desktop's CloudStorage folder, `sharepoint` into the OneDrive sync folder — and this
page is how you get that mount working.

Nothing here is required. If you cannot install a sync agent, do not want one, or run Linux (where
Google ships no Drive for Desktop client at all), use the [rclone
adapter](../adapters/docstore/rclone.md) instead: same two verbs, no mount, nothing to install but a
single binary. `/setup` never asks which one you want — it reads the adapter your `stack.yaml` names.

## Google Drive for Desktop

Install it from <https://support.google.com/a/users/answer/13022292>, sign in, and let the first sync
finish. Then find the mount root — the prefix your shared drive lives under:

| OS | Mount root |
|---|---|
| **macOS** | `~/Library/CloudStorage/GoogleDrive-<your-email>/` — shared drives are under `Shared drives/`, personal files under `My Drive/` |
| **Windows** | a drive letter, `G:\` by default (changeable in Drive settings), or `%USERPROFILE%\My Drive` |
| **Linux** | not available — Google ships no client. Use the rclone adapter above. |

## The OneDrive client (for `sharepoint`)

Same shape for the mounted mode of the `sharepoint` adapter. Install the OneDrive client, sign in
with the work account, and open the SharePoint library once with **Sync** so it appears locally:

| OS | Mount root |
|---|---|
| **macOS** | `~/Library/CloudStorage/OneDrive-<Organization>/` |
| **Windows** | `%USERPROFILE%\OneDrive - <Organization>` |

The `sharepoint` adapter also documents a Microsoft Graph upload path, which needs no mount at all.

## What `mount_root` is, and where it goes

The destination splits across two config tiers, and mixing them is the mistake this page exists to
prevent:

- **Which destination** — `drive_folder` (e.g. `Shared drives/Tickets`) is a **team** decision. It
  goes in `.claude/config/stack.yaml`, committed.
- **Where it is mounted on your machine** — `mount_root` is **yours**, and differs per person and per
  OS. It goes in `.claude/config/connections.local.yaml`, which is gitignored.

The resolver composes `{base_path}` from the two, so adapter commands interpolate `{base_path}` and
never care whose laptop they are on. Writing your `mount_root` into `stack.yaml` commits your home
directory to a shared repo and breaks the slot for everyone else.

## Verify it in one line

```bash
bash bin/verify_stack.sh .claude/config/stack.yaml --dry-run
```

The docstore row runs `test -d "{base_path}"`. A `✗ UNREACHABLE` there means the mount is missing or
`mount_root` is wrong — re-read the table above, or switch to the rclone adapter. Details on the
tiers live in [stack.schema.md](../.claude/config/stack.schema.md).
