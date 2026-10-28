#!/usr/bin/env python3
"""Upsert LLM-extracted records into tickets/index_data.json (the enrichment store).

`build_ticket_index.py` renders INDEX.md but never invents summaries — the LLM-authored
fields (summary / status / best-date / tags / cross_refs) live in tickets/index_data.json.
This helper takes records produced by the refresh skill (index mode) (or a single hand-written
record at ticket close), stamps each with the live README's content hash (so the renderer can
flag stale summaries), upserts by (owner, id), and writes the store.

Usage:
  ingest_index_records.py --from-json records.json     # bulk upsert from {"records":[...]} or [...]
  ingest_index_records.py --from-json -                # read JSON from stdin
  ingest_index_records.py --tracker-status statuses.json [--read-on YYYY-MM-DD]
                                                       # record statuses READ FROM THE TRACKER
  ingest_index_records.py --tracker-status statuses.json --planned
                                                       # record the status /ship is about to move to
  ingest_index_records.py --withdraw-planned <owner>/<id> | <id>   # the move is off: drop the plan
  ingest_index_records.py --confirm-planned statuses.json --for <owner>/<id>   # read-only check
  ingest_index_records.py --in-review <owner>/<id> [--tracker-now STATUS]      # Ticketwright-side review

Statuses have one source, the tracker. `--tracker-status` takes what `tracker.search` returned for a
list of ids ({"statuses":[{id, status, owner?}]} or [...]) and records it on every ticket folder with
that id (one tracker ticket can have a folder under more than one owner) as `tracker_status` plus
the date it was read. The renderer shows it ahead of the curated status, which is a model's reading
of the README and drifts. A curated upsert keeps the recorded tracker status: they are separate
fields with separate writers. A status is free text from the tracker, checked for shape only
(`build_ticket_index.clean_status`); one that fails is reported and not recorded.

A PLANNED status is /ship's answer to a timing problem. /ship commits the index in the pull request,
and only moves the tracker ticket after that pull request merges, so a read taken before the merge is
already out of date when it lands. `--planned` records the status the approved plan moves to as
`planned_status` (+ `planned_status_on`), in the same commit, so the merged index shows the status
the ticket ends on. It is a claim about the future, so it is kept apart from the read and undone
when the move does not happen: `--withdraw-planned` drops it (the merge was left to the team, or
was blocked), and the next real read (`--tracker-status` without `--planned`) replaces it. After
the move, `--confirm-planned` takes the status read back from the tracker and says whether it is
the planned one (exit 0), differs (exit 8), or was not read (exit 7). It writes nothing: on main the
plan is already the truth when the tracker agrees, and a write there would be a change nobody ships.
`--planned` also rewrites the ticket README's `- **Status:**` line, so the README, the index and the
graph note agree in the shipped commit; `--withdraw-planned` puts the line back.

`--in-review` is for a ship that hands the work to stakeholders when the tracker has no review status
(or the team does not track status there): the README line and the index say `In review`, awaiting
stakeholder feedback, while the tracker stays where it is. The next ship replaces it, and so does a
tracker read showing the ticket moved since (`--tracker-now` records where it was).

After ingesting, run: python3 bin/build_ticket_index.py
Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path

from build_ticket_index import (discover, repo_root, sha256_file, ref_key, load_config,
                               ticket_url, id_key_regex, clean_status, readme_status)

VALID_STATUS = {"Completed", "Deployed", "In Review", "In Progress", "Blocked", "Unknown"}


def _as_list(v) -> list:
    """Normalize a possibly-string / possibly-missing value into a list of strings."""
    if isinstance(v, str):
        return [v]
    if isinstance(v, (list, tuple)):
        return [x for x in v if isinstance(x, str)]
    return []


# --- validators: this is the single trust boundary for LLM-authored records ---
def _valid_date(v):
    """Keep an ISO YYYY-MM-DD date that actually parses; drop anything else (e.g. an invented date)."""
    s = (v or "").strip() if isinstance(v, str) else ""
    try:
        return date.fromisoformat(s).isoformat() if s else None
    except ValueError:
        return None


def _clean_objects(v) -> list:
    """Qualified object names only (must contain a dot) — drops bare prose like 'the orders view'."""
    seen: dict[str, str] = {}
    for o in _as_list(v):
        o = o.strip()
        if "." in o:
            seen.setdefault(o.lower(), o)
    return sorted(seen.values(), key=str.lower)


def _clean_tags(v, cap: int = 6) -> list:
    """Coerce to kebab-case, dedup (order-preserving), cap the count."""
    out = []
    for t in _as_list(v):
        k = re.sub(r"[^a-z0-9]+", "-", t.strip().lower()).strip("-")
        if k and k not in out:
            out.append(k)
    return out[:cap]


def load_records(spec: str) -> list[dict]:
    text = sys.stdin.read() if spec == "-" else Path(spec).read_text()
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: --from-json input is not valid JSON ({e}).")
    if isinstance(data, dict):
        data = data.get("records", [])
    if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
        sys.exit('ERROR: records must be a JSON array of objects (or {"records": [...]}).')
    return data


def load_statuses(spec: str) -> list[dict]:
    text = sys.stdin.read() if spec == "-" else Path(spec).read_text()
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: --tracker-status input is not valid JSON ({e}).")
    if isinstance(data, dict):
        data = data.get("statuses", [])
    if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
        sys.exit('ERROR: statuses must be a JSON array of objects (or {"statuses": [...]}).')
    return data


PLANNED_KEYS = ("planned_status", "planned_status_on")
# A Ticketwright-side status: `In review`, awaiting stakeholder feedback, for a tracker that has no
# review status. `ticketwright_status_tracker` is the tracker's status when it was set, so a later
# read showing the tracker moved on (someone closed the ticket by hand) replaces it.
REVIEW_KEYS = ("ticketwright_status", "ticketwright_status_on", "ticketwright_status_tracker")
# What /ship wrote into the README's Status line, and what the line said before. If the line changes
# afterwards (a `local` transition, a hand edit), the README is the newer copy and the plan yields.
README_KEYS = ("readme_status_set", "readme_status_before")
TICKETWRIGHT_REVIEW = "In review"
EXIT_CONFIRMED, EXIT_NOT_READ, EXIT_DIFFERS = 0, 7, 8
README_STATUS_LINE = re.compile(r"(?m)^(\s*[-*]\s+\*\*Status:\*\*)[ \t]*.*$")


def _norm(s: str) -> str:
    """Status names compared the way transition_plan.py matches them: case and spacing aside."""
    return " ".join(s.split()).casefold()


def _keys_for(dirs: dict, tid: str, owner: str | None) -> list:
    return [k for k in dirs if k[1] == tid and (owner is None or k[0] == owner)]


def _parse_locator(loc: str) -> tuple[str | None, str]:
    loc = loc.strip()
    if "/" in loc:
        owner, _, tid = loc.rpartition("/")
        return owner.strip() or None, tid.strip()
    return None, loc


def _drop(rec: dict, keys) -> None:
    for k in keys:
        rec.pop(k, None)


def set_readme_status(readme, status: str) -> bool:
    """Rewrite the README's `- **Status:**` line(s) to `status`. False when there is no README or no
    line: the line is never added, because where it belongs is the ticket template's call."""
    if not readme or not Path(readme).is_file():
        return False
    text = Path(readme).read_text(encoding="utf-8")
    # A replacement FUNCTION: a status is free text, and `\1` in a replacement string would expand.
    new, n = README_STATUS_LINE.subn(lambda m: f"{m.group(1)} {status}", text)
    if n and new != text:
        Path(readme).write_text(new, encoding="utf-8")
    return bool(n)


