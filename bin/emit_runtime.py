#!/usr/bin/env python3
"""Install the kit's skills for a named runtime — verify where the runtime already sees the
canonical copy, translate-on-emit where it cannot.

  emit_runtime.py --runtime <name> [--local|--global] [--root <path>]

The canonical skill source is `.claude/skills/` and it never moves (see docs/architecture.md,
"Why the canonical source stays put"). This command is the compatibility layer between that source
and each runtime's own skill layout:

  --runtime claude-code   VERIFY-ONLY. Claude Code reads the canonical copy natively (plugin or
                          vendored install), so there is nothing to emit; the command reports the
                          install's state and touches nothing.
  --runtime codex-cli     EMIT. Codex CLI reads `.agents/skills/<name>/SKILL.md`, so each canonical
                          skill is translated there: `name` + `description` frontmatter (the two
                          fields Codex requires), a provenance header, and the body carried over.
  everything else         Known runtimes that are not wired yet exit nonzero naming the unit that
                          adds them; unknown names exit nonzero listing what exists.

Safety carve-out: a skill whose SOURCE frontmatter declares `disable-model-invocation: true` is NOT
emitted — Codex has no equivalent field yet, so emitting it would silently turn a user-invocable-only
skill into a model-invocable one. The deferral is printed, never silent; the metadata mapping that
lifts it lands in a later unit (U2).

Hand-copying skill files between runtime layouts is unsupported: a stale duplicate silently winning
over the canonical copy is the failure mode this command exists to prevent. Re-run it to update.

Exposed three ways, one implementation: `ticketwright install` (the pip entrypoint),
`bin/install.sh` (the shell convenience), and this script directly. Stdlib only; takes `--root`;
no Claude environment variable required. Exit codes: 0 ok · 2 usage/not-installable · 3 kit not
locatable. Diagnostics go to stderr; the install report goes to stdout.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# kit_paths.py is the one authority on kit/project location, runtime adapters and their aliases —
# resolve it from THIS file's directory (a kit script must find siblings from its own kit dir,
# never the project root).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import kit_paths  # noqa: E402

# What this skeleton can do per runtime. Everything else in adapters/runtime/ is known-but-not-wired
# until the emission matrix (U2) extends coverage to all seven.
WIRED = {"claude-code": "verify-only", "codex-cli": "emit"}
NOT_WIRED_UNIT = "U2 (the emission matrix)"

PROVENANCE_TEMPLATE = ("<!-- emitted by ticketwright install v{version} — do not hand-edit; "
                       "re-run `ticketwright install --runtime {runtime}` to update. -->")


def kit_version(kit: Path) -> str:
    """The kit's version, from whichever install shape is present. Never guesses: 'unknown' beats
    a wrong number in a provenance line.

    One probe per install shape, single source of truth throughout: the repo and a full-clone
    `cp -r` carry ticketwright/__init__.py at the kit root; a wheel's `_kit` sits inside the
    package, so the same file is one level up; a `ticketwright init` vendors only the four kit
    dirs, so init writes bin/KIT_VERSION (from __init__.py, at vendor time) for exactly this
    lookup; a plugin-cache install ships .claude-plugin/plugin.json.
    """
    for probe in (kit / "ticketwright" / "__init__.py",          # repo / cp -r of the full repo
                  kit.parent / "__init__.py"):                   # wheel: kit is ticketwright/_kit
        try:
            m = re.search(r'__version__\s*=\s*["\']([^"\']+)["\']', probe.read_text(encoding="utf-8"))
        except OSError:
            continue
        if m:
            return m.group(1)
    try:  # `ticketwright init`-vendored kit: the marker init wrote next to the scripts it copied
        v = (kit / "bin" / "KIT_VERSION").read_text(encoding="utf-8").strip()
        if v:
            return v
    except OSError:
        pass
    try:  # plugin cache install ships .claude-plugin/plugin.json
        import json
        v = json.loads((kit / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8")).get("version")
        if v:
            return str(v)
    except (OSError, ValueError):
        pass
    return "unknown"


def split_frontmatter(text: str) -> tuple[str, str] | None:
    """(frontmatter block without delimiters, body after the closing ---), or None."""
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 3)
    if end == -1:
        return None
    return text[4:end + 1], text[end + 5:]


def raw_description_line(fm_block: str) -> str | None:
    """The source's own `description:` line, verbatim — reusing it keeps whatever quoting the
    source needed, instead of re-serializing YAML and betting on the escaping. A block-scalar
    description (`|`/`>`) cannot be carried by one line, so it is refused rather than mangled."""
    for ln in fm_block.splitlines():
        if ln.startswith("description:"):
            if ln.partition(":")[2].strip()[:1] in ("|", ">"):
                return None
            return ln
    return None


def source_skills(kit: Path) -> list[Path]:
    return sorted((kit / ".claude" / "skills").glob("*/SKILL.md"))


def skills_emit_root(fm: dict, tool: str) -> str:
    """The runtime's skill directory, derived from its adapter's `skills_root` frontmatter
    (`.agents/skills/<name>/SKILL.md` -> `.agents/skills`) — never hardcoded here."""
    root = fm.get("skills_root", "")
    suffix = "/<name>/SKILL.md"
    if not root.endswith(suffix):
        print(f"emit_runtime: the {tool} adapter's skills_root ({root!r}) does not match the "
              f"'<dir>{suffix}' shape this installer expects — fix the adapter frontmatter.",
              file=sys.stderr)
        raise SystemExit(2)
    return root[: -len(suffix)]


def verify_claude_code(project: Path) -> int:
    """Claude Code reads the canonical copy natively — report the install, write nothing.

    "Some SKILL.md exists under .claude/skills/" is not evidence of a ticketwright install (any
    project can carry its own skills), so the vendored check requires the kit's own markers — the
    same is_kit test the launcher uses — with the canonical skills present alongside them. The
    plugin check reads the same install manifest kit_paths trusts, never a glob.
    """
    skills = sorted((project / ".claude" / "skills").glob("*/SKILL.md"))
    if kit_paths.is_kit(project) and skills:
        print(f"claude-code: verify-only — nothing to emit. Vendored install found (kit markers "
              f"present; {len(skills)} SKILL.md files under .claude/skills/).")
        return 0
    plugin = kit_paths._plugin_kit(project)
    if plugin:
        print(f"claude-code: verify-only — nothing to emit. Installed as a Claude Code plugin "
              f"(kit at {plugin}).")
        return 0
    print("claude-code: no ticketwright install found for this project — no plugin-manifest entry, "
          "and no vendored kit (bin/kit_paths.py + adapters/ + templates/ + .claude/skills/).",
          file=sys.stderr)
    if skills:
        print("  note: this project has its own .claude/skills/ files, but a skills directory alone "
              "is not a ticketwright install.", file=sys.stderr)
    print("  install with: claude plugin install ticketwright@ticketwright --scope project", file=sys.stderr)
    print("  or vendor it: pip install ticketwright && ticketwright init", file=sys.stderr)
    return 2


def emit_codex(kit: Path, project: Path, fm: dict, tool: str) -> int:
    emit_root = project / skills_emit_root(fm, tool)
    version = kit_version(kit)
    emitted, deferred, removed, foreign, dropped_keys = [], [], [], [], set()
    for src in source_skills(kit):
        parts = split_frontmatter(src.read_text(encoding="utf-8"))
        if not parts:
            print(f"emit_runtime: {src} has no frontmatter block — skipping.", file=sys.stderr)
            continue
        fm_block, body = parts
        skill_fm = kit_paths.read_frontmatter(src)
        name = src.parent.name
        if skill_fm.get("disable-model-invocation") == "true":
            deferred.append(name)
            # "Deferred" must also mean "not left behind": a copy emitted before the skill was
            # gated (or hand-copied in) would stay model-invocable on this runtime. Our own stale
            # emission (identified by its provenance header) is removed — that is what "re-run to
            # update" means. A file we did not emit is never deleted, but it fails the install
            # loudly below rather than being silently tolerated.
            existing = emit_root / name / "SKILL.md"
            if existing.exists():
                try:
                    stale_text = existing.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    stale_text = ""
                if "emitted by ticketwright install v" in stale_text:
                    existing.unlink()
                    try:
                        existing.parent.rmdir()
                    except OSError:
                        pass
                    removed.append(name)
                else:
                    foreign.append(existing)
            continue
        desc_line = raw_description_line(fm_block)
        if not desc_line:
            print(f"emit_runtime: {src} has no description: line — skipping.", file=sys.stderr)
            continue
        dropped_keys.update(k for k in skill_fm if k not in ("name", "description"))
        out = emit_root / name / "SKILL.md"
        out.parent.mkdir(parents=True, exist_ok=True)
        header = PROVENANCE_TEMPLATE.format(version=version, runtime=tool)
        out.write_text(f"---\nname: {name}\n{desc_line}\n---\n\n{header}\n{body}", encoding="utf-8")
        emitted.append(out)
    print(f"{tool}: emitted {len(emitted)} skills into {emit_root}/")
    for p in emitted:
        print(f"  emitted   {p}")
    for name in deferred:
        print(f"  deferred  {name} — its source declares disable-model-invocation: true (user-invocable "
              f"only); {tool} has no equivalent field yet, so emitting it now would silently make it "
              f"model-invocable. {NOT_WIRED_UNIT} adds the metadata mapping and warning block.")
    for name in removed:
        print(f"  removed   stale emitted copy of {name} — its source declares "
              f"disable-model-invocation: true, so leaving it would keep it model-invocable here.")
    if dropped_keys:
        print(f"  note: source frontmatter keys not carried over ({', '.join(sorted(dropped_keys))}) — "
              f"per-runtime metadata mapping lands with {NOT_WIRED_UNIT}.")
    print("  hand-copying these files between runtime layouts is unsupported — re-run this install to update.")
    if foreign:
        for p in foreign:
            print(f"emit_runtime: {p} makes a user-invocable-only skill model-invocable on this "
                  f"runtime, and this installer did not emit it (no provenance header — hand-copying "
                  f"is unsupported). It was not deleted; delete or move it yourself, then re-run.",
                  file=sys.stderr)
        return 2
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="emit_runtime.py",
        description="Install the kit's skills for a runtime: verify-only where it reads the "
                    "canonical .claude/skills/ copy, translate-on-emit where it cannot.")
    ap.add_argument("--runtime", required=True, help="runtime name or alias (see adapters/runtime/)")
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--local", action="store_true", help="emit into the project repo (default)")
    scope.add_argument("--global", dest="global_scope", action="store_true",
                       help="emit into the runtime's per-user global skills root (not wired yet)")
    ap.add_argument("--root", help="the project repo (default: $TICKETWRIGHT_PROJECT, git toplevel, cwd)")
    args = ap.parse_args(argv)

    project, _ = kit_paths.resolve_project(args.root)
    kit, _ = kit_paths.resolve_kit(project)
    if not kit:
        print("emit_runtime: cannot locate the ticketwright kit. Set TICKETWRIGHT_KIT=<path to the kit>.",
              file=sys.stderr)
        return 3

    adapters = kit_paths.runtime_adapters(kit)
    entry = adapters.get(args.runtime)
    if not entry:
        tools = sorted({fm["tool"] for _, fm in adapters.values()})
        aliases = sorted(name for name in adapters if name not in tools)
        print(f"emit_runtime: unknown runtime '{args.runtime}'.", file=sys.stderr)
        print(f"  runtimes: {', '.join(tools)}", file=sys.stderr)
        print(f"  aliases:  {', '.join(aliases)}", file=sys.stderr)
        return 2
    _, fm = entry
    tool = fm["tool"]  # canonical: an alias like windsurf resolves to devin here

    if args.global_scope:
        print(f"emit_runtime: --global is not wired yet — it needs the per-runtime "
              f"global_skills_root capability, which {NOT_WIRED_UNIT} adds. Use --local (the default).",
              file=sys.stderr)
        return 2

    if tool not in WIRED:
        print(f"emit_runtime: runtime '{tool}' is known but not wired yet — {NOT_WIRED_UNIT} adds it. "
              f"Wired today: claude-code (verify-only), codex-cli (emit).", file=sys.stderr)
        return 2

    if tool == "claude-code":
        return verify_claude_code(project)
    return emit_codex(kit, project, fm, tool)


if __name__ == "__main__":
    raise SystemExit(main())
