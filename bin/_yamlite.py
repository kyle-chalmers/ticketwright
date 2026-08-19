#!/usr/bin/env python3
"""_yamlite.py — the kit's supported YAML subset, parsed with the standard library only.

WHY THIS EXISTS. `pyproject.toml` advertises "Zero runtime dependencies — the kit is deliberately
stdlib-only", so the config resolver must not shell out to `yq`: that would make a shell binary a
hard dependency of a pip package promising none. The alternative the kit used to reach for — a
narrow regex per key — is worse, because it silently reads the wrong thing rather than failing.

So: an EXPLICIT SUPPORTED SUBSET, validated, that FAILS LOUDLY with a file:line and the rule that
was broken. Never a silent misparse.

SUPPORTED (every construct below appears in a shipped kit file — this list is derived from the tree,
not aspirational):
  - block mappings at any indent width
  - block sequences, INCLUDING sequences of mappings (`- glob: "*.sql"` with a sibling `app:` on the
    next line) — `.claude/config/viewer.example.yaml` needs this, and bin/handoff.sh cannot leave
    `yq` behind without it
  - flow mappings `{a: 1, b: 2}` and flow sequences `[a, b]`, nested
  - single/double-quoted scalars with escapes, plain scalars, and `#` comment stripping AFTER a
    closing quote or a closing flow node (not just on plain scalars)
  - block scalars `|` `>` with the `-`/`+`/indent indicators. NOT optional: all 23 adapters carry
    `auth: |` in their frontmatter, and the resolver's whole allowlist is read out of that
    frontmatter.
  - a leading `---` document marker

REJECTED, each naming its line and its rule: anchors (`&x`), aliases (`*x`), tags (`!!str`),
multi-document streams, explicit/complex keys (`? `), and merge keys (`<<:`).

SCALAR TYPING matches `yq -o=json` (go-yaml v3, YAML 1.2 core schema) so selftest can use `yq` as an
independent oracle against this parser:
  true/false -> bool;  on/off/yes/no -> STRING;  null/~/empty -> None;  ints/floats -> numbers;
  `0a1b2c3d4e5f6789` and `C0XXXXXXXXX` -> string;  anything quoted -> string.

CALLERS READING A POLICY MUST USE `scalar_str()`. `.claude/hooks/_stack.py` aliases the *string*
"true" to high_risk; handing it a Python bool makes the lookup miss and silently tighten two shipped
configs to `all`.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

__all__ = ["YamliteError", "config_trace", "parse", "parse_file", "parse_frontmatter",
           "scalar_str"]

SUBSET_DOC = "the supported YAML subset (see bin/_yamlite.py)"


class YamliteError(ValueError):
    """A construct outside the supported subset, or a malformed document.

    Carries the location and the rule so a caller can print something actionable rather than
    "parse error".
    """

    def __init__(self, message: str, line: int, filename: str = "<config>", rule: str = "") -> None:
        self.message, self.line, self.filename, self.rule = message, line, filename, rule
        hint = f"  [{rule}]" if rule else ""
        super().__init__(f"{filename}:{line}: {message}{hint}")



def config_trace(root: object, note: str) -> None:
    """Test-only breadcrumb: prove a consumer read config through the shared stack.

    Selftest asserts every migrated consumer reaches this code, which cannot be shown by comparing
    VALUES — everything build_ticket_index.load_config() returns is `project.*`, reserved to tier 1
    by construction, so a correct migration changes no output at all. Lives in this leaf module so
    both the resolver and resolve_user.py can call it with no import cycle.
    """
    import os
    dest = os.environ.get("TICKETWRIGHT_CONFIG_TRACE")
    if not dest:
        return
    try:
        with open(dest, "a", encoding="utf-8") as fh:
            fh.write(f"{root}\t{note}\n")
    except OSError:
        pass


# ── scalar typing ──────────────────────────────────────────────────────────────────────────────
_INT = re.compile(r"^[-+]?[0-9]+$")
_HEX = re.compile(r"^[-+]?0[xX][0-9a-fA-F]+$")
_OCT = re.compile(r"^[-+]?0[oO][0-7]+$")
_FLOAT = re.compile(r"^[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.[0-9]*)(?:[eE][-+]?[0-9]+)?$"
                    r"|^[-+]?[0-9]+[eE][-+]?[0-9]+$")


def _plain_scalar(text: str) -> Any:
    """Type a PLAIN (unquoted) scalar the way yq/go-yaml v3 does."""
    if text == "" or text in ("~", "null", "Null", "NULL"):
        return None
    if text in ("true", "True", "TRUE"):
        return True
    if text in ("false", "False", "FALSE"):
        return False
    # on/off/yes/no are NOT booleans in the YAML 1.2 core schema, and yq agrees. Treating them as
    # bools here would flip `db_write_requires_approval: off` into a Python False and defeat the
    # policy alias table, which keys on strings.
    if _INT.match(text):
        return int(text, 10)
    if _HEX.match(text):
        return int(text, 16)
    if _OCT.match(text):
        return int(text.replace("o", "").replace("O", ""), 8)
    if _FLOAT.match(text):
        return float(text)
    return text


def scalar_str(value: Any) -> str:
    """Render a parsed scalar back to its YAML spelling, lowercased — for enum lookups.

    `True` -> "true", `None` -> "null", `"Off"` -> "off". Policy readers must go through this;
    see the module docstring.
    """
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value).strip().lower()


# ── line model ─────────────────────────────────────────────────────────────────────────────────
class _Line:
    __slots__ = ("indent", "text", "no")

    def __init__(self, indent: int, text: str, no: int) -> None:
        self.indent, self.text, self.no = indent, text, no


_TAB = re.compile(r"^[ ]*\t")


def _reject_scan(raw: str, no: int, filename: str) -> None:
    """Constructs we refuse OUTRIGHT, checked before any structural parsing.

    Deliberately checked on the raw line: a rejected construct must be reported at the line the
    author wrote, not wherever the parser happened to notice the damage.
    """
    body = raw.strip()
    if body.startswith("? "):
        raise YamliteError("explicit/complex mapping keys are not supported", no, filename,
                           "no complex keys")
    if body.startswith("<<:") or body.startswith("<< :"):
        raise YamliteError("YAML merge keys (`<<:`) are not supported", no, filename,
                           "no merge keys")


def _scan(text: str, filename: str) -> list[_Line]:
    """Split into significant lines, resolving block scalars and rejecting the unsupported.

    Block scalar bodies are consumed here rather than in the parser so that prose inside them can
    never be mistaken for configuration — the same reason `db_write_guard.seam_block` skips them.
    """
    out: list[_Line] = []
    raw_lines = text.splitlines()
    i, n = 0, len(raw_lines)
    seen_doc_start = False
    while i < n:
        raw = raw_lines[i]
        no = i + 1
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if stripped in ("---", "...") or stripped.startswith("--- "):
            # One leading document marker is fine; a second means a multi-document stream.
            if stripped.startswith("...") or seen_doc_start or out:
                raise YamliteError("multi-document YAML streams are not supported", no, filename,
                                   "single document only")
            seen_doc_start = True
            i += 1
            continue
        if _TAB.match(raw):
            raise YamliteError("tab indentation is not valid YAML", no, filename, "spaces only")
        _reject_scan(raw, no, filename)
        indent = len(raw) - len(raw.lstrip(" "))
        body = raw[indent:].rstrip()
        # Block scalar? Consume its body now and hand the parser a resolved string.
        m = re.match(r"^(.*?):\s*([|>])([+-]?)([0-9]*)([+-]?)\s*(?:#.*)?$", body)
        if m and not _looks_flow(m.group(1)):
            key_part = m.group(1)
            style, chomp1, digits, chomp2 = m.group(2), m.group(3), m.group(4), m.group(5)
            chomp = chomp1 or chomp2
            value, i = _read_block_scalar(raw_lines, i + 1, indent, style, chomp,
                                          int(digits) if digits else None)
            out.append(_Line(indent, f"{key_part}: \x00{value}", no))
            continue
        out.append(_Line(indent, body, no))
        i += 1
    return out


def _looks_flow(s: str) -> bool:
    return "{" in s or "[" in s


def _read_block_scalar(lines: list[str], i: int, parent_indent: int, style: str,
                       chomp: str, explicit_indent: int | None) -> tuple[str, int]:
    body: list[str] = []
    content_indent = (parent_indent + explicit_indent) if explicit_indent else None
    n = len(lines)
    while i < n:
        raw = lines[i]
        if raw.strip() == "":
            body.append("")
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent <= parent_indent:
            break
        if content_indent is None:
            content_indent = indent
        if indent < content_indent:
            break
        body.append(raw[content_indent:])
        i += 1
    while body and body[-1] == "":
        body.pop()
    if style == "|":
        text = "\n".join(body)
    else:  # folded: a single newline between non-empty lines becomes a space
        parts: list[str] = []
        for ln in body:
            if ln == "":
                parts.append("\n")
            elif parts and parts[-1] not in ("\n",) and not ln.startswith(" "):
                parts[-1] = parts[-1] + " " + ln
                continue
            else:
                parts.append(ln)
        text = "".join(p if p == "\n" else p for p in parts) if parts else ""
        text = "\n".join(x for x in text.split("\n"))
    if chomp == "-":
        return text, i
    if chomp == "+":
        return text + "\n", i
    return (text + "\n") if text else "", i


# ── scalar / flow parsing ──────────────────────────────────────────────────────────────────────
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "/": "/",
            "b": "\b", "f": "\f", "'": "'"}


def _read_quoted(s: str, i: int, no: int, filename: str) -> tuple[str, int]:
    quote = s[i]
    i += 1
    buf: list[str] = []
    while i < len(s):
        c = s[i]
        if quote == '"' and c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            buf.append(_ESCAPES.get(nxt, nxt))
            i += 2
            continue
        if quote == "'" and c == "'" and i + 1 < len(s) and s[i + 1] == "'":
            buf.append("'")
            i += 2
            continue
        if c == quote:
            return "".join(buf), i + 1
        buf.append(c)
        i += 1
    raise YamliteError("unterminated quoted string", no, filename, "balanced quotes")


def _strip_comment(s: str) -> str:
    """Drop a trailing ` # comment` from a PLAIN scalar. A '#' with no leading space is literal."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "#" and (i == 0 or s[i - 1] in " \t"):
            break
        out.append(c)
        i += 1
    return "".join(out).rstrip()


