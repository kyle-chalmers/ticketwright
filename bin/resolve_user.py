#!/usr/bin/env python3
"""resolve_user.py — map the current machine identity to a voice-profile id.

Answers one question for the comms skills: *who is shipping this?* — so `/ship` can load the
right person's `voices/<id>.md` and the chat adapter can resolve a `{self}` mention. The map from
identity → profile id is **explicit** and enumerated per person; this script never guesses (a fuzzy git-name → folder normalization is exactly the wrong-profile
footgun the design avoids).

THE MAP MOVED. It now lives in TIER 2 — `people/<id>.yaml`, one file per person, under
`identities:` — because a person's work email and display name are person data, not team data, and
`stack.yaml` is committed team config. The legacy `project.voice_profiles` block in `stack.yaml` is
STILL READ as a fallback, with a one-time warning on stderr: a repo with a working committed map
must not lose voice resolution the moment it upgrades. stdout stays clean either way, so a caller
can still treat empty output as "no voice profile".

`voices/<id>.md` is unchanged — a RENDERED MARKDOWN writing-style profile referenced from
`people/<id>.yaml`. It does not become YAML.

Resolution order of local identities (first that hits the map wins):
  git config user.email  →  git config user.name  →  $USER

Both the config and `git config` are read from the **project root** (`CLAUDE_PROJECT_DIR`, else the
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

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _yamlite import YamliteError, config_trace, parse_file  # noqa: E402

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



def _people_dirs(root: Path) -> list[Path]:
    """Tier-2 homes, cross-repo FIRST so the in-repo copy wins.

    The cross-repo copy is the whole point of "portable": someone whose profile lives only in
    `$XDG_CONFIG_HOME/ticketwright/people/` must still resolve, or the tier is portable in name only.
    """
    xdg = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ticketwright"
    return [xdg / "people", root / "people"]


def people_config(root: Path) -> dict[str, tuple[str, str]]:
    """identity → (profile_id, path_template), from TIER 2.

    The template is PER PERSON, not global. Holding one template while iterating every file meant a
    person with no custom `voice.path` inherited whichever custom path happened to be read last —
    Alice resolving to Bob's profile file, silently, which is exactly the wrong-profile footgun this
    resolver exists to avoid.

    Every identity is ENUMERATED in the person's own file; nothing is inferred from a name. A file
    that fails to parse is skipped rather than fatal — one malformed teammate file must not stop
    everyone else resolving.
    """
    mapping: dict[str, tuple[str, str]] = {}
    for people in _people_dirs(root):
        if not people.is_dir():
            continue
        for path in sorted(people.glob("*.yaml")):
            try:
                data = parse_file(path)
            except (YamliteError, OSError):
                continue
            if not isinstance(data, dict):
                continue
            voice = data.get("voice") if isinstance(data.get("voice"), dict) else {}
            if not voice:
                continue                      # no voice block = this person has not opted in
            profile_id = str(voice.get("profile_id") or path.stem).strip()
            template = str(voice.get("path") or DEFAULT_PATH_TEMPLATE).strip()
            for ident in (data.get("identities") or []):
                text = str(ident).strip()
                if text:
                    mapping[text.lower()] = (profile_id, template)   # later dir wins: in-repo
    return mapping


def resolve(root: Path) -> dict | None:
    """Tier 2 first, then the legacy tier-1 block. Fails open: None means "behave as today"."""
    config_trace(root, "resolve_user")
    mapping = people_config(root)
    legacy = False

    if not mapping:
        stack = root / ".claude/config/stack.yaml"
        if not stack.is_file():
            return None
        try:
            text = stack.read_text(errors="replace")
        except OSError:
            return None
        path_template, legacy_map = voice_config(text)
        mapping = {k: (v, path_template) for k, v in legacy_map.items()}
        legacy = bool(mapping)
    if not mapping:
        return None

    for ident in local_identities(root):
        hit = mapping.get(ident.lower())
        if hit:
            pid, path_template = hit
            if legacy and sys.stderr.isatty():
                # Warn on stderr, never stdout: callers read stdout as the answer, and a warning
                # there would look like a profile id.
                #
                # TTY-gated on purpose. This resolver is invoked by hooks, the statusline and /ship,
                # several times per session — an unconditional warning printed into the stderr of
                # every one of those, including unrelated commands that merely started a shell.
                # The durable channel for this is `effective_config.py --lint`, which surfaces it
                # once per verify run where config problems are supposed to appear.
                print("resolve_user: using the legacy `project.voice_profiles` map in stack.yaml. "
                      "That map holds personal identities in committed team config — move it to "
                      "people/<id>.yaml (see templates/person.yaml.tmpl).", file=sys.stderr)
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
