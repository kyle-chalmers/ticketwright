---
seam: docstore
tool: rclone
transport: cli         # rclone CLI upload — no desktop sync agent anywhere in the path
requires: [remote_path, target_sentinel]  # stack.yaml seams.docstore.{remote_path, target_sentinel} (+ tier-3 remote)
destination_key: remote_path   # the TEAM-owned destination key routing compares targets on (`remote` is machine-local)
user_keys: [remote]   # tier-3 overridable: the rclone remote NAME on this machine. `remote_path` (which destination) is a team decision
auth: |
  rclone installed and the named remote configured (`rclone config`). No mount, no sync agent.
  Verify: `test "$(rclone cat "{base_path}/.ticketwright-target")" = "{target_sentinel}"`.
  Want the mounted Drive/OneDrive route instead? See
  <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>.
---

# rclone adapter (docstore without a mount)

Maps the `docstore` verb contract to any rclone remote — Drive, OneDrive, Dropbox, S3, Box — with no
desktop sync agent involved. The team owns which destination (`remote_path`, tier 1); each person
owns only the local alias for the account that reaches it (`remote`, tier 3). `remote_path` is
**path-only, never prefixed with a remote name** — a value like `remote:analysis-backups` would
double the prefix.

**Every command below interpolates `{base_path}`, never `{remote}:{remote_path}` by hand.** The
resolver composes `{base_path}` = `{remote}:{remote_path}` (`bin/effective_config.py`), exactly as it
composes `{mount_root}/{drive_folder}` for the mounted adapters. That indirection is load-bearing,
not cosmetic: `{base_path}` is the value delivery routing prints, fingerprints and metachar-checks,
so writing the two halves out separately here would let what EXECUTES drift from what a human
approved — and a personal alias re-pointed after approval would then redirect a delivery without
moving the `resolution_fingerprint`.

**Under named targets** (`seams.docstore.targets:`), the destination is the ROUTED target's own,
chosen from the ticket `delivery-plan.yaml`'s `classification:` declaration (`bin/delivery_plan.py`)
— never inferred from a folder name. `backup` records the target it used, and `link_for` is called
against **that same target**, so a link can never be minted from a different store than the copy.

The target's `sharing_scope:` is a DECLARATION. This adapter proves the destination is the team's
(the sentinel check below) and never inspects a bucket policy, an ACL, or a sharing setting — so a
correctly routed file is not evidence that its permissions match the declared scope. rclone widens
the blast radius relative to a mounted drive: an S3 bucket can be world-readable and `rclone link`
mints accountless URLs, and neither fact is visible to the kit.

## Per-person setup notes (consumed by the onboarding flow; not verbs)
- **Enumerate remotes by NAME only.** `rclone listremotes` prints names and nothing else. ⛔ **Never
  `rclone config show` / `rclone config dump`** — `show`'s own help reads "Print (decrypted) config
  file" and `dump` prints the whole config as JSON, so either is exactly the
  credential echo to avoid; `rclone listremotes --json` likewise "always includes all attributes -
  including the source", and `rclone config redacted` warns that "the redaction may not be perfect".
  To read one remote's backend type safely: `rclone listremotes --long --name <remote> --exact`
  — it emits name, type and description, none of which are credential attributes (the description
  is free text someone set, so treat it as content, not as a guaranteed-blank field). Never `cat ~/.config/rclone/rclone.conf`, and never paste
  its contents anywhere: it can hold plaintext tokens and access keys.
- **Expected-target evidence.** A remote name is a per-machine alias, so it can point at a different
  account or bucket than the team's with nothing in review to catch it. Reachability is not identity:
  `rclone about` only prints quota (and is not even supported on every backend — S3 has no
  `About`), and `rclone lsd "{base_path}"` can succeed against a *different* account that
  happens to hold the same path — on an object store, listing an absent prefix returns empty and
  exits 0 rather than failing. So the proof is a **team-pinned sentinel**, checked by exact contents:
  ```bash
  test "$(rclone cat "{base_path}/.ticketwright-target")" = "{target_sentinel}"
  ```
  One-time team step: write `.ticketwright-target` containing `{target_sentinel}` at `remote_path`.
  `rclone cat` works on every backend, is read-only, and a redirected remote lands somewhere the file
  is absent or holds a different token — a real failure, not a hoped-for one. Say the comparison out
  loud during setup: "your remote reaches the team's configured destination" — or name the mismatch.

