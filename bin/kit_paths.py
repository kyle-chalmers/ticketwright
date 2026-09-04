#!/usr/bin/env python3
"""Locate the kit and the project, and report the current runtime's capabilities.

The kit ships three ways (Claude Code plugin, `pip install ticketwright` + `ticketwright init`,
plain `cp -r`), and until now every skill found kit assets through
`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}` — which expands to nothing under Codex, Cursor,
Gemini CLI or anything else. This is the one command that answers "where is the kit, where is the
project, and what can this runtime actually do", with no Claude environment variable required.

  kit_paths.py --kit          # the kit root (where adapters/ + templates/ + bin/ live)
  kit_paths.py --project      # the repo being worked on
  kit_paths.py --runtime      # the detected runtime id
  kit_paths.py --json         # everything, with per-value provenance

Exit codes:  0 ok · 2 usage · 3 kit not locatable · 4 runtime adapter unreadable

Stdlib only. Every diagnostic goes to stderr, so `"$(kit_paths.py --kit)"` can never capture an
error message into a filesystem path.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# A directory is only the kit if it carries the assets skills actually ask for. This is what stops
# a partial copy (say a lone bin/ vendored into a project) from declaring itself the kit and then
# resolving adapters/runtime/ to nothing.
KIT_MARKERS = ("adapters", "templates", "bin/kit_paths.py")

CAPABILITY_KEYS = (
    "skills_root", "skills_format", "session_start", "tool_gate",
    "subagents", "structured_questions", "model_cmd", "model_sandbox", "detect_env",
    # The 3b safety axes and the installer-driving keys (PROMPT 7 / U5). gate_ask_tier and
    # gate_fail_mode are DELIBERATELY separate: Antigravity has the richest gate and no session
    # hook, Devin has a session hook and a gate that fails open by documented design — nothing may
    # average them into one capability score. gate_fail_mode records the runtime's NATIVE default,
    # not the installed state (cursor is `open` here precisely because an installer must set
    # failClosed: true to compensate).
    "gate_ask_tier", "gate_fail_mode", "subagent_isolation",
    "reads_foreign_skills", "global_skills_root",
)

# Floors for a runtime we cannot identify, per key. A generic "no" is not a legal value for the
# non-boolean keys, and forcing one would manufacture a confident wrong answer — `unknown` IS the
# honest floor for an enum, and every consumer must treat it as the never-optimistic case (an
# unknown gate is not a gate; an unknown isolation is not isolation).
_FLOOR = {
    "skills_root": "", "skills_format": "", "model_cmd": "", "detect_env": "",
    "session_start": "no", "tool_gate": "no", "subagents": "no", "structured_questions": "no",
    "model_sandbox": "unknown",
    "gate_ask_tier": "unknown", "gate_fail_mode": "unknown",
    "subagent_isolation": "unknown", "global_skills_root": "unknown",
    "reads_foreign_skills": "none",
}


def is_kit(path: Path | None) -> bool:
    return bool(path) and all((path / m).exists() for m in KIT_MARKERS)


def _pip_kit() -> Path | None:
    """The installed wheel's bundled _kit, probed with cwd off sys.path.

    A plain `import ticketwright` run from a repo that HAS a ticketwright/ directory imports the
    source tree instead of the installed package. `-P` handles that on 3.11+; on 3.9/3.10 the
    protection is cwd="/" (neither -P nor PYTHONSAFEPATH exists there).
    """
    # `-P` is 3.11+ and this kit supports 3.9; cwd="/" is what protects the older interpreters.
    code = "import ticketwright, pathlib; print(pathlib.Path(ticketwright.__file__).parent / '_kit')"
    for argv in ([sys.executable, "-P", "-c", code], [sys.executable, "-c", code]):
        try:
            env = {**os.environ, "PYTHONSAFEPATH": "1"}
            out = subprocess.run(argv, capture_output=True, text=True, cwd="/", env=env, timeout=15)
        except (OSError, subprocess.SubprocessError):
            continue
        cand = Path(out.stdout.strip()) if out.stdout.strip() else None
        if is_kit(cand):
            return cand
    return None


def _safe_resolve(p: Path) -> Path:
    """resolve() that never raises — a manifest path may name a deleted directory."""
    try:
        return p.resolve()
    except OSError:
        return p


def _plugin_kit(project: Path | None) -> Path | None:
    """The Claude plugin cache, read from installed_plugins.json — never globbed.

    The cache keeps every installed version side by side (3.3.0, 3.4.1, 3.5.0 …), so a glob picks
    an arbitrary one and silently runs a stale kit. The manifest names the exact install path per
    scope, so it is the only honest source. Ambiguity returns nothing rather than guessing.
    """
    home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
    manifest = home / "plugins" / "installed_plugins.json"
    try:
        entries = json.loads(manifest.read_text(encoding="utf-8")).get("plugins", {})
    except (OSError, ValueError):
        return None
    rows = []
    for name, installs in entries.items():
        if not name.startswith("ticketwright@") or not isinstance(installs, list):
            continue
        rows.extend(r for r in installs if isinstance(r, dict))
    if project:
        # .resolve() BOTH sides: `project` is already resolved, but projectPath is whatever the
        # installer wrote. On macOS /tmp is a symlink to /private/tmp, so an unresolved compare
        # misses — and the deliberate no-fall-through below then reports no kit at all. This is
        # now THE resolution path for every documented command on a plugin install.
        exact = [r for r in rows if r.get("projectPath")
                 and _safe_resolve(Path(r["projectPath"])) == project]
        if exact:
            # A project-scoped entry exists, so it is the answer or there is no answer. Falling through
            # to the user-scope entry here would silently run a DIFFERENT version of the kit — the same
            # stale-kit failure that reading this manifest instead of globbing was meant to avoid.
            if len(exact) == 1 and is_kit(Path(exact[0].get("installPath", ""))):
                return Path(exact[0]["installPath"])
            return None
    user = [r for r in rows if r.get("scope") == "user"]
    if len(user) == 1 and is_kit(Path(user[0].get("installPath", ""))):
        return Path(user[0]["installPath"])
    return None


def resolve_kit(project: Path | None = None) -> tuple[Path | None, str]:
    env = os.environ.get("TICKETWRIGHT_KIT")
    if env and is_kit(Path(env).expanduser()):
        return Path(env).expanduser().resolve(), "TICKETWRIGHT_KIT"
    own = Path(__file__).resolve().parent.parent
    if is_kit(own):
        return own, "script location"
    plug = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plug and is_kit(Path(plug)):
        return Path(plug).resolve(), "CLAUDE_PLUGIN_ROOT"
    pip = _pip_kit()
    if pip:
        return pip.resolve(), "installed ticketwright package"
    cached = _plugin_kit(project)
    if cached:
        return cached.resolve(), "claude plugin manifest"
    return None, "unresolved"


def resolve_project(root: str | None = None) -> tuple[Path, str]:
    if root:
        return Path(root).expanduser().resolve(), "--root"
    for var in ("TICKETWRIGHT_PROJECT", "CLAUDE_PROJECT_DIR"):
        if os.environ.get(var):
            return Path(os.environ[var]).resolve(), var
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True).stdout.strip()
        if top:
            return Path(top).resolve(), "git toplevel"
    except OSError:
        pass
    return Path.cwd().resolve(), "cwd"


def _strip_comment(value: str) -> str:
    """Drop a trailing `# comment`, but only when the `#` is OUTSIDE quotes.

    Every adapter in the tree carries trailing comments on frontmatter keys
    (`transport: cli          # LaunchServices via /usr/bin/open`), so a naive split on `#` would
    silently append comment words to a command template.
    """
    out, quote = [], ""
    for i, ch in enumerate(value):
        if quote:
            out.append(ch)
            if ch == quote:
                quote = ""
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or value[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).strip()


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def read_frontmatter(path: Path) -> dict:
    """The leading `---` block of an adapter, as flat key -> string. Stdlib, no YAML dependency.

    Deliberately narrow: single-line scalars only. A key whose value opens a block scalar (`|`/`>`)
    is skipped rather than half-parsed — `auth:` is the only such key adapters use, and nothing here
    needs it.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    out, in_block = {}, False
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        if in_block:
            if ln[:1] in (" ", "\t") or not ln.strip():
                continue
            in_block = False
        if not ln.strip() or ln.lstrip().startswith("#") or ln[:1] in (" ", "\t"):
            continue
        key, sep, raw = ln.partition(":")
        if not sep or not key.strip():
            continue
        val = _strip_comment(raw.strip())
        if val[:1] in ("|", ">"):
            in_block = True
            continue
        out[key.strip()] = _unquote(val)
    return out


