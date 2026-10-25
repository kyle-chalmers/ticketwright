# Publishing to PyPI

Ticketwright publishes to PyPI via **GitHub Trusted Publishing** (OIDC — no API tokens stored
anywhere). The workflow is [`.github/workflows/publish.yml`](../../.github/workflows/publish.yml): it
fires on a `v*` tag, builds the sdist + wheel with `uv`, checks the tag matches the package version,
and uploads via `pypa/gh-action-pypi-publish`.

## Part A — one-time PyPI setup (~3 min, manual)

1. **Account:** log in at [pypi.org](https://pypi.org) with your **personal** account (the one that
   owns `jobwright` / `streamsnow`).
2. **2FA:** already enabled on that account (PyPI blocks publishing without it).
3. **Add the pending Trusted Publisher:** go to
   [pypi.org/manage/account/publishing](https://pypi.org/manage/account/publishing) → *"Add a new
   pending publisher"* → **GitHub** tab → enter exactly:

   | Field | Value |
   |---|---|
   | PyPI Project Name | `ticketwright` |
   | Owner | `kyle-chalmers` |
   | Repository name | `ticketwright` |
   | Workflow name | `publish.yml` |
   | Environment name | `pypi` |

   → click **Add**. (Workflow name = the filename; Environment = `pypi`, matching `environment: pypi`
   in the workflow.) "Pending" means the project doesn't exist on PyPI yet — the first successful run
   creates it and binds the publisher.

> Optional hardening: in the GitHub repo → Settings → Environments → create an environment named
> `pypi` with a protection rule (e.g. required reviewer) so a tag can't publish without sign-off.

## Part B — cut a release (each version)

1. Bump all three version files in one command, then add a `CHANGELOG.md` entry:
   ```bash
   bash bin/bump_version.sh 3.4.0
   ```
   It rewrites `ticketwright/__init__.py` (the source of truth — `pyproject.toml` reads it
   dynamically via Hatch, so there is nothing to edit there), `.claude-plugin/plugin.json`, and
   `.claude-plugin/marketplace.json`, then verifies they agree and both manifests still parse.
   Doing this by hand is what let PyPI drift a full minor behind the plugin; `selftest.sh` §16
   fails the build if the three ever disagree.
2. `bash bin/selftest.sh` — must be green.
3. Commit, then tag and push the tag:
   ```bash
   git tag v3.4.0 && git push origin v3.4.0
   ```
4. The `publish` workflow runs, verifies `tag == package version`, builds, and publishes. Watch it in
   the repo's Actions tab. Done — `pip install ticketwright` now serves the new version.

> Don't skip the tag. An untagged bump leaves PyPI serving the previous release while the plugin
> (installed from the git marketplace) moves ahead — pip users then get stale skill prose with
> bugs the plugin has already fixed. CI's `wheel` job proves the package *builds*; only the tag
> ships it.

> Note: `v1.3.0` was tagged before this workflow existed, so the **first** publish is `v1.3.1`.

## Part C: the Claude plugin directory listing

The listing in Anthropic's plugin directory ([claude.ai/directory/manage](https://claude.ai/directory/manage))
follows the **`directory` branch**, not `main`. After `publish.yml` puts a release on PyPI, its
`directory-branch` job fast-forwards `directory` to the release tag. The directory then scans that
commit and publishes it. Nothing to do by hand per release; if the job fails, the listing keeps
serving the previous version. Only a final `vX.Y.Z` tag moves it: a prerelease tag such as
`v4.3.0rc1` still publishes to PyPI but leaves the listing alone. `.git-sweep-keep` stops branch
cleanup from deleting `directory`.

Three rules follow from how the directory and Claude Code pick up a version:

- **`version` must rise with every release.** The directory's checklist requires it, and Claude
  Code keeps an installed plugin on the `version` in `plugin.json` until that changes, so a commit at
  an unchanged version reaches no existing install. `bin/bump_version.sh` already moves all three
  version files, the tag check in `publish.yml` refuses a tag that disagrees with
  `ticketwright/__init__.py`, and selftest section 16 keeps `plugin.json` in step with that file.
  This is also why the listing does not follow `main`: day-to-day commits there stay at the last
  release's version (AGENTS.md, "Hard constraints").
- **The icon locks at the first portal save.** Whatever icon the plugin has the first time it is
  saved or submitted in the developer portal becomes the listing icon, and changing the file later
  does not change it. Settle `.claude-plugin/icon.png` (square PNG, 512 to 2048 px, under 2 MB)
  before that first save.
- **The first submission waits for a release with the current layout.** Releases up to v4.2.0 load
  their skills through root `skills`, `agents` and `commands` symlinks, which the directory blocks.
  The first release cut after the move to `plugin.json` paths creates `directory`; submit then,
  with the listing set to follow that branch. Submission is done by the maintainer in the portal.

**The listing is Claude Code only.** Ticketwright ships its scripts in a top-level `bin/`, and
claude.ai chat and Cowork refuse to install a plugin that has one
([platform support](https://claude.com/docs/plugins/platform-support)); the portal derives the
supported surfaces from that rule. `bin/` stays where it is: every installed project's `bin/tw`
resolves kit scripts at `<kit>/bin/`, and those scripts are the harness-neutral layer the skills
call (AGENTS.md, tiebreaker 5).

**What the directory checks, and where this repo stands.** The CI `plugin-directory` job runs
`claude plugin validate --profile directory --strict` (Claude Code 2.1.305 or later) on the committed
tree. Run the same thing locally on a clean export, so untracked files such as `.DS_Store` are not
judged:

```bash
tmp="$(mktemp -d)" && git archive HEAD | tar -x -C "$tmp" && claude plugin validate --profile directory --strict "$tmp"
```

That command covers a subset; the portal's **Validate** runs the full
[pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist), and a
security scan follows on each version. Three of its checks hold a version for a reviewer rather
than block it, and all three apply here today: `bin/selftest.sh` is over the 256 KiB per-file limit,
`tests/source_materials/fixtures/export.bin` is a binary fixture, and `scripts/readme_media/` names
bundled image paths in its scripts and docs. The scan can raise the same holds on each new version;
trimming those dev-only paths from the `directory` branch would clear them. Re-read the checklist
before any structural change to the plugin.

## What ships

`pip install ticketwright` installs a zero-dependency, stdlib-only CLI:

- `ticketwright init [path]` — scaffold the kit into a repo (a versioned, upgrade-safe `cp -r`).
- `ticketwright recall …` / `index …` — the prior-art recall + ticket-index engines, run against the
  repo at `$PWD`. Pure stdlib; no Claude Code required.
- `ticketwright enrich …` — refresh a ticket's curated summary. Calls the model headlessly via
  a model CLI resolved per runtime (`adapters/runtime/*.md`, or `--model-cmd`), so this one **does**
  need some model command on `PATH` — `claude` by default.

The kit assets (`bin/`, `.claude/`, `adapters/`, `templates/`) are bundled into the wheel under
`ticketwright/_kit/` via hatchling `force-include`, so the Claude Code **plugin** and `cp -r` install
paths (which reference `bin/` at the repo root) are unchanged.

`.claude/config` is force-included **file by file**, not as a directory: the repo's own
`.claude/config/stack.yaml` is a fictional "Acme" worked example, and mapping the directory shipped
it in the wheel so `init` scaffolded it into fresh repos as if it were real config. Only the schema
and the `stack.example.*.yaml` files belong in the bundle — `/setup` writes the live `stack.yaml`
from evidence in the user's repo. Adding a new file under `.claude/config/` means adding a
force-include line for it; `selftest.sh` §16 fails if one is missing.
