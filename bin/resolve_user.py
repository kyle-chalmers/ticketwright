#!/usr/bin/env python3
"""resolve_user.py — map the current machine identity to a voice-profile id.

Answers one question for the comms skills: *who is shipping this?* — so `/ship` can load the
right person's `voices/<id>.md` and the chat adapter can resolve a `{self}` mention. The map from
identity → profile id is **explicit** and lives in `stack.yaml` under `project.voice_profiles.map`;
this script never guesses (a fuzzy git-name → folder normalization is exactly the wrong-profile
footgun the design avoids).

Resolution order of local identities (first that hits the map wins):
  git config user.email  →  git config user.name  →  $USER

Both `stack.yaml` and `git config` are read from the **project root** (`CLAUDE_PROJECT_DIR`, else the
nearest ancestor holding `.claude/config/stack.yaml`), so a plugin install — where this script lives
in the plugin dir but the repo is elsewhere — still reads the shipper's own repo, not wherever the
process happened to start.

Stdlib only. **Offline only** — reads local `git config` and `$USER`; no network, no tracker call
(tracker enrichment happens once in `/setup --voice`, written into the profile frontmatter). Fails
open: an unconfigured feature, a missing map, or an identity miss all print nothing and exit 0, so a
caller can treat empty output as "no voice profile — behave as today."

Usage:
  python3 bin/resolve_user.py            # prints the resolved profile id (empty on miss)
  python3 bin/resolve_user.py --path     # prints the profile file path (path template applied)
  python3 bin/resolve_user.py --field id|path|identity
  python3 bin/resolve_user.py --json     # {"id":…, "path":…, "identity":…} (only when resolved)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_PATH_TEMPLATE = "voices/{profile_id}.md"


def project_root() -> Path:
    """The *consuming* repo (holds .claude/config/stack.yaml) — not the plugin dir."""
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return Path(env)
    here = Path.cwd()
    for cand in (here, *here.parents):
        if (cand / ".claude/config/stack.yaml").is_file():
            return cand
    return here


def _git_config(key: str, cwd: Path) -> str:
    try:
        out = subprocess.run(
            ["git", "config", "--get", key],
            capture_output=True, text=True, timeout=3, cwd=str(cwd),
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def local_identities(root: Path) -> list[str]:
    """Ordered, de-duplicated identity candidates — most specific first, read from `root`."""
    cands = [_git_config("user.email", root), _git_config("user.name", root), os.environ.get("USER", "")]
    seen: set[str] = set()
    out: list[str] = []
    for c in cands:
        c = c.strip()
        key = c.lower()
        if c and key not in seen:
            seen.add(key)
            out.append(c)
    return out


def voice_config(stack_text: str) -> tuple[str, dict[str, str]]:
    """Extract (path_template, identity→id map) from the `project.voice_profiles` block.

    Line/indent based (not one greedy regex) so a `path:` that appears *after* `map:` is treated as
    a sibling key, never swallowed as a bogus map entry. Stdlib only — the kit avoids a YAML
    dependency (matching session_context.py). Returns ("", {}) when the block is absent or commented
    out, which the caller treats as feature-off.
    """
    lines = stack_text.splitlines()
    VP_INDENT = 2  # voice_profiles is a direct child of `project:`
    start = None
    for i, ln in enumerate(lines):
        m = re.match(r"^(\ *)voice_profiles:\s*(#.*)?$", ln)
        if m and len(m.group(1)) == VP_INDENT:
            start = i
            break
    if start is None:
        return "", {}

    path_template = DEFAULT_PATH_TEMPLATE
    mapping: dict[str, str] = {}
    map_indent: int | None = None
    for ln in lines[start + 1:]:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        if indent <= VP_INDENT:
            break  # dedented out of the voice_profiles block
        if map_indent is not None and indent > map_indent:
            entry = re.match(r"^\s*[\"']?([^\"'#][^\"':]*?)[\"']?\s*:\s*[\"']?([A-Za-z0-9_.-]+)", ln)
            if entry:
                mapping[entry.group(1).strip().lower()] = entry.group(2).strip()
            continue
        # a direct child of voice_profiles (path: / map:) — we've left any prior map body
        map_indent = None
        pm = re.match(r"^\s*path:\s*[\"']?([^\"'#\n]+?)[\"']?\s*(?:#.*)?$", ln)
        if pm:
            path_template = pm.group(1).strip()
            continue
        mk = re.match(r"^(\s*)map:\s*(#.*)?$", ln)
        if mk:
            map_indent = len(mk.group(1))
    return path_template, mapping


def resolve(root: Path) -> dict | None:
    stack = root / ".claude/config/stack.yaml"
    if not stack.is_file():
        return None
    try:
        text = stack.read_text(errors="replace")
    except OSError:
        return None
    path_template, mapping = voice_config(text)
    if not mapping:
        return None
    for ident in local_identities(root):
        pid = mapping.get(ident.lower())
        if pid:
            return {
                "id": pid,
                "path": path_template.replace("{profile_id}", pid),
                "identity": ident,
            }
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Resolve the current user's voice-profile id (fail-open).")
    ap.add_argument("--field", choices=["id", "path", "identity"], default="id",
                    help="id (default), path (path template applied), or identity (the matched local id)")
    ap.add_argument("--path", action="store_true", help="shorthand for --field path")
    ap.add_argument("--json", action="store_true", help="emit the full resolution as JSON")
    args = ap.parse_args(argv)

    res = resolve(project_root())
    if res is None:
        return 0  # fail open — nothing to say

    if args.json:
        print(json.dumps(res))
        return 0
    field = "path" if args.path else args.field
    print(res.get(field, ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
