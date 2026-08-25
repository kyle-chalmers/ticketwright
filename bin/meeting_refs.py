#!/usr/bin/env python3
"""Enumerate and validate a ticket's meeting references — the meetings slot's mechanical parser.

The reference contract (documented in .claude/config/stack.schema.md):

- ONE canonical placement: the YAML frontmatter of a `source_materials/YYYY-MM-DD-<slug>-meeting.md`
  stub, key `meeting_ref:`.
- Grammar: `meeting_ref: <provider>:<id>` — `<provider>` is `[a-z0-9-]+`; `<id>` is the provider's
  opaque id, charset `[A-Za-z0-9._~/=+-]+`. An id needing YAML quoting may be double-quoted; the
  same charset applies after unquoting. Whitespace and shell metacharacters are REFUSED (the
  tier-3 injection-refusal precedent — this value interpolates into adapter commands).
- Optional `meeting_date: YYYY-MM-DD` as a separate key.
- Exactly one `meeting_ref:` per stub (a YAML list is invalid); many stubs are fine and are
  returned ordered by filename (the date prefix gives chronology).
- No reference => silence, mechanically: `{"refs": []}` and exit 0. The skill then does nothing —
  never a speculative fetch.
- Invalid reference => a NAMED error, never silence: exit 4 with the offending file and reason.
- Credential prohibition, checked at parse time: a value carrying `://`, a `?` query string, or a
  credential-shaped token (`token=`, `access_token`, `key=`, `Bearer `) is refused with
  `"reason": "refused-credential"` — committed refs must never carry URLs or secrets.

Exit family: 0 ok (including zero refs) · 2 usage · 4 malformed-or-refused. `refused-credential`
in an error's `reason` distinguishes a credential refusal from a grammar error; both exit 4.

Purely syntactic and config-free: this tool never reads stack.yaml. Matching a ref's provider
against the configured `seams.meetings.tool` is the calling skill's job (bin/effective_config.py).
Stdlib-only; takes --root; needs no Claude environment variables.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

EXIT_OK, EXIT_USAGE, EXIT_MALFORMED = 0, 2, 4

PROVIDER_RE = re.compile(r"^[a-z0-9-]+$")
ID_RE = re.compile(r"^[A-Za-z0-9._~/=+-]+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# Credential shapes refused at parse time (checked case-insensitively — stricter, never looser).
CREDENTIAL_MARKS = ("://", "?", "token=", "access_token", "key=", "bearer ")


def frontmatter_lines(text: str) -> list[str]:
    """The lines between a leading '---' fence and its closing '---', or []."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i]
    return []


def unquote(value: str) -> tuple[str, bool]:
    """Strip one layer of double quotes. Returns (value, was_quoted)."""
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1], True
    return value, False


