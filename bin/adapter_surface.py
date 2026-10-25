#!/usr/bin/env python3
"""Which tool names an MCP adapter's verbs use on the agent that is running right now.

One connector can reach a session under different tool names depending on the agent. Claude Code
lists the Gmail connector's tools as `mcp__<server>__create_draft`; Codex CLI lists ChatGPT apps
under one server, `codex_apps`, with an app prefix on every tool (`gmail_create_draft`, with a
different argument shape), and the same is true of Slack and Notion. The tool did not change, so
this is not a new adapter, and the agent is per-machine (two teammates on one repo may run
different ones), so it can never be a `stack.yaml` choice either. It lives in the adapter: the
`## verb:` sections are the DEFAULT surface, and a runtime whose tool names differ gets a
`## Runtime surface: <runtime>` section with a `### verb:` subsection for every verb. This command
is the one place that picks between them:

  adapter_surface.py --adapter adapters/chat/gmail.md                # one plain line: which surface
  adapter_surface.py --adapter adapters/chat/gmail.md --verb draft   # that verb's section, as chosen
  adapter_surface.py --adapter adapters/chat/gmail.md --probe        # the read-only probe, as chosen
  adapter_surface.py --adapter adapters/chat/gmail.md --json         # everything, with provenance
    --runtime <id>    choose for this runtime instead of the detected one (aliases accepted)
    --surface <name>  choose a surface by name: `default` or a runtime id. Never falls back.

Selection: --surface, else the runtime's own section when the adapter has one, else the default.
The default's names were checked on the runtime the frontmatter's `default_surface:` names (the
reference runtime when absent); on any other runtime with no section of its own, the summary says
the names are unchecked there and asks for a report, never an edit. A surface is used WHOLE: a
runtime section missing a verb is a malformed adapter (exit 6), never a quiet mix of two surfaces'
tool names. The runtime comes from bin/kit_paths.py, the kit's one authority on that (--runtime,
$TICKETWRIGHT_RUNTIME, then each runtime adapter's detect_env).

When more than one agent's signals are set and they would pick different surfaces (a Codex session
started from inside Claude Code carries both), it refuses with exit 7 rather than guess.

Exit codes: 0 ok · 2 usage · 3 adapter not found · 5 no such surface · 6 malformed surfaces ·
7 the running agent is ambiguous (pass --runtime).
Stdlib only, read-only, no network. Diagnostics go to stderr.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Siblings resolve from THIS file's directory, never the project root (selftest section 20).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import kit_paths  # noqa: E402
from _yamlite import YamliteError, parse_frontmatter  # noqa: E402

DEFAULT = "default"
# The runtime an adapter's `## verb:` sections were checked against when its frontmatter does not
# say (`default_surface:`): the reference runtime the kit was built on (adapters/runtime/claude-code.md).
REFERENCE_RUNTIME = "claude-code"
SURFACE_RE = re.compile(r"^## Runtime surface: (\S+)\s*$")
VERB_RE = re.compile(r"^## verb: (\S+)")
SUB_VERB_RE = re.compile(r"^### verb: (\S+)")
SERVER_RE = re.compile(r"^server: ([A-Za-z0-9_-]+)\s*$")
TOOL_CALL_RE = re.compile(r"mcp__(.+?)__")


def _sections(lines: list[str], level: str) -> list[tuple[str, list[str]]]:
    """Split lines into (heading, body) at headings of exactly `level` ('## ' or '### ').

    A heading-looking line inside a code fence is content, not structure. The text before the
    first heading comes back under the heading ''.
    """
    out: list[tuple[str, list[str]]] = [("", [])]
    fence = False
    for ln in lines:
        if ln.startswith("```"):
            fence = not fence
        if not fence and ln.startswith(level):
            out.append((ln.rstrip(), []))
            continue
        out[-1][1].append(ln)
    return out


def _fenced(lines: list[str]) -> list[str]:
    out, fence = [], False
    for ln in lines:
        if ln.startswith("```"):
            fence = not fence
            continue
        if fence:
            out.append(ln)
    return out


def _probe(lines: list[str]) -> str | None:
    """The `### Read-only probe` subsection's text, heading included."""
    for head, body in _sections(lines, "### "):
        if head == "### Read-only probe":
            return "\n".join([head] + body).strip()
    return None


