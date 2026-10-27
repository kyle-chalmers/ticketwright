#!/usr/bin/env bash
# render.sh — tiny {{token}} renderer. No deps beyond coreutils + perl (preinstalled on macOS/Linux).
#
# Usage:
#   bin/render.sh TEMPLATE KEY=VALUE [KEY2=VALUE2 ...]        # vars on the command line
#   bin/render.sh TEMPLATE --vars FILE                       # vars from a KEY=VALUE file
#   bin/render.sh TEMPLATE --sections FILE                   # multi-line values from a Markdown file
#   bin/render.sh TEMPLATE ... --strict                      # exit 2 if any {{token}} is left unresolved
#
# --sections reads a Markdown file of `## Heading` blocks: each block's body fills the token named
# by its heading, lowercased, with any (parenthetical) dropped and every run of other characters
# turned into `_` ("## Validation strategy (defined BEFORE code)" fills {{validation_strategy}}).
# It is how a prose record such as plan.md is rendered from content that was already approved,
# without passing multi-line Markdown through shell quoting. Text before the first heading, and
# `## ` lines inside a ``` fence, are not headings. Under --strict these also exit 2: a heading the
# template has no token for (its content would be dropped), the same heading twice, an empty block,
# and a placeholder line (`- …`, `1. ...`, `- **In:** …`) left in a block.
#
# Writes the rendered text to stdout. Unresolved {{tokens}} are always reported to stderr.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 TEMPLATE [KEY=VALUE ... | --vars FILE | --sections FILE] [--strict]" >&2
  exit 1
fi

template="$1"; shift
[[ -f "$template" ]] || { echo "render: template not found: $template" >&2; exit 1; }

strict=0
sections=""
declare -a pairs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) strict=1; shift ;;
    --vars)   shift; [[ -f "${1:-}" ]] || { echo "render: vars file not found: ${1:-}" >&2; exit 1; }
              while IFS= read -r line; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ "$line" == *"="* ]] && pairs+=("$line")
              done < "$1"; shift ;;
    --sections) shift; [[ -f "${1:-}" ]] || { echo "render: sections file not found: ${1:-}" >&2; exit 1; }
              sections="$1"; shift ;;
    *=*)      pairs+=("$1"); shift ;;
    *)        echo "render: unrecognized arg: $1" >&2; exit 1 ;;
  esac
done

# --sections: perl splits the file into NUL-separated key/value pairs on stdout and reports each
# problem on stderr; exit 3 means it found at least one. Read back with `read -d ''` (bash 3.2-safe).
section_problems=0
if [[ -n "$sections" ]]; then
  sec_out="$(mktemp)"
  TEMPLATE="$template" perl -CSD -e '
    use strict; use warnings;
    my %tok; { open(my $t, "<:encoding(UTF-8)", $ENV{TEMPLATE}) or die; local $/; my $s = <$t>; $tok{$1} = 1 while $s =~ /\{\{([^}]+)\}\}/g; }
    my (@order, %body, %head, @bad); my ($key, $fence) = (undef, 0);
    open(my $f, "<:encoding(UTF-8)", $ARGV[0]) or die;
    while (my $line = <$f>) {
      $fence = !$fence if $line =~ /^\s*```/;
      if (!$fence && $line =~ /^## (.+?)\s*$/) {
        my $h = $1; (my $k = lc $h) =~ s/\([^)]*\)//g; $k =~ s/[^a-z0-9]+/_/g; $k =~ s/^_+|_+$//g;
        if (exists $body{$k}) { push @bad, "the heading \"$h\" appears twice"; $key = undef; next; }
        push @order, $k; $body{$k} = ""; $head{$k} = $h; $key = $k; next;
      }
      $body{$key} .= $line if defined $key;
    }
    for my $k (@order) {
      (my $v = $body{$k}) =~ s/\A\s*\n//; $v =~ s/\s+\z//;
      push @bad, "\"## $head{$k}\" has no {{$k}} in the template, so its content would be dropped" unless $tok{$k};
      push @bad, "\"## $head{$k}\" is empty" if $v !~ /\S/;
      for my $l (split /\n/, $v) {
        push @bad, "\"## $head{$k}\" still has a placeholder line: $l"
          if $l =~ /^\s*(?:[-*+]|\d+\.)?\s*(?:\*\*[^*]*\*\*:?\s*)?(?:\x{2026}|\.\.\.)\s*(?:\(.*\))?\s*$/;
      }
      print $k, "\0", $v, "\0";
    }
    print STDERR "render: $_\n" for @bad;
    exit(@bad ? 3 : 0);
  ' "$sections" > "$sec_out" || { [[ $? -eq 3 ]] && section_problems=1 || { echo "render: could not read sections file: $sections" >&2; exit 1; }; }
  while IFS= read -r -d '' skey && IFS= read -r -d '' sval; do
    pairs+=("$skey=$sval")
  done < "$sec_out"
fi
# One substitution pass over the TEMPLATE, never over output already rendered: a value is inserted
# verbatim and never re-scanned, so a plan that quotes `{{ ref('x') }}` or mentions `{{risks}}`
# renders as written instead of failing or pulling another section's text in. Pairs reach perl as a
# NUL-separated file (any value bytes are safe); the first pair for a key wins. "Unresolved" means a
# token in the template that no pair supplied.
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir" ${sec_out:+"$sec_out"}' EXIT
: > "$render_dir/pairs"
# Guard the empty-array case: on bash 3.2 under `set -u`, "${pairs[@]}" with zero elements aborts.
if [[ ${#pairs[@]} -gt 0 ]]; then
  for pair in "${pairs[@]}"; do
    printf '%s\0%s\0' "${pair%%=*}" "${pair#*=}" >> "$render_dir/pairs"
  done
fi
PAIRS="$render_dir/pairs" LEFT="$render_dir/left" perl -e '
  use strict; use warnings;
  my %v; { open(my $p, "<", $ENV{PAIRS}) or die; local $/ = "\0"; my @f = <$p>; chomp @f;
    while (@f >= 2) { my ($k, $x) = splice(@f, 0, 2); $v{$k} = $x unless exists $v{$k}; } }
  my $s = do { local $/; <STDIN> }; my %left;
  $s =~ s/\{\{([^}]+)\}\}/exists $v{$1} ? $v{$1} : do { $left{$1} = 1; "{{$1}}" }/ge;
  $s =~ s/\n+\z//;
  print $s, "\n";
  open(my $l, ">", $ENV{LEFT}) or die; print $l "{{$_}}\n" for sort keys %left;
' < "$template" > "$render_dir/out"

# Report anything still unresolved.
leftover="$(cat "$render_dir/left")"
if [[ -n "$leftover" ]]; then
  echo "render: WARNING unresolved tokens:" >&2
  echo "$leftover" >&2
fi
# A failed --strict render prints NOTHING to stdout, so `> file` never leaves a half-filled record
# behind that looks like a finished one. Non-strict: warn only, print, exit 0 (don't fail callers).
if [[ "$strict" -eq 1 ]] && { [[ -n "$leftover" ]] || [[ "$section_problems" -eq 1 ]]; }; then exit 2; fi
cat "$render_dir/out"
