#!/usr/bin/env bash
# render.sh — tiny {{token}} renderer. No deps beyond coreutils + perl (preinstalled on macOS/Linux).
#
# Usage:
#   bin/render.sh TEMPLATE KEY=VALUE [KEY2=VALUE2 ...]        # vars on the command line
#   bin/render.sh TEMPLATE --vars FILE                       # vars from a KEY=VALUE file
#   bin/render.sh TEMPLATE ... --strict                      # exit 2 if any {{token}} is left unresolved
#
# Writes the rendered text to stdout. Unresolved {{tokens}} are always reported to stderr.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 TEMPLATE [KEY=VALUE ... | --vars FILE] [--strict]" >&2
  exit 1
fi

template="$1"; shift
[[ -f "$template" ]] || { echo "render: template not found: $template" >&2; exit 1; }

strict=0
declare -a pairs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) strict=1; shift ;;
    --vars)   shift; [[ -f "${1:-}" ]] || { echo "render: vars file not found: ${1:-}" >&2; exit 1; }
              while IFS= read -r line; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ "$line" == *"="* ]] && pairs+=("$line")
              done < "$1"; shift ;;
    *=*)      pairs+=("$1"); shift ;;
    *)        echo "render: unrecognized arg: $1" >&2; exit 1 ;;
  esac
done

content="$(cat "$template")"
# Guard the empty-array case: on bash 3.2 under `set -u`, "${pairs[@]}" with zero elements aborts.
if [[ ${#pairs[@]} -gt 0 ]]; then
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    # Replace every {{key}} with val. perl handles arbitrary value chars safely via env passing.
    content="$(KEY="$key" VAL="$val" perl -pe 's/\{\{\Q$ENV{KEY}\E\}\}/$ENV{VAL}/g' <<< "$content")"
  done
fi

printf '%s\n' "$content"

# Report anything still unresolved.
leftover="$(grep -oE '\{\{[^}]+\}\}' <<< "$content" | sort -u || true)"
if [[ -n "$leftover" ]]; then
  echo "render: WARNING unresolved tokens:" >&2
  echo "$leftover" >&2
  if [[ "$strict" -eq 1 ]]; then exit 2; fi   # non-strict: warn only, exit 0 (don't fail callers)
fi