def parse_adapter(path: Path, runtimes: dict) -> dict:
    """The adapter's surfaces, plus every structural error. Errors mean nothing may be emitted.

    `runtimes` is kit_paths.runtime_adapters(): a surface must be named by a runtime's own `tool:`
    id, and its `server:` must be the namespace that runtime's adapter declares as
    `connector_server:`. That is what keeps a literal server name out of every other place.
    """
    canonical = {fm["tool"]: fm for _, fm in runtimes.values()}
    text = path.read_text(encoding="utf-8", errors="replace")
    errors: list[str] = []
    try:
        fm, body = parse_frontmatter(text, str(path))
    except YamliteError as exc:
        fm, body = {}, text
        errors.append(f"frontmatter does not parse: {exc}")
    declared = fm.get("surfaces") or []
    if isinstance(declared, str):
        declared = [declared]
    declared = [str(s).strip() for s in declared if str(s).strip()]

    verbs: dict[str, str] = {}
    default_probe = None
    found: dict[str, dict] = {}
    for head, sec in _sections(body.splitlines(), "## "):
        m = VERB_RE.match(head)
        if m:
            verbs[m.group(1)] = "\n".join([head] + sec).strip()
            continue
        if head == "## Permission posture (MCP)":
            default_probe = _probe(sec)
            continue
        m = SURFACE_RE.match(head)
        if not m:
            continue
        name = m.group(1)
        if name in found:
            errors.append(f"runtime surface {name} appears twice")
            continue
        subs = _sections(sec, "### ")
        servers = [SERVER_RE.match(ln).group(1) for ln in subs[0][1] if SERVER_RE.match(ln)]
        sverbs = {}
        for shead, sbody in subs:
            sm = SUB_VERB_RE.match(shead)
            if sm:
                sverbs[sm.group(1)] = "\n".join([shead] + sbody).strip()
        intro = "\n".join(ln for ln in subs[0][1] if not SERVER_RE.match(ln)).strip()
        found[name] = {"server": servers[0] if len(servers) == 1 else None, "verbs": sverbs,
                       "probe": _probe(sec), "lines": sec, "intro": intro}
        if len(servers) != 1:
            errors.append(f"runtime surface {name} must name exactly one `server:` line before its "
                          f"first ### heading (found {len(servers)})")

    for name in declared:
        if name not in found:
            errors.append(f"frontmatter lists surface {name} but the adapter has no "
                          f"'## Runtime surface: {name}' section")
    for name, s in found.items():
        if name not in declared:
            errors.append(f"section '## Runtime surface: {name}' is not listed in frontmatter "
                          f"`surfaces:`")
        if name == DEFAULT or name not in canonical:
            errors.append(f"runtime surface {name} names no runtime adapter under adapters/runtime/ "
                          f"(use the runtime's own `tool:` id, not an alias)")
        elif s["server"] and s["server"] != canonical[name].get("connector_server"):
            errors.append(f"runtime surface {name} names server {s['server']}, but "
                          f"adapters/runtime/{name}.md declares connector_server="
                          f"{canonical[name].get('connector_server') or '(none)'}")
        missing = sorted(set(verbs) - set(s["verbs"]))
        extra = sorted(set(s["verbs"]) - set(verbs))
        if missing:
            errors.append(f"runtime surface {name} lacks verb(s) {', '.join(missing)}: a surface is "
                          f"used whole, so every verb needs its own subsection")
        if extra:
            errors.append(f"runtime surface {name} has verb(s) outside this adapter's contract: "
                          f"{', '.join(extra)}")
        if s["probe"] is None or not _fenced(s["probe"].splitlines()):
            errors.append(f"runtime surface {name} has no fenced '### Read-only probe'")
        if s["server"]:
            for ln in _fenced(s["lines"]):
                for srv in TOOL_CALL_RE.findall(ln):
                    if srv != s["server"]:
                        errors.append(f"runtime surface {name} calls mcp__{srv}__… but declares "
                                      f"server {s['server']}")
    return {"fm": fm, "verbs": verbs, "default_probe": default_probe, "surfaces": found,
            "declared": declared, "errors": errors}


