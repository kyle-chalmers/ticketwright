#!/usr/bin/env bash
# bump_version.sh — move the version in ONE command.
#
# Three files carry a literal version and must stay in lockstep (Claude Code reads plugin.json and
# marketplace.json directly, so neither can be generated at build time; pyproject reads __init__.py
# dynamically). Bumping them by hand is what let PyPI drift a full minor behind the plugin — this
# script makes the release ritual mechanical, and selftest §16 fails the build if they disagree.
#
#   bash bin/bump_version.sh 3.4.0
#   bash bin/bump_version.sh 3.4.0rc1     # PEP 440 pre/post/dev suffixes are allowed
#
# All-or-nothing: every file is rendered and verified into a .tmp first, and nothing is moved into
# place until all three are known good. A half-applied bump would be worse than no bump at all —
# it ships a release whose plugin and package disagree, which is the exact failure this prevents.
#
# Read-only on everything else; prints the tag command rather than running it, because tagging
# publishes to PyPI (.github/workflows/publish.yml fires on v*) and that's the maintainer's call.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

INIT="ticketwright/__init__.py"
PLUGIN=".claude-plugin/plugin.json"
MARKET=".claude-plugin/marketplace.json"

die() { echo "bump_version: $1" >&2; exit "${2:-2}"; }

# Read the version a file actually declares — exactly, as a string. Digit-stripping (the old
# approach, and what selftest §16 still does for its equality check) mangles "3.4.0rc1" into
# "3.4.01", so a prerelease bump would write every file and then report a bogus mismatch.
# NB: the verify phase passes "<file>.tmp", so every pattern needs its .tmp twin.
read_ver() {
  case "$1" in
    *.py|*.py.tmp) python3 -c "import re,sys; m=re.search(r'__version__\s*=\s*\"([^\"]+)\"', open(sys.argv[1]).read()); print(m.group(1) if m else '')" "$1" ;;
    *)             python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['version'] if 'version' in d else d['plugins'][0]['version'])" "$1" ;;
  esac
}

new="${1:-}"
if [ -z "$new" ]; then
  echo "usage: bash bin/bump_version.sh <version>   (current: $(read_ver "$INIT"))" >&2
  exit 2
fi
python3 -c "
import re, sys
sys.exit(0 if re.fullmatch(r'\d+\.\d+\.\d+((a|b|rc)\d+|\.post\d+|\.dev\d+)?', sys.argv[1]) else 1)
" "$new" || die "'$new' is not a valid version (want MAJOR.MINOR.PATCH, optionally rcN/aN/bN/.postN/.devN)"

for f in "$INIT" "$PLUGIN" "$MARKET"; do
  [ -f "$f" ] || die "missing $f"
  [ -w "$f" ] || die "$f is not writable"
done

old="$(read_ver "$INIT")"
[ -n "$old" ] || die "could not read the current version from $INIT"

# Each manifest carries exactly ONE "version" key today, so the sed range below is unambiguous.
# If that ever changes (e.g. a second entry in marketplace.json's plugins[]), a range edit would
# silently bump only the first and ship a half-synced release — refuse instead of guessing.
for f in "$PLUGIN" "$MARKET"; do
  n="$(grep -c '"version"' "$f")"
  [ "$n" -eq 1 ] || die "$f has $n \"version\" keys, expected 1 — this script edits only the first.
              Update bump_version.sh (and selftest §16's grep -m1) before releasing."
done

cleanup() { rm -f "$INIT.tmp" "$PLUGIN.tmp" "$MARKET.tmp"; }
trap cleanup EXIT

# --- render phase: nothing below touches an original until every .tmp verifies -------------------
# sed -i is not portable (BSD wants an arg, GNU doesn't), hence the explicit .tmp + mv.
render() {  # render <file> <sed-expression>
  sed "$2" "$1" > "$1.tmp" || die "sed failed on $1"
  [ -s "$1.tmp" ] || die "rendering $1 produced an empty file"
}
render "$INIT"   "s/^__version__ = \".*\"/__version__ = \"$new\"/"
# only the FIRST "version" key in each manifest is the package version
render "$PLUGIN" "1,/\"version\"/ s/\"version\": \"[^\"]*\"/\"version\": \"$new\"/"
render "$MARKET" "1,/\"version\"/ s/\"version\": \"[^\"]*\"/\"version\": \"$new\"/"

# --- verify phase: the .tmp files must parse and declare exactly $new ----------------------------
python3 -c "import json,sys; [json.load(open(p)) for p in sys.argv[1:]]" "$PLUGIN.tmp" "$MARKET.tmp" \
  || die "a rendered manifest is not valid JSON — the sed expression needs fixing (originals untouched)"
for f in "$INIT" "$PLUGIN" "$MARKET"; do
  got="$(read_ver "$f.tmp")"
  [ "$got" = "$new" ] || die "rendering $f produced version '$got', wanted '$new' (originals untouched)"
done

# --- commit phase --------------------------------------------------------------------------------
for f in "$INIT" "$PLUGIN" "$MARKET"; do
  mv "$f.tmp" "$f" || die "failed to write $f — tree may be partially bumped, check \`git diff\`" 1
done

echo "bumped $old → $new  ($INIT, $PLUGIN, $MARKET)"
echo
echo "next:"
echo "  1. update CHANGELOG.md for $new"
echo "  2. regenerate tests/emit fixtures (provenance headers embed the version — tests/emit/README.md has the recipe)"
echo "  3. bash bin/selftest.sh — and CHECK ITS EXIT CODE, not just the printed tail"
echo "  4. commit, then publish to PyPI by tagging:"
echo "       git tag v$new && git push origin v$new"
