# PROMPT — A visible "release available" notice, until upstream autoUpdate re-installs

STATUS: DRAFT for maintainer review. Not scheduled. Written 2026-08-23 after reproducing the gap
live; codex-reviewed the same day with findings folded in. SELF-CONTAINED — the retired planning
document's standing constraints are restated at the end.

## Why (the reproduced gap)

`autoUpdate: true` on a git-source marketplace entry refreshes the marketplace CATALOG after
session start, but Claude Code does not re-install a project-scoped plugin from it. Upstream
tracking: [claude-code#61854](https://github.com/anthropics/claude-code/issues/61854) (closed as
a duplicate; the reported behavior persists — verified live 2026-08-23 on a real install: after
the v3.6.0 release, the marketplace cache read 3.6.0 while the installed plugin stayed pinned at
3.5.0 with nothing telling anyone). So a release reaches every teammate's MACHINE and is silently
not RUNNING — an invisible degradation, the shape tiebreaker 6 exists to forbid. The README and
docs/troubleshooting.md document the manual remediation (uninstall + reinstall at project scope;
`claude plugin update` does not work at project scope) — this prompt makes the gap VISIBLE so the
remediation gets used. It deliberately does NOT auto-swap the install: that is upstream's job,
and a kit that silently swaps its own running code has a worse property than a stale version.

## The design — one CLI, one presenter, per the house split

