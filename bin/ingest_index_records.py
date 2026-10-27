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

Statuses have one source, the tracker. `--tracker-status` takes what `tracker.search` returned for a
list of ids ({"statuses":[{id, status, owner?}]} or [...]) and records it on every ticket folder with
that id (one tracker ticket can have a folder under more than one owner) as `tracker_status` plus
the date it was read. The renderer shows it ahead of the curated status, which is a model's reading
of the README and drifts. A curated upsert keeps the recorded tracker status: they are separate
fields with separate writers. A status is free text from the tracker, checked for shape only
(`build_ticket_index.clean_status`); one that fails is reported and not recorded.

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
                               ticket_url, id_key_regex, clean_status)

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


def record_statuses(store: dict, dirs: dict, rows: list[dict], read_on: str) -> tuple[int, list, list]:
    """Write each tracker status onto every on-disk folder with that id. Returns (recorded, skipped,
    rejected). An id with no folder is skipped, never stored: the index lists folders, not tickets."""
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
        keys = [k for k in dirs if k[1] == tid and (owner is None or k[0] == owner)]
        if not keys:
            skipped.append(f"{owner + '/' if owner else ''}{tid}")
            continue
        for k in keys:
            rec = store.get(k) or {"id": k[1], "owner": k[0]}
            rec["tracker_status"] = status
            rec["tracker_status_read"] = read_on
            store[k] = rec
            recorded += 1
    return recorded, skipped, rejected


def main() -> int:
    ap = argparse.ArgumentParser(description="Upsert records into tickets/index_data.json")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--from-json", help="path to records JSON, or '-' for stdin")
    mode.add_argument("--tracker-status", metavar="FILE",
                      help="statuses read from the tracker (tracker.search by ids), or '-' for stdin")
    ap.add_argument("--read-on", default=None, metavar="YYYY-MM-DD",
                    help="with --tracker-status: the date the statuses were read (default: today)")
    args = ap.parse_args()
    if args.read_on is not None and not args.tracker_status:
        ap.error("--read-on goes with --tracker-status")
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

    if args.tracker_status:
        recorded, skipped, rejected = record_statuses(store, dirs, load_statuses(args.tracker_status),
                                                      read_on)
        tickets = sorted(store.values(),
                         key=lambda t: ((t.get("date") or "0000-00-00"), ref_key(t["id"], key_re), t["owner"]),
                         reverse=True)
        payload = json.dumps({"schema_version": 1, "tickets": tickets}, indent=2, ensure_ascii=False) + "\n"
        store_path.parent.mkdir(parents=True, exist_ok=True)
        store_path.write_bytes(payload.encode("utf-8"))
        print(f"Recorded the tracker status for {recorded} ticket folder(s), read on {read_on}.",
              file=sys.stderr)
        if skipped:
            print(f"Skipped {len(skipped)} (no matching folder): {', '.join(skipped)}", file=sys.stderr)
        if rejected:
            print(f"Not recorded ({len(rejected)}): " + "; ".join(rejected), file=sys.stderr)
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
        for k in ("tracker_status", "tracker_status_read"):
            if k in prev:   # the tracker's own read has its own writer; a curated upsert keeps it
                rec[k] = prev[k]
        store[(owner, tid)] = rec
        upserted += 1

    tickets = sorted(store.values(),
                     key=lambda t: ((t.get("date") or "0000-00-00"), ref_key(t["id"], key_re), t["owner"]),
                     reverse=True)
    payload = json.dumps({"schema_version": 1, "tickets": tickets}, indent=2, ensure_ascii=False) + "\n"
    store_path.parent.mkdir(parents=True, exist_ok=True)
    store_path.write_bytes(payload.encode("utf-8"))
    print(f"Upserted {upserted} record(s); store now has {len(tickets)}.", file=sys.stderr)
    if skipped:
        print(f"Skipped {len(skipped)} (no matching folder): {', '.join(skipped)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
