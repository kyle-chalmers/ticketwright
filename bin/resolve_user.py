#!/usr/bin/env python3
"""resolve_user.py — THIN SHIM: map the resolved person to a voice-profile id.

Identity resolution lives in ONE place: `bin/whoami.py` (tier-3 `person:` → `$TICKETWRIGHT_PERSON`
→ the enumerated identity map; statuses resolved/miss/ambiguous/conflict, never a guess). This
script asks it who the person is and answers the only question the comms skills have: *which voice
profile is theirs?* — so `/ship` can load the right person's `voices/<id>.md` and the chat adapter
can resolve a `{self}` mention. It keeps existing callers working while they migrate to calling
`whoami.py` directly, and is scheduled for deletion in a later release once `/ship` has moved.

THE VOICE MAP: a person's `people/<id>.yaml` carries an optional `voice:` block (`profile_id`,
`path`). The path template is resolved PER PERSON — one person's custom `voice.path` must never
leak to a teammate (a single template held across a scan once resolved Alice to Bob's profile
file, silently). The legacy `project.voice_profiles` block in `stack.yaml` is STILL READ as a
fallback whenever the person has no tier-2 voice block (or nothing resolves at all), with a
one-time TTY-gated warning on stderr: a repo with a working committed map must not lose voice
resolution the moment it upgrades. This fallback is now PER PERSON too — previously any tier-2
voice mapping existing for anyone switched the legacy map off for everyone.

`voices/<id>.md` is unchanged — a RENDERED MARKDOWN writing-style profile referenced from
`people/<id>.yaml`. It does not become YAML.

Stdlib only. **Offline only** — no network, no tracker call. Fails open: an unconfigured feature,
a missing map, an identity miss, and an AMBIGUOUS identity (whoami refuses to pick, so does this)
all print nothing and exit 0, so a caller can treat empty output as "no voice profile — behave as
today."

Usage:
  python3 bin/resolve_user.py            # prints the resolved profile id (empty on miss)
  python3 bin/resolve_user.py --path     # prints the profile file path (path template applied)
  python3 bin/resolve_user.py --field id|path|identity
  python3 bin/resolve_user.py --json     # {"id":…, "path":…, "identity":…} (only when resolved)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import whoami  # noqa: E402 — the kit's single identity resolver; this shim only maps to a voice
from _yamlite import config_trace  # noqa: E402

# Re-exported for callers that imported these from here before the whoami split.
project_root = whoami.project_root
local_identities = whoami.local_identities

DEFAULT_PATH_TEMPLATE = "voices/{profile_id}.md"


def voice_config(stack_text: str) -> tuple[str, dict[str, str]]:
    """Extract (path_template, identity→id map) from the LEGACY `project.voice_profiles` block.

    Line/indent based (not one greedy regex) so a `path:` that appears *after* `map:` is treated as
    a sibling key, never swallowed as a bogus map entry. Returns ("", {}) when the block is absent
    or commented out, which the caller treats as feature-off.
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


def _person_voice(root: Path, pid: str) -> tuple[str, str] | None:
    """(profile_id, path_template) from THIS person's tier-2 `voice:` block, or None.

    Read through whoami's two-home merge, so the template is the person's own — never a value
    left over from scanning someone else's file.
    """
    person = whoami.load_people(root).get(pid) or {}
    voice = person.get("voice") if isinstance(person.get("voice"), dict) else {}
    if not voice:
        return None  # no voice block = this person has not opted in
    profile_id = str(voice.get("profile_id") or pid).strip()
    template = str(voice.get("path") or DEFAULT_PATH_TEMPLATE).strip()
    return profile_id, template


def _legacy_voice(root: Path) -> tuple[str, str, str] | None:
    """(profile_id, path_template, identity) from the legacy stack.yaml map, or None."""
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
    for ident in whoami.local_identities(root):
        pid = mapping.get(ident.lower())
        if pid:
            return pid, path_template, ident
    return None


def resolve(root: Path) -> dict | None:
    """whoami first, then the legacy tier-1 block. Fails open: None means "behave as today"."""
    config_trace(root, "resolve_user")
    who = whoami.resolve(root)

    if who["status"] in ("resolved", "conflict"):
        hit = _person_voice(root, who["id"])
        if hit:
            pid, path_template = hit
            return {
                "id": pid,
                "path": path_template.replace("{profile_id}", pid),
                "identity": who.get("identity") or "",
            }
    if who["status"] == "ambiguous":
        return None  # whoami refuses to pick between two people; a voice pass must not either

    legacy = _legacy_voice(root)
    if legacy is None:
        return None
    pid, path_template, ident = legacy
    if sys.stderr.isatty():
        # Warn on stderr, never stdout: callers read stdout as the answer, and a warning there
        # would look like a profile id.
        #
        # TTY-gated on purpose. This resolver is invoked by hooks, the statusline and /ship,
        # several times per session — an unconditional warning printed into the stderr of every
        # one of those, including unrelated commands that merely started a shell. The durable
        # channel for this is `effective_config.py --lint`, which surfaces it once per verify run
        # where config problems are supposed to appear.
        print("resolve_user: using the legacy `project.voice_profiles` map in stack.yaml. "
              "That map holds personal identities in committed team config — move it to "
              "people/<id>.yaml (see templates/person.yaml.tmpl).", file=sys.stderr)
    return {"id": pid, "path": path_template.replace("{profile_id}", pid), "identity": ident}


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
