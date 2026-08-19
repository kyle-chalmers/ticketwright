#!/usr/bin/env python3
"""whoami.py — resolve WHO is working, as a harness-neutral command. Never guesses.

Owner routing (which `tickets/<owner>/` folder new work lands in, whose voice `/ship` drafts in,
which tier-2 person file supplies preferences) all hangs on one question: who is at the keyboard?
This is the kit's SINGLE identity resolver. `bin/resolve_user.py` is a thin voice-mapping shim over
it, and `bin/effective_config.py` asks it who the person is — two independent resolvers is the
thing that must not happen.

RESOLUTION ORDER (first hit wins; every match exact after trimming + case-folding — the only
normalization permitted, because neither can produce a wrong person):
  1. `person: <id>` in tier 3 (`.claude/config/connections.local.yaml`, gitignored) — an explicit
     self-declaration on THIS machine, so a shared or oddly configured box is a one-time fix and
     git config never has to be right.
  2. `$TICKETWRIGHT_PERSON` — CI and headless.
  3. The identity map: `git config user.email` → `git config user.name` → `$USER`, matched against
     the identities ENUMERATED in `people/<id>.yaml` (both tier-2 homes; the in-repo file overrides
     the cross-repo copy key by key). Nothing is inferred from a name — a fuzzy guess silently
     misfiles work or drafts comms in the wrong person's voice.
  4. Nothing → status `miss`. The host agent runs the self-healing interview and calls `--bind`.
     NEVER a fallback to `project.assignee_dir`: silently filing a new teammate's work under
     whoever set the repo up is the failure mode hardest to notice.

STATUSES:
  resolved   one owner, unambiguously.
  conflict   tier 3 names one person but the git identity maps to another. Tier 3 still WINS
             (first-hit-wins is not weakened), with a one-line warning naming both — usually a
             shared machine or a stale repo-local git config, and it must surface before work
             lands in a colleague's folder.
  ambiguous  one identity is enumerated by two people. ASK — never rank or pick (the same
             discipline bin/recall.py applies to duplicate seed ids).
  miss       no owner. Non-interactive callers resolve to NO owner, never a guess.

SELF-HEALING (`--bind <id>`): the separate mutation verb the host agent calls after asking
"I don't recognize <identity>. Who are you?" — the person's own answer is authority; that is
asking, not guessing. It pins `person: <id>` in tier 3 FIRST (gitignored — fixes this machine
with zero disclosure), then appends the identity to `people/<id>.yaml` (in-repo — identities are
committed by default; these are private analysis repos), so the next session resolves exactly,
forever. A person may bind to their OWN file only: binding while already resolved as someone else
requires `--confirm-cross-person`, and the refusal names both people. An identity that already
maps to a DIFFERENT person is never appended (it could only create ambiguity) — the pin alone
fixes this machine. On concurrent edits the file is re-read immediately before writing, and the
identity is appended rather than the file rewritten; a valid append is never rolled back for an
unrelated later failure, because discarding the person's own answer would be worse.

PRIVACY: when the identity to bind is email-shaped and the repo's `origin` remote is on a public
code host, `--bind` warns once per run and the offer is real — a DERIVED email is never written
(pin only, with instructions to re-run using `--identity <handle-or-$USER>`, or `--identity
<email>` to commit it deliberately); an explicit `--identity` email is honored, still warned.

Stdlib only. Offline: reads local git config and the environment — no network, no credentials.
`--root <repo>` is the only location input; no Claude environment variable is required
(`CLAUDE_PROJECT_DIR` is honored as a default root, nothing more).

Usage:
  python3 bin/whoami.py [--root <repo>]              # the one-line "Working as …" display
  python3 bin/whoami.py --json                       # full result: status, id, display_name, …
  python3 bin/whoami.py --field id|status|display_name|identity|source
  python3 bin/whoami.py --bind <id> [--identity <value>] [--confirm-cross-person]

Exit codes: 0 resolved/conflict · 1 write error · 2 usage · 3 miss · 4 ambiguous · 5 bind refused.
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

LOCAL_REL = ".claude/config/connections.local.yaml"

EXIT_OK, EXIT_WRITE, EXIT_USAGE, EXIT_MISS, EXIT_AMBIGUOUS, EXIT_REFUSED = 0, 1, 2, 3, 4, 5

_UNSET = object()

# Hosts where a remote commonly means a PUBLIC repo. Offline heuristic: visibility cannot be
# checked without a network call, so the warning says "if this repo is public", not "it is".
PUBLIC_HOSTS = {"github.com", "gitlab.com", "bitbucket.org", "codeberg.org"}


# ── locating things ────────────────────────────────────────────────────────────────────────────
def project_root() -> Path:
    """The *consuming* repo (holds .claude/config/stack.yaml) — not the kit/plugin dir."""
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return Path(env)
    here = Path.cwd()
    for cand in (here, *here.parents):
        if (cand / ".claude/config/stack.yaml").is_file():
            return cand
    return here


def people_dirs(root: Path) -> list[Path]:
    """Tier-2 homes, cross-repo first so the in-repo copy wins the key-by-key merge."""
    xdg = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ticketwright"
    return [xdg / "people", root / "people"]


# ── reading identities ─────────────────────────────────────────────────────────────────────────
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
    """Ordered, de-duplicated identity candidates — most specific first, read from `root` (a
    plugin install runs this script from the plugin dir, but the shipper's repo is `root`)."""
    cands = [_git_config("user.email", root), _git_config("user.name", root),
             os.environ.get("USER", "")]
    seen: set[str] = set()
    out: list[str] = []
    for c in cands:
        c = c.strip()
        key = c.lower()
        if c and key not in seen:
            seen.add(key)
            out.append(c)
    return out


def _deep_merge(base: dict, over: dict) -> dict:
    """Key-by-key merge between the two tier-2 homes — the same rule bin/effective_config.py
    applies. A list is a LEAF: an in-repo `identities:` REPLACES the cross-repo one, so a person
    can retire a stale or colliding identity in one repo without editing their portable copy."""
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_people(root: Path) -> dict[str, dict]:
    """id → merged person dict, across both tier-2 homes (in-repo overrides key by key).

    A file that fails to parse is skipped rather than fatal — one malformed teammate file must not
    stop everyone else resolving.
    """
    people: dict[str, dict] = {}
    for home in people_dirs(root):
        if not home.is_dir():
            continue
        for path in sorted(home.glob("*.yaml")):
            try:
                data = parse_file(path)
            except (YamliteError, OSError):
                continue
            if not isinstance(data, dict):
                continue
            people[path.stem] = _deep_merge(people.get(path.stem, {}), data)
    return people


def identity_index(people: dict[str, dict]) -> dict[str, set[str]]:
    """lower(identity) → the set of person ids enumerating it. A set of 2+ is an ambiguity."""
    index: dict[str, set[str]] = {}
    for pid, data in people.items():
        for ident in (data.get("identities") or []):
            text = str(ident).strip()
            if text:
                index.setdefault(text.lower(), set()).add(pid)
    return index


def _match(root: Path, index: dict[str, set[str]]) -> tuple[str | None, list[str]]:
    """(matched identity, sorted person ids) for the FIRST local identity with any hit.

    Deliberately no fall-through past an ambiguous hit: resolving via a weaker identity after the
    strong one matched two people would be ranking by the back door.
    """
    for ident in local_identities(root):
        ids = index.get(ident.lower())
        if ids:
            return ident, sorted(ids)
    return None, []


def _display_name(people: dict[str, dict], pid: str) -> str:
    data = people.get(pid) or {}
    return str(data.get("display_name") or data.get("name") or pid).strip() or pid


def _display_line(name: str, pid: str) -> str:
    return (f"Working as {name} ({pid}) — new analyses go in tickets/{pid}/ "
            f"unless told otherwise.")


def _load_tier3(root: Path) -> dict | None:
    path = root / LOCAL_REL
    if not path.is_file():
        return None
    try:
        data = parse_file(path)
    except (YamliteError, OSError):
        return None  # fail open: an unparseable tier 3 is effective_config's problem to report
    return data if isinstance(data, dict) else None


# ── the resolution ─────────────────────────────────────────────────────────────────────────────
def resolve(root: str | Path, tier3: object = _UNSET) -> dict:
    """Resolve the current person. Returns a JSON-ready dict; never raises, never asks.

    `tier3` lets bin/effective_config.py pass the local file it already parsed (None = no usable
    tier 3); left unset, this function loads the file itself.
    """
    root = Path(root)
    config_trace(root, "whoami")
    people = load_people(root)
    index = identity_index(people)
    ident, ids = _match(root, index)

    res: dict = {"status": "miss", "id": None, "display_name": None, "identity": None,
                 "source": "none", "candidates": [], "warning": None, "display": None}

    t3 = _load_tier3(root) if tier3 is _UNSET else tier3
    pinned = t3.get("person") if isinstance(t3, dict) else None
    if isinstance(pinned, str) and pinned.strip():
        pid = pinned.strip()
        res.update(id=pid, display_name=_display_name(people, pid), source="machine",
                   status="resolved", display=_display_line(_display_name(people, pid), pid))
        if len(ids) == 1 and ids[0] != pid:
            res["status"] = "conflict"
            res["identity"] = ident
            res["warning"] = (
                f"whoami: this machine is pinned to '{pid}' (connections.local.yaml person:), "
                f"but the local identity '{ident}' maps to '{ids[0]}'. Using '{pid}' — if that is "
                f"wrong, fix the pin or this repo's git config before work lands in a colleague's "
                f"folder.")
        return res

    env = os.environ.get("TICKETWRIGHT_PERSON", "").strip()
    if env:
        res.update(id=env, display_name=_display_name(people, env), source="env",
                   status="resolved", display=_display_line(_display_name(people, env), env))
        return res

    if len(ids) == 1:
        pid = ids[0]
        res.update(id=pid, display_name=_display_name(people, pid), identity=ident,
                   source="identity_map", status="resolved",
                   display=_display_line(_display_name(people, pid), pid))
        return res
    if len(ids) > 1:
        res.update(status="ambiguous", identity=ident, candidates=ids,
                   warning=(f"whoami: '{ident}' is enumerated by more than one person "
                            f"({', '.join(ids)}) — say who you are: whoami.py --bind <id>"))
        return res
    return res


_STATUS_EXIT = {"resolved": EXIT_OK, "conflict": EXIT_OK,
                "miss": EXIT_MISS, "ambiguous": EXIT_AMBIGUOUS}


# ── the mutation verb: --bind ──────────────────────────────────────────────────────────────────
class BindError(RuntimeError):
    """A --bind write that could not be completed safely (nothing half-written is left behind).

    Deliberately NOT a YamliteError: that class requires a parse location (message, line, file),
    and these are write-safety failures, not parse failures — raising it without the location was
    a TypeError that escaped bind()'s handler entirely.
    """


def _quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _append_identity(path: Path, pid: str, ident: str) -> str:
    """Append `ident` to the identities list in `path`, creating the file if needed.

    Re-reads the file immediately before writing (concurrent edits) and APPENDS rather than
    rewriting, so comments and unrelated keys survive. Returns "appended" | "present".
    Raises OSError/BindError with the original content restored if the result fails to parse.
    """
    if path.is_file():
        original = path.read_text(encoding="utf-8")  # the re-read: always the file's live state
        try:
            data = parse_file(path)
        except YamliteError as exc:
            raise BindError(f"{path} does not parse; fix it before binding: {exc}") from exc
        existing = [str(i).strip().lower() for i in ((data or {}).get("identities") or [])]
        if ident.lower() in existing:
            return "present"
        lines = original.splitlines()
        new_text = None
        for i, ln in enumerate(lines):
            m = re.match(r"^(identities:\s*\[)(.*?)(\]\s*(?:#.*)?)$", ln)
            if m:  # flow style: extend the list in place
                body = m.group(2).strip()
                joined = f"{body}, {_quote(ident)}" if body else _quote(ident)
                lines[i] = m.group(1) + joined + m.group(3)
                new_text = "\n".join(lines) + ("\n" if original.endswith("\n") else "")
                break
            if re.match(r"^identities:\s*(#.*)?$", ln):  # block style: append after the last item
                indent, last = "  ", i
                for j in range(i + 1, len(lines)):
                    im = re.match(r"^(\s+)-\s+\S", lines[j])
                    if im:
                        indent, last = im.group(1), j
                    elif lines[j].strip() and not lines[j].lstrip().startswith("#"):
                        break
                lines.insert(last + 1, f"{indent}- {_quote(ident)}")
                new_text = "\n".join(lines) + ("\n" if original.endswith("\n") else "")
                break
        if new_text is None:  # no identities key at all: append a fresh block
            new_text = original + ("" if original.endswith("\n") or not original else "\n") \
                + f"identities:\n  - {_quote(ident)}\n"
    else:
        original = None
        new_text = (
            f"# people/{pid}.yaml — created by `whoami.py --bind`. TIER 2: person-scoped,\n"
            f"# portable, committed. Fill it out from templates/person.yaml.tmpl\n"
            f"# (display name, tracker handle, voice, viewer preferences).\n"
            f"display_name: {pid}\n"
            f"identities:\n  - {_quote(ident)}\n")
        path.parent.mkdir(parents=True, exist_ok=True)

    path.write_text(new_text, encoding="utf-8")
    # Self-check: the write must leave a parseable file that actually carries the identity. An
    # explicit check, not an assert — asserts vanish under `python -O`, and this is the one line
    # standing between a formatting edge case and a silently corrupted committed people file.
    try:
        check = parse_file(path)
        landed = ident.lower() in [str(i).strip().lower()
                                   for i in ((check or {}).get("identities") or [])]
    except (YamliteError, OSError):
        landed = False
    if not landed:
        if original is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original, encoding="utf-8")
        raise BindError(f"appending to {path} produced an unreadable file — restored")
    return "appended"


