#!/usr/bin/env python3
"""Plain-language lint for text a person sees (selftest section 59).

The rule: the plain part of a message, everything before the first "Details:", is non-empty and
contains no term from terms.txt. Text inside `code spans` is exempt, because it is something the
person types or reads literally (a command, a setting, a file name). The Details part is free.

Inputs (repeatable):
  --golden FILE  a guard golden corpus (tests/guard/golden.json): each case's stdout is parsed and
                 its `ask` permissionDecisionReason and any systemMessage are checked. `allow` and
                 `deny` reasons are skipped: per the Claude Code hooks docs an allow reason goes to
                 the debug log and a deny reason goes to the model.
  --text FILE    captured output; every non-blank line is one message
  --marked FILE  a skill or agent file; text between the user-facing markers is checked line by line
  --py FILE      python source; string literals passed as ConfigError's 3rd argument, _err's 2nd
                 argument, or assigned to a variable named `msg` are checked (f-string fields are
                 replaced by "{}")
Exit 0 when clean, 1 with one finding per line, 2 on bad usage. Stdlib only. Repo-only test
material: tests/ ships in neither the wheel nor the plugin.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BEGIN = "<!-- ticketwright:user-facing:begin -->"
END = "<!-- ticketwright:user-facing:end -->"
CODE_SPAN = re.compile(r"`[^`]*`")
DETAILS = re.compile(r"(?:^|\s)Details:")
PY_SINKS = {"ConfigError": 2, "_err": 1}
# An unreadable or malformed input is a usage error (exit 2), never a traceback.
READ_ERRORS = (OSError, UnicodeDecodeError, json.JSONDecodeError, SyntaxError)


def load_terms(path: Path) -> list[tuple[re.Pattern, str, str]]:
    out = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        term, _, plain = raw.partition("\t")
        term = term.strip()
        # Whole-word only for plain ASCII words. Python's \w also matches circled digits (①), so
        # those, and anything containing "/" or non-ASCII, match as substrings.
        if "/" in term or not re.fullmatch(r"[A-Za-z0-9_-]+", term):
            pat = re.compile(re.escape(term), re.I)
        else:
            pat = re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(term) + r"(?![A-Za-z0-9_-])", re.I)
        out.append((pat, term, plain.strip()))
    return out


def plain_part(message: str) -> str:
    return DETAILS.split(message, maxsplit=1)[0]


def check(source: str, message: str, terms) -> list[str]:
    message = message.strip()
    if not message:
        return []
    plain = CODE_SPAN.sub(" ", plain_part(message)).strip()
    excerpt = message if len(message) <= 120 else message[:117] + "..."
    if not plain:
        return [f"{source}: no plain part before 'Details:' in: {excerpt}"]
    return [f"{source}: '{term}' (say: {say}) in: {excerpt}"
            for pat, term, say in terms if pat.search(plain)]


def from_golden(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    for name, case in sorted(data.items()):
        for line in (case.get("stdout") or "").splitlines():
            if not line.startswith("{"):
                continue
            out = json.loads(line)
            hso = out.get("hookSpecificOutput") or {}
            if hso.get("permissionDecision") == "ask":
                yield f"{path.name}#{name} (ask)", hso.get("permissionDecisionReason", "")
            if out.get("systemMessage"):
                yield f"{path.name}#{name} (systemMessage)", out["systemMessage"]


def from_text(path: Path):
    for n, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if line.strip():
            yield f"{path.name}:{n}", line


def from_marked(path: Path):
    inside = False
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip() == BEGIN:
            inside = True
        elif line.strip() == END:
            inside = False
        elif inside and line.strip():
            yield f"{path}:{n}", line.lstrip("> ").strip()


def _literal(node) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) else "{}" for v in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _literal(node.left), _literal(node.right)
        if left is not None or right is not None:
            return (left or "{}") + (right or "{}")
    return None


def from_py(path: Path):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in PY_SINKS:
            idx = PY_SINKS[node.func.id]
            if len(node.args) > idx:
                text = _literal(node.args[idx])
                if text is not None:
                    yield f"{path}:{node.lineno}", text
        elif isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "msg" for t in node.targets):
            text = _literal(node.value)
            if text is not None:
                yield f"{path}:{node.lineno}", text


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--terms", type=Path, default=HERE / "terms.txt")
    ap.add_argument("--golden", type=Path, action="append", default=[])
    ap.add_argument("--text", type=Path, action="append", default=[])
    ap.add_argument("--marked", type=Path, action="append", default=[])
    ap.add_argument("--py", type=Path, action="append", default=[])
    args = ap.parse_args(argv)
    if not (args.golden or args.text or args.marked or args.py):
        ap.error("give at least one input")
    try:
        terms = load_terms(args.terms)
    except READ_ERRORS as e:
        print(f"check.py: cannot read {args.terms}: {e}", file=sys.stderr)
        return 2
    findings: list[str] = []
    for readers, paths in ((from_golden, args.golden), (from_text, args.text),
                           (from_marked, args.marked), (from_py, args.py)):
        for p in paths:
            try:
                items = list(readers(p))
            except READ_ERRORS as e:
                print(f"check.py: cannot read {p}: {e}", file=sys.stderr)
                return 2
            for source, message in items:
                findings += check(source, message, terms)
    for f in findings:
        print(f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