def _reject_node_prefix(value: str, no: int, filename: str) -> None:
    v = value.lstrip()
    if v.startswith("&"):
        raise YamliteError("YAML anchors (`&name`) are not supported", no, filename, "no anchors")
    if v.startswith("*"):
        raise YamliteError("YAML aliases (`*name`) are not supported", no, filename, "no aliases")
    if v.startswith("!"):
        raise YamliteError("YAML tags (`!`/`!!`) are not supported", no, filename, "no tags")


def _parse_value(value: str, no: int, filename: str) -> Any:
    """A scalar or a flow collection, given the text to the right of `key:` or `-`."""
    if value.startswith("\x00"):          # a block scalar resolved during the scan
        return value[1:]
    value = value.strip()
    _reject_node_prefix(value, no, filename)
    if value == "":
        return None
    if value[0] in "\"'":
        text, end = _read_quoted(value, 0, no, filename)
        rest = value[end:].strip()
        if rest and not rest.startswith("#"):
            raise YamliteError(f"unexpected text after a quoted scalar: {rest!r}", no, filename,
                               "one value per key")
        return text
    if value[0] in "{[":
        node, end = _parse_flow(value, 0, no, filename)
        rest = value[end:].strip()
        if rest and not rest.startswith("#"):
            raise YamliteError(f"unexpected text after a flow collection: {rest!r}", no, filename,
                               "one value per key")
        return node
    return _plain_scalar(_strip_comment(value))


