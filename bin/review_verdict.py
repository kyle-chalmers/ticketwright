#!/usr/bin/env python3
"""The review-verdict classifier — harness-neutral, one implementation.

Logic belongs in harness-neutral CLIs under bin/; hooks and skills are presentation (AGENTS.md
tiebreaker 5). This module is the ONE place that answers "what review verdict is on file for this
ticket?", and three presenters consume it:

  .claude/skills/{ship,build,review}/SKILL.md   the lifecycle skills call the CLI and branch on `status`
  .claude/hooks/review_verdict_guard.py         Claude Code PreToolUse presenter (ask/allow, exit 0)
  bin/hook_shim.py                              every other runtime's hook protocol

WHY A SCRIPT AND NOT A PARAGRAPH. The verdict used to be read by prose in three skills — "the
newest file", "the verdict: line" — which three agents interpreted three ways, and which fired only
when a human typed `/ship`. Two real tickets shipped unreviewed through raw `git push` + `gh pr
create`, never entering the skill. A classifier makes the read identical everywhere and gives the
hook something mechanical to present. It is the third instance of a shape the kit already has:
bin/sql_scan.py + db_write_guard.py, bin/scan_source_materials.py + source_material_guard.py.

THE CONTRACT it reads (written by /review, and by /ship for an unreviewed ship):

    <ticket-dir>/qc_queries/<n>_review_verdict.md      <n> = an unpadded integer
    verdict: APPROVE | REQUEST-CHANGES | SKIPPED         the first such line; lowercase key, exact

The CURRENT verdict is the file with the HIGHEST <n>, compared numerically — `10_` beats `9_`.
A lexical sort gets that wrong and an mtime is meaningless after a clone; neither is consulted.

STATUSES (closed vocabulary; `status` in --json, and the exit code):

  approve          0   the current verdict is APPROVE
  none             3   no `*_review_verdict.md` in qc_queries/ (a legacy report may be listed)
  unreadable       4   the current file has no `verdict:` line, or a value outside the vocabulary
  request-changes  5   the current verdict is REQUEST-CHANGES
  skipped          6   the current verdict is SKIPPED — /ship recorded an unreviewed ship; this
                       never counts as approval and a later real review supersedes it

Anything that is not `approve` is a reason to stop and look; `unreadable` is deliberately its own
status rather than a guess in either direction — a verdict nobody can read is not a verdict.

WHAT IT DOES NOT DO — stated plainly (tiebreaker 6). It reads the record; it does not judge the
work. An APPROVE written by hand is an APPROVE here. `legacy_candidates` lists other qc_queries/
files that look like a review report from before the fixed filename existed; they are REPORTED
for a human or /ship to honor, never used as the verdict. And a ticket with nothing in
final_deliverables/ has nothing to review yet — `deliverables` is reported so the hook can stay
silent on a work-in-progress push.

CLI (stdlib only, no Claude environment variable):

  bin/review_verdict.py --ticket <dir> [--json]

Exit codes: the status codes above · 2 usage (missing/unreadable ticket dir).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

STATUS_APPROVE = "approve"
STATUS_REQUEST_CHANGES = "request-changes"
STATUS_SKIPPED = "skipped"
STATUS_NONE = "none"
STATUS_UNREADABLE = "unreadable"

EXIT_CODE = {
    STATUS_APPROVE: 0,
    STATUS_NONE: 3,
    STATUS_UNREADABLE: 4,
    STATUS_REQUEST_CHANGES: 5,
    STATUS_SKIPPED: 6,
}

_VALUES = {
    "APPROVE": STATUS_APPROVE,
    "REQUEST-CHANGES": STATUS_REQUEST_CHANGES,
    "SKIPPED": STATUS_SKIPPED,
}

VERDICT_FILE_RE = re.compile(r"^(\d+)_review_verdict\.md$")
# The key is lowercase and exact: `Verdict:` (the pre-4.1 agent output) is NOT the contract, and
# matching it loosely here would let the writer and the readers drift apart silently again.
VERDICT_LINE_RE = re.compile(r"^verdict:\s*(\S.*?)\s*$")
REVIEW_MODE_RE = re.compile(r"^review_mode:\s*(\S.*?)\s*$")
# A legacy report: any other qc_queries/ file whose text carries a verdict-shaped line, in any
# case or markdown emphasis. Reported, never trusted.
LEGACY_LINE_RE = re.compile(r"^\W{0,4}verdict\W{0,4}\s*(APPROVE|REQUEST-CHANGES)\b", re.I | re.M)
READ_BYTES = 64 * 1024
TICKET_MARKERS = ("plan.md", "qc_queries", "final_deliverables", "README.md")


def verdict_files(ticket_dir: Path) -> list[tuple[int, Path]]:
    """Every `<n>_review_verdict.md` in qc_queries/, sorted by <n> ascending (numeric)."""
    qc = ticket_dir / "qc_queries"
    out: list[tuple[int, Path]] = []
    if not qc.is_dir():
        return out
    for p in qc.iterdir():
        m = VERDICT_FILE_RE.match(p.name)
        if m and p.is_file():
            out.append((int(m.group(1)), p))
    return sorted(out, key=lambda t: t[0])


def _read(path: Path) -> str:
    with path.open("rb") as fh:
        return fh.read(READ_BYTES).decode("utf-8", errors="replace")


def read_verdict(path: Path) -> dict:
    """Parse one verdict file: the first `verdict:` line decides; `review_mode:` is carried along."""
    text = _read(path)
    value = review_mode = None
    for line in text.splitlines():
        if value is None:
            m = VERDICT_LINE_RE.match(line)
            if m:
                value = m.group(1).strip("*` ").upper()
                continue
        m2 = REVIEW_MODE_RE.match(line)
        if m2 and review_mode is None:
            review_mode = m2.group(1).strip("*` ")
    if value is None:
        return {"status": STATUS_UNREADABLE, "value": None, "review_mode": review_mode,
                "reason": "no `verdict:` line (lowercase key, first thing after the title)"}
    status = _VALUES.get(value)
    if status is None:
        return {"status": STATUS_UNREADABLE, "value": value, "review_mode": review_mode,
                "reason": f"`verdict: {value}` is outside APPROVE | REQUEST-CHANGES | SKIPPED"}
    return {"status": status, "value": value, "review_mode": review_mode, "reason": None}


def deliverables(ticket_dir: Path) -> int:
    d = ticket_dir / "final_deliverables"
    if not d.is_dir():
        return 0
    return sum(1 for p in d.rglob("*") if p.is_file() and not p.name.startswith("."))


def legacy_candidates(ticket_dir: Path) -> list[str]:
    qc = ticket_dir / "qc_queries"
    if not qc.is_dir():
        return []
    out = []
    for p in sorted(qc.iterdir()):
        if not p.is_file() or VERDICT_FILE_RE.match(p.name) or p.suffix.lower() not in (".md", ".txt"):
            continue
        try:
            if LEGACY_LINE_RE.search(_read(p)):
                out.append(p.name)
        except OSError:
            continue
    return out


def classify(ticket_dir: Path) -> dict:
    """The one answer every presenter uses. Never raises on a readable directory."""
    ticket_dir = Path(ticket_dir)
    record: dict = {
        "ticket": str(ticket_dir),
        "locator": f"{ticket_dir.parent.name}/{ticket_dir.name}",
        "deliverables": deliverables(ticket_dir),
        "legacy_candidates": legacy_candidates(ticket_dir),
        "file": None, "n": None, "value": None, "review_mode": None, "reason": None,
    }
    files = verdict_files(ticket_dir)
    if not files:
        record["status"] = STATUS_NONE
        record["reason"] = "no qc_queries/<n>_review_verdict.md on file"
        return record
    n, path = files[-1]
    record.update(read_verdict(path))
    record["file"] = str(path)
    record["n"] = n
    return record


# --- locating the ticket a shell command is about --------------------------------------------------

def ticket_dir_of(path: Path, repo: Path) -> Path | None:
    """Walk up from `path` to the enclosing ticket folder, stopping at the repo."""
    try:
        cur = path.resolve()
        repo = repo.resolve()
    except OSError:
        return None
    while True:
        if cur.parent.parent.name == "tickets" and any((cur / m).exists() for m in TICKET_MARKERS):
            return cur
        if cur == repo or cur.parent == cur:
            return None
        cur = cur.parent


def current_branch(repo: Path) -> str | None:
    """The checked-out branch, read from .git without spawning git (worktrees included)."""
    git = repo / ".git"
    try:
        if git.is_file():
            first = git.read_text(encoding="utf-8", errors="replace").strip()
            if first.startswith("gitdir:"):
                git = Path(first.split(":", 1)[1].strip())
                if not git.is_absolute():
                    git = (repo / git).resolve()
        head = (git / "HEAD").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/"):]
    return None


def ticket_dirs_for_branch(repo: Path, branch: str | None) -> list[Path]:
    """`tickets/<owner>/<id>` folders a branch names: `<id>`, or `<owner>-<id>` when the id was taken."""
    if not branch:
        return []
    tickets = repo / "tickets"
    out: list[Path] = []
    if not tickets.is_dir():
        return out
    for owner in tickets.iterdir():
        if not owner.is_dir() or owner.name.startswith("."):
            continue
        for d in owner.iterdir():
            if not d.is_dir() or d.name.startswith("."):
                continue
            if branch == d.name or branch == f"{owner.name}-{d.name}":
                out.append(d)
    return out


def locate(repo: Path, paths: list[Path] | None = None, cwd: Path | None = None,
           branch: str | None = None) -> list[Path]:
    """Every ticket folder a command plausibly concerns: its path arguments, its cwd, its branch."""
    found: list[Path] = []
    for p in list(paths or []) + ([cwd] if cwd else []):
        t = ticket_dir_of(p, repo)
        if t and t not in found:
            found.append(t)
    for t in ticket_dirs_for_branch(repo, branch):
        if t not in found:
            found.append(t)
    return found


def describe(record: dict) -> str:
    s = record["status"]
    if s == STATUS_APPROVE:
        return f"APPROVE on file ({Path(record['file']).name}, {record.get('review_mode') or 'review_mode unrecorded'})"
    if s == STATUS_REQUEST_CHANGES:
        return f"REQUEST-CHANGES on file ({Path(record['file']).name})"
    if s == STATUS_SKIPPED:
        return f"SKIPPED on file ({Path(record['file']).name}) — an unreviewed ship was recorded; this is not approval"
    if s == STATUS_UNREADABLE:
        return f"{Path(record['file']).name} is unreadable as a verdict: {record['reason']}"
    extra = ""
    if record.get("legacy_candidates"):
        extra = " (report-shaped files present, not honored automatically: " + ", ".join(record["legacy_candidates"]) + ")"
    return "no review verdict on file" + extra


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Report the review verdict on file for a ticket folder.")
    ap.add_argument("--ticket", required=True, help="the ticket folder (…/tickets/<owner>/<id>)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)
    ticket = Path(args.ticket)
    if not ticket.is_dir():
        print(f"review_verdict: not a directory: {ticket}", file=sys.stderr)
        return 2
    record = classify(ticket)
    if args.json:
        print(json.dumps(record, indent=2))
    else:
        print(f"{record['locator']}: {describe(record)} · deliverables: {record['deliverables']}")
    return EXIT_CODE[record["status"]]


if __name__ == "__main__":
    sys.exit(main())