def _pin_person(path: Path, pid: str) -> str:
    """Set the top-level `person:` key in tier 3, preserving everything else in the file."""
    if path.is_file():
        original = path.read_text(encoding="utf-8")
        lines = original.splitlines()
        for i, ln in enumerate(lines):
            m = re.match(r"^person:\s*([^\s#]*)\s*(#.*)?$", ln)
            if m:
                if m.group(1).strip("\"'") == pid:
                    return "unchanged"
                lines[i] = f"person: {pid}" + (f"  {m.group(2)}" if m.group(2) else "")
                path.write_text("\n".join(lines)
                                + ("\n" if original.endswith("\n") else ""), encoding="utf-8")
                return "updated"
        text = original + ("" if original.endswith("\n") or not original else "\n") \
            + f"person: {pid}\n"
        path.write_text(text, encoding="utf-8")
        return "added"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# connections.local.yaml — TIER 3: person + machine, gitignored. Written by\n"
        "# `whoami.py --bind`; per-connection keys are added by the per-person setup flow.\n"
        f"person: {pid}\n", encoding="utf-8")
    return "created"


def _public_remote(root: Path) -> bool:
    url = _git_config("remote.origin.url", root)
    m = re.search(r"(?:@|://(?:[^/@]+@)?)([A-Za-z0-9.-]+)", url)
    host = m.group(1).lower() if m else ""
    return host in PUBLIC_HOSTS