def _parse_flow(s: str, i: int, no: int, filename: str) -> tuple[Any, int]:
    opening = s[i]
    closing = "}" if opening == "{" else "]"
    container: Any = {} if opening == "{" else []
    i += 1
    while True:
        while i < len(s) and s[i] in " \t,":
            i += 1
        if i >= len(s):
            raise YamliteError(f"unterminated flow collection (expected `{closing}`)", no, filename,
                               "balanced flow nodes")
        if s[i] == closing:
            return container, i + 1
        item, i = _parse_flow_item(s, i, no, filename)
        if opening == "{":
            if not (isinstance(item, tuple) and len(item) == 2):
                raise YamliteError("a flow mapping entry must be `key: value`", no, filename,
                                   "flow mappings are key/value")
            key, val = item
            container[key] = val
        else:
            container.append(item)


def _parse_flow_item(s: str, i: int, no: int, filename: str) -> tuple[Any, int]:
    """One flow entry. In a mapping context this returns (key, value); in a sequence, the value."""
    token, i = _read_flow_scalar(s, i, no, filename)
    while i < len(s) and s[i] in " \t":
        i += 1
    if i < len(s) and s[i] == ":":
        i += 1
        while i < len(s) and s[i] in " \t":
            i += 1
        if i < len(s) and s[i] in "{[":
            val, i = _parse_flow(s, i, no, filename)
        else:
            val, i = _read_flow_scalar(s, i, no, filename)
        return (str(token) if not isinstance(token, str) else token, val), i
    return token, i


