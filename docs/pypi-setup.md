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

1. Bump the version in **all four** places (keep them in lockstep): `pyproject.toml`,
   `ticketwright/__init__.py`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`. Add a
   `CHANGELOG.md` entry.
2. Commit, then tag and push the tag:
   ```bash
   git tag v1.3.1 && git push origin v1.3.1
   ```
3. The `publish` workflow runs, verifies `tag == package version`, builds, and publishes. Watch it in
   the repo's Actions tab. Done — `pip install ticketwright` now serves the new version.

> Note: `v1.3.0` was tagged before this workflow existed, so the **first** publish is `v1.3.1`.

## What ships

`pip install ticketwright` installs a zero-dependency, stdlib-only CLI:

- `ticketwright init [path]` — scaffold the kit into a repo (a versioned, upgrade-safe `cp -r`).
- `ticketwright recall …` / `index …` / `enrich …` — run the prior-art recall + ticket-index tools
  against the repo at `$PWD`.

The kit assets (`bin/`, `.claude/`, `adapters/`, `templates/`) are bundled into the wheel under
`ticketwright/_kit/` via hatchling `force-include`, so the Claude Code **plugin** and `cp -r` install
paths (which reference `bin/` at the repo root) are unchanged.
