# PROMPT — Docstore without a desktop mount: install guidance + an rclone adapter

STATUS: DRAFT for maintainer review. Not scheduled. Written 2026-08-22 at the close of the
waves-A-I change set (v3.6.0), codex-reviewed 2026-08-22 with findings folded in. This document
is SELF-CONTAINED: the planning document that used to carry the standing constraints
(`docs/PLANNED-CHANGES.md`) is retired, so everything an implementer needs is restated here.

## Why

The shipped `gdrive` docstore adapter is `transport: cli` — a filesystem copy into the Google
Drive for Desktop CloudStorage mount, with `link_for` reading a macOS extended attribute. Two
gaps observed in real use:
1. A user WITHOUT Drive for Desktop installed gets a bare `test -d` failure with no path to
   success. The kit solved this shape once already — the Obsidian treatment (detect and guide,
   never ask; `docs/obsidian.md`) — and the docstore deserves the same.
2. A GOOGLE DRIVE team that will not (or cannot) run a desktop sync agent has no unmounted
   route. Note the scope honestly: SharePoint already has one — `adapters/docstore/sharepoint.md`
   documents Graph upload and link creation with no sync mount — so this gap is Drive-shaped
   plus everything-else-shaped (Dropbox, S3, Box), not universal. Uploading without a mount is
   an ADAPTER problem, not a skill problem: the verb contract (`backup`, `link_for`) doesn't
   care how the bytes travel.

## Deliverable 1 — detect and guide (cheap, ship first)

