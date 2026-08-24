#!/usr/bin/env python3
"""Say — once, in one line — that a newer release is sitting in the marketplace catalog unused.

WHY THIS EXISTS. `autoUpdate: true` on a git-source marketplace entry refreshes the marketplace
CATALOG after session start, but Claude Code does not re-install a PROJECT-SCOPED plugin from it
(claude-code#61854, closed as a duplicate; the behavior persists). So a release reaches every
teammate's machine and is silently not RUNNING. This CLI makes that visible. It deliberately does
NOT swap the install: that is upstream's job, and a kit that silently swaps its own running code has
a worse property than a stale version. When upstream closes the gap the two versions match, this
prints nothing, and the notice retires itself with no cleanup.

  update_notice.py [--root <repo>] [--config-root <dir>]

Reads THREE local files. No network, no writes, no credentials:

  <root>/.claude/settings.json
      Eligibility AND the names. The marketplace must appear under `extraKnownMarketplaces` with
      `"autoUpdate": true`, and `enabledPlugins["<plugin>@<marketplace>"]` must be true. An explicit
      false on either is a deliberate opt-out that /setup already honors -> silence. Both names are
      read from here and never hardcoded, so forks and renames keep working.

  <config-root>/plugins/installed_plugins.json
      The INSTALLED version, from the matching record's own `version` field.

  <config-root>/plugins/marketplaces/<marketplace>/.claude-plugin/plugin.json
      The CATALOG version. This is the marketplace root's own plugin manifest, which is the right
      file for a marketplace publishing one plugin at `source: "."` -- what this kit is, and what
      selftest section 16 pins equal to marketplace.json. A marketplace laid out any other way makes
      this file absent or name-mismatched, and the answer there is SILENCE, not a second guess at
      where the version lives: generalizing the lookup is a separate, separately-tested change.

`--config-root` exists for tests; otherwise $CLAUDE_CONFIG_DIR then ~/.claude, matching
bin/kit_paths.py.

TWO CONTRACTS THIS FILE MUST NEVER BREAK:

  1. EXIT 0, ALWAYS. A notice tool that can fail is a notice tool that can break a session.
  2. SILENCE OR ONE LINE, NOTHING ELSE -- on stdout or stderr -- for every invocation a HOOK can
     make. `installed_plugins.json` lists OTHER repos' filesystem paths; nothing read from it is
     ever printed except a version string. Every failure mode (file missing, truncated JSON,
     unexpected shape, oversized or non-regular file, no match, ambiguity, unparseable version, a
     usage error) is silence. The ONE deliberate exception is `--help`, which prints argparse's usage
     because a harness-neutral CLI with no discoverable help is worse than one with it; no hook
     passes that flag, and the presenter rejects multi-line output anyway. Stated rather than
     implied, because "silence or one line, no exceptions" would have been a false claim.

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

# `<plugin>@<marketplace>` — the key shape Claude Code uses in both enabledPlugins and
# installed_plugins.json. Split on the LAST "@" so a plugin name containing one cannot shift the
# marketplace half.
PAIR_SEP = "@"

# A name is interpolated into a shell command this notice invites a person to PASTE, so it must be
# an ordinary identifier or the notice does not fire. Anything else — a space, a quote, `;`, `$(`,
# a newline — would either break the "one line" contract or hand the reader a command that does
# something other than what it appears to. The repo's own settings.json is the source, which is not
# a hostile file, but "not hostile" is not the same as "safe to splice into a shell command".
# fullmatch, NOT match: `re.match(r"^…$", "acme\n")` SUCCEEDS, because `$` also matches just before
# a trailing newline. That is exactly the input this guard exists to reject, so the anchors are gone
# and every use below is fullmatch.
SAFE_NAME = re.compile(r"[A-Za-z0-9._-]+")

# `.` and `..` clear SAFE_NAME and are catastrophic as the marketplace name, which is used as a
# PATH COMPONENT under plugins/marketplaces/. A marketplace named `..` would read a manifest one
# directory up and report a version from the wrong catalog entirely.
TRAVERSAL = {".", ".."}

# Deliberately NOT str.isdigit(): that is True for fullwidth and superscript digits ("３", "³"),
# which int() then rejects. A version segment is ASCII digits or this is not a version we compare.
# fullmatch for the same trailing-newline reason — and int() would happily strip that whitespace.
ASCII_INT = re.compile(r"[0-9]+")


# These files are kilobytes in practice (a manifest of a handful of plugins, a repo settings block).
# The cap is not a security boundary — it is a promise about TIME: this CLI runs as a child inside a
# SessionStart budget, and "parse whatever is there" is how a notice becomes the reason a session
# starts slowly.
MAX_BYTES = 4 * 1024 * 1024


def _load_json(path: Path) -> object | None:
    """Parse `path`, or None. Every failure — missing, unreadable, truncated, not UTF-8 — is None.

    A notice must never turn a malformed local file into a traceback on a session's first breath,
    and it must not be blockable. Two guards beyond the usual: the path has to be a REGULAR file (a
    FIFO would hang the read forever, and `st_size` is 0 for one, so a size check alone is no
    defense), and it has to be under MAX_BYTES.
    """
    fd = None
    try:
        # O_NONBLOCK, then fstat the DESCRIPTOR — not a stat() of the path. A path-first check is a
        # race: between "it is a regular file" and open(), the path can become a FIFO and open()
        # blocks forever, or the file can grow past the cap. O_NONBLOCK makes the open of a FIFO
        # return instead of waiting, and fstat then judges the thing we actually hold open.
        fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks, total, limit = [], 0, MAX_BYTES + 1
        while total < limit:
            # Bounded by what we READ, never by st_size — a file that grows mid-read cannot make
            # this child do unbounded work. EACH read is clamped to what is left of the budget, so
            # the worst case is limit bytes, not limit + one chunk. Reading exactly one byte past
            # the cap is what separates "at the cap" from "over it".
            chunk = os.read(fd, min(65536, limit - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > MAX_BYTES:
            return None
        return json.loads(b"".join(chunks).decode("utf-8"))
    except (OSError, ValueError):
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


def _resolve_root(root: str | None) -> Path:
    """The repo this notice is about.

    Same ladder as kit_paths.resolve_project, duplicated rather than imported: this CLI is invoked
    by a hook as a subprocess and must stand alone even if the rest of bin/ is unreadable.
    """
    if root:
        return Path(root).expanduser().resolve()
    for var in ("TICKETWRIGHT_PROJECT", "CLAUDE_PROJECT_DIR"):
        if os.environ.get(var):
            return Path(os.environ[var]).expanduser().resolve()
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        if top:
            return Path(top).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd().resolve()


def _config_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))


def eligible_pair(settings: object) -> tuple[str, str] | None:
    """The one `(plugin, marketplace)` this repo has opted into auto-update for, or None.

    BOTH halves must be affirmative: the marketplace carries `autoUpdate: true`, and the plugin is
    `true` under `enabledPlugins`. An explicit false on either is a deliberate opt-out. `true` is
    required literally — a truthy string or 1 is not the shape Claude Code writes, and guessing at
    intent here would nag someone who opted out.

    AMBIGUITY IS SILENCE: two eligible pairs mean we cannot say which one the notice is about, and a
    notice naming the wrong plugin is worse than no notice.
    """
    if not isinstance(settings, dict):
        return None
    markets = settings.get("extraKnownMarketplaces")
    enabled = settings.get("enabledPlugins")
    if not isinstance(markets, dict) or not isinstance(enabled, dict):
        return None

    auto = {name for name, entry in markets.items()
            if isinstance(entry, dict) and entry.get("autoUpdate") is True}
    if not auto:
        return None

    found = []
    for key, on in enabled.items():
        if on is not True or not isinstance(key, str) or PAIR_SEP not in key:
            continue
        plugin, _, marketplace = key.rpartition(PAIR_SEP)
        if (SAFE_NAME.fullmatch(plugin) and plugin not in TRAVERSAL
                and marketplace in auto and SAFE_NAME.fullmatch(marketplace)
                and marketplace not in TRAVERSAL):
            found.append((plugin, marketplace))
    return found[0] if len(found) == 1 else None


def installed_version(config_root: Path, plugin: str, marketplace: str, root: Path) -> str | None:
    """The version installed at PROJECT scope for `root`, or None.

    The manifest keeps every installed version side by side (3.5.0, 3.6.0, 3.6.1 …) across several
    repos, so selection has to be exact: scope `project`, and a `projectPath` that resolves to the
    same directory as `root`. Zero matches or two matches is None — the same refusal-to-guess
    kit_paths._plugin_kit makes, for the same reason.

    NOTHING READ HERE IS EVER RETURNED EXCEPT THE VERSION STRING. The records carry other repos'
    filesystem paths.
    """
    data = _load_json(config_root / "plugins" / "installed_plugins.json")
    if not isinstance(data, dict):
        return None
    plugins = data.get("plugins")          # sibling keys (`version`, …) are tolerated and ignored
    if not isinstance(plugins, dict):
        return None
    records = plugins.get(f"{plugin}{PAIR_SEP}{marketplace}")
    if not isinstance(records, list):
        return None

    root_str = str(root)
    candidates = [r for r in records
                  if isinstance(r, dict) and r.get("scope") == "project"
                  and isinstance(r.get("projectPath"), str) and r["projectPath"]]

    # Two ways a record can name this repo, and BOTH are checked for EVERY record:
    #   exact — Claude Code writes an already-resolved path, so a plain string compare against the
    #           canonical root settles the common case with no filesystem access at all;
    #   resolved — a record can legitimately hold a symlink to this repo (a git worktree,
    #           /var vs /private/var), and only resolution can see that.
    #
    # NOT normpath. `<root>/alias/..` collapses TEXTUALLY to `<root>`, but if `alias` is a symlink
    # the real path is somewhere else entirely — a false match, which is the one outcome worse than
    # a miss. Canonical-vs-canonical, or resolve and find out; never a lexical shortcut in between.
    #
    # It is also tempting to skip resolution once an exact match is found. DON'T: one canonical
    # record plus one symlinked record are TWO installs for this repo at possibly different
    # versions, and short-circuiting would pick one and call it the answer — the guess this function
    # exists to refuse. The price is resolving other repos' paths, bounded by the hook's child
    # timeout. That price buys the ambiguity guarantee, which is the more load-bearing property.
    matches = []
    for rec in candidates:
        raw = rec["projectPath"]
        if raw == root_str:
            matches.append(rec)
            continue
        candidate = Path(raw)
        if not candidate.is_absolute():
            # A relative record (`"."`, `"../repo"`) would resolve against THIS PROCESS'S cwd, so a
            # child launched inside the repo would match a record that names no repo at all. Claude
            # Code writes absolute paths; anything else is unjudgeable.
            continue
        try:
            # strict=True is the whole point. The default resolve() collapses `..` LEXICALLY when a
            # component does not exist, so `<root>/missing/..` comes back as `<root>` and matches a
            # repo it does not name. strict makes a nonexistent path raise instead of pretending.
            # No expanduser() either: `~` is another lexical rewrite of a path nobody verified.
            if candidate.resolve(strict=True) == root:
                matches.append(rec)
        except (OSError, ValueError, RuntimeError):
            continue  # missing, dead mount, unreadable parent, symlink loop — all unjudgeable
    if len(matches) != 1:
        return None
    version = matches[0].get("version")
    return version if isinstance(version, str) and version else None


def catalog_version(config_root: Path, plugin: str, marketplace: str) -> str | None:
    """The version the cached marketplace advertises, or None.

    The `name` must match the plugin the repo enabled. Without that check a marketplace whose root
    manifest describes a DIFFERENT plugin would have its version compared against ours, and the
    notice would name a version nobody can install — the one way this file could produce a
    confidently wrong line rather than silence.
    """
    data = _load_json(config_root / "plugins" / "marketplaces" / marketplace
                      / ".claude-plugin" / "plugin.json")
    if not isinstance(data, dict) or data.get("name") != plugin:
        return None
    version = data.get("version")
    return version if isinstance(version, str) and version else None


def parse_version(value: str) -> tuple[int, ...] | None:
    """`"3.6.1"` -> `(3, 6, 1)`, or None when any segment is not a base-10 integer.

    Prereleases and exotic schemes are OUT OF SCOPE ON PURPOSE. Ordering `3.7.0-rc1` against `3.6.1`
    correctly needs precedence rules this file has no business owning, and a wrong answer here nags
    someone toward a downgrade. None means silence, never a guess.
    """
    out = []
    for seg in value.split("."):
        if not ASCII_INT.fullmatch(seg):  # rejects "", "-rc1", "1a", "+build", signs, whitespace, "³"
            return None
        out.append(int(seg))
    return tuple(out) if out else None


def is_newer(catalog: str, installed: str) -> bool:
    """True only when `catalog` is strictly newer. Equal or older is False — never a downgrade.

    The shorter tuple is zero-padded, so `3.6` == `3.6.0`.
    """
    a, b = parse_version(catalog), parse_version(installed)
    if a is None or b is None:
        return False
    width = max(len(a), len(b))
    return a + (0,) * (width - len(a)) > b + (0,) * (width - len(b))


def notice(root: Path, config_root: Path) -> str | None:
    """The one line, or None. This is the whole decision, in reading order."""
    pair = eligible_pair(_load_json(root / ".claude" / "settings.json"))
    if pair is None:
        return None
    plugin, marketplace = pair

    installed = installed_version(config_root, plugin, marketplace, root)
    catalog = catalog_version(config_root, plugin, marketplace)
    if not installed or not catalog or not is_newer(catalog, installed):
        return None

    ref = f"{plugin}{PAIR_SEP}{marketplace}"
    return (f"{plugin} {catalog} is available — this repo is running {installed}. "
            f"Pick it up: claude plugin uninstall {ref} --scope project "
            f"&& claude plugin install {ref} --scope project")


class _BadArgs(Exception):
    """A usage error, raised INSTEAD of argparse printing to stderr and exiting 2."""


class _QuietParser(argparse.ArgumentParser):
    """argparse that cannot violate contract 2.

    On a usage error the stock parser writes usage + a message to stderr and exits 2. A hook that
    appends this CLI's stdout would then see a nonzero exit with stderr noise — recoverable, but the
    contract here is that the CLI itself is silent, not that its caller cleans up after it. `--help`
    is left alone deliberately: it is an explicit human request, never something a hook passes.
    """

    def error(self, message: str) -> None:  # type: ignore[override]
        raise _BadArgs(message)


def main(argv: list[str] | None = None) -> int:
    ap = _QuietParser(
        description="Print one line when the marketplace catalog is newer than the installed plugin")
    ap.add_argument("--root", help="the repo (default: $TICKETWRIGHT_PROJECT, git toplevel, cwd)")
    ap.add_argument("--config-root", help="Claude config dir (default: $CLAUDE_CONFIG_DIR, ~/.claude)")
    try:
        args = ap.parse_args(argv)
    except _BadArgs:
        return 0
    except SystemExit:   # `--help` (0) and any exit path argparse still owns
        return 0
    except Exception:  # noqa: BLE001
        # `--help` WRITES before it exits, so a closed or unwritable stdout raises here — from the
        # act of rendering help, not from parsing. Contract 1 has no exceptions, so this is caught
        # too: the documented `--help` exception is about what gets PRINTED when printing works, not
        # a licence to traceback.
        return 0

    # print() is INSIDE the guard on purpose: a closed or non-UTF-8 stdout raises on write, and a
    # traceback from the act of printing the notice would break contract 1 just as surely as one
    # from reading a file. flush() forces that failure to surface here rather than at interpreter
    # exit, where it would print to stderr no matter what this function returned.
    try:
        line = notice(_resolve_root(args.root), _config_root(args.config_root))
        if line:
            print(line)
            sys.stdout.flush()
    except Exception:  # noqa: BLE001 — contract 1: this CLI cannot be the thing that fails
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