def runtime_adapters(kit: Path | None) -> dict:
    """Every runtime adapter, keyed by `tool` AND by each name in `aliases`.

    Aliases are load-bearing rather than cosmetic: two runtimes have already been renamed
    (gemini-cli -> antigravity, windsurf -> devin), and a person types the name of the thing they
    actually installed. Without alias indexing, `--runtime gemini-cli` would silently resolve to no
    adapter and report every capability absent — which reads identically to "this runtime cannot gate
    a tool call", the exact wrong answer for a safety policy.

    A real `tool` always wins over an alias, so a future runtime legitimately named `windsurf` could
    not be shadowed by devin's alias.
    """
    if not kit:
        return {}
    out, aliased = {}, {}
    for f in sorted((kit / "adapters" / "runtime").glob("*.md")):
        if f.name == "README.md":
            continue
        fm = read_frontmatter(f)
        if fm.get("seam") != "runtime" or not fm.get("tool"):
            continue
        out[fm["tool"]] = (f, fm)
        for alias in (a.strip() for a in fm.get("aliases", "").split(",")):
            if alias:
                aliased.setdefault(alias, (f, fm))
    for name, entry in aliased.items():
        out.setdefault(name, entry)
    return out


def detect_runtime(kit: Path | None) -> tuple[str, str]:
    """Which agent is running us.

    The env signals live in each adapter's `detect_env:` frontmatter rather than in a table here, so
    adding a runtime stays a one-file change — the same rule the tool seams already follow. Nothing
    safety-critical may depend on this: it is best-effort, and an unrecognized harness is reported as
    `unknown` with every capability false rather than optimistically assumed.
    """
    override = os.environ.get("TICKETWRIGHT_RUNTIME")
    if override:
        return override, "TICKETWRIGHT_RUNTIME"
    for tool, (_, fm) in sorted(runtime_adapters(kit).items()):
        for var in (v.strip() for v in fm.get("detect_env", "").split(",")):
            if var and os.environ.get(var):
                return tool, f"${var}"
    return "unknown", "no runtime signal"


