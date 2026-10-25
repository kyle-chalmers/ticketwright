# Getting help

Ticketwright has one maintainer, so where you ask decides how fast you get an answer.

| You want to... | Go to |
|---|---|
| Fix an install, setup or upgrade problem | [Troubleshooting](docs/troubleshooting.md) first: most failures have a numbered entry and a check that names them |
| Learn how a phase or a hook works | [docs/README.md](docs/README.md), the index of every doc |
| Report a bug | [New issue](https://github.com/kyle-chalmers/ticketwright/issues/new/choose), using the bug form |
| Request a feature or a new adapter | [New issue](https://github.com/kyle-chalmers/ticketwright/issues/new/choose), using the feature form. A new tool is usually one adapter file: see [docs/architecture.md](docs/architecture.md) |
| Report a vulnerability | Privately, per [SECURITY.md](SECURITY.md). Never in a public issue |

## Before you file

Run the plugin doctor and paste its output. It reads local files only, sends nothing anywhere, and
names the exact state an install is in:

```bash
python3 ~/.claude/plugins/marketplaces/ticketwright/bin/plugin_doctor.py
```

Inside a repo that `/setup` has configured, `bash bin/tw plugin_doctor.py` runs the same check.

Include the Ticketwright version and how you installed it (Claude Code plugin, PyPI package, or a
vendored copy). Never paste credentials, warehouse or tracker identifiers, or real data: a
fictional example with `TEST-` ticket keys is enough.

## What to expect

The maintainer reads every issue, and either takes it on, asks a question, or explains why it is
out of scope. Changes are judged against the [mission and vision](README.md#mission): high-volume
analysis without letting quality slide, on whatever tools a team already uses.
