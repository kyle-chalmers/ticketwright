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
`directory-branch` job runs `.github/scripts/directory_tree.sh commit <tag> <directory head>` and
pushes the commit it prints. The directory then scans that commit and publishes it. Nothing to do
by hand per release; if the job fails, the listing keeps serving the previous version. Only a final
`vX.Y.Z` tag moves it: a prerelease tag such as `v4.3.0rc1` still publishes to PyPI but leaves the
listing alone. `.git-sweep-keep` stops branch cleanup from deleting `directory`.

**The listing serves a trimmed tree.** The commit holds the release tree but removes `tests/`, `scripts/`, `.github/`, `docs/images/`, `docs/maintainers/` and `bin/selftest.sh`.
Those are dev-only, and they are paths that trip the directory's reviewer holds: the self-test is
over the 256 KiB per-file limit, a test fixture is a binary that is not an image, the media scripts
and the README images are PNGs and GIFs a script could reach (the README loads its images from
GitHub URLs, so the listing needs none of them), and the maintainer docs pair credential words with
remote URLs. Nothing a plugin install runs lives there; `/setup`
offers the self-test only on a kit that has it (a clone, a vendored copy or a pip install, all of
which keep the full tree). The commit's only parent is the previous `directory` head, so the push
is a plain fast-forward, and its message names the tag and the tag's commit. The tag is not a
parent on purpose: GitHub refuses a push from the Actions token whose new commits change anything
under `.github/workflows/`, and against a parent that still has those files the trim reads as
deleting them. The script refuses a tag whose `plugin.json` version disagrees with it, a version
that is not higher than the one already on `directory` (so the listing never moves backward), and
a `directory` head that still carries `.github/` (the one trimmed path only the bootstrap can remove;
any other path added to the trim list later is simply dropped by the next release).

**Policy holds a version can still raise.** The scan holds a version for a reviewer on more than
file rules. The kit cleared the ones it tripped (LABS-206): skills grant no `Bash` (the scan also holds a
pattern whose program path is built at run time, like the `bin/tw` launcher's), no hook approves a tool call, the listing carries no PNG or GIF (the icon is SVG), and no
file pairs a word the scan reads as a credential (`$PWD`, rclone's config path, `pass` where a shell
command would start, an environment variable read by a computed name) with a URL. Selftest section
60b pins each of those on the trimmed tree. Three holds stay by design, all from two adapters: the Zoom and Azure
DevOps adapters read the user's token from the environment and send it only to that vendor's API
(one hold each), and the scan pairs the Zoom token with `/setup`'s rclone backup. A reviewer
confirms them, so a version still waits on review until those adapters take their tokens another way. The scan's matching is heuristic and changes, so check a release candidate in the
portal: **Submit new → Plugin bundle**, enter `kyle-chalmers/ticketwright@<branch>` with a branch
that holds the trimmed tree (`directory_tree.sh tree`), select **Validate**, read the holds, then
leave the form without submitting.

**One-time bootstrap.** For that last reason, the first trimmed commit cannot come from Actions:
through v4.9.1, `directory` was a plain copy of each tag. A maintainer builds it from the current
listing head and pushes it once, with their own credentials:

```bash
git fetch origin directory
commit="$(bash .github/scripts/directory_tree.sh bootstrap origin/directory)"
git log -1 --stat "$commit" | tail -3     # removes only the dev-only paths, nothing else
git push origin "$commit:refs/heads/directory"
```

It keeps the listed version (v4.9.1) and only removes files. Every release after it is committed by
`publish.yml` on top. Until it is pushed, the `directory-branch` job fails with a message naming
this step, and the listing stays where it was. Push it just before cutting the next release, not
as a listing of its own: v4.9.1's `/setup` teammate path still runs the self-test unconditionally,
so a bootstrapped v4.9.1 is not something to submit or leave listed. Selftest section
60b builds the same tree from the working copy and checks it the way the directory does; CI's
`plugin-directory` job runs `--profile directory --strict` on it.

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
  does not change it. Settle the icon that `plugin.json` names (square PNG, 512 to 2048 px, under 2 MB)
  before that first save.
- **The first submission waits for the bootstrap and then a release.** Until the bootstrap above
  is pushed, `directory` still carries the held paths; until a release cut after the trim lands on
  top of it, the listed `/setup` is v4.9.1's, which still runs the removed self-test. The release
  also proves the Actions half. Submission is done by the maintainer in the portal.

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

To check what the listing actually serves, build the trimmed tree instead:

```bash
tmp="$(mktemp -d)" && bash .github/scripts/directory_tree.sh tree HEAD "$tmp/tw" && claude plugin validate --profile directory --strict "$tmp/tw"
```

Either command covers a subset; the portal's **Validate** runs the full
[pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist), and a
security scan follows on each version. The checklist's reviewer holds (a non-image file over
256 KiB, a non-image binary, a script naming a bundled image, more than 512 files) are cleared by
the trim and pinned by selftest section 60b. Re-read the checklist before any structural change
to the plugin.

### Submitting in the portal

The maintainer does this from their own claude.ai account; no script or agent touches the portal.

1. Push the one-time bootstrap (above) if `directory` still has `tests/`. Then cut a release
   (`bash bin/bump_version.sh X.Y.Z`, merge, push the `vX.Y.Z` tag) and wait for `publish.yml`'s
   `directory-branch` job to go green. Confirm the newest commit on `directory` starts
   `directory: vX.Y.Z` and that its `.claude/skills/setup/teammate.md` offers the self-test only on a
   kit that has it. Both are required: the release is what lists a `/setup` that works without the
   self-test.
2. Open [claude.ai/directory/manage](https://claude.ai/directory/manage), choose **Submit new**,
   then **Plugin bundle**.
3. **Source:** repository `kyle-chalmers/ticketwright`, plugin path the repository root, and the
   branch the listing follows: `directory`. The repository is also a single-plugin marketplace; the
   directory treats the root as the plugin, which is what we want.
4. Select **Validate**. Fix anything marked **Blocking** on `main`, cut a release, then
   **Re-validate**. A **Policy hold** can still be submitted, but should not appear: if one does,
   section 60b missed a rule, so fix the check as well as the file.
5. Check the listing fields the portal reads from `plugin.json` and the README (name
   `ticketwright`, display name, description, icon, documentation, support and privacy links). The
   icon locks at this first save.
6. Submit. The security scan runs, then review. Follow the plugin's **Versions** tab in the portal;
   later releases reach the listing through the `directory` branch with no portal step.

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
