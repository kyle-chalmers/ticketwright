# Publishing to PyPI

Ticketwright publishes to PyPI via **GitHub Trusted Publishing** (OIDC — no API tokens stored
anywhere). The workflow is [`.github/workflows/publish.yml`](../.github/workflows/publish.yml): it
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