def _read_flow_scalar(s: str, i: int, no: int, filename: str) -> tuple[Any, int]:
    if i < len(s) and s[i] in "{[":
        return _parse_flow(s, i, no, filename)
    if i < len(s) and s[i] in "\"'":
        text, end = _read_quoted(s, i, no, filename)
        return text, end
    start = i
    depth = 0
    while i < len(s):
        c = s[i]
        if c in "{[":
            depth += 1
        elif c in "}]":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c in ",:":
            break
        i += 1
    raw = s[start:i].strip()
    _reject_node_prefix(raw, no, filename)
    return _plain_scalar(raw), i


# ── block structure ────────────────────────────────────────────────────────────────────────────
_KEY = re.compile(r"^((?:\"(?:[^\"\\]|\\.)*\")|(?:'(?:[^']|'')*')|(?:[^:#]+?))\s*:(?:\s+(.*))?$")


def _split_key(text: str, no: int, filename: str) -> tuple[str, str] | None:
    if text.startswith("\x00"):
        return None
    # A block scalar was resolved during the scan into `key: \x00<body>`, and the body carries real
    # newlines — so the `key:` regex (deliberately not DOTALL) cannot match it. Split on the
    # sentinel first. Without this every adapter's `auth: |` frontmatter fails to parse.
    sentinel = text.find(": \x00")
    if sentinel != -1:
        key_raw, rest = text[:sentinel].strip(), text[sentinel + 2:]
        if key_raw[:1] in "\"'":
            key, end = _read_quoted(key_raw, 0, no, filename)
            if key_raw[end:].strip():
                return None
        else:
            _reject_node_prefix(key_raw, no, filename)
            key = key_raw
        return key, rest
    m = _KEY.match(text)
    if not m:
        # `key:` with nothing after it (no trailing space) is the common nested-block form.
        m2 = re.match(r"^((?:\"(?:[^\"\\]|\\.)*\")|(?:'(?:[^']|'')*')|(?:[^:#]+?))\s*:$", text)
        if not m2:
            return None
        key_raw, rest = m2.group(1), ""
    else:
        key_raw, rest = m.group(1), (m.group(2) or "")
    key_raw = key_raw.strip()
    if key_raw[:1] in "\"'":
        key, end = _read_quoted(key_raw, 0, no, filename)
        if key_raw[end:].strip():
            return None
    else:
        _reject_node_prefix(key_raw, no, filename)
        key = key_raw
    return key, rest


