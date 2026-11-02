#!/usr/bin/env bash
# directory_tree.sh: build what the Claude plugin directory listing serves from a release.
#
# The listing follows the `directory` branch (docs/maintainers/pypi-setup.md, Part C). The
# directory holds a version for a human reviewer when the plugin folder carries a non-image file
# over 256 KiB, a binary that is not an image or font, or a script that names a bundled image
# (https://claude.com/docs/plugins/pre-submission-checklist), and its scan holds any PNG or GIF a
# script could reach and any file that pairs a credential-looking word with a remote URL. Only
# dev-only paths trip those checks, so the listing gets the release tree minus TRIM_PATHS: tests,
# media tooling, CI, the README images (the README loads them from GitHub URLs), maintainer docs
# and the self-test. Nothing a plugin install runs lives under them: /setup offers the self-test
# only when bin/selftest.sh exists.
#
#   bash .github/scripts/directory_tree.sh --list                 # the trimmed paths, one per line
#   bash .github/scripts/directory_tree.sh tree <ref> <outdir>    # export the trimmed tree of <ref>
#   bash .github/scripts/directory_tree.sh commit <tag> [<base>]  # print a commit for `directory`
#   bash .github/scripts/directory_tree.sh bootstrap <base>       # one-time: trim <base> itself
#
# `commit` refuses a tag that is not a final vX.Y.Z, a tag whose plugin.json disagrees with it, and
# a version that is not higher than the one on <base>, so the listing can never move backward. The
# commit's only parent is <base>, so pushing it is a fast-forward; its message names the tag and
# the tag's commit. A tag parent would be simpler provenance, but GitHub refuses a push from the
# Actions token whose new commits change .github/workflows/ (the token cannot hold the `workflows`
# permission), and a parent that still has those files makes the trim look like deleting them.
# For the same reason the FIRST trimmed commit, whose parent still carries .github/, cannot be
# pushed by Actions: `bootstrap` builds it from the untrimmed listing head, for a maintainer to push
# once with their own credentials (docs/maintainers/pypi-setup.md, Part C). Both modes write
# nothing but git objects and print the commit; the caller pushes.
#
# This file lives under .github/, which it trims, so it never ships in the listing itself.
set -uo pipefail

TRIM_PATHS="tests scripts .github docs/images docs/maintainers bin/selftest.sh"
PLUGIN_JSON=".claude-plugin/plugin.json"

die() { echo "directory_tree: $1" >&2; exit "${2:-2}"; }

# The tree object of <ref> with TRIM_PATHS removed, built in a throwaway index so modes and
# contents come straight from git and no working tree is touched.
trimmed_tree() {
  local ref="$1" idx tree
  git rev-parse -q --verify "${ref}^{tree}" >/dev/null || die "not a git ref: $ref"
  idx="$(mktemp "${TMPDIR:-/tmp}/tw-dir-index.XXXXXX")" || die "mktemp failed"
  rm -f "$idx"
  # shellcheck disable=SC2086
  if ! GIT_INDEX_FILE="$idx" git read-tree "${ref}^{tree}" ||
     ! GIT_INDEX_FILE="$idx" git rm -r -q -f --cached --ignore-unmatch -- $TRIM_PATHS >/dev/null ||
     ! tree="$(GIT_INDEX_FILE="$idx" git write-tree)"; then
    rm -f "$idx"; die "could not build the trimmed tree of $ref"
  fi
  rm -f "$idx"
  printf '%s\n' "$tree"
}

plugin_version() { # <ref>: the version plugin.json declares at <ref>, or nothing
  git show "$1:$PLUGIN_JSON" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

version_gt() { # X.Y.Z > X.Y.Z, numerically
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}

case "${1:-}" in
  --list)
    for p in $TRIM_PATHS; do printf '%s\n' "$p"; done ;;

  tree)
    [ $# -eq 3 ] || die "usage: directory_tree.sh tree <ref> <outdir>"
    out="$3"
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then die "$out is not empty"; fi
    tree="$(trimmed_tree "$2")" || exit $?
    mkdir -p "$out" || die "cannot create $out"
    git archive "$tree" | tar -x -C "$out" || die "export failed"
    ;;

  commit)
    [ $# -ge 2 ] && [ $# -le 3 ] || die "usage: directory_tree.sh commit <tag> [<base>]"
    tag="$2"; base="${3:-}"
    printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
      die "$tag is not a final release tag (vX.Y.Z); the listing takes final releases only." 3
    tag_commit="$(git rev-parse -q --verify "${tag}^{commit}")" || die "no such tag: $tag"
    ver="$(plugin_version "$tag_commit")"
    [ "v$ver" = "$tag" ] || die "$tag carries $PLUGIN_JSON version '$ver'; the two must agree."
    parents=""
    if [ -n "$base" ]; then
      base_commit="$(git rev-parse -q --verify "${base}^{commit}")" || die "no such ref: $base"
      base_ver="$(plugin_version "$base_commit")"
      [ -n "$base_ver" ] || die "$base has no readable $PLUGIN_JSON version."
      # shellcheck disable=SC2086
      [ -z "$(git ls-tree --name-only "$base_commit" -- $TRIM_PATHS)" ] ||
        die "$base still carries dev-only paths; a maintainer pushes \`directory_tree.sh bootstrap $base\` once first (pypi-setup.md, Part C)." 6
      version_gt "$ver" "$base_ver" ||
        die "$tag is not newer than the listing ($base_ver); the listing only moves forward." 4
      parents="-p $base_commit"
    fi
    tree="$(trimmed_tree "$tag_commit")" || exit $?
    # shellcheck disable=SC2086
    git commit-tree "$tree" $parents \
      -m "directory: $tag, the release tree without dev-only files" \
      -m "Built by .github/scripts/directory_tree.sh from $tag ($tag_commit). Removed: $TRIM_PATHS." ||
      die "git commit-tree failed"
    ;;

  bootstrap)
    [ $# -eq 2 ] || die "usage: directory_tree.sh bootstrap <base>"
    base_commit="$(git rev-parse -q --verify "${2}^{commit}")" || die "no such ref: $2"
    tree="$(trimmed_tree "$base_commit")" || exit $?
    [ "$tree" != "$(git rev-parse "${base_commit}^{tree}")" ] ||
      die "$2 is already trimmed; nothing to bootstrap." 5
    base_ver="$(plugin_version "$base_commit")"
    git commit-tree "$tree" -p "$base_commit" \
      -m "directory: trim v$base_ver to the listing tree" \
      -m "One-time bootstrap by .github/scripts/directory_tree.sh, pushed by a maintainer: later releases are committed on top of this by publish.yml. Removed: $TRIM_PATHS." ||
      die "git commit-tree failed"
    ;;

  *)
    die "usage: directory_tree.sh --list | tree <ref> <outdir> | commit <tag> [<base>] | bootstrap <base>" ;;
esac