## verb: backup
**In:** local ticket dir, dest name (**always full title, not just the ID** — recommended convention).
```bash
dest="{base_path}/<TICKET-ID> <Full Ticket Title>"
rclone copy --dry-run "<local ticket dir>" "$dest"   # SHOW this output before anything moves
rclone copy           "<local ticket dir>" "$dest"
rclone lsl "$dest"                                   # verify
```
Requires explicit approval (external side effect) — policy `hard_halt_before_external_posts`. The
dry-run result is part of the plan the human authorizes, not a step to run afterwards.

`rclone copy` is also inside the `source_material_guard` policy's jurisdiction, exactly like the
mounted adapters' `cp -r`: a folder-wide backup carries everything in the ticket directory, so when
raw source material (a full meeting transcript) is sitting in `source_materials/`, the guard asks
before the upload. `.gitignore` has no bearing on a copy, so moving such a file to
`source_materials/private/` protects git and does **not** protect this path.

**Never `rclone sync`.** Per rclone's own docs, `copy` "Doesn't delete files from the destination",
whereas `sync` deletes destination files absent from the source to make it match. A folder-backup
verb must not be able to delete remote content that predates it, so `copy` is the only form here.

**`copy` is non-deleting, not non-destructive** — state this plainly rather than implying more safety
than exists. It overwrites a same-name file whose size or modification time differs. That is the
intended policy: re-running a backup after editing a deliverable **should** update it. What must
never happen is losing destination-only content, and `copy` cannot do that.

Note `copy` transfers the **contents** of the source directory, not the directory itself — which is
why `dest` names the ticket folder explicitly.

**Stale prior backups.** If an earlier backup used a different title, list with
`rclone lsd "{base_path}"` and remove **that one exact path**. Never a prefix glob — it
would also match `<ID>0`, `<ID>1234`. `rclone purge` is recursive and, per its docs, "does not obey
include/exclude filters - everything will be removed", so it gets its **own** `--dry-run` and its own
approval, separate from the backup's.

## verb: link_for
**In:** a backed-up file path. **Out:** a shareable URL (for tracker/chat smart links).

⛔ **READ BEFORE RUNNING — this is a sharing side effect, not an observation.** rclone documents
`link` as "Create, retrieve or remove a **public** link", and: "the link will always by default be
created with the least constraints - e.g. no expiry, no password protection, accessible without
account." Minting one therefore needs the same visible authorization as the upload itself: the
resolved delivery plan must already show this destination and its declared `sharing_scope`, and a
human must have approved THAT plan. Never run it implicitly, never to "check whether a link
exists" — there is no read-only form of this command.

`--expire` and `--unlink` exist, but rclone documents both as flags "not all backends support", so
neither may be offered as a guaranteed mitigation for a link that is already public.

```bash
rclone link "{base_path}/<TICKET-ID> <Full Ticket Title>/<file>"
```

Link support is backend-dependent. Where the backend cannot mint one, or org policy forbids public
links, this verb returns an explicit manual fallback — "open the destination in <backend>'s console
and share it to the audience the plan declared" — and never a fabricated or guessed URL.

## gotchas
- Deliverables (incl. export CSVs) commit with the ticket by default — this docstore is for durable external sharing / smart links. Keep PII exports out of git via a `*.private.csv` name or a `final_deliverables/**/private/` subfolder, and back those up here instead.
- Tracker/chat must link the **specific file**, never a folder link (recommended convention).
- A tier-3 `remote` is part of the resolved destination, so changing it after an approval moves the delivery plan's `resolution_fingerprint` and the delivery refuses rather than silently redirecting.
