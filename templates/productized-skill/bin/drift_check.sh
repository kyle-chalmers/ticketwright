#!/usr/bin/env bash
# drift_check.sh — Phase-0 catch: confirm every object/view this workflow reads is still reachable.
# Generalizes a view/object drift-check pattern. Resolves the warehouse adapter from stack.yaml.
# Exit non-zero on any unreachable object so the skill halts before doing work.
set -uo pipefail

STACK="${STACK:-.claude/config/stack.yaml}"

# The objects this workflow depends on. Fill these in when stamping the skill.
OBJECTS=(
  # "SCHEMA.OBJECT_ONE"
  # "SCHEMA.OBJECT_TWO"
)

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
  echo "drift_check: no OBJECTS defined yet — edit this file when you stamp the skill." >&2
  exit 0
fi

# Example for a Snowflake warehouse (swap the probe for your adapter's `describe`/`query` verb).
fail=0
for obj in "${OBJECTS[@]}"; do
  if snow sql -q "DESCRIBE TABLE $obj" >/dev/null 2>&1 \
     || snow sql -q "DESCRIBE VIEW $obj" >/dev/null 2>&1; then
    echo "✓ $obj"
  else
    echo "✗ UNREACHABLE: $obj" >&2; fail=1
  fi
done
exit $fail
