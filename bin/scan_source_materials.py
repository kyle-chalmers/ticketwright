#!/usr/bin/env python3
"""The source-material guard's deterministic classifier — harness-neutral, one implementation.

Logic belongs in harness-neutral CLIs under bin/; hooks and shims are presentation (AGENTS.md
tiebreaker 5). This module is the ONE implementation of the kit's source-material classification;
the presenters map its verdicts onto each runtime:

  .claude/hooks/source_material_guard.py   Claude Code PreToolUse (ask/allow, always exit 0)
  bin/hook_shim.py                         every other runtime's hook protocol

It deliberately does NOT extend bin/sql_scan.py. That module classifies warehouse shell/SQL
commands; bolting file semantics into it would put two unrelated jurisdictions behind one
default-deny table. The two share a SHAPE (classifier in bin/, presenters elsewhere), not code.

WHAT THIS IS FOR. A ticket's `source_materials/` holds inputs a person dropped in — forwarded
threads, tracker attachments, and (the case that motivated this) meeting notes from an AI
notetaker. Meeting transcripts are the most PII- and confidentiality-dense artifact the kit
touches. The policy: CURATED EXCERPTS AND ACTION ITEMS ARE COMMITTED; RAW FULL TRANSCRIPTS ARE
NOT, BY DEFAULT.

WHAT IT CANNOT DO — say this plainly rather than implying parity (AGENTS.md tiebreaker 6). This
classifier matches FILENAMES AND DOCUMENT SHAPE, NEVER MEANING. A curated summary that quotes
confidential material verbatim reads as `other` and passes. It is a gate against the bulk
artifact, not a confidentiality review, and nothing here replaces a human reading the file.

Three more limits worth naming rather than discovering:
  · A BINARY office document (a `.docx` transcript export, say) is reported `binary` and is NOT
    flagged — its text is not extracted. Only its filename and extension are evidence.
  · A SHORT transcript can fall under MIN_SPEAKER_LINES, and material past SCAN_BYTES is not read.
  · Speaker labels that are lowercase, numeric, or non-Latin do not match the same-line patterns;
    the cue-line and extension rules are what cover those files in practice.

THE KINDS, and the precedence between them (order matters; the first match wins):

  1. symlink      not followed — reported so an out-of-tree link is never silently scanned
  2. raw_suspect  the filename declares it (`*transcript*`, case-insensitive)
  3. raw_suspect  a caption/subtitle EXTENSION (.vtt/.srt/…) — timed dialogue is the whole format,
                  and VTT is what the major meeting platforms export by default, usually named for
                  the meeting rather than for what it is
  4. binary       NUL byte in the first 8 KB — reported, shape test skipped
  5. raw_suspect  a WEBVTT header, which the spec makes definitional
  6. raw_suspect  the CONTENT has transcript shape (see below)
  7. curated      `YYYY-MM-DD-<slug>-meeting.md` — the committed, curated form
  8. other        everything else; reported, never flagged

CONTENT BEATS FILENAME, and that ordering is the point: rule 6 runs BEFORE rule 7, so a file
named `2026-08-20-pricing-meeting.md` whose body is a full transcript is `raw_suspect`. The
convention is a CLAIM; the content is EVIDENCE, and evidence wins. A convention that could be
satisfied by renaming would not be a gate at all.

THE SHAPE TEST — two rules, because the two kinds of evidence are not equally strong. CUE TIMING
LINES (`00:00:01.000 --> 00:00:04.120`) decide on COUNT alone: ordinary prose does not contain
them, and a ratio test would only add a way to miss a caption file whose payloads are long. The
SAME-LINE SPEAKER SHAPES need two conditions, BOTH required, so a curated summary quoting a few
exchanges does not trip it: at least MIN_SPEAKER_LINES matching lines AND at least MIN_SPEAKER_RATIO of non-blank
lines matching. One condition alone fails in a predictable direction — a count alone flags a long
document with a short quoted passage; a ratio alone flags a five-line fragment. The thresholds are
named constants because tests/source_materials/golden.json pins them: change one and that corpus
is what should stop you shipping it silently.

Only the first SCAN_BYTES are read. A larger file with no hit reports `truncated` in its reason,
so the bound is VISIBLE rather than a silent miss.

CLI (stdlib only, --root, no Claude environment variable):

  bin/scan_source_materials.py --root <repo> [--ticket <dir>] [--json] [--intake]

Default: report every `source_materials/` file under the repo. `--ticket` scopes to one ticket.
`--intake` lists only the files a priming pass should READ as ticket inputs (curated + other) —
the second job, and the reason `/ticket` has an executable consumer for the naming convention
instead of a glob a model approximates. Exit codes: 0 clean · 1
(at least one `raw_suspect`, OR coverage was incomplete — either way the scan does not certify
the tree, which is what `/ship` branches on) · 2 usage/unreadable input. `--intake` reports rather than gates, so
it exits 0 unless the arguments themselves are bad.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# ---- thresholds (pinned by tests/source_materials/golden.json) ------------------

MIN_SPEAKER_LINES = 10
MIN_SPEAKER_RATIO = 0.30
MIN_CUE_LINES = 5      # cue timing lines decide alone — see has_transcript_shape()
SCAN_BYTES = 256 * 1024
BINARY_SNIFF_BYTES = 8 * 1024
MAX_DIRS = 5000   # bounds the directory walk; a runaway tree must not hang a 10s hook budget
MAX_FILES = 2000  # ...and the per-directory file walk, for the same reason

SOURCE_DIR_NAME = "source_materials"

KIND_SYMLINK = "symlink"
KIND_RAW_SUSPECT = "raw_suspect"
KIND_BINARY = "binary"
KIND_CURATED = "curated"
KIND_OTHER = "other"
# Coverage ran out before the tree did. This is NOT a kind of file — it is a statement that the
# scan is not authoritative, and it must gate exactly like a raw_suspect. Reporting truncation as
# `other` (an earlier version did) makes an incomplete scan indistinguishable from a clean one,
# which is the same silent pass the whole guard exists to prevent.
KIND_INCOMPLETE = "incomplete"

# Directories that never hold ticket inputs and can cost a lot to walk.
_SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__", ".claude"}

# The committed, curated form: `YYYY-MM-DD-<slug>-meeting.md`.
CURATED_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-.+-meeting\.md$", re.IGNORECASE)

# The filename that declares itself. Deliberately broad and case-insensitive: `transcript.txt`,
# `Zoom-Transcript.vtt`, `raw_transcripts.md` all match.
FILENAME_RAW_RE = re.compile(r"transcript", re.IGNORECASE)

# Caption/subtitle files by EXTENSION. WebVTT and SubRip exist to carry timed dialogue — that is
# the entire format — and VTT is what the major meeting platforms hand you by default, usually
# named for the meeting rather than for what it is (`weekly-sync.vtt`). Treating the extension as
# declarative closes the single largest real-world hole a same-line speaker pattern leaves open.
CAPTION_EXTS = {".vtt", ".srt", ".sbv", ".ttml", ".dfxp"}

# A WEBVTT header is definitional: the spec requires the file to start with it.
WEBVTT_HEADER_RE = re.compile(r"^\s*\ufeff?WEBVTT\b")

# Cue timing lines — `00:00:01.000 --> 00:00:04.120` (VTT) and `00:00:01,000 --> 00:00:04,120`
# (SRT). In these formats the timestamp and the speaker are on DIFFERENT lines, which is exactly
# why the three same-line patterns below cannot see them.
CUE_LINE_RE = re.compile(r"^\s*(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->\s*"
                         r"(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}")

_TS = r"(?:\d{1,2}:)?\d{1,2}:\d{2}"
_NAME = r"[A-Z][\w.'\-]*(?:\s+[A-Z][\w.'\-]*){0,3}"

# The three speaker-plus-timestamp shapes AI notetakers actually emit. Each anchors at the start
# of a line and requires BOTH a timestamp and a capitalized speaker followed by a delimiter — an
# ordinary agenda line like `- 10:30 Standup kickoff` has no delimiter after the name and does
# not match. That the alternation is narrow is intentional: the corpus carries a false-positive
# fixture (ordinary timestamped notes) that must stay unflagged.
SPEAKER_LINE_RES = (
    re.compile(rf"^\s*[\[(]{_TS}[\])]\s*{_NAME}\s*[::]"),        # [00:12:34] Alex Kim:
    re.compile(rf"^\s*{_NAME}\s*[\[(]{_TS}[\])]\s*[::]"),        # Alex Kim (00:12):
    re.compile(rf"^\s*{_TS}\s+{_NAME}\s*[::—–-]"),     # 00:12:34 Alex Kim —
)


def _speaker_line_count(text: str) -> tuple[int, int]:
    """(matching lines, non-blank lines) for the shape test.

    A cue timing line counts as a hit alongside the same-line speaker shapes: in a caption file
    the dialogue is carried by cue blocks, so cue density IS transcript density.
    """
    hits = nonblank = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        nonblank += 1
        if CUE_LINE_RE.match(line):
            hits += 1
            continue
        for pattern in SPEAKER_LINE_RES:
            if pattern.match(line):
                hits += 1
                break
    return hits, nonblank


def cue_line_count(text: str) -> int:
    return sum(1 for line in text.splitlines() if CUE_LINE_RE.match(line))


def has_transcript_shape(text: str) -> bool:
    """Cue lines decide on COUNT alone; same-line speaker shapes need count AND ratio.

    The two rules differ because the evidence differs. A `00:00:01.000 --> 00:00:04.120` timing
    line is near-unique to caption formats — ordinary prose does not contain them — so a handful
    is conclusive and a ratio test only adds a way to miss one (a caption file with long
    multi-line payloads dilutes the ratio without becoming any less of a transcript). A
    `Name (00:12):` line is weaker evidence, since ordinary minutes can carry a few, so it keeps
    both conditions.
    """
    if cue_line_count(text) >= MIN_CUE_LINES:
        return True
    hits, nonblank = _speaker_line_count(text)
    if hits < MIN_SPEAKER_LINES or nonblank == 0:
        return False
    return (hits / nonblank) >= MIN_SPEAKER_RATIO


def in_declared_raw_area(path: Path) -> bool:
    """True for a file under `source_materials/private/` — the documented raw OPT-IN area.

    Scope is exact (a `private/` directory directly inside `source_materials/`), matching the
    gitignore pattern that area is defined by. A deeper directory that merely happens to be named
    `private/` earns nothing.
    """
    parts = path.parts
    for i, part in enumerate(parts[:-1]):
        if part == "source_materials" and i + 1 < len(parts) - 1 and parts[i + 1] == "private":
            return True
    return False


def classify_path(path: Path) -> dict:
    """Classify one file. Never raises — an unreadable file reports, it does not crash a hook."""
    name = path.name
    result = {"file": str(path), "name": name, "kind": KIND_OTHER, "reason": ""}

    # 1 · DECLARED raw, before any test that depends on reading the file. `source_materials/private/`
    # is the opt-in area a PERSON puts raw material into: the declaration is the classification, so
    # coverage here never depends on what the shape test can parse. This closes the case the
    # classifier provably cannot judge — a binary export (a .docx/.pdf transcript) reports `binary`,
    # skips the shape test, and would otherwise flag nothing at all, letting a folder-wide docstore
    # backup carry it out with no per-file approval. Gating more, visibly, is the standing rule.
    if in_declared_raw_area(path):
        result.update(kind=KIND_RAW_SUSPECT,
                      reason="under source_materials/private/ — the declared raw opt-in area "
                             "(declaration, not a content judgement)")
        return result

    try:
        if path.is_symlink():
            result.update(kind=KIND_SYMLINK, reason="symlink — not followed")
            return result
    except OSError as e:
        result.update(kind=KIND_OTHER, reason=f"unreadable ({e.__class__.__name__})")
        return result

    # 2 · the filename declares it, before any read at all
    if FILENAME_RAW_RE.search(name):
        result.update(kind=KIND_RAW_SUSPECT, reason="filename matches *transcript*")
        return result
    if path.suffix.lower() in CAPTION_EXTS:
        result.update(kind=KIND_RAW_SUSPECT,
                      reason=f"caption/subtitle format ({path.suffix.lower()}) — timed dialogue "
                             f"is the whole format")
        return result

    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            head = fh.read(SCAN_BYTES)
    except OSError as e:
        result.update(kind=KIND_OTHER, reason=f"unreadable ({e.__class__.__name__})")
        return result

    # 3 · binary — reported, shape test skipped (rule 2 already had its say)
    if b"\x00" in head[:BINARY_SNIFF_BYTES]:
        result.update(kind=KIND_BINARY, reason="binary (NUL byte in the first 8 KB)")
        return result

    text = head.decode("utf-8", errors="replace")
    truncated = size > SCAN_BYTES

    # A WEBVTT header is definitional, and cheaper than counting anything.
    if WEBVTT_HEADER_RE.match(text):
        result.update(kind=KIND_RAW_SUSPECT, reason="WEBVTT header — a caption/transcript file")
        return result

    # 4 · content beats filename — this runs BEFORE the curated-name check on purpose
    if has_transcript_shape(text):
        note = " (first 256 KB)" if truncated else ""
        cues = cue_line_count(text)
        if cues >= MIN_CUE_LINES:
            reason = (f"caption cue timing lines{note}: {cues} `-->` cues "
                      f"(threshold: {MIN_CUE_LINES})")
        else:
            hits, nonblank = _speaker_line_count(text)
            reason = (f"transcript shape{note}: {hits}/{nonblank} non-blank lines are "
                      f"speaker+timestamp (thresholds: {MIN_SPEAKER_LINES} lines, "
                      f"{int(MIN_SPEAKER_RATIO * 100)}%)")
        result.update(kind=KIND_RAW_SUSPECT, reason=reason)
        return result

    # 5 · the curated convention
    if CURATED_RE.match(name):
        result.update(kind=KIND_CURATED, reason="curated form YYYY-MM-DD-<slug>-meeting.md")
        return result

    result["reason"] = "truncated scan (first 256 KB); no transcript shape found" if truncated \
        else "no transcript indicators"
    return result


def scan_dir(directory: Path) -> list[dict]:
    """Classify every file directly under one `source_materials/` tree (recursive)."""
    out: list[dict] = []
    if not directory.is_dir():
        return out
    # rglob is lazy; collecting a BOUNDED slice keeps the traversal itself bounded. Sorting the
    # whole tree first (an earlier version did) walks every entry before any limit applies, so the
    # cap bounded classification cost but not walk cost — no use inside a 10s hook budget.
    batch: list[Path] = []
    overflow = False
    for path in directory.rglob("*"):
        if len(batch) >= MAX_FILES:
            overflow = True
            break
        batch.append(path)

    for path in sorted(batch):
        try:
            if path.is_dir():
                continue
            # A FIFO or device node would block open() and hang a 10s hook budget. Symlinks are
            # reported by classify_path; anything else non-regular is named, never silently
            # skipped — an unscannable file is a fact the caller should see.
            if not path.is_symlink() and not path.is_file():
                out.append({"file": str(path), "name": path.name, "kind": KIND_OTHER,
                            "reason": "not a regular file — not scanned"})
                continue
        except OSError:
            continue
        out.append(classify_path(path))
    if overflow:
        out.append({"file": str(directory), "name": directory.name, "kind": KIND_INCOMPLETE,
                    "reason": f"stopped at {MAX_FILES} entries — this tree was NOT fully scanned"})
    return out


def find_source_dirs(root: Path, ticket: str | None = None) -> list[Path]:
    """Every `source_materials/` directory under `root`, or just the one under `--ticket`."""
    if ticket:
        base = Path(ticket)
        if not base.is_absolute():
            base = root / base
        candidate = base if base.name == SOURCE_DIR_NAME else base / SOURCE_DIR_NAME
        return [candidate] if candidate.is_dir() else []

    found: list[Path] = []
    seen = 0
    stack = [root]
    while stack:
        current = stack.pop()
        seen += 1
        if seen > MAX_DIRS:
            _DISCOVERY_TRUNCATED.append(root)   # recorded, never a silent break
            break
        try:
            entries = list(current.iterdir())
        except OSError:
            continue
        for entry in entries:
            try:
                if not entry.is_dir() or entry.is_symlink():
                    continue
            except OSError:
                continue
            if entry.name in _SKIP_DIRS:
                continue
            if entry.name == SOURCE_DIR_NAME:
                found.append(entry)
                continue          # don't descend into it twice; scan_dir recurses
            stack.append(entry)
    return sorted(found)


def scan(root: Path, ticket: str | None = None) -> list[dict]:
    out: list[dict] = []
    _DISCOVERY_TRUNCATED.clear()
    dirs = find_source_dirs(root, ticket)
    for directory in dirs:
        out.extend(scan_dir(directory))
    if _DISCOVERY_TRUNCATED:
        out.append({"file": str(root), "name": str(root), "kind": KIND_INCOMPLETE,
                    "reason": f"directory discovery stopped at {MAX_DIRS} directories — "
                              f"source_materials trees may exist that were never looked at"})
    return out


def incomplete(records: list[dict]) -> list[dict]:
    """Records saying the scan is not authoritative. A caller that gates MUST check this."""
    return [r for r in records if r["kind"] == KIND_INCOMPLETE]


_DISCOVERY_TRUNCATED: list[Path] = []


def flagged(records: list[dict]) -> list[dict]:
    return [r for r in records if r["kind"] == KIND_RAW_SUSPECT]


def intake(records: list[dict]) -> list[dict]:
    """Files a priming pass should READ as ticket inputs.

    Curated meeting notes and ordinary inputs qualify. A `raw_suspect` deliberately does not —
    priming should not pull a full transcript into context — and neither do binaries or symlinks.
    """
    return [r for r in records if r["kind"] in (KIND_CURATED, KIND_OTHER)
            and r["kind"] != KIND_INCOMPLETE]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="scan_source_materials.py",
        description="Classify a ticket's source_materials/ files (curated / raw_suspect / other).")
    parser.add_argument("--root", default=".", help="repo root (default: .)")
    parser.add_argument("--ticket", default=None,
                        help="scope to one ticket dir (or its source_materials/)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--intake", action="store_true",
                        help="list only the files priming should read as inputs")
    args = parser.parse_args(argv)

    root = Path(args.root)
    if not root.is_dir():
        print(f"scan_source_materials: --root is not a directory: {root}", file=sys.stderr)
        return 2

    records = scan(root, args.ticket)
    selected = intake(records) if args.intake else records

    if args.json:
        print(json.dumps({"root": str(root), "mode": "intake" if args.intake else "scan",
                          "files": selected,
                          "flagged": [r["file"] for r in flagged(records)]}, indent=2))
    elif not selected:
        print("no source material found" if not args.intake else "no intake material found")
    else:
        for record in selected:
            print(f"{record['kind']:12} {record['file']}"
                  + (f"  — {record['reason']}" if record["reason"] and not args.intake else ""))

    # --intake REPORTS; it never gates. Only the classification mode carries the exit-code
    # contract, so a priming pass cannot be made to fail by material it merely declined to read.
    if args.intake:
        return 0
    return 1 if (flagged(records) or incomplete(records)) else 0


if __name__ == "__main__":
    sys.exit(main())
