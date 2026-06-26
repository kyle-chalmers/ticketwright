# Contributing

Thanks for your interest! This is a small, self-contained harness — contributions that keep it
**tool-agnostic** and **dependency-light** (stdlib Python + `yq`/`jq` + standard CLIs) are most welcome.

## Getting started

```bash
bash bin/selftest.sh        # kit integrity + hook unit tests — must pass before you change anything
```

The self-test needs `yq` and `python3`. No network, no credentials.

## The golden rule: skills are tool-agnostic

Skills and commands are written **once against the verb contract** and must never name a concrete
tool (`acli`, `snow`, `slack`, `gh`, …). Tool specifics live in **`adapters/<seam>/<tool>.md`** and
in **`.claude/config/stack.yaml`**. The self-test enforces this (it greps skills for tool names).

## Adding a tool (the common contribution)

1. Copy the closest adapter in the same seam (e.g. `adapters/tracker/jira.md`) to
   `adapters/<seam>/<yourtool>.md`.
2. Keep the frontmatter (`seam`, `tool`, `transport`, `requires`, `auth`) and implement **every**
   verb section the seam's contract lists (see `adapters/README.md`).
3. Point a `stack.yaml` seam at it and add a read-only `verify` command.
4. `bash bin/verify_stack.sh` (reachability) and `bash bin/selftest.sh` (coverage) must pass.

No skill edits should be required — if they are, the abstraction is leaking; raise it in the PR.

## Adding / changing a skill

- Keep the `SKILL.md` frontmatter (`name`, `description`, …) and the verb-only discipline.
- If it reads config, read it from `stack.yaml` (don't hardcode project facts).
- Run `bash bin/selftest.sh` — frontmatter validity and tool-name isolation are checked.

## Pull requests

- Keep changes focused; update `docs/` and the README if behavior changes.
- Ensure `bash bin/selftest.sh` prints `0 failed`.
- Conventional commit titles (`feat:`, `fix:`, `docs:`, …) are appreciated.
