#!/usr/bin/env python3
"""setup_detect.py: what /setup's first phase needs to know about this machine, as one read-only probe.

Detection used to be shell the agent improvised from a list in the skill. On a fresh Mac that went
wrong twice: a `timeout` wrapper (not shipped on macOS) silently ran nothing, and "no synced drive
folder" was reported without anything having looked. This script is the one place those facts come
from, so every runtime gets the same answers (AGENTS.md tiebreaker 5: logic lives in bin/).

WHAT IT REPORTS (all of it local, names and paths only):
  git          is this a repo, the branch, the origin HOST (never the full URL), the default branch,
               whether a git name and email are set (booleans: whoami reports identities itself)
  clis         which data/tracker/VCS command-line tools are on PATH
  mounts       cloud-drive sync folders (Google Drive, OneDrive, Dropbox, Box): the folder NAME and
               path of each mount root. Never the contents: listing what is inside someone's drive
               is a question for the person, not something a probe does
  obsidian     installed or not
  analysis     analysis apps and CLIs found on this machine. Context for the setup report only:
               setup no longer asks which tools the team analyzes with (team docs replaced it)

WHAT IT NEVER DOES: no network call, no credential read, no tool login, no file contents. MCP
connectors are invisible to a shell; the agent reports those itself.

Usage:
  python3 bin/setup_detect.py [--root <dir>] [--json]
Exit: 0 always for a completed probe (absence is a finding, not an error) · 2 usage.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

CLIS = ("git", "gh", "glab", "az", "acli", "snow", "bq", "gcloud", "databricks", "psql",
        "rclone", "yq", "jq", "dbt", "duckdb", "python3", "R", "jupyter")

# App name → how it is spelled on disk. Matching is on the application bundle / executable name,
# so a hit means "installed here", never "the team uses it".
APPS_MAC = {
    "Tableau": "Tableau", "Power BI": "Power BI", "Excel": "Microsoft Excel",
    "Google Sheets": "Google Sheets", "Numbers": "Numbers", "DataGrip": "DataGrip",
    "DBeaver": "DBeaver", "VS Code": "Visual Studio Code", "Cursor": "Cursor",
    "Positron": "Positron", "RStudio": "RStudio", "Jupyter": "Jupyter", "Hex": "Hex",
}
APP_CLIS = {"dbt": "dbt", "DuckDB": "duckdb", "Python": "python3", "R": "R", "Jupyter": "jupyter",
            "VS Code": "code", "Cursor": "cursor"}

MOUNT_PROVIDERS = (("GoogleDrive", "Google Drive"), ("OneDrive", "OneDrive"),
                   ("Dropbox", "Dropbox"), ("Box", "Box"))


def _git(args: list[str], cwd: Path) -> str | None:
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def _host(url: str) -> str:
    """The host of a remote URL, never the path (which can name a private org or repo)."""
    u = url.strip()
    if "://" in u:
        u = u.split("://", 1)[1]
        u = u.split("@", 1)[-1]
        return u.split("/", 1)[0].split(":", 1)[0].lower()
    if "@" in u and ":" in u:                       # scp-style git@host:org/repo
        return u.split("@", 1)[1].split(":", 1)[0].lower()
    return ""


def git_facts(root: Path) -> dict:
    top = _git(["rev-parse", "--show-toplevel"], root)
    facts: dict = {"repo": bool(top), "branch": None, "origin_host": None,
                   "origin_public_host": False, "default_branch": None,
                   "default_branch_source": None, "name_set": False, "email_set": False}
    facts["name_set"] = bool(_git(["config", "user.name"], root))
    facts["email_set"] = bool(_git(["config", "user.email"], root))
    if not top:
        return facts
    facts["branch"] = _git(["symbolic-ref", "--short", "HEAD"], root)
    origin = _git(["remote", "get-url", "origin"], root)
    if origin:
        host = _host(origin)
        facts["origin_host"] = host or None
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from whoami import PUBLIC_HOSTS            # one heuristic, shared with whoami --bind
        except Exception:                               # pragma: no cover - fail open to "unknown"
            PUBLIC_HOSTS = set()
        facts["origin_public_host"] = host in PUBLIC_HOSTS
    head = _git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], root)
    if head:
        facts["default_branch"] = head.split("/", 1)[-1]
        facts["default_branch_source"] = "origin"
    elif facts["branch"]:
        # Nothing pushed yet: the probe above exits 128. The current branch is the honest guess,
        # and it is labeled as such so setup confirms it instead of stating it.
        facts["default_branch"] = facts["branch"]
        facts["default_branch_source"] = "current branch (nothing pushed yet)"
    return facts


def _subdirs(path: Path, pattern: str = "*") -> list[Path]:
    """Directories directly under `path`, or none when it cannot be read (privacy controls,
    permissions, a vanished mount). A probe that crashes reports nothing; one that skips an
    unreadable folder still reports the rest."""
    try:
        return sorted(p for p in path.glob(pattern) if _is_dir(p))
    except OSError:
        return []


def _is_dir(path: Path) -> bool:
    try:
        return path.is_dir()
    except OSError:
        return False


def mount_roots() -> list[dict]:
    try:
        home = Path.home()
    except (RuntimeError, KeyError, OSError):      # no resolvable home directory
        return []
    found: list[dict] = []
    system = platform.system()
    candidates: list[Path] = []
    if system == "Darwin":
        candidates += _subdirs(home / "Library" / "CloudStorage")
        candidates += _subdirs(Path("/Volumes"), "GoogleDrive*")
        candidates += [home / "Dropbox"]
    elif system == "Windows":
        candidates += [home / "Google Drive", home / "My Drive", home / "Dropbox", home / "Box"]
        candidates += _subdirs(home, "OneDrive*")
        candidates += [Path(f"{d}:\\My Drive") for d in "GHIJ"]
    else:
        candidates += [home / "GoogleDrive", home / "google-drive", home / "Dropbox",
                       home / "OneDrive"]
    seen = set()
    for p in candidates:
        if p in seen or not _is_dir(p):
            continue
        seen.add(p)
        provider = next((label for key, label in MOUNT_PROVIDERS if key.lower() in p.name.lower()),
                        "Google Drive" if "drive" in p.name.lower() else "other")
        found.append({"provider": provider, "name": p.name, "path": str(p)})
    return found


def obsidian_installed() -> bool:
    if shutil.which("obsidian"):
        return True
    if platform.system() == "Darwin":
        try:
            return Path("/Applications/Obsidian.app").exists() or (Path.home() / "Applications/Obsidian.app").exists()
        except (RuntimeError, KeyError, OSError):
            return False
    if platform.system() == "Windows":
        local = os.environ.get("LOCALAPPDATA", "")
        return bool(local) and (Path(local) / "Obsidian").exists()
    return False


def analysis_candidates() -> list[str]:
    hits: set[str] = set()
    if platform.system() == "Darwin":
        roots = [Path("/Applications")]
        try:
            roots.append(Path.home() / "Applications")
        except (RuntimeError, KeyError, OSError):
            pass
        names = []
        for r in roots:
            try:
                names += [p.name for p in r.iterdir() if p.suffix == ".app"]
            except OSError:
                pass
        for label, needle in APPS_MAC.items():
            if any(n.lower().startswith(needle.lower()) for n in names):
                hits.add(label)
    for label, exe in APP_CLIS.items():
        if shutil.which(exe):
            hits.add(label)
    return sorted(hits)


def detect(root: Path) -> dict:
    return {
        "schema": 1,
        "os": platform.system(),
        "git": git_facts(root),
        "clis": {c: bool(shutil.which(c)) for c in CLIS},
        "mounts": mount_roots(),
        "obsidian": obsidian_installed(),
        "analysis": analysis_candidates(),
        "not_visible_here": "MCP connectors: the agent lists the ones connected in its session",
    }


def render(d: dict) -> str:
    g = d["git"]
    lines = []
    if g["repo"]:
        origin = g["origin_host"] or "no remote yet"
        lines.append(f"git: a repository on branch {g['branch'] or '?'} ({origin}); "
                     f"default branch {g['default_branch'] or '?'} ({g['default_branch_source'] or '?'})")
    else:
        lines.append("git: this folder is not a git repository yet")
    lines.append(f"git identity: name {'set' if g['name_set'] else 'not set'}, "
                 f"email {'set' if g['email_set'] else 'not set'}")
    have = [c for c, ok in d["clis"].items() if ok]
    lines.append("command-line tools: " + (", ".join(have) if have else "none of the known ones"))
    if d["mounts"]:
        lines.append("synced drive folders: " + "; ".join(f"{m['provider']} at {m['path']}" for m in d["mounts"]))
    else:
        lines.append("synced drive folders: none found in the usual places")
    lines.append(f"obsidian: {'installed' if d['obsidian'] else 'not found'}")
    lines.append("analysis tools on this machine: " + (", ".join(d["analysis"]) or "none recognized"))
    lines.append("not visible from a shell: " + d["not_visible_here"])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Read-only machine probe for /setup.")
    ap.add_argument("--root", default=".", help="folder to probe (default: current directory)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    if not root.is_dir():
        print(f"setup_detect: no such folder: {root}", file=sys.stderr)
        return 2
    d = detect(root)
    print(json.dumps(d, indent=2) if a.json else render(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