1. `bin/update_notice.py` — harness-neutral CLI, stdlib-only, `--root <repo>`, no Claude env vars
   REQUIRED, exit 0 ALWAYS (a notice tool must never break anything). Config-root override
   follows the existing precedent in `bin/kit_paths.py`: honor `CLAUDE_CONFIG_DIR` when set,
   default `~/.claude` — and expose it as a flag for tests the way existing fixtures place
   `plugins/installed_plugins.json` directly under that root. It reads THREE local files, no
   network (the catalog refresh is Claude Code's own job):
   - the repo's `.claude/settings.json` — eligibility: the marketplace present under
     `extraKnownMarketplaces` with `"autoUpdate": true`, and the plugin `true` under
     `enabledPlugins`. An EXPLICIT `false` on either is a deliberate opt-out setup already
     honors — stay silent.
   - `<config-root>/plugins/installed_plugins.json` — require a top-level `plugins` mapping
     (tolerate and ignore sibling keys such as `version`, observed live; the kit's own selftest
     fixture carries only `plugins`). The plugin's entries live under
     `plugins["<plugin>@<marketplace>"]` as a LIST of records; AMBIGUITY-SAFE selection: exactly
     one enabled `<plugin>@<marketplace>` pair in the repo settings, and exactly one record with
     `scope: "project"` whose `projectPath` equals the resolved `--root`. Zero or two of either →
     silent (never guess between versions — the same stale-copy discipline `kit_paths.py`
     applies).
   - `<config-root>/plugins/marketplaces/<marketplace>/.claude-plugin/plugin.json` — the catalog
     version. (This repo pins `marketplace.json` equal to `plugin.json` by selftest; read
     `plugin.json` and say so in the CLI's docstring.)
   VERSION COMPARISON, defined not implied: split both strings on dots; every segment must parse
   as a base-10 integer or the CLI stays silent (prereleases and exotic schemes are out of
   scope — silence, never a guess); pad the shorter tuple with zeros (`3.6` == `3.6.0`); notice
   ONLY when catalog > installed. Equal or older → silent (never suggest a downgrade). When
   upstream closes the gap, versions match and the notice retires itself with zero cleanup.
   Output on the single firing condition — ONE line, versions only, names read from the repo's
   own settings (never hardcoded, so forks and renames keep working):
   `ticketwright 3.6.0 is available — this repo is running 3.5.0. Pick it up: claude plugin
   uninstall ticketwright@ticketwright --scope project && claude plugin install
   ticketwright@ticketwright --scope project`
   PRIVACY: `installed_plugins.json` contains OTHER repos' paths — the CLI must never print any
   path from it, only version strings. Every failure mode (missing file, truncated JSON, unknown
   shape, no match, ambiguity) is SILENCE with exit 0, not an error.
2. `.claude/hooks/session_context.py` — the Claude presenter appends the CLI's line (if any) to
   the existing SessionStart banner, once per session (SessionStart gives that for free; the hook
   keeps no state). THIS hook fails open: it resolves the script from its own KIT directory (the
   file already separates project root from kit-root imports — follow that), runs it as a
   subprocess with a timeout comfortably under the 10-second hook budget, captures stdout/stderr,
   and appends stdout only if it is exactly one non-empty line; anything else — timeout, nonzero
   exit, multi-line, empty — yields no banner line and no error. Do NOT generalize "fail open" to
   the other hooks in prose: `db_write_guard` deliberately fails SAFE (asks more when its scanner
   is unavailable), and that asymmetry is load-bearing.
3. Other runtimes: the CLI is invocable through the established launcher form
   (`bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" update_notice.py --root .` — keep the fallback; a
   plugin install has no project `bin/`, and the launcher rejects path-containing script names).
   Add one line naming it in whichever runtime artifact already lists per-runtime session-start
   equivalents. No new per-runtime machinery.
4. GUIDANCE ALREADY UPDATED (do not redo): the README Quickstart caveat, the README
   project-scoped bullet, and docs/troubleshooting.md's upgrade row were corrected to the
   catalog-only reality in the same PR that shipped this draft. When the notice ships, extend the
   README caveat with one sentence saying sessions now announce a pending release.

## Selftest (behavioral, fixture config-root)

New hand-numbered section (read the highest ON CURRENT MAIN first). Build a fixture config-root
with fabricated `installed_plugins.json` + marketplace `plugin.json` and a fixture repo, then
assert OUTPUT AND EXIT CODE per case: newer catalog → exactly one line carrying both versions and
the remediation pair, exit 0; equal → silent; catalog older → silent; `3.6` vs `3.6.0` → equal,
silent; a non-integer segment → silent; missing either plugin file, truncated JSON, top-level
shape without `plugins`, entry not a list, no matching `projectPath`, two matching records, no
marketplace in settings, explicit `autoUpdate: false`, explicit enabled `false` → all silent,
exit 0; and the privacy case — a fixture `installed_plugins.json` carrying a foreign repo path
proves the output never contains it. Hook side: the existing session-banner fixture gains the
line when the fixture config-root says newer, and stays byte-identical when the CLI is broken
(fail-open pin) and when it times out.

## Standing constraints (carried over)
- `bash bin/selftest.sh` prints `0 failed` — CHECK THE EXIT CODE, not the printed tail. Add your
  section; never renumber existing ones. The suite is read-only, offline, credential-free.
- Existing configs in the wild keep working; fixture identifiers only, files AND commit messages;
  THIS REPO IS PUBLIC.
- Stdlib only; no version bump (release commits only — and a bump regenerates `tests/emit/`
  fixtures); conventional-commit title; CHANGELOG entry (user-facing). Editing any
  `.claude/skills/*` file regenerates emitted fixtures per `tests/emit/README.md` in the same
  commit (this prompt should not need to).
- User-facing prose says "tool slot"; branch from current main; squash-merge; surgical edits in
  shared files.

## Gates (non-optional, the house pattern)
codex twice, verdicts verbatim in the PR body — PLAN before coding, DIFF before the PR
(`codex exec --skip-git-repo-check -C . "…cite file:line…"`; maintainer note: codex runs 15+
minutes here — background it with stdin closed, collect from the output file). Verify findings
against source. The diff review must specifically answer: can the notice ever print a path from
`installed_plugins.json`; can any failure mode produce output other than silence or the one line;
does a broken or hanging CLI leave the session banner byte-identical; and is the ambiguity rule
(two records → silence) actually exercised by a test?

## Evidence-of-done
The reproduced live gap prints the one-line notice in a fixture mirroring it (3.5.0 installed,
3.6.0 catalog); every silence case is pinned; the hook fail-open and timeout pins are green;
selftest `0 failed` with exit code checked.
