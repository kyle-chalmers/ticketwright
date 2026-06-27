#!/usr/bin/env python3
"""Prior-art recall — rank prior tickets most relevant to a new one, for reuse in the PLAN phase.

Deterministic, lexical, stdlib-only (NO embeddings/vector DB — see the kit's KISS stance). Scores
every ticket (from tickets/index_data.json, falling back to README-derived fields for un-enriched
ones) against a query built from a seed ticket and/or free text / tags / object, with a transparent
score breakdown. The `/recall` command runs this, then reads the top hits and writes a reuse brief.

Usage:
  recall.py --for ENG-12 [--top 5] [--json]        # query = that ticket's title/summary/tags/objects
  recall.py --query "genesys call metrics" [--tags a,b] [--object SCHEMA.VW] [--top 5] [--json]
  recall.py --object BI.ANALYTICS.VW_LOAN          # reverse lookup: tickets that touched an object

Scoring (transparent): object match ×4, tag match ×3, cross-ref link +5, keyword overlap ×1 (capped).
Recency is a tiebreak only. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

from build_ticket_index import repo_root, build_rows, ticket_number

STOPWORDS = {
    "the", "a", "an", "and", "or", "for", "of", "to", "in", "on", "by", "with", "from", "into",
    "is", "are", "be", "as", "at", "this", "that", "it", "via", "per", "vs", "new", "add", "update",
    "fix", "ticket", "data", "report", "list", "file", "files", "table", "view",
}
W_OBJECT, W_TAG, W_REF, W_KEYWORD, KEYWORD_CAP = 4, 3, 5, 1, 6


def tokenize(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9]+", (text or "").lower()) if len(t) >= 3 and t not in STOPWORDS}


def ci(values) -> set[str]:
    return {str(v).strip().lower() for v in (values or []) if str(v).strip()}


def leaf(name: str) -> str:
    """Trailing object name, stripped of schema/db qualification: `bi.analytics.vw_loan` -> `vw_loan`."""
    return name.rsplit(".", 1)[-1]


def object_hits(q_objects: set[str], r_objects: set[str]) -> list[str]:
    """Row objects that match a query object, leaf-aware so `vw_loan` finds `bi.analytics.vw_loan`."""
    q_leaves = {leaf(q) for q in q_objects}
    return sorted(o for o in r_objects if o in q_objects or leaf(o) in q_leaves)


def main() -> int:
    ap = argparse.ArgumentParser(description="Rank prior tickets relevant to a new one (prior-art recall)")
    ap.add_argument("--for", dest="seed", help="seed ticket id (use its title/summary/tags/objects as the query)")
    ap.add_argument("--owner", help="disambiguate the seed when an id exists under multiple owners")
    ap.add_argument("--query", default="", help="free-text query")
    ap.add_argument("--tags", default="", help="comma-separated tags to match")
    ap.add_argument("--object", dest="object", default="", help="object name (also enables reverse lookup)")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    root = repo_root()
    rows = build_rows(root)

    # --- build the query from a seed ticket and/or explicit inputs ---
    q_tokens, q_tags, q_objects = tokenize(args.query), ci(args.tags.split(",")), ci([args.object] if args.object else [])
    seed_id, seed_owner, seed_refs = None, None, set()
    if args.seed:
        sid, sown = args.seed.lower(), (args.owner or "").lower()  # case-insensitive id/owner match
        seed_matches = [r for r in rows if r["id"].lower() == sid and (not sown or r["owner"].lower() == sown)]
        if not seed_matches:
            sys.exit(f"recall: seed ticket {args.seed} not found (try --owner to disambiguate).")
        if len(seed_matches) > 1:  # same id under >1 owner and no --owner — don't silently pick one
            owners = ", ".join(sorted(r["owner"] for r in seed_matches))
            sys.exit(f"recall: {args.seed} exists under multiple owners ({owners}); pass --owner to pick one.")
        seed = seed_matches[0]
        seed_id, seed_owner = seed["id"], seed["owner"]
        seed_refs = ci(seed.get("cross_refs"))
        q_tokens |= tokenize(f"{seed['title']} {seed['summary']}")
        q_tags |= ci(seed.get("tags"))
        q_objects |= ci(seed.get("objects"))

    # --- pure reverse lookup: --object with no other query terms ---
    reverse_only = bool(args.object) and not (args.seed or args.query or args.tags)

    scored = []
    for r in rows:
        if seed_id and r["id"] == seed_id and r["owner"] == seed_owner:
            continue  # exclude only the chosen seed row (same id under another owner is a real candidate)
        r_tags, r_objects = ci(r.get("tags")), ci(r.get("objects"))
        # tags are NOT folded in here — they score via tag_hits (×W_TAG) only, not also as keywords
        r_tokens = tokenize(f"{r['title']} {r['summary']}")

        obj_hits = object_hits(q_objects, r_objects)
        tag_hits = sorted(q_tags & r_tags)
        kw_hits = q_tokens & r_tokens
        ref_link = bool(seed_id and (r["id"].lower() in seed_refs or seed_id.lower() in ci(r.get("cross_refs"))))

        if reverse_only:
            if not obj_hits:
                continue
            score = W_OBJECT * len(obj_hits)
        else:
            score = (W_OBJECT * len(obj_hits) + W_TAG * len(tag_hits)
                     + W_REF * (1 if ref_link else 0) + W_KEYWORD * min(len(kw_hits), KEYWORD_CAP))
            if score <= 0:
                continue
        why = []
        if obj_hits: why.append("obj:" + ",".join(obj_hits))
        if tag_hits: why.append("tag:" + ",".join(tag_hits))
        if ref_link: why.append("ref")
        if kw_hits and not reverse_only: why.append(f"kw:{min(len(kw_hits), KEYWORD_CAP)}")
        scored.append((score, r, why))

    # sort (self-contained total order): score, then date, ticket number, id, owner — all desc.
    scored.sort(key=lambda x: (x[0], x[1]["date"] or "0000-00-00", ticket_number(x[1]["id"]), x[1]["id"], x[1]["owner"]), reverse=True)
    top = scored[: args.top]

    if args.json:
        print(json.dumps([
            {"id": r["id"], "owner": r["owner"], "score": s, "why": why, "title": r["title"],
             "summary": r["summary"], "date": r["date"], "tags": r.get("tags"), "objects": r.get("objects"),
             "readme": r["link"], "url": r["url"]}
            for s, r, why in top], ensure_ascii=False, indent=2))
        return 0

    header = (f"Reverse lookup: tickets touching {args.object}" if reverse_only
              else f"Prior art" + (f" for {seed_id}" if seed_id else "")) + f" — top {len(top)} of {len(scored)}"
    print(header)
    if not top:
        print("  (no matches)")
        return 0
    for s, r, why in top:
        print(f"  {r['id']:<10} score {s:<3} [{' '.join(why)}]  {r['date'] or '—'}  {r['title'][:60]}")
        print(f"             {r['link']}")
    if not reverse_only:
        print("\nRead these READMEs and write a reuse brief: what to copy (which SQL/QC artifact + path),"
              " known gotchas, and what's different this time.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