def _ship_readme(rec: dict, readme, status: str, notes: list, loc: str) -> None:
    """/ship's README write: set the line, remember what it said, so a withdraw can put it back."""
    before = readme_status(readme)
    if set_readme_status(readme, status):
        rec.setdefault("readme_status_before", before)
        rec["readme_status_set"] = status
    else:
        notes.append(f"{loc}: the README has no Status line, so only the index shows {status}")


def record_statuses(store: dict, dirs: dict, rows: list[dict], read_on: str,
                    planned: bool = False, set_readme: bool = False,
                    notes: list | None = None) -> tuple[int, list, list]:
    """Write each tracker status onto every on-disk folder with that id. Returns (recorded, skipped,
    rejected). An id with no folder is skipped, never stored: the index lists folders, not tickets.
    `planned` records the status /ship is about to move to instead of one read from the tracker, and
    writes it into the README's Status line too, so the README, the index and the graph agree in the
    shipped commit. A real read replaces any plan, because it is newer and came from the tracker;
    `set_readme` makes that read rewrite the README line as well (/ship's fix-up after a failed move)."""
    notes = notes if notes is not None else []
    recorded, skipped, rejected = 0, [], []
    for r in rows:
        tid, owner = r.get("id"), r.get("owner")
        if not isinstance(tid, str) or not tid.strip():
            rejected.append(f"{r!r}: no id")
            continue
        tid = tid.strip()
        status = clean_status(r.get("status"))
        if status is None:
            rejected.append(f"{tid}: status {r.get('status')!r} cannot go in a table cell (empty, over "
                            f"40 characters, or carrying one of | ` < > {{ }} [ ] \\)")
            continue
        keys = _keys_for(dirs, tid, owner)
        if not keys:
            skipped.append(f"{owner + '/' if owner else ''}{tid}")
            continue
        for k in keys:
            rec = store.get(k) or {"id": k[1], "owner": k[0]}
            readme = dirs[k].get("readme")
            if planned:
                _drop(rec, REVIEW_KEYS)
                rec["planned_status"] = status
                rec["planned_status_on"] = read_on
                _ship_readme(rec, readme, status, notes, f"{k[0]}/{k[1]}")
                store[k] = rec
                recorded += 1
                continue
            _drop(rec, PLANNED_KEYS)
            if rec.get("ticketwright_status_tracker") is not None \
                    and _norm(rec["ticketwright_status_tracker"]) != _norm(status):
                _drop(rec, REVIEW_KEYS)   # the tracker moved on since the review was recorded
            if set_readme:
                _ship_readme(rec, readme, status, notes, f"{k[0]}/{k[1]}")
            if not any(x in rec for x in REVIEW_KEYS):
                _drop(rec, README_KEYS)
            rec["tracker_status"] = status
            rec["tracker_status_read"] = read_on
            # What the README's Status line said at the read. If the line changes later (the `local`
            # tracker's transition writes it; /ticket rewrites it), the README is the newer copy.
            rec["readme_status_at_read"] = readme_status(readme)
            store[k] = rec
            recorded += 1
    return recorded, skipped, rejected


