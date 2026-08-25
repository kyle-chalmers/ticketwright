#!/usr/bin/env python3
"""Install the kit's skills and agent definitions for a named runtime — verify where the runtime
already sees the canonical copy, translate-on-emit where it cannot.

  emit_runtime.py --runtime <name> [--local|--global] [--root <path>]

The canonical skill source is `.claude/skills/` and it never moves (see docs/architecture.md,
"Why the canonical source stays put"). This command is the compatibility layer between that source
and each runtime's own layout, and the decision is DATA-DRIVEN off `adapters/runtime/*.md`
frontmatter — never a runtime name in branch logic:

  NATIVE    the runtime's own `skills_root` IS the canonical copy (claude-code). Verify-only:
            report the install's state, touch nothing.
  VERIFY    the runtime's `reads_foreign_skills` includes `.claude/skills` (cursor, opencode,
            cline, devin today). The runtime reads the canonical copy directly, so emitting a
            translated duplicate would create the stale-copy-silently-wins failure mode — the
            installer verifies the canonical copy is reachable, prints the documented caveats and
            metadata losses, and emits NO skill files. (The shared-file trap: one file, many
            readers — a foreign reader ignores Claude-specific keys, so `allowed-tools` and
            `disable-model-invocation` are exactly as lost here as on an emit runtime lacking the
            primitive. The verify report states that loss per affected skill.)
  EMIT      everything else (codex-cli and antigravity today, sharing one `.agents/skills/`
            emission). Each canonical skill is translated: `name` + `description` frontmatter,
            a provenance header, and the body carried over.

Metadata mapping (per-runtime record: adapters/runtime/<tool>.md § Metadata mapping): a source
skill declaring `disable-model-invocation: true` IS emitted on emit runtimes, but with a topmost
warning block stating that user-invocable-only cannot be expressed there — the loss rides in the
artifact a user actually reads, never only in a report. `allowed-tools` has no equivalent on any
emit runtime and is named as lost in the install report. Agent definitions (`.claude/agents/*.md`,
qc-reviewer today) are emitted wherever the adapter declares an `agents_root` pattern; `none`
(subagents not user-definable) and `unknown` (no documented definition path) are stated, not
guessed around.

Collision handling is provenance-aware for every emitted artifact: a file this installer wrote
(identified by its provenance header) is overwritten on re-run — that is what "re-run to update"
means. A file it did NOT write is never touched: the install fails loudly instead, because
hand-copying between runtime layouts is unsupported and silently clobbering a hand-maintained
file would be worse.

--global emits into the adapter's declared `global_skills_root` (skills only — no global agents
root is researched). Where that key is `unknown` (antigravity: its documented sources disagree)
the installer REFUSES with the explanation rather than guessing a path. On native/verify runtimes
--global is a deliberate no-op with the reason printed: those runtimes read the canonical
per-project copy, so a global emission would be a permanent stale-duplicate risk.

Exposed three ways, one implementation: `ticketwright install` (the pip entrypoint),
`bin/install.sh` (the shell convenience), and this script directly. Stdlib only; takes `--root`;
no Claude environment variable required. Exit codes: 0 ok · 2 usage/not-installable/verify-failed
· 3 kit not locatable. Diagnostics go to stderr; the install report goes to stdout.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# kit_paths.py is the one authority on kit/project location, runtime adapters and their aliases —
# resolve it from THIS file's directory (a kit script must find siblings from its own kit dir,
# never the project root).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import kit_paths  # noqa: E402

CANONICAL_SKILLS = ".claude/skills"
CANONICAL_AGENTS = ".claude/agents"

# The literal marker substring is load-bearing: it identifies OUR emissions for provenance-aware
# overwrites, and selftest greps for it in every emitted file. Do not reword it.
PROVENANCE_MARK = "emitted by ticketwright install v"
PROVENANCE_TEXT = ("emitted by ticketwright install v{version} — do not hand-edit; "
                   "re-run `ticketwright install --runtime {runtime}` to update.")


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


def raw_line(fm_block: str, key: str) -> str | None:
    """The source's own `<key>:` line, verbatim — reusing it keeps whatever quoting the source
    needed, instead of re-serializing YAML and betting on the escaping. A block-scalar value
    (`|`/`>`) cannot be carried by one line, so it is refused rather than mangled."""
    prefix = key + ":"
    for ln in fm_block.splitlines():
        if ln.startswith(prefix):
            if ln.partition(":")[2].strip()[:1] in ("|", ">"):
                return None
            return ln
    return None


def parse_list(value: str | None) -> list[str]:
    items = [i.strip() for i in (value or "").split(",")]
    return [i for i in items if i and i != "none"]


def source_skills(root: Path) -> list[Path]:
    return sorted((root / ".claude" / "skills").glob("*/SKILL.md"))


def source_agents(kit: Path) -> list[Path]:
    return sorted((kit / ".claude" / "agents").glob("*.md"))


def gated_skills(root: Path) -> dict[str, str]:
    """Every skill whose frontmatter declares disable-model-invocation: true, enumerated from the
    SOURCE at run time (never a hardcoded list — a future gated skill is covered automatically),
    mapped to its allowed-tools declaration for the warning text."""
    out = {}
    for src in source_skills(root):
        fm = kit_paths.read_frontmatter(src)
        if fm.get("disable-model-invocation") == "true":
            out[src.parent.name] = fm.get("allowed-tools", "")
    return out


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


def emission_mode(fm: dict, tool: str) -> str:
    """native | verify | emit, decided by adapter data alone (see the module docstring)."""
    if skills_emit_root(fm, tool) == CANONICAL_SKILLS:
        return "native"
    if CANONICAL_SKILLS in parse_list(fm.get("reads_foreign_skills", "none")):
        return "verify"
    return "emit"


def warning_block(tool: str, allowed_tools: str) -> str:
    """The topmost rendered block of an emitted user-invocable-only skill: the loss rides in the
    artifact itself, because a report scrolls away and this file does not."""
    lines = [
        f"> **User-invocable only — not enforced on {tool}.** The canonical source of this skill",
        "> declares `disable-model-invocation: true`: a person invokes it deliberately; the model",
        f"> must never choose it on its own. {tool} has no equivalent control, so nothing mechanical",
        "> prevents model invocation here — treat any model-initiated use of this skill as a bug.",
    ]
    if allowed_tools:
        lines.append(f"> Its canonical `allowed-tools` restriction ({allowed_tools}) is not "
                     "enforced here either.")
    return "\n".join(lines)


def write_emitted(out: Path, content: str, foreign: list[Path]) -> bool:
    """Provenance-aware write. Ours (provenance header present) -> overwrite; absent or identical
    -> write; a DIFFERENT file we did not emit -> never touched, recorded as foreign so the
    install fails loudly instead of clobbering a hand-maintained file."""
    if out.exists():
        try:
            existing = out.read_text(encoding="utf-8", errors="replace")
        except OSError:
            existing = ""
        if PROVENANCE_MARK not in existing and existing != content:
            foreign.append(out)
            return False
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(content, encoding="utf-8")
    return True


def hook_command(hook: str, tool: str) -> str:
    """The wiring line for a kit hook on this runtime. It runs through bin/tw — the launcher that
    finds the kit — so one line serves a vendored, wheel, or plugin-cache install alike."""
    return f"bash bin/tw hook_shim.py --runtime {tool} --hook {hook}"


_ENF_BEGIN = "<!-- ticketwright:enforcement:begin -->"
_ENF_END = "<!-- ticketwright:enforcement:end -->"
_POSTURE_BEGIN = "<!-- ticketwright:posture:begin -->"
_POSTURE_END = "<!-- ticketwright:posture:end -->"


def _marker_block(kit: Path, begin: str, end: str) -> str | None:
    try:
        text = (kit / "templates" / "AGENTS.md.tmpl").read_text(encoding="utf-8")
        start = text.index(begin) + len(begin)
        stop = text.index(end)
    except (OSError, ValueError):
        return None
    return text[start:stop].strip() + "\n"


def enforcement_block(kit: Path) -> str | None:
    """The enforcement table, extracted verbatim from the AGENTS.md template between its markers —
    ONE authoring point, two surfaces (the rendered AGENTS.md, and the rules-root copy for a
    runtime whose users never read AGENTS.md)."""
    return _marker_block(kit, _ENF_BEGIN, _ENF_END)


def posture_block(kit: Path) -> str | None:
    """The permission-posture table (Bash path vs MCP path, per policy), same one-authoring-point
    rule as the enforcement table: the rules-root artifact carries it too, because a runtime whose
    users never read AGENTS.md must still see when NATIVE (tool-side) is claimable."""
    return _marker_block(kit, _POSTURE_BEGIN, _POSTURE_END)


def emit_hooks(kit: Path, project: Path, fm: dict, tool: str, version: str,
               foreign: list[Path]) -> int:
    """Wire the kit's hooks for this runtime — or state, precisely, why they are not wired
    (PROMPT 7 / U3). A missing hook must never SILENTLY weaken a safety policy.

    Data-driven off adapter frontmatter (`hook_wiring`, `hook_protocol`, `hook_wiring_caveat`,
    `rules_root`, `gate_ask_tier`) — the emitter carries protocol code, never a runtime name in
    branch logic. The 3b collapse is surfaced once per install run on stdout (a safety decision,
    never a buried config detail) and permanently in the enforcement table the rendered AGENTS.md
    carries. Nothing here ever writes under .claude/ — the Claude Code wiring cannot be shadowed.
    """
    wiring = fm.get("hook_wiring", "unknown")
    protocol = fm.get("hook_protocol", "unknown")
    ask = fm.get("gate_ask_tier", "unknown")
    prov = PROVENANCE_TEXT.format(version=version, runtime=tool)
    caveat = fm.get("hook_wiring_caveat", "")

    if wiring == "native":
        print("  hooks     native — the Claude Code wiring (.claude-plugin/plugin.json, mirrored "
              "in .claude/settings.json) is untouched; this installer never emits anything under "
              ".claude/.")
        return 0

    # THE COLLAPSE (3b), stated per runtime class — once per install run, the "warn once" scope.
    if ask == "no":
        print("  policy    db_write_requires_approval=high_risk (the default) has NO native "
              "expression here — no ask tier. It collapses to DENY-WITH-ESCAPE: destructive "
              "statements are denied with a message naming the one-shot re-approval (the "
              "`TICKETWRIGHT_APPROVE=once` command prefix, or the .claude/config/approve.once "
              "token — consumed on use); additive statements pass untouched. It NEVER collapses "
              "toward allow.")
    elif ask == "yes":
        print("  policy    db_write_requires_approval=high_risk is expressed as `ask` here — a "
              "gated statement becomes a confirmation, not a refusal.")
    else:
        print("  policy    db_write_requires_approval degrades to GUIDANCE here — no verified "
              "hook mechanism can express it (see the enforcement table in the rendered "
              "AGENTS.md).")

    if wiring == "unknown":
        if protocol == "unknown":
            print(f"  hooks     none wired on {tool} — no verified hook mechanism exists to wire "
                  f"(see adapters/runtime/{tool}.md).")
        else:
            print(f"  hooks     shim-ready but NOT wired: {tool} documents its hook protocol, but "
                  f"the hooks-config file location is not in the kit's research — wire the guard "
                  f"yourself: `{hook_command('shell_guards', tool)} || exit 2` (the suffix keeps "
                  f"a bin/tw launcher failure inside the documented deny exit; the shim itself "
                  f"already exits only 0 or 2) — that one hook covers BOTH shell guards, plus "
                  f"the session banners via "
                  f"--hook session_context / ticket_index_context; live verification will "
                  f"establish the config path.")
        if caveat:
            print(f"  caveat    {caveat}")
    elif wiring.endswith(".json"):
        cfg: dict[str, object] = {
            "_provenance": prov,
            "_schema_note": "hook-entry shape assembled from the documented fields; the config "
                            "file's full schema is live-unverified — see the enforcement table "
                            "in AGENTS.md.",
        }
        # ONE entry running BOTH shell guards (`--hook shell_guards`), never two entries. Whether
        # a runtime executes every element of a hook array or stops at the first is undocumented
        # for every runtime here, and a WIRED cell resting on that assumption would be an
        # overclaim. One entry removes the assumption rather than documenting it.
        if protocol == "cursor-json":
            cfg["hooks"] = {"beforeShellExecution": [
                {"command": hook_command("shell_guards", tool), "failClosed": True}]}
            note = "failClosed: true is required configuration on a fail-open-by-default runtime"
        elif protocol == "agy-json":
            cfg["hooks"] = {
                "PreToolUse": [{"command": hook_command("shell_guards", tool)}],
                "PostToolUse": [{"command": hook_command("regenerate_ticket_index", tool)}],
            }
            note = "PreToolUse shell guards (ask/force_ask) + PostToolUse index regeneration"
        else:
            print(f"emit_runtime: the {tool} adapter declares hook_wiring {wiring!r} with "
                  f"hook_protocol {protocol!r}, which this emitter has no config shape for — fix "
                  f"the adapter frontmatter.", file=sys.stderr)
            return 2
        out = project / wiring
        if write_emitted(out, json.dumps(cfg, indent=2) + "\n", foreign):
            print(f"  emitted   {out} (hook config; {note})")
        if caveat:
            print(f"  caveat    {caveat}")
    elif wiring.endswith(".js"):
        src = kit / "bin" / "opencode_tool_gate.js"
        try:
            body = src.read_text(encoding="utf-8")
        except OSError:
            print(f"emit_runtime: {src} is missing from the kit — cannot emit the plugin wrapper.",
                  file=sys.stderr)
            return 2
        out = project / wiring
        if write_emitted(out, f"// {prov}\n{body}", foreign):
            print(f"  emitted   {out} (throw-to-deny plugin wrapper: exit 2 from the guard shim "
                  f"becomes a thrown error, this runtime's documented deny)")
        if caveat:
            print(f"  caveat    {caveat}")
    else:
        print(f"emit_runtime: the {tool} adapter declares hook_wiring {wiring!r}, which this "
              f"emitter does not recognize — fix the adapter frontmatter.", file=sys.stderr)
        return 2

    if wiring != "unknown":
        # The wired commands run through bin/tw, which must exist IN THE PROJECT.
        if not (project / "bin" / "tw").is_file():
            print("  warning   the emitted hook wiring invokes `bash bin/tw ...`, but this "
                  "project has no bin/tw — vendor the kit (pip install ticketwright && "
                  "ticketwright init), or the wired hooks cannot run.")
        # Session banners: not wired anywhere yet — no runtime documents BOTH a hooks-config
        # location AND a context-injection schema the kit's research can cite. The fallback is
        # the workflow instruction, carried in the enforcement table.
        if fm.get("session_start") == "yes":
            print(f"  note      session banners are not wired ({tool} documents a session-start "
                  f"event, but not an injection schema this kit's research can cite) — run "
                  f"`{hook_command('session_context', tool)}` and the ticket_index_context "
                  f"variant at session start.")
        else:
            print(f"  note      no session-start event here — the banners are workflow: run "
                  f"`{hook_command('session_context', tool)}` and the ticket_index_context "
                  f"variant at session start; rules text is static, banner output is fresh.")

    # The honesty artifact for a runtime whose users do not read AGENTS.md.
    rules_root = fm.get("rules_root", "")
    if rules_root:
        block = enforcement_block(kit)
        if block is None:
            print("emit_runtime: templates/AGENTS.md.tmpl has no enforcement-table markers — "
                  "cannot emit the rules artifact.", file=sys.stderr)
            return 2
        posture = posture_block(kit)
        if posture is None:
            print("emit_runtime: templates/AGENTS.md.tmpl has no posture-table markers — "
                  "cannot emit the rules artifact.", file=sys.stderr)
            return 2
        content = (f"<!-- {prov} -->\n\n# Ticketwright enforcement — what is mechanical here\n\n"
                   + block + "\n" + posture)
        out = project / rules_root / "ticketwright-enforcement.md"
        if write_emitted(out, content, foreign):
            print(f"  emitted   {out} (the enforcement table, emitted where {tool} users "
                  f"actually read)")
    return 0


def report_foreign(foreign: list[Path]) -> int:
    for p in foreign:
        print(f"emit_runtime: {p} already exists and this installer did not emit it (no provenance "
              f"header — hand-copying between runtime layouts is unsupported). It was not deleted "
              f"and not overwritten; delete or move it yourself, then re-run.", file=sys.stderr)
    return 2 if foreign else 0


def emit_skills(kit: Path, emit_root: Path, tool: str, version: str,
                foreign: list[Path]) -> list[str]:
    """Translate every canonical skill into emit_root. Returns the names emitted."""
    gated = gated_skills(kit)
    emitted, warned, dropped_keys = [], [], set()
    for src in source_skills(kit):
        parts = split_frontmatter(src.read_text(encoding="utf-8"))
        if not parts:
            print(f"emit_runtime: {src} has no frontmatter block — skipping.", file=sys.stderr)
            continue
        fm_block, body = parts
        name = src.parent.name
        desc_line = raw_line(fm_block, "description")
        if not desc_line:
            print(f"emit_runtime: {src} has no description: line — skipping.", file=sys.stderr)
            continue
        skill_fm = kit_paths.read_frontmatter(src)
        dropped_keys.update(k for k in skill_fm if k not in ("name", "description"))
        header = "<!-- " + PROVENANCE_TEXT.format(version=version, runtime=tool) + " -->"
        content = f"---\nname: {name}\n{desc_line}\n---\n\n{header}\n"
        if name in gated:
            # The warning is the FIRST RENDERED BLOCK (the provenance line above is an HTML
            # comment): "model-invocable when the author said user-only" must be impossible to
            # hit without having been told, in the file itself.
            content += "\n" + warning_block(tool, gated[name]) + "\n"
        content += body
        out = emit_root / name / "SKILL.md"
        if write_emitted(out, content, foreign):
            emitted.append(name)
            print(f"  emitted   {out}")
            if name in gated:
                warned.append(name)
    for name in warned:
        print(f"  warned    {name} — user-invocable-only (disable-model-invocation: true) cannot be "
              f"expressed on {tool}; emitted with a topmost warning block "
              f"(see adapters/runtime/{tool}.md § Metadata mapping).")
    lost = sorted(k for k in dropped_keys if k in ("allowed-tools", "disable-model-invocation"))
    other = sorted(k for k in dropped_keys if k not in ("allowed-tools", "disable-model-invocation"))
    if lost:
        print(f"  note: control fields not expressible here and therefore lost: {', '.join(lost)} — "
              f"recorded per field in adapters/runtime/{tool}.md § Metadata mapping.")
    if other:
        print(f"  note: display-only source keys dropped (nothing a reader loses): {', '.join(other)}.")
    print("  hand-copying these files between runtime layouts is unsupported — re-run this install to update.")
    return emitted


def emit_agents(kit: Path, project: Path, fm: dict, tool: str, version: str,
                foreign: list[Path]) -> int:
    """Emit .claude/agents/*.md as runtime-native agent definitions wherever the adapter declares
    an agents_root pattern; state the loss where it declares none/unknown."""
    names = ", ".join(src.stem for src in source_agents(kit)) or "qc-reviewer"
    pattern = fm.get("agents_root", "unknown")
    if pattern == "none":
        print(f"  note: agent definitions ({names}) are NOT installable here — {tool} subagents "
              f"are not user-definable, so the deep review degrades to an inline same-context pass "
              f"and the /review verdict says so (adapters/runtime/{tool}.md § Metadata mapping).")
        return 0
    if pattern == "unknown":
        print(f"  note: agent definitions ({names}) not emitted — {tool} documents user-definable "
              f"subagents but no definition file path or format is established, and guessing one "
              f"would emit a file nothing reads (see adapters/runtime/{tool}.md).")
        return 0
    fmt = "md" if pattern.endswith("/<name>.md") else "toml" if pattern.endswith("/<name>.toml") else None
    if not fmt:
        print(f"emit_runtime: the {tool} adapter's agents_root ({pattern!r}) matches neither "
              f"'<dir>/<name>.md' nor '<dir>/<name>.toml' — fix the adapter frontmatter.",
              file=sys.stderr)
        return 2
    root = pattern[: -len("/<name>." + fmt)]
    if root == CANONICAL_AGENTS:
        return 0  # native — the canonical copy is already the runtime's own format
    rc = 0
    for src in source_agents(kit):
        parts = split_frontmatter(src.read_text(encoding="utf-8"))
        if not parts:
            print(f"emit_runtime: {src} has no frontmatter block — skipping.", file=sys.stderr)
            continue
        fm_block, body = parts
        name = src.stem
        agent_fm = kit_paths.read_frontmatter(src)
        tools = agent_fm.get("tools", "")
        prov = PROVENANCE_TEXT.format(version=version, runtime=tool)
        if fmt == "md":
            desc_line = raw_line(fm_block, "description")
            tools_line = raw_line(fm_block, "tools")
            if not desc_line:
                print(f"emit_runtime: {src} has no description: line — skipping.", file=sys.stderr)
                continue
            lines = ["---", f"name: {name}", desc_line]
            if tools_line:
                lines.append(tools_line)
            lines += ["---", "", f"<!-- {prov} -->"]
            content = "\n".join(lines) + "\n" + body
            note = ("tools: carried verbatim — whether the runtime honors it is live-verification "
                    "work" if tools_line else "no tools: line in the source")
        else:
            if "'''" in body or "'''" in tools:
                print(f"emit_runtime: {src} contains a TOML literal-string delimiter (''') and "
                      f"cannot be emitted as {tool} TOML — rewrite the source without it.",
                      file=sys.stderr)
                rc = 2
                continue
            content = (
                f"# {prov}\n"
                f"#\n"
                f"# Canonical source: {CANONICAL_AGENTS}/{name}.md, which restricts this agent to\n"
                f"# tools: {tools or '(none declared)'}. No documented field of this format carries a tool\n"
                f"# restriction, so it is NOT mechanically enforced here — the restriction is restated\n"
                f"# in the instructions, and whether this definition is accepted at all is\n"
                f"# live-verification work (see adapters/runtime/{tool}.md § Metadata mapping).\n"
                f"\n"
                f"description = {json.dumps(agent_fm.get('description', ''))}\n"
                f"\n"
                f"instructions = '''\n"
                f"READ-ONLY BY DESIGN — not mechanically enforced on this runtime. Use only\n"
                f"capabilities equivalent to: {tools or 'Read, Bash, Glob, Grep'}. Never edit files;"
                f" never post externally.\n"
                f"{body}'''\n"
            )
            note = "tools: lost — no documented field; the loss is restated inside the file"
        out = project / root / f"{name}.{fmt}"
        if write_emitted(out, content, foreign):
            print(f"  emitted   {out} (agent definition; {note})")
    return rc


def verify_native(project: Path, tool: str) -> int:
    """The runtime's own skills_root IS the canonical copy (claude-code) — report the install,
    write nothing.

    "Some SKILL.md exists under .claude/skills/" is not evidence of a ticketwright install (any
    project can carry its own skills), so the vendored check requires the kit's own markers — the
    same is_kit test the launcher uses — with the canonical skills present alongside them. The
    plugin check reads the same install manifest kit_paths trusts, never a glob. (The manifest
    probe is meaningful only for the runtime whose plugin cache it is; for the native runtime,
    that is exactly the right question.)
    """
    skills = source_skills(project)
    if kit_paths.is_kit(project) and skills:
        print(f"{tool}: verify-only — nothing to emit. Vendored install found (kit markers "
              f"present; {len(skills)} SKILL.md files under .claude/skills/).")
        print("  hooks     native — the Claude Code wiring is untouched; this installer never "
              "emits anything under .claude/.")
        return 0
    plugin = kit_paths._plugin_kit(project)
    if plugin:
        print(f"{tool}: verify-only — nothing to emit. Installed as a Claude Code plugin "
              f"(kit at {plugin}).")
        print("  hooks     native — the Claude Code wiring is untouched; this installer never "
              "emits anything under .claude/.")
        return 0
    print(f"{tool}: no ticketwright install found for this project — no plugin-manifest entry, "
          "and no vendored kit (bin/kit_paths.py + adapters/ + templates/ + .claude/skills/).",
          file=sys.stderr)
    if skills:
        print("  note: this project has its own .claude/skills/ files, but a skills directory alone "
              "is not a ticketwright install.", file=sys.stderr)
    print("  install with: claude plugin install ticketwright@ticketwright --scope project", file=sys.stderr)
    print("  or vendor it: pip install ticketwright && ticketwright init", file=sys.stderr)
    return 2


def verify_foreign(kit: Path, project: Path, fm: dict, tool: str, version: str) -> int:
    """The runtime reads the canonical .claude/skills/ copy natively: verify it is reachable and
    emit NO skills — then state, per affected skill, every control field that shared file cannot
    carry for this reader."""
    skills = source_skills(project)
    if not (kit_paths.is_kit(project) and skills):
        plugin = kit_paths._plugin_kit(project)
        print(f"{tool}: no canonical .claude/skills/ copy found in this project — {tool} reads the "
              f"PROJECT's copy, so there is nothing for it to discover here.", file=sys.stderr)
        if plugin:
            print(f"  note: ticketwright IS installed as a Claude Code plugin (kit at {plugin}), "
                  f"but {tool} cannot read Claude's plugin cache.", file=sys.stderr)
        elif skills:
            print("  note: this project has its own .claude/skills/ files, but a skills directory "
                  "alone is not a ticketwright install.", file=sys.stderr)
        print("  vendor the kit into the repo: pip install ticketwright && ticketwright init", file=sys.stderr)
        return 2
    print(f"{tool}: verify-only — {tool} reads the canonical {CANONICAL_SKILLS}/ copy natively; "
          f"found {len(skills)} skills at {project / '.claude' / 'skills'}. Emitting a translated "
          f"duplicate could silently shadow the canonical copy, so nothing is emitted.")
    caveat = fm.get("foreign_skills_caveat", "")
    if caveat:
        print(f"  caveat    {caveat}")
    # The shared-file trap, stated per affected skill and enumerated from the canonical copy this
    # runtime actually reads: one file, many readers, and a foreign reader ignores Claude-specific
    # keys — so user-invocable-only is exactly as lost here as on an emit runtime lacking the field.
    for name in sorted(gated_skills(project)):
        print(f"  warning   {name} is user-invocable-only (disable-model-invocation: true) in its "
              f"canonical frontmatter — {tool} reads the same file but ignores that key, so nothing "
              f"here prevents the model from invoking it on its own.")
    print(f"  note: allowed-tools restrictions in the canonical frontmatter are Claude-specific "
          f"keys in a shared file — {tool} does not honor them "
          f"(adapters/runtime/{tool}.md § Metadata mapping).")
    # Duplicate scan: every OTHER root this runtime reads (its own skills_root included) that
    # carries a same-named skill is the stale-copy-silently-wins risk, named while it is cheap.
    other_roots = [skills_emit_root(fm, tool)] + [
        r for r in parse_list(fm.get("reads_foreign_skills", "none")) if r != CANONICAL_SKILLS]
    for root in other_roots:
        for src in skills:
            name = src.parent.name
            dup = project / root / name / "SKILL.md"
            if dup.exists():
                print(f"  note: {root}/{name}/SKILL.md duplicates the canonical skill '{name}' — "
                      f"{tool} reads both roots and which copy wins is unverified; keep one, or "
                      f"re-run the install that emitted it to refresh it.")
    foreign: list[Path] = []
    rc = emit_agents(kit, project, fm, tool, version, foreign)
    rc = max(rc, emit_hooks(kit, project, fm, tool, version, foreign))
    return max(rc, report_foreign(foreign))


def run_emit(kit: Path, project: Path, fm: dict, tool: str, version: str) -> int:
    emit_root = project / skills_emit_root(fm, tool)
    foreign: list[Path] = []
    emitted = emit_skills(kit, emit_root, tool, version, foreign)
    print(f"{tool}: emitted {len(emitted)} skills into {emit_root}/")
    rc = emit_agents(kit, project, fm, tool, version, foreign)
    rc = max(rc, emit_hooks(kit, project, fm, tool, version, foreign))
    return max(rc, report_foreign(foreign))


def run_global(kit: Path, fm: dict, tool: str, version: str, mode: str) -> int:
    if mode != "emit":
        print(f"{tool}: --global is deliberately a no-op here — {tool} reads the canonical "
              f"{CANONICAL_SKILLS}/ copy inside each project, so a per-user global emission would "
              f"be a permanent stale-duplicate risk (the exact failure mode the emit-vs-verify "
              f"split exists to prevent). Run the per-project install instead (--local, the default).")
        return 0
    gsr = fm.get("global_skills_root", "unknown")
    if gsr == "unknown":
        print(f"emit_runtime: --global refused for {tool} — its adapter declares "
              f"global_skills_root: unknown because the documented sources disagree or are silent "
              f"on the per-user path, and guessing one would emit files nothing reads (see "
              f"adapters/runtime/{tool}.md and docs/runtimes.md; resolving it is live-verification "
              f"work). Use --local (the default).", file=sys.stderr)
        return 2
    emit_root = Path(gsr).expanduser()
    foreign: list[Path] = []
    emitted = emit_skills(kit, emit_root, tool, version, foreign)
    print(f"{tool}: emitted {len(emitted)} skills into {emit_root}/ (global)")
    print("  note: agent definitions are project-scoped (no global agents root is researched) — "
          "run the per-project install for them.")
    print("  note: hook wiring is project-scoped too (the guard reads the PROJECT's stack.yaml "
          "policy) — the per-project install emits or explains it.")
    return report_foreign(foreign)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="emit_runtime.py",
        description="Install the kit's skills for a runtime: verify-only where it reads the "
                    "canonical .claude/skills/ copy, translate-on-emit where it cannot.")
    ap.add_argument("--runtime", required=True, help="runtime name or alias (see adapters/runtime/)")
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--local", action="store_true", help="emit into the project repo (default)")
    scope.add_argument("--global", dest="global_scope", action="store_true",
                       help="emit into the runtime's declared per-user global skills root")
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
    version = kit_version(kit)
    mode = emission_mode(fm, tool)

    if args.global_scope:
        return run_global(kit, fm, tool, version, mode)
    if mode == "native":
        return verify_native(project, tool)
    if mode == "verify":
        return verify_foreign(kit, project, fm, tool, version)
    return run_emit(kit, project, fm, tool, version)


if __name__ == "__main__":
    raise SystemExit(main())
