# tests/meeting_refs — fixtures for `bin/meeting_refs.py`

Stub files exercising the meeting-reference contract (grammar in
`.claude/config/stack.schema.md`; parser exit family 0 ok · 2 usage · 4 malformed-or-refused).
`bin/selftest.sh` section 51d copies these into fixture ticket trees and drives the parser:

| Fixture | Proves |
|---|---|
| `2026-08-18-kickoff-meeting.md` | valid ref + optional `meeting_date` → JSON, exit 0 |
| `2026-08-20-pricing-review-meeting.md` | quoted opaque id using the full charset; no date |
| `2026-08-21-invalid-grammar-meeting.md` | invalid grammar → exit 4, named error (never silence) |
| `2026-08-22-credential-url-meeting.md` | URL/token value → exit 4, `"reason": "refused-credential"` |
| `2026-08-23-list-refs-meeting.md` | a YAML list → exit 4 (`list-not-allowed`) — one ref per stub |
| `no-ref-notes.md` | frontmatter without the key → zero refs, exit 0 (silence, mechanically) |
| `misplaced-ref-notes.md` | a ref outside the canonical `*-meeting.md` stub → exit 4 (`misplaced-ref`) |
| `2026-08-24-unterminated-meeting.md` | an unclosed frontmatter block hiding a real ref → exit 4 (`malformed-frontmatter`), never silence |

Section 51d also generates three oversized cases inline — a stub whose frontmatter exceeds the
8 KB read bound, a multi-megabyte file named as a canonical stub, and a multibyte block that
exceeds the bound in BYTES while staying well under it in characters (the case that separates a
byte bound from a character bound). They are built at test time rather than committed, because
fixtures that large have no business in a public kit.

All identifiers are fixtures (`acmemeet`, `DEMO-`/`SAMPLE-`); this is a public repo.