def record_review(store: dict, dirs: dict, locators: list[str], set_on: str,
                  tracker_now: str | None, notes: list) -> tuple[int, list]:
    """Mark each named folder `In review` on the Ticketwright side (README line + index), for a
    tracker that has no review status. Returns (recorded, missing)."""
    recorded, missing = 0, []
    for loc in locators:
        owner, tid = _parse_locator(loc)
        keys = _keys_for(dirs, tid, owner)
        if not keys:
            missing.append(loc)
        for k in keys:
            rec = store.get(k) or {"id": k[1], "owner": k[0]}
            _drop(rec, PLANNED_KEYS)
            rec["ticketwright_status"] = TICKETWRIGHT_REVIEW
            rec["ticketwright_status_on"] = set_on
            rec["ticketwright_status_tracker"] = clean_status(tracker_now) if tracker_now else None
            _ship_readme(rec, dirs[k].get("readme"), TICKETWRIGHT_REVIEW, notes, f"{k[0]}/{k[1]}")
            store[k] = rec
            recorded += 1
    return recorded, missing


def withdraw_planned(store: dict, dirs: dict, locators: list[str]) -> tuple[int, list]:
    """Drop the planned status from each named folder, and put the README's Status line back to what
    it said before /ship wrote it. Returns (withdrawn, not_planned)."""
    withdrawn, missing = 0, []
    for loc in locators:
        owner, tid = _parse_locator(loc)
        hit = False
        for k in _keys_for(dirs, tid, owner):
            rec = store.get(k)
            if rec and any(pk in rec for pk in PLANNED_KEYS):
                readme = dirs[k].get("readme")
                before, wrote = rec.get("readme_status_before"), rec.get("readme_status_set")
                if before and wrote and readme_status(readme) == wrote:
                    set_readme_status(readme, before)
                _drop(rec, PLANNED_KEYS + README_KEYS)
                withdrawn += 1
                hit = True
        if not hit:
            missing.append(loc)
    return withdrawn, missing


def confirm_planned(store: dict, dirs: dict, rows: list[dict] | None,
                    locators: list[str]) -> tuple[int, list[dict]]:
    """Compare what the tracker returned after the move with the planned status of the NAMED
    tickets only (an older plan on main for another ticket is not this ship's business). `rows` is
    None when the read-back could not be read at all. Read-only."""
    by_id: dict[tuple, str | None] = {}
    for r in rows or []:
        tid = r.get("id")
        if isinstance(tid, str) and tid.strip():
            for k in _keys_for(dirs, tid.strip(), r.get("owner")):
                by_id[k] = clean_status(r.get("status"))
    results, code = [], EXIT_CONFIRMED
    for loc in locators:
        owner, tid = _parse_locator(loc)
        keys = _keys_for(dirs, tid, owner)
        for k in keys or [(owner or "?", tid)]:
            plan = (store.get(k) or {}).get("planned_status")
            read = by_id.get(k)
            if not plan:
                result = "no_plan"
            elif read is None:
                result = "not_read"
            elif _norm(read) == _norm(plan):
                result = "confirmed"
            else:
                result = "differs"
            results.append({"owner": k[0], "id": k[1], "planned": plan, "read": read, "result": result})
            if result == "differs":
                code = EXIT_DIFFERS
            elif result in ("not_read", "no_plan") and code == EXIT_CONFIRMED:
                code = EXIT_NOT_READ
    return code, results


