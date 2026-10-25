# Security policy

## Reporting a vulnerability

Report security problems privately, through GitHub's private vulnerability reporting: open this
repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/kyle-chalmers/ticketwright/security/advisories/new)). Please do
not open a public issue for a vulnerability.

A useful report names:

- the Ticketwright version (`ticketwright --version`, or the `version` in the plugin's
  `.claude-plugin/plugin.json`) and how it is installed (Claude Code plugin, PyPI package, or a
  vendored copy);
- the part affected: a hook, a skill, an adapter, a `bin/` engine, or the setup scaffolding;
- the steps that reproduce it, and what an attacker gains.

Leave out credentials, warehouse or tracker identifiers and real data. A fictional example is
enough to show the problem.

The maintainer replies in the private advisory thread, and the fix ships in a release recorded in
the [CHANGELOG](CHANGELOG.md).

## Supported versions

Fixes land in the latest release. Upgrade the plugin with
[uninstall, install, relaunch](docs/troubleshooting.md#upgrading), or the package with
`pip install -U ticketwright`.

## Scope

In scope: anything in this repository that runs on a user's machine or in CI, above all the hooks
and guards. Out of scope: a person with write access to a ticket repo deliberately defeating a
guard. The guards catch accidents and drift; repository review stays the trust boundary for
malicious commits.

## What the guards promise, and what they do not

Ticketwright's safety rails are Claude Code hooks (listed in full in
[docs/how-it-works.md](docs/how-it-works.md#hooks-in-full)). Stated plainly:

- **They fail open.** A hook that errors lets the call through, so a broken hook never blocks a
  session. A guard is a second check, not the only one.
- **They match commands, not intent.** The warehouse guard reads the SQL a CLI command carries,
  including SQL in a `-f` file or a stdin redirect. SQL sent through an MCP tool never reaches a
  shell hook, so that tool's own permission settings are the control there.
- **They only exist where the runtime runs them.** The hooks are proven in Claude Code. On other
  agents the installer wires what each runtime documents, and
  [docs/runtimes.md](docs/runtimes.md) says per runtime what is enforced and what is guidance.
- **One guard removes a prompt.** Verifiably read-only SQL (`SELECT`, `SHOW`, `DESCRIBE`,
  `EXPLAIN`, with every referenced file read) is approved without asking. No hook can loosen a
  deny rule in your own settings.

The hooks make no network calls and write nothing outside the repo. The skills and engines make
no network calls of their own; they reach your tools through the CLIs and MCP servers you
configured, and a few setup choices write to your user config folder. What the plugin sends, what
it keeps, and where, is in [PRIVACY.md](PRIVACY.md).

## Everything else

Bugs, questions and feature requests: [SUPPORT.md](SUPPORT.md).
