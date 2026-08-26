---
meeting_ref: acmemeet:mtg-55
meeting_date: 2026-08-24

Malformed on purpose: the frontmatter block opens and never closes, so a real reference sits in an
unparseable block. The parser must NAME this (malformed-frontmatter, exit 4) rather than reporting
"no reference" — silence is reserved for a valid no-ref state.