def _write_store(store_path: Path, store: dict, key_re) -> list:
    tickets = sorted(store.values(),
                     key=lambda t: ((t.get("date") or "0000-00-00"), ref_key(t["id"], key_re), t["owner"]),
                     reverse=True)
    payload = json.dumps({"schema_version": 1, "tickets": tickets}, indent=2, ensure_ascii=False) + "\n"
    store_path.parent.mkdir(parents=True, exist_ok=True)
    store_path.write_bytes(payload.encode("utf-8"))
    return tickets


def main() -> int:
    ap = argparse.ArgumentParser(description="Upsert records into tickets/index_data.json")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--from-json", help="path to records JSON, or '-' for stdin")
    mode.add_argument("--tracker-status", metavar="FILE",
                      help="statuses read from the tracker (tracker.search by ids), or '-' for stdin")
    mode.add_argument("--withdraw-planned", nargs="+", metavar="LOCATOR",
                      help="drop the planned status from <owner>/<id> (or a bare id: every owner's folder)")
    mode.add_argument("--confirm-planned", metavar="FILE",
                      help="read-only: compare statuses read back from the tracker with the planned ones")
    mode.add_argument("--in-review", nargs="+", metavar="LOCATOR",
                      help="mark <owner>/<id> In review on the Ticketwright side (README + index)")
    ap.add_argument("--for", dest="for_locators", nargs="+", metavar="LOCATOR",
                    help="with --confirm-planned: the shipped ticket(s) to check (required)")
    ap.add_argument("--tracker-now", default=None, metavar="STATUS",
                    help="with --in-review: the tracker's status now, which stays as it is")
    ap.add_argument("--planned", action="store_true",
                    help="with --tracker-status: the status /ship is about to move to, not a read")
    ap.add_argument("--set-readme", action="store_true",
                    help="with --tracker-status: also rewrite each README's Status line to the read")
    ap.add_argument("--read-on", default=None, metavar="YYYY-MM-DD",
                    help="with --tracker-status: the date the statuses were read (default: today)")
    args = ap.parse_args()
    if args.read_on is not None and not args.tracker_status:
        ap.error("--read-on goes with --tracker-status")
    if (args.planned or args.set_readme) and not args.tracker_status:
        ap.error("--planned and --set-readme go with --tracker-status")
    if args.confirm_planned and not args.for_locators:
        ap.error("--confirm-planned needs --for <owner>/<id>: only the shipped ticket is checked")
    if args.for_locators and not args.confirm_planned:
        ap.error("--for goes with --confirm-planned")
    if args.tracker_now is not None and not args.in_review:
        ap.error("--tracker-now goes with --in-review")
    read_on = date.today().isoformat()
    if args.read_on is not None:
        try:
            read_on = date.fromisoformat(args.read_on.strip()).isoformat()
        except ValueError:
            ap.error(f"--read-on must be a date like 2026-10-26, got {args.read_on!r}")

    root = repo_root()
    dirs = {(t["owner"], t["id"]): t for t in discover(root)}
    _cfg = load_config(root)
    url_template = _cfg["url_template"]
    # The configured prefixes decide which ids carry a tracker number; without this a slug like
    # `a-1` would be persisted with {number}=1, pointing at an unrelated real ticket.
    key_re = id_key_regex(_cfg)

    store_path = root / "tickets" / "index_data.json"
    store: dict[tuple[str, str], dict] = {}
    if store_path.is_file():
        try:
            sdata = json.loads(store_path.read_text())
        except json.JSONDecodeError as e:
            sys.exit(f"ERROR: existing tickets/index_data.json is malformed ({e}); refusing to overwrite.")
        if not isinstance(sdata, dict) or not isinstance(sdata.get("tickets"), list):
            sys.exit("ERROR: existing tickets/index_data.json must be an object with a 'tickets' list.")
        store = {(t["owner"], t["id"]): t for t in sdata["tickets"]
                 if isinstance(t, dict) and isinstance(t.get("owner"), str) and isinstance(t.get("id"), str)}

    if args.confirm_planned:
        try:
            rows = load_statuses(args.confirm_planned)
        except (OSError, SystemExit):
            # No read-back to compare (the search failed and saved nothing): not confirmed, exit 7.
            rows = None
        code, results = confirm_planned(store, dirs, rows, args.for_locators)
        print(json.dumps({"results": results}, ensure_ascii=False))
        for r in results:
            loc = f"{r['owner']}/{r['id']}"
            if r["result"] == "confirmed":
                print(f"{loc}: the tracker shows {r['read']}, as the index says.", file=sys.stderr)
            elif r["result"] == "differs":
                print(f"{loc}: the index says {r['planned']} but the tracker shows {r['read']}.",
                      file=sys.stderr)
            elif r["result"] == "no_plan":
                print(f"{loc}: no planned status is on file, so there is nothing to confirm.",
                      file=sys.stderr)
            else:
                print(f"{loc}: the index says {r['planned']}, and the tracker's status was not read "
                      "back, so it is not confirmed.", file=sys.stderr)
        return code

    notes: list = []
    if args.in_review:
        recorded, missing = record_review(store, dirs, args.in_review, read_on, args.tracker_now, notes)
        _write_store(store_path, store, key_re)
        kept = f" The tracker stays at {args.tracker_now}." if args.tracker_now else ""
        print(f"Marked {recorded} ticket folder(s) {TICKETWRIGHT_REVIEW}, awaiting stakeholder "
              f"feedback, in the README and the index.{kept}", file=sys.stderr)
        if missing:
            print(f"No ticket folder for: {', '.join(missing)}", file=sys.stderr)
        for n in notes:
            print(n, file=sys.stderr)
        return 0

    if args.withdraw_planned:
        withdrawn, missing = withdraw_planned(store, dirs, args.withdraw_planned)
        _write_store(store_path, store, key_re)
        print(f"Withdrew the planned status from {withdrawn} ticket folder(s).", file=sys.stderr)
        if missing:
            print(f"No planned status on file for: {', '.join(missing)}", file=sys.stderr)
        return 0

    if args.tracker_status:
        recorded, skipped, rejected = record_statuses(store, dirs, load_statuses(args.tracker_status),
                                                      read_on, planned=args.planned,
                                                      set_readme=args.set_readme, notes=notes)
        _write_store(store_path, store, key_re)
        if args.planned:
            print(f"Recorded the planned status for {recorded} ticket folder(s), set on {read_on}. "
                  "It shows in the index until a read from the tracker replaces it.", file=sys.stderr)
        else:
            print(f"Recorded the tracker status for {recorded} ticket folder(s), read on {read_on}.",
                  file=sys.stderr)
        if skipped:
            print(f"Skipped {len(skipped)} (no matching folder): {', '.join(skipped)}", file=sys.stderr)
        if rejected:
            print(f"Not recorded ({len(rejected)}): " + "; ".join(rejected), file=sys.stderr)
        for n in notes:
            print(n, file=sys.stderr)
        return 0

    incoming = load_records(args.from_json)
    upserted, skipped = 0, []
    for r in incoming:
        owner, tid = r.get("owner"), r.get("id")
        loc = dirs.get((owner, tid))
        if not loc:
            skipped.append(f"{owner or '?'}/{tid or '?'}")
            continue
        owner, tid = str(owner), str(tid)
        readme = loc["readme"]
        status = r.get("status") if r.get("status") in VALID_STATUS else "Unknown"
        refs = sorted({c for c in _as_list(r.get("cross_refs")) if c != tid},
                      key=lambda i: ref_key(i, key_re))
        rec = {
            "id": tid,
            "owner": owner,
            "title": (r.get("title") or "").strip(),
            "status": status,
            "date": _valid_date(r.get("date")),
            "cross_refs": refs,
            "tags": _clean_tags(r.get("tags")),
            "objects": _clean_objects(r.get("objects")),
            "summary": (r.get("summary") or "").strip(),
            "confidence": r.get("confidence") or "medium",
            "readme_present": bool(readme),
            "readme_hash": sha256_file(readme) if readme else None,
        }
        url = r.get("ticket_url") or r.get("jira_url") or ticket_url(url_template, tid, key_re)
        if url:
            rec["ticket_url"] = url
        prev = store.get((owner, tid)) or {}
        for k in ("tracker_status", "tracker_status_read", "readme_status_at_read") + PLANNED_KEYS \
                + REVIEW_KEYS + README_KEYS:
            if k in prev:   # the tracker's own read has its own writer; a curated upsert keeps it
                rec[k] = prev[k]
        store[(owner, tid)] = rec
        upserted += 1

    tickets = _write_store(store_path, store, key_re)
    print(f"Upserted {upserted} record(s); store now has {len(tickets)}.", file=sys.stderr)
    if skipped:
        print(f"Skipped {len(skipped)} (no matching folder): {', '.join(skipped)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