def parse_stub(path: Path, rel: str, errors: list[dict]) -> dict | None:
    """Parse one stub's frontmatter. Returns a ref record, or None (no ref / error recorded)."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        errors.append({"file": rel, "reason": "unreadable", "detail": str(exc)})
        return None
    fm = frontmatter_lines(text)
    ref_lines = [ln for ln in fm if re.match(r"^meeting_ref\s*:", ln)]
    if not ref_lines:
        # A bare `meeting_ref:` followed by `- item` list lines has no inline value and is caught
        # below; a stub with no meeting_ref key at all is simply not a reference stub.
        return None
    if len(ref_lines) > 1:
        errors.append({"file": rel, "reason": "multiple-refs",
                       "detail": f"{len(ref_lines)} meeting_ref keys; exactly one per stub"})
        return None
    raw = ref_lines[0].split(":", 1)[1].strip()
    # A YAML list is invalid: inline `[...]` or a bare key whose items follow as `- ` lines.
    idx = fm.index(ref_lines[0])
    if raw.startswith("["):
        errors.append({"file": rel, "reason": "list-not-allowed",
                       "detail": "meeting_ref must be one <provider>:<id>, not a list"})
        return None
    if raw == "":
        nxt = next((ln for ln in fm[idx + 1:] if ln.strip()), "")
        if nxt.lstrip().startswith("- "):
            errors.append({"file": rel, "reason": "list-not-allowed",
                           "detail": "meeting_ref must be one <provider>:<id>, not a list"})
        else:
            errors.append({"file": rel, "reason": "invalid-grammar",
                           "detail": "meeting_ref has no value"})
        return None
    value, _ = unquote(raw)
    low = value.lower()
    if any(mark in low for mark in CREDENTIAL_MARKS):
        errors.append({"file": rel, "reason": "refused-credential",
                       "detail": "value carries a URL or credential-shaped token; "
                                 "committed refs must be bare <provider>:<id>"})
        return None
    if ":" not in value:
        errors.append({"file": rel, "reason": "invalid-grammar",
                       "detail": f"expected <provider>:<id>, got {value!r}"})
        return None
    provider, mid = value.split(":", 1)
    if not PROVIDER_RE.match(provider):
        errors.append({"file": rel, "reason": "invalid-grammar",
                       "detail": f"provider {provider!r} is not [a-z0-9-]+"})
        return None
    if not ID_RE.match(mid):
        # Whitespace and shell metacharacters land here: outside the charset, refused at parse
        # time because the id interpolates into adapter commands.
        errors.append({"file": rel, "reason": "unsafe-characters",
                       "detail": f"id {mid!r} outside charset [A-Za-z0-9._~/=+-]"})
        return None
    record: dict = {"file": rel, "provider": provider, "id": mid, "meeting_date": None}
    date_lines = [ln for ln in fm if re.match(r"^meeting_date\s*:", ln)]
    if date_lines:
        dv, _ = unquote(date_lines[0].split(":", 1)[1].strip())
        if not DATE_RE.match(dv):
            errors.append({"file": rel, "reason": "invalid-date",
                           "detail": f"meeting_date {dv!r} is not YYYY-MM-DD"})
            return None
        try:
            datetime.date.fromisoformat(dv)
        except ValueError:
            errors.append({"file": rel, "reason": "invalid-date",
                           "detail": f"meeting_date {dv!r} is not a real date"})
            return None
        record["meeting_date"] = dv
    return record


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Enumerate meeting_ref: references in a ticket's source_materials/.")
    ap.add_argument("--root", default=".", help="repo root (default: .)")
    ap.add_argument("--ticket", required=True,
                    help="ticket directory, relative to --root (or absolute)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return EXIT_USAGE

    root = Path(args.root).resolve()
    ticket = Path(args.ticket)
    if not ticket.is_absolute():
        ticket = root / ticket
    if not ticket.is_dir():
        print(f"meeting_refs: ticket directory not found: {ticket}", file=sys.stderr)
        return EXIT_USAGE

    refs: list[dict] = []
    errors: list[dict] = []
    src = ticket / "source_materials"
    if src.is_dir():
        # Top level only, ordered by filename (the YYYY-MM-DD prefix gives chronology).
        # private/ is the raw opt-in area and is never a reference source.
        for path in sorted(p for p in src.iterdir() if p.is_file() and p.suffix == ".md"):
            rel = f"source_materials/{path.name}"
            rec = parse_stub(path, rel, errors)
            if rec:
                refs.append(rec)

    out = {"schema": 1, "refs": refs, "errors": errors}
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        for r in refs:
            date = f"  ({r['meeting_date']})" if r["meeting_date"] else ""
            print(f"{r['provider']}:{r['id']}{date}  — {r['file']}")
        for e in errors:
            print(f"ERROR [{e['reason']}] {e['file']}: {e['detail']}", file=sys.stderr)
        if not refs and not errors:
            print("no meeting references (silence is the contract: nothing to fetch)")
    return EXIT_MALFORMED if errors else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