def locate(adapter: str, kit: Path | None, project: Path) -> Path | None:
    """Kit first, then the project (a vendored adapter), then as given (the resolver's order)."""
    p = Path(adapter).expanduser()
    if p.is_absolute():
        return p if p.is_file() else None
    for base in (kit, project, Path.cwd()):
        if base and (base / p).is_file():
            return (base / p).resolve()
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Pick the tool names an MCP adapter's verbs use on the running agent")
    ap.add_argument("--adapter", required=True, help="adapter path, e.g. adapters/chat/gmail.md")
    ap.add_argument("--runtime", help="choose for this runtime id instead of the detected one")
    ap.add_argument("--surface", help="choose this surface by name (default, or a runtime id)")
    ap.add_argument("--root", help="the project repo (default: as bin/kit_paths.py resolves it)")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--verb", help="print this verb's section for the chosen surface")
    out.add_argument("--probe", action="store_true", help="print the chosen surface's read-only probe")
    out.add_argument("--json", action="store_true", help="print everything as JSON")
    args = ap.parse_args()

    project, _ = kit_paths.resolve_project(args.root)
    kit, _ = kit_paths.resolve_kit(project)
    path = locate(args.adapter, kit, project)
    if path is None:
        print(f"Could not find the tool's setup notes at `{args.adapter}`. Check the path, or run "
              f"this from inside the project. Details: looked under kit={kit} and "
              f"project={project}.", file=sys.stderr)
        return 3
    # The runtime list comes from the kit that owns this adapter when it has one (a vendored copy
    # carries its own adapters/runtime/), so a fixture adapter is checked against real runtime ids.
    own_kit = path.parents[2] if len(path.parents) > 2 and kit_paths.is_kit(path.parents[2]) else kit
    runtimes = kit_paths.runtime_adapters(own_kit)
    parsed = parse_adapter(path, runtimes)
    fm = parsed["fm"]
    tool = str(fm.get("tool") or path.stem)

    if args.runtime:
        asked, runtime_src = args.runtime, "--runtime"
    else:
        asked, runtime_src = kit_paths.detect_runtime(own_kit)
    entry = runtimes.get(asked)
    runtime = entry[1]["tool"] if entry else asked   # an alias resolves to its runtime's own id

    # Detection takes the first runtime whose signal is set, and a Codex session started from
    # inside Claude Code carries Claude's signal too. When the agents whose signals are set would
    # pick DIFFERENT surfaces, guessing is how a session calls tools it does not have, so refuse
    # and ask for --runtime. An explicit --runtime, $TICKETWRIGHT_RUNTIME or --surface settles it.
    if not args.runtime and not args.surface and runtime_src != "TICKETWRIGHT_RUNTIME":
        signals = kit_paths.detect_runtimes(own_kit)
        picks = {(r if r in parsed["surfaces"] else DEFAULT) for r, _ in signals}
        if len(picks) > 1:
            names = ", ".join(f"{r} ({src})" for r, src in signals)
            print(f"More than one agent's signals are set here, and they use different tool names "
                  f"for {tool}, so no call is printed. Run again with `--runtime <id>` naming the "
                  f"agent you are. Details: signals: {names}.", file=sys.stderr)
            return 7

    available = [DEFAULT] + sorted(parsed["surfaces"])
    if args.surface:
        if args.surface not in available:
            print(f"`{tool}` has no tool-name section called `{args.surface}`. Pick one of: "
                  f"{', '.join(available)}. Details: --surface never falls back to another "
                  f"surface.", file=sys.stderr)
            return 5
        surface, selected_by = args.surface, "explicit"
    elif runtime in parsed["surfaces"]:
        surface, selected_by = runtime, "runtime"
    else:
        surface, selected_by = DEFAULT, "default"

    transport = str(fm.get("transport") or "").split()[0] if fm.get("transport") else ""
    if surface == DEFAULT:
        verbs, probe = parsed["verbs"], parsed["default_probe"]
        server, server_source = None, ("slot" if transport in ("mcp", "both") else None)
    else:
        s = parsed["surfaces"][surface]
        verbs, probe = s["verbs"], s["probe"]
        server, server_source = s["server"], "surface"

    rel = args.adapter
    checked_on = str(fm.get("default_surface") or REFERENCE_RUNTIME)
    if surface != DEFAULT:
        summary = (f"On {runtime}, {tool} uses its own tool names: run each action as the "
                   f"`## Runtime surface: {surface}` section of `{rel}` writes it. The tool slot's "
                   f"`mcp:` value is not used here. Details: surface={surface} "
                   f"selected_by={selected_by} server={server} runtime_source={runtime_src}.")
    elif runtime == checked_on or selected_by == "explicit" or server_source is None:
        summary = (f"{tool} uses the tool names in the action sections of `{rel}`, with the tool "
                   f"slot's `mcp:` value as the server name. Details: surface=default "
                   f"selected_by={selected_by} runtime={runtime} ({runtime_src}).")
    else:
        summary = (f"{tool} uses the tool names in the action sections of `{rel}`, but nobody has "
                   f"checked them on {runtime}. Before the first call, find each name in this "
                   f"session's tool list; if one is missing, report it so the kit can record this "
                   f"runtime's names, and do not edit the file. Details: surface=default "
                   f"selected_by=default runtime={runtime} ({runtime_src}); recorded surfaces: "
                   f"{', '.join(sorted(parsed['surfaces'])) or 'none'}.")

    if parsed["errors"]:
        if args.json:
            print(json.dumps({"schema": 1, "adapter": rel, "tool": tool, "surface": None,
                              "verbs": {}, "probe": None, "errors": parsed["errors"]}, indent=2))
        print(f"The tool-name sections of `{rel}` are broken, so no call is printed. Fix the file "
              f"in the kit. Details: " + "; ".join(parsed["errors"]), file=sys.stderr)
        return 6

    # A runtime section's opening paragraph says what differs and which rules still hold, so it
    # travels with every verb or probe printed from that section.
    lead = ""
    if surface != DEFAULT:
        lead = (f"## Runtime surface: {surface} (server `{server}`)\n\n"
                f"{parsed['surfaces'][surface]['intro']}\n\n")
    if args.verb:
        if args.verb not in verbs:
            print(f"`{tool}` has no action called `{args.verb}`. Pick one of: "
                  f"{', '.join(sorted(verbs))}.", file=sys.stderr)
            return 2
        print(lead + verbs[args.verb])
        return 0
    if args.probe:
        if not probe:
            print(f"`{rel}` carries no read-only probe for surface {surface}.", file=sys.stderr)
            return 2
        print(lead + probe)
        return 0
    if args.json:
        print(json.dumps({
            "schema": 1,
            "adapter": rel,
            "adapter_path": str(path),
            "seam": fm.get("seam"),
            "tool": tool,
            "runtime": runtime,
            "runtime_source": runtime_src,
            "surface": surface,
            "selected_by": selected_by,
            "surfaces": available,
            "default_checked_on": checked_on,
            "server": server,
            "server_source": server_source,
            "verbs": verbs,
            "probe": probe,
            "summary": summary,
            "errors": [],
        }, indent=2))
        return 0
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
