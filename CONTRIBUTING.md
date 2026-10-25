# Contributing

Thanks for your interest! This is a small, self-contained kit. Contributions that keep it
**tool-agnostic** and **dependency-light** (stdlib Python + `yq`/`jq` + standard CLIs) are most
welcome. Changes are judged against the [mission and vision](README.md#mission), and
[AGENTS.md](AGENTS.md) holds the full contributor rules, including the tiebreakers that decide an
ambiguous change.

## Getting started

```bash
bash bin/selftest.sh        # kit integrity + hook unit tests: must pass before you change anything
```

The self-test needs `yq` and `python3`. No network, no credentials. It must print `0 failed`.

## The golden rule: skills are tool-agnostic

Skills and commands are written **once against the verb contract** and must never **invoke** a
concrete tool: no `acli`/`snow`/`gh`/`psql`/MCP commands in their orchestration. Tool specifics live
in **`adapters/<seam>/<tool>.md`** and in **`.claude/config/stack.yaml`**. The self-test (section 3)
greps skills/commands for tool *commands* and fails on a leak. Two sanctioned exceptions: the
CLI-**detection** probe in `setup` (which must name CLIs to detect what's installed)
and the self-lint line in `skillify`. Naming a tool in illustrative prose is fine; calling
one is not.

## Adding a tool (the common contribution)

1. Copy the closest adapter in the same seam (e.g. `adapters/tracker/jira.md`) to
   `adapters/<seam>/<yourtool>.md`.
2. Keep the frontmatter (`seam`, `tool`, `transport`, `requires`, `auth`) and implement **every**
   verb section the seam's contract lists (see `adapters/README.md`).
3. Point a `stack.yaml` seam at it and add a read-only `verify` command.
4. `bash bin/verify_stack.sh <your stack.yaml> --dry-run` proves every slot resolves to an adapter
   without touching the network, and `bash bin/selftest.sh` checks coverage. Both must pass.

No skill edits should be required. If they are, the abstraction is leaking; raise it in the PR.

## Adding / changing a skill

- Keep the `SKILL.md` frontmatter (`name`, `description`, …) and the verb-only discipline.
- If it reads config, read it from `stack.yaml` (don't hardcode project facts).
- Run `bash bin/selftest.sh`: frontmatter validity and tool-name isolation are checked.

## House rules the self-test enforces

- **Bash 3.2.** Stock macOS `/bin/bash` mis-parses a heredoc nested inside `$( )`, so capture
  heredoc output through a temp file. CI runs the whole suite under `/bin/bash` on macOS.
- **Plain language in anything a person reads.** Lead with what happened and what to do; put the
  technical detail after ` Details:`. Section 59 checks it (`tests/plain_language/`).
- **"Tool slot" in user-facing prose.** `seam` stays the internal word (config keys, adapter
  frontmatter, contributor docs).
- **A 900-word README.** Prose only counts; fences, image lines and comments don't. Move detail
  into `docs/` and link it from [docs/README.md](docs/README.md).
- **No organization names, real ticket IDs, industry vocabulary, secrets or PII.** Examples use
  `TEST-` keys and the kit's invented orders-and-returns domain.
- **No version bumps outside a release.** The version lives in `ticketwright/__init__.py`, and a
  tagged release moves it in lockstep with both plugin manifests.

## Pull requests

- Keep changes focused; update `docs/` and the README if behavior changes, and add a line to
  `CHANGELOG.md` under Unreleased for anything user-facing.
- When you change behavior, add or update the matching numbered selftest section.
- Ensure `bash bin/selftest.sh` prints `0 failed`.
- Conventional commit titles (`feat:`, `fix:`, `docs:`, …) are appreciated.
- Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go to
  [SECURITY.md](SECURITY.md), never a public issue.