def bind(root: Path, pid: str, identity: str | None, confirm: bool) -> int:
    """Pin `person: <pid>` in tier 3 and bind an identity to `people/<pid>.yaml`."""
    # The id names two filesystem locations (people/<id>.yaml, tickets/<id>/), so it must be a
    # plain identifier — a separator or a leading dot would let a bind write outside people/.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", pid):
        print(f"whoami: '{pid}' is not a valid person id — letters, digits, dot, dash and "
              f"underscore only (it names people/<id>.yaml and tickets/<id>/).", file=sys.stderr)
        return EXIT_USAGE

    pre = resolve(root)

    # A person may bind to their OWN file only. Refusals name both people.
    if pre["status"] in ("resolved", "conflict") and pre["id"] != pid and not confirm:
        print(f"whoami: this environment already resolves to '{pre['id']}', and you asked to "
              f"bind '{pid}' — binding an identity to someone else's file needs explicit "
              f"confirmation naming both people. Re-run with --confirm-cross-person if "
              f"'{pre['id']}' → '{pid}' is really what you mean.", file=sys.stderr)
        return EXIT_REFUSED
    if pre["status"] == "ambiguous" and pid not in pre["candidates"] and not confirm:
        print(f"whoami: '{pre['identity']}' already maps to {', '.join(pre['candidates'])}, and "
              f"'{pid}' is not one of them — binding a third person needs "
              f"--confirm-cross-person.", file=sys.stderr)
        return EXIT_REFUSED

    explicit = bool((identity or "").strip())
    ident = (identity or "").strip() or next(iter(local_identities(root)), "")
    people_file = root / "people" / f"{pid}.yaml"

    if ident:
        owners = identity_index(load_people(root)).get(ident.lower(), set())
        if owners - {pid}:
            # Appending an identity that already maps elsewhere can only create ambiguity; the
            # tier-3 pin below is what fixes THIS machine.
            print(f"whoami: not appending '{ident}' to people/{pid}.yaml — it is already "
                  f"enumerated by {', '.join(sorted(owners - {pid}))}. Pinning person: {pid} "
                  f"for this machine instead.", file=sys.stderr)
            ident = ""
        elif "@" in ident and _public_remote(root):
            # Once per run, BEFORE any write. And the offer is real: a DERIVED email is never
            # written — the pin alone fixes this machine with zero disclosure — while an email the
            # person passed via --identity is a deliberate choice and is honored.
            print(f"whoami: this repo's origin remote is on a public code host, and "
                  f"'{ident}' looks like an email. people/{pid}.yaml is committed — prefer a "
                  f"handle or $USER (--identity <value>).", file=sys.stderr)
            if not explicit:
                print(f"whoami: pinning person: {pid} for this machine WITHOUT writing the "
                      f"email. To make other machines resolve too, re-run with "
                      f"--identity <handle> — or --identity {ident} to commit the email "
                      f"deliberately.", file=sys.stderr)
                ident = ""

    try:
        # Tier 3 first: the gitignored, zero-disclosure write that fixes THIS machine. The tracked
        # people-file append comes second, so its loud failure never leaves the machine unpinned —
        # and a valid append is never rolled back for an unrelated failure, because discarding the
        # person's own answer would be worse than a partial (and still-correct) self-heal.
        _pin_person(root / LOCAL_REL, pid)
        if ident:
            _append_identity(people_file, pid, ident)
    except (OSError, YamliteError, BindError) as exc:
        print(f"whoami: bind failed: {exc}", file=sys.stderr)
        return EXIT_WRITE

    post = resolve(root)
    if post.get("display"):
        print(post["display"])
    return EXIT_OK


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="whoami.py",
        description="Resolve who is working (resolved | miss | ambiguous | conflict) — never a guess.",
        epilog="Exit codes: 0 resolved/conflict, 1 write error, 2 usage, 3 miss, 4 ambiguous, "
               "5 bind refused.")
    ap.add_argument("--root", default=None, help="repo root (default: $CLAUDE_PROJECT_DIR, else "
                                                 "the nearest ancestor with a stack.yaml)")
    ap.add_argument("--json", action="store_true", help="emit the full result as JSON")
    ap.add_argument("--field", choices=["id", "status", "display_name", "identity", "source"],
                    default=None, help="print one field (empty when unresolved)")
    ap.add_argument("--bind", metavar="ID", default=None,
                    help="append the current identity to people/<ID>.yaml and pin person: <ID> "
                         "in tier 3 (the self-healing verb)")
    ap.add_argument("--identity", default=None,
                    help="with --bind: the identity to append (default: the first local identity)")
    ap.add_argument("--confirm-cross-person", action="store_true",
                    help="with --bind: required to bind while already resolved as someone else")
    args = ap.parse_args(argv)

    root = Path(args.root) if args.root else project_root()

    if args.bind is not None:  # not truthiness: --bind "" must be REJECTED (exit 2), not resolved
        return bind(root, args.bind.strip(), args.identity, args.confirm_cross_person)

    res = resolve(root)
    code = _STATUS_EXIT[res["status"]]
    if args.json:
        print(json.dumps(res))  # machine callers read the warning from the JSON, stderr stays clean
        return code
    if args.field:
        print(res.get(args.field) or "")
        if res.get("warning") and res["status"] == "conflict":
            print(res["warning"], file=sys.stderr)
        return code
    if res["status"] in ("resolved", "conflict"):
        print(res["display"])
        if res.get("warning"):
            print(res["warning"], file=sys.stderr)
    elif res["status"] == "ambiguous":
        print(res["warning"], file=sys.stderr)
    else:
        print("whoami: no identity resolved — the host agent should ask who you are and run "
              "whoami.py --bind <id> (never guessing an owner).", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
