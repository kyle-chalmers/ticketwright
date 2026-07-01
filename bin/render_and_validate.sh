#!/usr/bin/env bash
# render_and_validate.sh — render a SQL template AND gate the result. Wraps bin/render.sh so the
# token substitution stays single-sourced; adds the two authoring rules that bit a productized pull
# in the wild, plus a cheap structural check on the rendered SQL:
#
#   1. No {{token}} inside a SQL comment (ERROR). The renderer expands tokens everywhere — including
#      inside a `--` comment. A multi-line value (e.g. a 75-row VALUES list) then spills past the
#      `--`; the continuation rows are bare SQL → compile error. Describe params in prose, not tokens.
#   2. A token used as a SQL string/date literal must be QUOTED in the template (WARN; ERROR under
#      --strict). `SET d = {{asof}};` renders to `= 2026-06-30`, which the warehouse reads as
#      arithmetic (=1990), not a date — silent wrong results. Write `'{{asof}}'` in the template.
#
# Then it validates the rendered SQL: zero {{tokens}} remain, balanced single-quotes, balanced parens.
#
# Usage (same surface as render.sh):
#   bin/render_and_validate.sh STEP.sql.tmpl KEY=VALUE [KEY2=VALUE2 ...] [--strict]
#   bin/render_and_validate.sh STEP.sql.tmpl --vars FILE [--strict]
#
# Rendered SQL → stdout. Findings → stderr. Exit 1 on any ERROR (WARN also fails under --strict).
# This is for SQL step/QC templates; use plain render.sh for prose templates (README, tracker comment).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
render="$here/render.sh"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 TEMPLATE [KEY=VALUE ... | --vars FILE] [--strict]" >&2
  exit 1
fi
template="$1"; shift
[[ -f "$template" ]] || { echo "render_and_validate: template not found: $template" >&2; exit 1; }
[[ -f "$render"   ]] || { echo "render_and_validate: render.sh not found beside this script" >&2; exit 1; }

strict=0
declare -a fwd=()    # everything except --strict is forwarded to render.sh verbatim
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) strict=1; shift ;;
    *)        fwd+=("$1"); shift ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Substitute via the canonical renderer (non-strict: the validator below reports leftover tokens
# with full context). Guard the empty-array case for bash 3.2 under `set -u`.
if [[ ${#fwd[@]} -gt 0 ]]; then
  bash "$render" "$template" "${fwd[@]}" > "$TMP/rendered" 2>/dev/null
else
  bash "$render" "$template" > "$TMP/rendered" 2>/dev/null
fi

python3 - "$template" "$TMP/rendered" "$strict" <<'PY'
import re, sys
template_path, rendered_path, strict = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
errs, warns = [], []
TOKEN   = re.compile(r"\{\{[^{}]+\}\}")
LITERAL = re.compile(r"(<=|>=|<>|!=|=|<|>)[ \t]*\{\{\s*[\w.-]+\s*\}\}")

def classify(text):
    """Tag each char: 'c' code, 's' single-quoted string (''-escapes honored), 'm' comment
    (-- to EOL and /* */ blocks). Returns (tags, ended_inside_string)."""
    tags = []
    in_str = in_line = in_block = False
    i, n = 0, len(text)
    while i < n:
        c, two = text[i], text[i:i+2]
        if in_line:
            tags.append('m')
            if c == '\n':
                in_line = False
            i += 1; continue
        if in_block:
            if two == '*/':
                tags += ['m', 'm']; i += 2; in_block = False; continue
            tags.append('m'); i += 1; continue
        if in_str:
            if c == "'":
                if text[i+1:i+2] == "'":          # '' is an escaped quote, stay in string
                    tags += ['s', 's']; i += 2; continue
                tags.append('s'); in_str = False; i += 1; continue
            tags.append('s'); i += 1; continue
        if two == '--':
            tags += ['m', 'm']; i += 2; in_line = True; continue
        if two == '/*':
            tags += ['m', 'm']; i += 2; in_block = True; continue
        if c == "'":
            tags.append('s'); in_str = True; i += 1; continue
        tags.append('c'); i += 1; continue
    return ''.join(tags), in_str

# ---- pre-render lint on the TEMPLATE ----
tpl = open(template_path, encoding="utf-8").read()
ttags, _ = classify(tpl)
code_only = ''.join(ch if ttags[i] == 'c' else ' ' for i, ch in enumerate(tpl))
lineno = lambda pos: tpl.count('\n', 0, pos) + 1
for m in TOKEN.finditer(tpl):
    if all(ttags[j] == 'm' for j in range(m.start(), m.end())):      # rule 1: token in a comment
        ln = lineno(m.start())
        errs.append(f"L{ln}: {m.group(0)} inside a SQL comment — describe the param in prose; the "
                    f"renderer expands it and a multi-line value breaks out of the `--`.")
for m in LITERAL.finditer(code_only):                                # rule 2: unquoted SQL literal
    ln = lineno(m.start())
    warns.append(f"L{ln}: '{m.group(0).strip()}' — token used as an unquoted SQL literal; quote it "
                 f"in the template ('{{{{token}}}}') if it is a date/string, else it reads as arithmetic.")

# ---- post-render validation on the RENDERED output ----
out = open(rendered_path, encoding="utf-8").read()
left = sorted(set(t.group(0) for t in TOKEN.finditer(out)))
if left:
    errs.append("unresolved token(s) remain after render: " + " ".join(left))
otags, open_str = classify(out)
if open_str:
    errs.append("unbalanced single-quote in rendered SQL (a string literal never closes) — likely an "
                "unquoted token or a stray quote.")
depth = lo = 0
for i, ch in enumerate(out):
    if otags[i] != 'c':
        continue
    if ch == '(':
        depth += 1
    elif ch == ')':
        depth -= 1
        lo = min(lo, depth)
if depth != 0 or lo < 0:
    errs.append(f"unbalanced parentheses in rendered SQL (net depth {depth}) — a token may have "
                "expanded into a comment or broken a clause.")

for w in warns: print("  ⚠ WARN  " + w, file=sys.stderr)
for e in errs:  print("  ✗ ERROR " + e, file=sys.stderr)
fail = bool(errs) or (strict and bool(warns))
if errs or warns:
    print(f"render_and_validate: {len(errs)} error(s), {len(warns)} warning(s)"
          + ("" if not (strict and warns and not errs) else " (warnings fail under --strict)"),
          file=sys.stderr)
sys.exit(1 if fail else 0)
PY
rc=$?
cat "$TMP/rendered"
exit "$rc"