- `docs/drive-mount.md`, following the `docs/obsidian.md` precedent IN FULL — which means README
  discoverability in BOTH locations the precedent's selftest pins (the topical section AND the
  further-reading list), not just adapter pointers: install Drive for Desktop
  (https://support.google.com/a/users/answer/13022292), find the CloudStorage mount path per OS,
  what the tier-3 `mount_root` key means, and the one-line verify that proves it works. One
  page, two sections — mirror the OneDrive-client guidance for `sharepoint`'s mounted mode in
  the same file.
- Point at it from: the `gdrive` adapter's `auth:` text; the per-person setup flow's
  verification-failure path (a failed mount check names the doc); and the docstore row of the
  setup interview.
- `docs/` DOES NOT SHIP in the wheel — any pointer printed by installed code uses the GitHub
  URL, as the Obsidian and live-verification docs already do.

## Deliverable 2 — `adapters/docstore/rclone.md` (the general unmounted answer)

One adapter file covers Drive, OneDrive, Dropbox, S3, and Box without a desktop mount.

Frontmatter:
- `seam: docstore`, `tool: rclone`, `transport: cli`.
- `requires: [remote_path]` — the TEAM-owned destination path. PATH-ONLY, no remote prefix
  (commands render `"{remote}:{remote_path}/…"`, so a value like `remote:analysis-backups`
  would double the prefix). `requires:` declares config keys; it does not prove the binary
  exists — the runnable read-only `verify:` is what proves CLI, auth, and reachability.
- `destination_key: remote_path` — MANDATORY for a docstore adapter used as a named target (the
  routing contract in `adapters/README.md` § "Resolving the active target" keys on it). Also
  extend the resolver's reserved destination-key protection: it is currently hardcoded to
  `drive_folder` (`bin/effective_config.py`, `RESERVED_SEAM_KEYS` area) — generalize it to
  every adapter-declared `destination_key`, or at minimum add `remote_path`, so no future
  adapter can leave its destination tier-3-overridable.
- `user_keys: [remote]` — the named rclone remote from `~/.config/rclone/rclone.conf`, a
  per-machine credential alias (tier 3), the same split warehouse profiles use. ⛔ AND THE SAME
  HOLE they had to close: a tier-3 alias can silently point at a different cloud account or
  bucket, redirecting deliveries with nothing in review to catch it. Follow the Databricks
  precedent — an EXPECTED-TARGET check: `verify` (and `/ship`'s pre-backup verification) must
  assert the remote's resolved identity matches something team-committed (e.g. `rclone
  about`/`config show` fields compared against a tier-1 `expected_account` or the remote's
  declared backend type + root), and the delivery-plan fingerprint must incorporate the resolved
  destination so a redirect trips `--expect-fingerprint`, not just prose.

Verbs (the docstore contract is EXACTLY two — `bin/selftest.sh` asserts `docstore) echo 2` by
exact equality; do not add a third):
- `backup`: use `rclone copy --dry-run` first, then `rclone copy` — NOT `rclone sync`, which
  DELETES destination files absent from the source; a folder-backup verb must never be able to
  delete remote content that predates it. Define the stale-file policy explicitly (stale prior
  backups under a renamed title are listed and removed by exact path with approval, mirroring
  the gdrive adapter's exact-target `rm` discipline). The external-action approval
  (`hard_halt_before_external_posts`) covers the copy, and the printed plan must show the
  dry-run result before anything moves.
- `link_for`: `rclone link "{remote}:{remote_path}/<file>"` — ⛔ THIS IS A SHARING SIDE EFFECT,
  not an observation: on most backends it CREATES a public link accessible without an account.
  It therefore requires the same visible authorization as the upload itself — surface it in the
  resolved delivery plan (destination + declared `sharing_scope`), never run it implicitly. Per
  backend, state the honest floor in the adapter notes: link support is backend-dependent; where
  a backend cannot mint one (or policy forbids it), the verb returns an explicit
  manual-fallback instruction rather than pretending.
- `verify:` read-only AND aimed at the configured team path, not the remote root:
  `rclone lsd "{remote}:{remote_path}" --max-depth 1` (plus the expected-target identity check
  above).

⛔ METACHARACTER SCOPE, stated precisely (do not overclaim inheritance): the resolver's refusal
covers tier-3 values substituted into `verify` templates, and `delivery_plan.py` checks its own
emitted destination/recipients/sender. NEITHER validates an arbitrary `remote` value on other
paths. So this adapter must route its remote through those existing checks — the verify template
carries `{remote}` (so a poisoned value is refused there), and the delivery-plan fingerprint
carries the resolved destination (so routing sees it too). The test proves BOTH: a
`remote: "x; touch /tmp/PWNED"` fixture is refused at verify AND cannot reach a routed backup.

rclone is an EXTERNAL binary, not a runtime dep of the package (the kit stays stdlib-only;
adapters may require CLIs — that is what `requires:`/`verify:` exist for). The selftest stays
READ-ONLY, OFFLINE, CREDENTIAL-FREE: all rclone tests run against a fixture/mock (a stub `rclone`
on PATH inside the fixture, the way other sections stub CLIs) — never a live remote.

## Setup integration — detection only, per the golden rule

Tool CHOICE stays adapter/config-driven; a skill must not gain an rclone-specific option (the
"new adapter, no skill edits" rule — the only sanctioned skill touchpoint is the CLI DETECTION
probe). So: add `rclone` to the existing Phase-1 detector line. ⚠ THE TRAP, precisely: the two
leak-grep EXEMPTIONS match the literal substring `for c in snow acli gh` and SURVIVE an append —
appending `rclone` to the list does not break them — but a SEPARATE exact-line assertion pins
the detector line VERBATIM (near `bin/selftest.sh:3863`), and THAT must be updated in the same
change. Remotes are enumerated by NAME ONLY (`rclone listremotes`) — never echo `rclone.conf`
contents anywhere: config files a probe opens can hold plaintext secrets, and a pretty-printed
probe result is one paste away from publishing one (the same rule the warehouse profile
enumeration follows).

## Delivery-plan contract (inherit, never fork)
An rclone target used for delivery follows the merged routing contract in full: classification
declared in the ticket's `delivery-plan.yaml`, resolved plan (exact destination + declared
`sharing_scope`, declared-not-inspected) shown before approval, target + fingerprint pinned,
delivery recorded with `--record-delivered`, and `link_for` minted from that recorded target.
`sharing_scope` remains a DECLARATION — rclone widens the blast radius (an S3 bucket can be
public), so restate declared-not-inspected in the adapter rather than implying the kit checks
ACLs.

## Selftest-trap accounting (same commit)
- +1 adapter moves the derived count: `docs/architecture.md`'s `**<N> adapters**` and
  `ROADMAP.md`'s `- <N> adapters across <M> seams` (ROADMAP is the asserted copy), and rclone
  listed in `adapters/README.md` § "Adapters shipped".
- New hand-numbered selftest section (read the highest ON CURRENT MAIN first): frontmatter valid
  incl. `destination_key`; both verbs present; the poisoned-remote fixture refused at verify AND
  unroutable; the expected-target check fires on a mismatched stub identity; the copy-not-sync
  discipline pinned (the verb text carries `rclone copy`, and a `sync` mutation turns the pin
  red); `docs/drive-mount.md` linked from all five sites (two README + three others); counts
  reconciled.
- Existing `stack.yaml` files in the wild keep working; all shipped examples still verify.
- Fixture identifiers only, files AND commit messages. No version bump. Stdlib only; any new CLI
  takes `--root`, no Claude env vars. Conventional-commit title; CHANGELOG entry (user-facing).
  Editing any `.claude/skills/*` file regenerates emitted fixtures per `tests/emit/README.md` in
  the same commit.

## Gates (non-optional, the house pattern)
codex twice, verdicts verbatim in the PR body — on the PLAN before coding and on the DIFF before
the PR (`codex exec --skip-git-repo-check -C . "…cite file:line…"`; maintainer note: codex runs
15+ minutes in this repo — background it with stdin closed and collect from the output file).
Verify its findings against source. The diff review must specifically answer: does any path echo
credential-file contents; can a tier-3 `remote` redirect a delivery past the fingerprint; can
`backup` ever delete pre-existing remote content; and is `link_for`'s sharing side effect always
surfaced before it runs?

## Evidence-of-done
- A repo with no mount and a stubbed rclone remote passes `verify_stack.sh`, `backup` lands the
  ticket folder (copy semantics proven — pre-existing remote files in the fixture survive), and
  `link_for` returns a URL or the explicit manual fallback.
- A missing-mount `gdrive` failure names `docs/drive-mount.md`'s GitHub URL.
- The redirect and poisoned-remote fixtures are refused. Selftest `0 failed`, exit code checked;
  all count literals agree.