class _Parser:
    def __init__(self, lines: list[_Line], filename: str) -> None:
        self.lines, self.filename, self.i = lines, filename, 0

    def peek(self) -> _Line | None:
        return self.lines[self.i] if self.i < len(self.lines) else None

    def parse_document(self) -> Any:
        if not self.lines:
            return {}
        value = self.parse_block(self.lines[0].indent)
        nxt = self.peek()
        if nxt is not None:
            raise YamliteError(f"unexpected dedent or trailing content: {nxt.text!r}", nxt.no,
                               self.filename, "consistent indentation")
        return value

    def parse_block(self, indent: int) -> Any:
        line = self.peek()
        if line is None or line.indent < indent:
            return None
        if line.text == "-" or line.text.startswith("- "):
            return self.parse_seq(indent)
        return self.parse_map(indent)

    def parse_map(self, indent: int) -> dict:
        out: dict = {}
        while True:
            line = self.peek()
            if line is None or line.indent < indent:
                return out
            if line.indent > indent:
                raise YamliteError(f"unexpected indentation: {line.text!r}", line.no,
                                   self.filename, "consistent indentation")
            if line.text == "-" or line.text.startswith("- "):
                raise YamliteError("a sequence item where a mapping key was expected", line.no,
                                   self.filename, "one node kind per block")
            split = _split_key(line.text, line.no, self.filename)
            if split is None:
                raise YamliteError(f"not a `key: value` mapping entry: {line.text!r}", line.no,
                                   self.filename, "block mappings only")
            key, rest = split
            self.i += 1
            if rest.strip() == "" and not rest.startswith("\x00"):
                nxt = self.peek()
                out[key] = self.parse_block(nxt.indent) if (nxt and nxt.indent > indent) else None
            else:
                out[key] = _parse_value(rest, line.no, self.filename)

    def parse_seq(self, indent: int) -> list:
        out: list = []
        while True:
            line = self.peek()
            if line is None or line.indent < indent:
                return out
            if line.indent > indent or not (line.text == "-" or line.text.startswith("- ")):
                return out
            rest = line.text[1:]
            content_indent = indent + 1 + (len(rest) - len(rest.lstrip(" ")))
            rest = rest.strip()
            self.i += 1
            if rest == "":
                nxt = self.peek()
                out.append(self.parse_block(nxt.indent) if (nxt and nxt.indent > indent) else None)
                continue
            # `- key: value` — a mapping whose first entry shares the dash's line. Splice a
            # synthetic line at the content column so following siblings join the same mapping;
            # this is the shape viewer routes use (`- glob: "*.sql"` / `  app: DataGrip`).
            if _split_key(rest, line.no, self.filename) is not None:
                self.lines.insert(self.i, _Line(content_indent, rest, line.no))
                out.append(self.parse_map(content_indent))
            else:
                out.append(_parse_value(rest, line.no, self.filename))


def parse(text: str, filename: str = "<config>") -> Any:
    """Parse the supported subset. Raises YamliteError with a file:line and the rule broken."""
    return _Parser(_scan(text, filename), filename).parse_document()


def parse_file(path: str | Path) -> Any:
    p = Path(path)
    return parse(p.read_text(encoding="utf-8", errors="replace"), str(p))


_FM = re.compile(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|$)", re.S)


def parse_frontmatter(text: str, filename: str = "<doc>") -> tuple[dict, str]:
    """Split a `---` frontmatter block from a markdown body and parse the block.

    Adapter files are frontmatter + markdown, NOT a YAML multi-document stream — parsing them as
    one would trip the multi-doc rejection on every adapter in the tree. Returns ({}, text) when
    there is no frontmatter.
    """
    m = _FM.match(text)
    if not m:
        return {}, text
    data = parse(m.group(1), filename)
    return (data if isinstance(data, dict) else {}), text[m.end():]
