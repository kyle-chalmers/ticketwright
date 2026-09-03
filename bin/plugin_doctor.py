#!/usr/bin/env python3
"""Name every state a plugin install can be in, and say how to leave it.

WHY THIS EXISTS. Registering a marketplace is not installing a plugin. A repo can carry a committed
`extraKnownMarketplaces` + `enabledPlugins` block, a teammate can open and trust that repo, and
NOTHING is installed — the marketplace clone lands, the plugin does not, and on a Claude Code older
than 2.1.195 nothing on screen says so. Around that one gap sit four more states nobody could name
from the outside: a CLI too old to accept `--scope` (2.0.x rejects it, and rejects `plugin list`
too), an install record whose payload directory was never written (seen on 2.0.22), a global install
nobody meant to make, and a Download-ZIP folder that is not a git clone at all. This CLI turns all of
them into one line each, with the command that ends them.

  plugin_doctor.py [--root <repo>] [--config-root <dir>] [--plugin <name>] [--marketplace <name>]
                   [--url <clone url>] [--json] [--no-probe]

WHERE IT RUNS. Anywhere python3 does — including before anything is installed. The marketplace clone
appears at `~/.claude/plugins/marketplaces/<name>/` as soon as the folder is trusted, which is
exactly the moment a teammate's agent has nothing else to read:

  python3 ~/.claude/plugins/marketplaces/<marketplace>/bin/plugin_doctor.py

WHAT IT NEVER DOES. No network. No writes. No credentials. It never runs an install, an uninstall or
a `marketplace add` — it NAMES them and stops. The only subprocesses are `git` and, unless
`--no-probe` is passed, two read-only `claude` calls (`--version`, `plugin install --help`), each
with `capture_output=True, timeout=10`.

IT MUST NEVER IMPORT bin/kit_paths.py. That module answers "where is the kit" by collapsing
ambiguity to None by contract, exits 3 when there is no kit at all, and runs on every single
`bin/tw` invocation — none of which suits a diagnostic whose entire job is to describe a broken or
absent install without dying and without adding subprocess probes to the launcher's hot path. What
this file reuses instead is bin/update_notice.py, imported defensively: when that sibling is not
importable (a partial copy, a bare script beside a marketplace manifest) the checks that need it
report `unknown` rather than failing to run.

PRIVACY, stated exactly so it can be tested. `installed_plugins.json` and `known_marketplaces.json`
carry OTHER REPOS' filesystem paths. The rule: NO VALUE READ FROM EITHER OF THOSE FILES appears in
any output, in either mode, other than the caller's own `--root`. Versions, scopes and names are
reported; every `installPath`, `projectPath` and `installLocation` is JUDGED and then discarded —
named as a field where a fix has to talk about it, never printed as a value.

The one `~/…` path that does appear, in the `install_payload` fix, is not an exception to that rule:
it is a documentation template built from the marketplace NAME the caller supplied (a `--marketplace`
flag, the repo's own settings, or the clone's own manifest), never a location read from either config
file. A fork therefore reads its own marketplace name there, and no other repo's path rides along.

EXIT: 0 when nothing failed, 1 when any check failed, 2 on a usage error. Never a traceback — every
check is wrapped, and an exception becomes `unknown` carrying the exception's class name only.

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import shutil
import subprocess
import sys
from pathlib import Path

# Defensive by design: a diagnostic that dies because the file it wanted to reuse is missing is a
# diagnostic that cannot run in the situation it exists for. Consumers test the NAME they are
# about to call (bound to None below), never a bare "did the import work" flag.
try:
    from update_notice import (            # noqa: F401  (PAIR_SEP is used to build the ref)
        PAIR_SEP,
        _config_root as _un_config_root,
        _load_json as _un_load_json,
        _resolve_root as _un_resolve_root,
        catalog_version,
        install_pair_command,
        is_newer,
        repo_install_matches,
        select_repo_install,
        settings_pairs,
        install_rows,
    )
    _HAVE_UN = True
except ImportError:                        # pragma: no cover - exercised by selftest 55(h)
    # Every name is BOUND, to None, rather than left undefined. An unbound name turns the degrade
    # path into a NameError at the first use — the traceback this file promises never to produce —
    # and it hides the branch from a type checker, which is how a "defensive" import becomes a crash
    # nobody sees until the one machine that needs it. Each consumer below tests for None.
    _HAVE_UN = False
    PAIR_SEP = "@"
    _un_config_root = _un_load_json = _un_resolve_root = None
    catalog_version = install_pair_command = is_newer = None
    install_rows = repo_install_matches = select_repo_install = settings_pairs = None

SCHEMA = 1
TIMEOUT = 10

# THE PINNED ORDER. This list is the contract shared with README.md and templates/AGENTS.md.tmpl,
# whose install checklists tag each line with `<!-- doctor-check: <id> -->`; selftest section 55(k)
# asserts the three lists are equal, in order. Renaming or reordering an id means editing all three.
CHECK_IDS = [
    "git_clone",
    "cwd_is_root",
    "claude_on_path",
    "claude_version",
    "scope_supported",
    "install_channel",
    "marketplace_registered",
    "repo_install",
    "install_payload",
    "user_install",
    "catalog_current",
    "yq_present",
    "git_identity",
    "restart",
]

# "Restart" was read as "new chat" on three machines in a row, and a new chat inside the running app
# loads nothing. Said once, here, so every surface quotes the same words — and README.md's check 14
# carries this string VERBATIM, pinned by selftest 55, so the tool and the page cannot drift apart.
RESTART_ADVISORY = (
    "Run `/reload-plugins` or start a new session. If the skills still do not appear, fully quit "
    "the Claude app (Cmd+Q on macOS, File → Exit on Windows/Linux) and relaunch. A new chat inside "
    "the running app is not a restart."
)

# The version at which Claude Code began saying, on its own, that a declared plugin is not installed.
# Below it the same repo is silently plugin-less, which is the whole reason this file exists.
HINT_VERSION = "2.1.195"

UPDATE_COMMANDS = {
    "native": ["claude update"],
    "npm": ["npm install -g @anthropic-ai/claude-code@latest",
            "an nvm-installed `claude` shadows a native one; `claude doctor` lists conflicting "
            "installs"],
    "brew": ["brew upgrade claude-code"],
}
UPDATE_UNKNOWN = ["claude update  (native installer)",
                  "npm install -g @anthropic-ai/claude-code@latest  (npm/nvm)",
                  "brew upgrade claude-code  (Homebrew)",
                  "`claude doctor` shows install health and conflicting installs"]

SYMBOL = {"ok": "✓", "warn": "!", "fail": "✗", "unknown": "?"}


# ── small local helpers ───────────────────────────────────────────────────────────────────────────
def _read_json(path: Path) -> object | None:
    """The fallback JSON reader, used only when update_notice.py is not importable.

    Same two refusals as the real one, cheaply: a non-regular file (a FIFO would block forever) and
    anything that does not parse. Every failure is None, never an exception.
    """
    try:
        if not stat.S_ISREG(os.stat(str(path)).st_mode):
            return None
        with open(str(path), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _json(path: Path) -> object | None:
    return _un_load_json(path) if _un_load_json is not None else _read_json(path)


def _resolve_root(root: str | None) -> Path:
    if _un_resolve_root is not None:
        return _un_resolve_root(root)
    if root:
        return Path(root).expanduser().resolve()
    return Path.cwd().resolve()


def _config_root(explicit: str | None) -> Path:
    if _un_config_root is not None:
        return _un_config_root(explicit)
    if explicit:
        return Path(explicit).expanduser()
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))


def _run(cmd: list) -> tuple:
    """`(returncode, stdout, stderr)`, or `(None, "", "")` when the command could not run at all."""
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, "", ""


def manifest_pair(manifest: Path) -> tuple | None:
    """`(plugin, marketplace)` from a marketplace manifest, or None.

    This is the tier that makes the pre-install one-liner work in a repo with no settings at all: the
    script is sitting INSIDE the marketplace clone, so the clone's own manifest knows both names.
    Reading them beats hardcoding `ticketwright`, which would make every fork's doctor lie.
    """
    data = _json(manifest)
    if not isinstance(data, dict):
        return None
    marketplace = data.get("name")
    plugins = data.get("plugins")
    if not isinstance(marketplace, str) or not marketplace:
        return None
    if not isinstance(plugins, list) or not plugins:
        return None
    first = plugins[0]
    plugin = first.get("name") if isinstance(first, dict) else None
    if not isinstance(plugin, str) or not plugin:
        return None
    return plugin, marketplace


def resolve_names(args, root: Path, script_dir: Path) -> tuple:
    """`(plugin, marketplace, url, names_from, reason)`.

    Order: explicit flags, then the repo's own settings, then the marketplace manifest sitting beside
    this script, then nothing. `reason` explains a `none` — "two plugins are enabled here" is a
    different problem from "this repo declares no plugin", and the fix differs too.
    """
    plugin = marketplace = url = None
    names_from, reason = "none", "no plugin name could be resolved"

    if args.plugin and args.marketplace:
        return args.plugin, args.marketplace, args.url, "flags", ""

    pairs_fn = settings_pairs
    pairs = pairs_fn(_json(root / ".claude" / "settings.json")) if pairs_fn is not None else []
    if len(pairs) == 1:
        plugin, marketplace, url = pairs[0]
        names_from, reason = "settings", ""
    elif len(pairs) > 1:
        reason = ("this repo's .claude/settings.json enables more than one plugin; "
                  "pass --plugin and --marketplace to say which one")
    else:
        found = manifest_pair(script_dir.parent / ".claude-plugin" / "marketplace.json")
        if found:
            plugin, marketplace = found
            names_from, reason = "manifest", ""
        elif pairs_fn is None:
            reason = ("this repo's settings could not be read (update_notice.py is not importable "
                      "beside this script)")
        else:
            reason = ("this repo's .claude/settings.json declares no enabled plugin; "
                      "pass --plugin and --marketplace")

    if args.plugin:
        plugin, names_from = args.plugin, "flags"
    if args.marketplace:
        marketplace, names_from = args.marketplace, "flags"
    if args.url:
        url = args.url

    if not (plugin and marketplace):
        return None, None, url, "none", reason
    return plugin, marketplace, url, names_from, ""


def claude_channel(claude_path: str | None) -> str:
    """`native` | `npm` | `brew` | `unknown` — how this machine's `claude` was installed.

    The channel decides the UPDATE COMMAND, and the wrong one is worse than none: telling an nvm user
    to run `claude update` updates a native install they are not running. The realpath is inspected
    and DISCARDED — it is a filesystem path, and this CLI prints exactly one of those.
    """
    if not claude_path:
        return "unknown"
    try:
        real = os.path.realpath(claude_path)
    except OSError:
        return "unknown"
    if "/.local/share/claude/versions/" in real or real.endswith("/.local/bin/claude"):
        return "native"
    if "node_modules/@anthropic-ai/claude-code" in real or "/.nvm/" in real:
        return "npm"
    if "/Cellar/" in real or "/homebrew/" in real or "/linuxbrew/" in real:
        return "brew"
    return "unknown"


def yq_install_command() -> str:
    # `platform` is read into a local first, deliberately: comparing `sys.platform` directly lets a
    # type checker narrow it to whichever platform IT was run on and call the other two branches
    # dead code. The branches are all live — this string is read by a person on some other machine.
    platform = str(sys.platform)
    if platform == "darwin":
        return "brew install yq"
    if platform.startswith("win"):
        return "winget install MikeFarah.yq"
    return "install yq with your distribution's package manager (apt install yq, dnf install yq, …)"


# ── the checks ────────────────────────────────────────────────────────────────────────────────────
class Doctor:
    """One instance per run. Each `c_<id>` returns `(status, detail, fix_lines)` and may raise."""

    def __init__(self, args) -> None:
        self.args = args
        self.root = _resolve_root(args.root)
        self.config_root = _config_root(args.config_root)
        self.script_dir = Path(__file__).resolve().parent
        self.plugin, self.marketplace, self.url, self.names_from, self.name_reason = resolve_names(
            args, self.root, self.script_dir)
        self.ref = (f"{self.plugin}{PAIR_SEP}{self.marketplace}"
                    if self.plugin and self.marketplace else None)
        self.claude = shutil.which("claude")
        self.channel = claude_channel(self.claude)
        self.results: list = []
        # Filled in by c_repo_install so the payload/catalog checks judge the SAME record.
        self._rows: list = []
        self._matches: list = []
        self._selected: tuple | None = None

    # -- helpers shared by several checks --
    def _reusable(self) -> bool:
        """True when update_notice.py's install selectors are actually importable.

        Asked as "is this specific name bound", not as a flag: the four checks below CALL these, and
        a flag says only that an import once succeeded.
        """
        return _HAVE_UN and None not in (install_rows, repo_install_matches,
                                         select_repo_install, catalog_version, is_newer,
                                         install_pair_command)

    def _no_names(self) -> tuple:
        return "unknown", self.name_reason or "no plugin name could be resolved", [
            "pass --plugin <name> --marketplace <name> (and --url <clone url>) to name the plugin"]

    def _track2(self) -> list:
        ref = self.ref or "<plugin>@<marketplace>"
        url = self.url or "<marketplace clone url>"
        return [f"claude plugin marketplace add {url} --scope project",
                f"claude plugin install {ref} --scope project",
                "run both from the repository root (claude-code#82830 keys a project-scope install "
                "to the session's working directory)",
                "no terminal? in a Claude session run `/plugin install " + ref +
                "` and choose Project scope."]

    def _update_fix(self) -> list:
        return list(UPDATE_COMMANDS.get(self.channel, UPDATE_UNKNOWN))

    # -- 1 --
    def c_git_clone(self) -> tuple:
        if (self.root / ".git").exists():        # a dir normally, a file inside a git worktree
            return "ok", "this repo is a git clone", []
        return ("fail",
                "no .git here — a folder from GitHub's Download ZIP button (named "
                "<repo>-main) cannot branch, commit or open a pull request",
                [f"git clone {self.url or '<repository url>'} and work in the clone instead"])

    # -- 2 --
    def c_cwd_is_root(self) -> tuple:
        rc, out, _ = _run(["git", "rev-parse", "--show-toplevel"])
        if rc != 0 or not out.strip():
            return "unknown", "no git repository at the current working directory", []
        try:
            same = Path(out.strip()).resolve() == Path.cwd().resolve()
        except (OSError, ValueError, RuntimeError):
            same = False
        if same:
            return "ok", "the shell is at the repository root", []
        return ("warn",
                "the shell is inside the repo but not at its root",
                ["cd to the repository root before running any plugin command "
                 "(claude-code#82830 keys a project-scope install to the session's working "
                 "directory, not the repository)"])

    # -- 3 --
    def c_claude_on_path(self) -> tuple:
        if self.claude:
            return "ok", "the `claude` CLI is on PATH", []
        return ("fail",
                "no `claude` on PATH",
                ["install Claude Code (https://code.claude.com/docs/en/setup), then open a new "
                 "terminal",
                 "the in-app route needs no CLI: in a Claude session run `/plugin install "
                 f"{self.ref or '<plugin>@<marketplace>'}` and choose Project scope"])

    # -- 4 --
    def c_claude_version(self) -> tuple:
        if self.args.no_probe:
            return "unknown", "version not read (--no-probe)", []
        if not self.claude:
            return "unknown", "no `claude` on PATH to ask for a version", []
        rc, out, err = _run(["claude", "--version"])
        raw = (out or err).strip().splitlines()
        if rc is None or not raw:
            return "unknown", "`claude --version` produced no answer", []
        version = raw[0].replace("(Claude Code)", "").strip()
        return ("ok",
                f"Claude Code CLI {version} — from {HINT_VERSION} the app itself says when a "
                "declared plugin is not installed; 2.0.x accepts neither `--scope` nor "
                "`plugin list`",
                [])

    # -- 5 --
    def c_scope_supported(self) -> tuple:
        if self.args.no_probe:
            return "unknown", "not probed (--no-probe)", []
        if not self.claude:
            return "unknown", "no `claude` on PATH to probe", []
        # --help ONLY. This never installs anything; an install is the one thing a diagnostic must
        # not do behind someone's back.
        rc, out, err = _run(["claude", "plugin", "install", "--help"])
        if rc is None:
            return "unknown", "`claude plugin install --help` could not run", []
        if "--scope" in (out + err):
            return "ok", "this CLI accepts `--scope`, so it can install into this repo only", []
        return ("fail",
                "this CLI rejects `--scope`, so every install it makes is global (Claude Code "
                "2.0.x)",
                self._update_fix() + [
                    "no terminal, no update: in a Claude session run `/plugin install "
                    f"{self.ref or '<plugin>@<marketplace>'}` and choose Project scope, or use "
                    "+ → Plugins → Add plugin"])

    # -- 6 --
    def c_install_channel(self) -> tuple:
        if not self.claude:
            return "unknown", "no `claude` on PATH to classify", self._update_fix()
        if self.channel == "unknown":
            return ("unknown",
                    "could not tell how this `claude` was installed",
                    self._update_fix())
        labels = {"native": "the native installer", "npm": "npm or nvm", "brew": "Homebrew"}
        return ("ok",
                f"`claude` was installed by {labels[self.channel]}; update it with "
                f"`{UPDATE_COMMANDS[self.channel][0]}`",
                self._update_fix())

    # -- 7 --
    def c_marketplace_registered(self) -> tuple:
        if not self.marketplace:
            return self._no_names()
        data = _json(self.config_root / "plugins" / "known_marketplaces.json")
        entries = data
        if isinstance(data, dict) and isinstance(data.get("marketplaces"), dict):
            entries = data["marketplaces"]
        add = (f"claude plugin marketplace add {self.url or '<marketplace clone url>'} "
               "--scope project")
        if not isinstance(entries, dict) or self.marketplace not in entries:
            return ("fail",
                    f"the `{self.marketplace}` marketplace is not registered on this machine",
                    [add,
                     "\"already installed\" from that command means it IS registered — "
                     "harmless, move on to the install"])
        entry = entries.get(self.marketplace)
        location = entry.get("installLocation") if isinstance(entry, dict) else None
        if isinstance(location, str) and location and Path(location).exists():
            return "ok", f"the `{self.marketplace}` marketplace is registered and cloned", []
        return ("warn",
                f"`{self.marketplace}` is registered but its clone is not on disk",
                [add, "then restart the session so the clone is re-fetched"])

    # -- 8 --
    def c_repo_install(self) -> tuple:
        if not self.ref:
            return self._no_names()
        # Bound to locals first so the "not importable" branch is one the reader AND a type
        # checker can see: these three names are None on the degrade path.
        rows_fn, matches_fn, select_fn = install_rows, repo_install_matches, select_repo_install
        if rows_fn is None or matches_fn is None or select_fn is None:
            return "unknown", "update_notice.py is not importable beside this script", []
        self._rows = rows_fn(self.config_root, self.plugin, self.marketplace)
        self._matches = matches_fn(self._rows, self.root)
        self._selected = select_fn(self._rows, self.root)
        if self._selected:
            version, scope = self._selected
            return ("ok",
                    f"{self.plugin} {version} is installed for this repo at {scope} scope",
                    [])
        if not self._matches:
            return ("fail",
                    f"nothing is installed for this repo — registering a marketplace is not "
                    f"installing a plugin, and a committed enabledPlugins entry does not install "
                    f"`{self.ref}` either",
                    self._track2())
        versions = ", ".join(sorted({str(r.get("version")) for r in self._matches}))
        return ("warn",
                f"{len(self._matches)} install records name this repo (versions: {versions}) "
                "— which one runs is not knowable from here",
                [f"claude plugin uninstall {self.ref} --scope project",
                 f"claude plugin uninstall {self.ref} --scope local",
                 f"then install once: claude plugin install {self.ref} --scope project"])

    # -- 9 --
    def c_install_payload(self) -> tuple:
        if not self.ref:
            return self._no_names()
        if not self._reusable():
            return "unknown", "update_notice.py is not importable beside this script", []
        if len(self._matches) != 1:
            return "unknown", "no single install record to check a payload for", []
        record = self._matches[0]
        location = record.get("installPath")
        scope = record.get("scope") or "project"
        if not isinstance(location, str) or not location:
            return "unknown", "the install record carries no installPath", []
        # PRIVACY: the path is judged, never printed.
        target = Path(location)
        if target.is_dir() and (target / ".claude-plugin" / "plugin.json").is_file():
            return "ok", "the install record points at a real plugin payload", []
        why = ("the install record points at a directory that does not exist"
               if not target.exists() else
               "the install directory carries no .claude-plugin/plugin.json")
        return ("fail",
                f"{why} — the install reported success and wrote nothing (seen on Claude Code "
                "2.0.22)",
                self._update_fix()[:1] + [
                    f"claude plugin uninstall {self.ref} --scope {scope} "
                    f"&& claude plugin install {self.ref} --scope {scope}",
                    # The command shape matters: the installPath usually EXISTS and is merely
                    # empty or partial (that is the state above), and `cp -R src dst` on an
                    # existing dst nests the clone at dst/<name> instead of filling it. Trailing
                    # slashes + rsync copy the CONTENTS. Kept identical to docs/troubleshooting.md.
                    "if uninstall answers \"not found\", copy the marketplace clone's CONTENTS "
                    f"(~/.claude/plugins/marketplaces/{self.marketplace}/) into the installPath the "
                    "record names: mkdir -p \"$DST\" && rsync -a --exclude .git -- \"$SRC\"/ "
                    "\"$DST\"/ — only when that clone is at the same commit as the record and the "
                    "marketplace entry uses \"source\": \"./\"",
                ])

    # -- 10 --
    def c_user_install(self) -> tuple:
        if not self.ref:
            return self._no_names()
        if not self._reusable():
            return "unknown", "update_notice.py is not importable beside this script", []
        globals_ = [r for r in self._rows if isinstance(r, dict) and r.get("scope") == "user"]
        if not globals_:
            return "ok", "no user-scope install (this plugin is not global on this machine)", []
        versions = ", ".join(sorted({str(r.get("version")) for r in globals_}))
        return ("warn",
                f"{self.ref} is also installed at user scope (versions: {versions}) — it "
                "loads in every repo on this machine, which the bare `claude plugin install` "
                "command does by default",
                [f"if you meant this repo only: claude plugin uninstall {self.ref} --scope user"]
                + self._track2()[:2])

    # -- 11 --
    def c_catalog_current(self) -> tuple:
        if not self.ref:
            return self._no_names()
        catalog_fn, newer_fn, pair_fn = catalog_version, is_newer, install_pair_command
        if catalog_fn is None or newer_fn is None or pair_fn is None:
            return "unknown", "update_notice.py is not importable beside this script", []
        if not self._selected:
            return "unknown", "no single install record to compare against the catalog", []
        installed, scope = self._selected
        catalog = catalog_fn(self.config_root, self.plugin, self.marketplace)
        if not catalog:
            return "unknown", "the cached marketplace advertises no comparable version", []
        if newer_fn(catalog, installed):
            return ("warn",
                    f"{self.plugin} {catalog} is in the marketplace catalog; this repo runs "
                    f"{installed}",
                    [pair_fn(self.ref, scope)])
        return "ok", f"this repo runs {installed}; the catalog offers {catalog}", []

    # -- 12 --
    def c_yq_present(self) -> tuple:
        if shutil.which("yq"):
            return "ok", "yq is on PATH", []
        return ("warn",
                "yq is missing — needed only by bin/selftest.sh, which reports many unrelated "
                "failures from this one cause",
                [yq_install_command()])

    # -- 13 --
    def c_git_identity(self) -> tuple:
        missing = []
        for key in ("user.name", "user.email"):
            rc, out, _ = _run(["git", "config", "--get", key])
            if rc != 0 or not out.strip():
                missing.append(key)
        if not missing:
            return "ok", "git user.name and user.email are set", []
        return ("warn",
                "git identity is unset (" + ", ".join(missing) + ") — commits will be "
                "rejected or misattributed",
                ["git config --global user.name \"Your Name\"",
                 "git config --global user.email \"you@example.com\""])

    # -- 14 --
    def c_restart(self) -> tuple:
        # THE one carrier of RESTART_ADVISORY. Every check whose remedy changes what is installed
        # used to append the advisory to its own fix list, so a single broken install printed the
        # same four sentences three times and the reader skimmed past all three. The advisory is
        # said once, by this check, which watches every state whose fix ends in a reload.
        watched = {r["id"]: r["status"] for r in self.results
                   if r["id"] in ("repo_install", "install_payload", "user_install",
                                  "catalog_current")}
        if watched and any(s != "ok" for s in watched.values()):
            return ("warn",
                    "the install state above changes only after Claude Code reloads",
                    [RESTART_ADVISORY])
        return "ok", "nothing above needs a restart to take effect", []

    # -- driver --
    def run(self) -> list:
        for cid in CHECK_IDS:
            fn = getattr(self, "c_" + cid)
            try:
                status, detail, fix = fn()
            except Exception as exc:            # noqa: BLE001 — never a traceback, ever
                status, detail, fix = "unknown", f"the check raised {type(exc).__name__}", []
            if status not in SYMBOL:
                status = "unknown"
            self.results.append({"id": cid, "status": status,
                                 "detail": str(detail), "fix": [str(f) for f in fix]})
        return self.results


def render_human(doc: Doctor, results: list) -> str:
    lines = ["plugin_doctor · {} · names from {} · {}".format(
        doc.ref or "plugin unknown", doc.names_from, doc.root), ""]
    for res in results:
        lines.append("{}  {}  {}".format(SYMBOL[res["status"]], res["id"], res["detail"]))
        # `restart`'s fix IS the footer below — printing it in both places is the duplication this
        # render deliberately avoids. The fix list still carries it for `--json`, which has no
        # footer and whose consumer (/setup) reports each non-ok finding's fix verbatim.
        if res["status"] != "ok" and res["id"] != "restart":
            for fix in res["fix"]:
                lines.append("     → fix: {}".format(fix))
    counts = summarize(results)
    lines.append("")
    lines.append("plugin_doctor: {ok} ok · {warn} warn · {fail} fail · "
                 "{unknown} unknown".format(**counts))
    restart = next((r for r in results if r["id"] == "restart"), None)
    if restart and restart["status"] != "ok":
        lines.append("")
        lines.append(RESTART_ADVISORY)
    return "\n".join(lines)


def summarize(results: list) -> dict:
    counts = {"ok": 0, "warn": 0, "fail": 0, "unknown": 0}
    for res in results:
        counts[res["status"]] += 1
    return counts


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="plugin_doctor.py",
        description="Name every state a plugin install can be in, and say how to leave it.")
    ap.add_argument("--root", help="the repo (default: $TICKETWRIGHT_PROJECT, git toplevel, cwd)")
    ap.add_argument("--config-root", help="Claude config dir (default: $CLAUDE_CONFIG_DIR, ~/.claude)")
    ap.add_argument("--plugin", help="plugin name (default: read from the repo settings/manifest)")
    ap.add_argument("--marketplace", help="marketplace name (default: the same)")
    ap.add_argument("--url", help="the marketplace clone URL used in the fix commands")
    ap.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    ap.add_argument("--no-probe", action="store_true",
                    help="skip the two read-only `claude` subprocesses")
    args = ap.parse_args(argv)      # a usage error exits 2, which is this CLI's usage contract

    try:
        doc = Doctor(args)
        results = doc.run()
        if args.json:
            print(json.dumps({"schema": SCHEMA, "root": str(doc.root), "plugin": doc.plugin,
                              "marketplace": doc.marketplace, "names_from": doc.names_from,
                              "checks": results, "summary": summarize(results)}, indent=2))
        else:
            print(render_human(doc, results))
        return 1 if summarize(results)["fail"] else 0
    except Exception as exc:        # noqa: BLE001 — a diagnostic may not be the thing that crashes
        sys.stderr.write("plugin_doctor: could not complete ({})\n".format(type(exc).__name__))
        return 1


if __name__ == "__main__":
    sys.exit(main())