def capabilities(kit: Path | None, runtime: str) -> dict:
    """Capability flags for `runtime`, defaulting to the honest per-key floor.

    An unknown runtime reports every capability at its declared floor (`_FLOOR`): booleans absent,
    enums `unknown`, foreign-skill reading `none`. That is deliberate: a wrong `yes` here would let
    a caller believe `db_write_requires_approval` is mechanically enforced when nothing is
    enforcing it, which is the failure mode this whole file exists to prevent.
    """
    entry = runtime_adapters(kit).get(runtime)
    if not entry:
        return dict(_FLOOR)
    _, fm = entry
    return {k: fm.get(k, _FLOOR[k]) for k in CAPABILITY_KEYS}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Locate the kit + project and report runtime capabilities (no Claude env var required)")
    ap.add_argument("--root", help="the project repo (default: $TICKETWRIGHT_PROJECT, git toplevel, cwd)")
    for flag, helptext in (("kit", "print the kit root"), ("project", "print the project root"),
                           ("runtime", "print the detected runtime id"), ("json", "print everything as JSON")):
        ap.add_argument(f"--{flag}", action="store_true", help=helptext)
    args = ap.parse_args()

    project, project_src = resolve_project(args.root)
    kit, kit_src = resolve_kit(project)
    runtime, runtime_src = detect_runtime(kit)

    if not kit and (args.kit or args.json or not (args.project or args.runtime)):
        print("kit_paths: cannot locate the ticketwright kit. Set TICKETWRIGHT_KIT=<path to the kit>.",
              file=sys.stderr)
        return 3

    if args.json:
        adapter = runtime_adapters(kit).get(runtime)
        print(json.dumps({
            "kit_root": str(kit) if kit else None,
            "project_root": str(project),
            "runtime": runtime,
            "runtime_adapter": str(adapter[0]) if adapter else None,
            "capabilities": capabilities(kit, runtime),
            "provenance": {"kit": kit_src, "project": project_src, "runtime": runtime_src},
        }, indent=2))
        return 0
    if args.kit:
        print(kit)
    if args.project:
        print(project)
    if args.runtime:
        print(runtime)
    if not (args.kit or args.project or args.runtime):
        print(kit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
