#!/usr/bin/env bash
# split_and_export.sh — the export-phase helper productized multi-deliverable skills kept re-improvising.
#
# Two jobs, both about getting clean CSVs out of a warehouse CLI:
#
#   SPLIT  one multi-result SQL file (N independent SELECT blocks delimited by `-- Query N` markers)
#          into N runnable .sql files, each carrying the shared preamble (USE WAREHOUSE / USE ROLE /
#          any SPLIT_TO_TABLE sample that sits above the first marker). Optionally --run each through
#          your warehouse adapter and strip the CLI preamble from every CSV.
#
#   STRIP  the multi-statement preamble a `-f` run prints ahead of the real result
#          (`status` / `Statement executed successfully.` / blank lines). Robust: drops through the
#          LAST "Statement executed successfully." then leading blanks, or anchors on a known header.
#
# Usage:
#   bin/split_and_export.sh INPUT.sql OUTDIR [--marker REGEX] [--ext csv] [--run 'CMD']
#   bin/split_and_export.sh --strip-only FILE [--header REGEX]        # FILE may be - for stdin→stdout
#
#   --run CMD : a command template run once per split file. {sql} → the chunk path, {csv} → its output
#               path. CMD's stdout is captured as the CSV (then stripped); or CMD may write {csv} itself.
#               Tool-agnostic — you supply your adapter's query verb, e.g.
#                 --run 'snow sql -f {sql} --format csv'
#               (a leaf helper may name your warehouse CLI; the skill orchestration stays neutral.)
#   --marker  : default '^\s*--+\s*Query\s+\d+' (case-insensitive). --ext: output extension (csv).
set -uo pipefail

py_strip() {  # py_strip FILE HEADER_REGEX  — strips the preamble from FILE in place (real path only)
  python3 - "$1" "$2" <<'PY'
import re, sys
path, header = sys.argv[1], (sys.argv[2] or None)
data = open(path, encoding="utf-8").read().splitlines()
idx = [i for i, l in enumerate(data) if l.strip() == "Statement executed successfully."]
if idx:                                            # drop through the LAST "Statement executed…"
    start = idx[-1] + 1
elif header:                                       # …or anchor on a known header row
    h = re.compile(header); hit = [i for i, l in enumerate(data) if h.search(l)]
    start = hit[0] if hit else 0
else:
    start = 0
while start < len(data) and data[start].strip() == "":   # …then leading blanks
    start += 1
out = "\n".join(data[start:])
open(path, "w", encoding="utf-8").write(out + "\n" if out else out)
print(f"strip: dropped {start} preamble line(s) from {path}", file=sys.stderr)
PY
}

# ---- strip-only mode ----
if [[ "${1:-}" == "--strip-only" ]]; then
  file="${2:-}"; header=""
  [[ -n "$file" ]] || { echo "usage: $0 --strip-only FILE [--header REGEX]" >&2; exit 1; }
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in --header) header="${2:-}"; shift 2 ;; *) echo "unrecognized arg: $1" >&2; exit 1 ;; esac
  done
  if [[ "$file" == "-" ]]; then                 # stdin → stdout (heredoc owns python's stdin, so buffer first)
    tmp="$(mktemp)"; cat > "$tmp"
    py_strip "$tmp" "$header" 2>/dev/null
    cat "$tmp"; rm -f "$tmp"
  else
    [[ -f "$file" ]] || { echo "strip: file not found: $file" >&2; exit 1; }
    py_strip "$file" "$header"
  fi
  exit 0
fi

# ---- split (+ optional run) mode ----
input="${1:-}"; outdir="${2:-}"
{ [[ -n "$input" && -n "$outdir" ]]; } || { echo "usage: $0 INPUT.sql OUTDIR [--marker REGEX] [--ext csv] [--run 'CMD']" >&2; exit 1; }
[[ -f "$input" ]] || { echo "split: input not found: $input" >&2; exit 1; }
shift 2
marker='^\s*--+\s*Query\s+\d+'; ext="csv"; run=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker) marker="${2:-}"; shift 2 ;;
    --ext)    ext="${2:-}";    shift 2 ;;
    --run)    run="${2:-}";    shift 2 ;;
    *) echo "unrecognized arg: $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$outdir"

# Split into OUTDIR/NN-slug.sql (preamble replicated into each). Print the written paths, one per line.
made=()   # bash-3.2-safe collection (no mapfile/readarray)
while IFS= read -r _line; do made+=("$_line"); done < <(python3 - "$input" "$outdir" "$marker" <<'PY'
import re, sys, os
input_path, outdir, marker = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(input_path, encoding="utf-8").read().splitlines()
mre = re.compile(marker, re.IGNORECASE)
marks = [i for i, l in enumerate(lines) if mre.search(l)]
if marks:
    preamble = lines[:marks[0]]
    bounds = marks + [len(lines)]
    chunks = [(marks[k], lines[marks[k]:bounds[k+1]]) for k in range(len(marks))]
else:                                   # no markers → treat the whole file as one query
    preamble, chunks = [], [(None, lines)]
pre = ("\n".join(preamble).rstrip() + "\n\n") if any(s.strip() for s in preamble) else ""
def slug(headline, k):
    if headline is None:
        return "query"
    s = re.sub(r'^\s*--+\s*', '', headline)                 # drop the leading dashes
    s = re.sub(r'(?i)\bquery\s*\d+\b[:.\-\s]*', '', s, count=1)  # drop "Query N"
    s = re.sub(r'[^A-Za-z0-9]+', '-', s).strip('-').lower()
    return s[:48] or "query"
for k, (mark, body) in enumerate(chunks, 1):
    headline = lines[mark] if mark is not None else None
    name = f"{k:02d}-{slug(headline, k)}.sql"
    path = os.path.join(outdir, name)
    text = pre + "\n".join(body).rstrip() + "\n"
    open(path, "w", encoding="utf-8").write(text)
    print(path)
PY
)
[[ ${#made[@]} -gt 0 ]] || { echo "split: produced no files (empty input?)" >&2; exit 1; }
echo "split: wrote ${#made[@]} file(s) to $outdir/" >&2
printf '  %s\n' "${made[@]}" >&2

# Optional: run each through the supplied adapter command and strip the preamble from each CSV.
if [[ -n "$run" ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  fail=0
  for sql in "${made[@]}"; do
    csv="${sql%.sql}.$ext"
    sqlq="$(printf '%q' "$sql")"; csvq="$(printf '%q' "$csv")"
    cmd="${run//\{sql\}/$sqlq}"; cmd="${cmd//\{csv\}/$csvq}"
    if bash -c "$cmd" > "$TMP/raw" 2> "$TMP/err"; then
      if [[ -s "$TMP/raw" ]]; then mv "$TMP/raw" "$csv"; fi      # CMD wrote to stdout
      if [[ -s "$csv" ]]; then
        py_strip "$csv" "" ; echo "✓ $csv" >&2
      else
        echo "⚠ $sql produced no rows (empty CSV)" >&2; fail=1
      fi
    else
      echo "✗ run failed for $sql (rc=$?)" >&2; sed 's/^/      /' "$TMP/err" >&2; fail=1
    fi
  done
  exit "$fail"
fi
