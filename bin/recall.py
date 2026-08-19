#!/usr/bin/env python3
"""Prior-art recall — rank prior tickets most relevant to a new one, for reuse in the PLAN phase.

Deterministic, lexical, stdlib-only (NO embeddings/vector DB — see the kit's KISS stance). Scores
every ticket (from tickets/index_data.json, falling back to README-derived fields for un-enriched
ones) against a query built from a seed ticket and/or free text / tags / object, with a transparent
score breakdown. The `/ticket --recall` command runs this, then reads the top hits and writes a reuse brief.

Usage:
  recall.py --for ENG-12 [--top 5] [--min-score N] [--json]   # query = that ticket's fields
  recall.py --for alice/ENG-12                     # owner-qualified locator == --for ENG-12 --owner alice
  recall.py --query "orders feed latency" [--tags a,b] [--object SCHEMA.VW] [--top 5] [--json]
  recall.py --object BI.ANALYTICS.VW_ORDERS          # reverse lookup: tickets that touched an object
  recall.py --eval [--sweep]                       # diagnostic: recall quality vs curated cross_refs

Scoring (transparent): object match ×4 (IDF-discounted — a ubiquitous object counts less than a rare
shared one), tag match ×3, cross-ref link +5, keyword overlap ×1 (capped). Recency is a tiebreak only.
Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys

from build_ticket_index import repo_root, build_rows, ticket_number, id_key_regex, load_config, split_ref

STOPWORDS = {
    "the", "a", "an", "and", "or", "for", "of", "to", "in", "on", "by", "with", "from", "into",
    "is", "are", "be", "as", "at", "this", "that", "it", "via", "per", "vs", "new", "add", "update",
    "fix", "ticket", "data", "report", "list", "file", "files", "table", "view",
}
W_OBJECT, W_TAG, W_REF, W_KEYWORD, KEYWORD_CAP = 4, 3, 5, 1, 6
OBJ_IDF_FLOOR = 0.4  # ubiquitous object still counts, but < a rare shared one. 0.4 tuned via --eval
# on a benchmark corpus: strict Pareto gain (MRR .550->.571, P@1 .408->.421, P@3 .618->.671, rec@5 .462->.494)
DEFAULT_WEIGHTS = {"obj": W_OBJECT, "tag": W_TAG, "ref": W_REF, "kw": W_KEYWORD}


def tokenize(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9]+", (text or "").lower())
            if len(t) >= 3 and t not in STOPWORDS}


def ci(values) -> set[str]:
    return {str(v).strip().lower() for v in (values or []) if str(v).strip()}


def leaf(name: str) -> str:
    """Trailing object name, stripped of schema/db qualification: `bi.analytics.vw_orders` -> `vw_orders`."""
    return name.rsplit(".", 1)[-1]


def object_hits(q_objects: set[str], r_objects: set[str]) -> list[str]:
    """Row objects that match a query object, leaf-aware so `vw_orders` finds `bi.analytics.vw_orders`."""
    q_leaves = {leaf(q) for q in q_objects}
    return sorted(o for o in r_objects if o in q_objects or leaf(o) in q_leaves)


def object_df(rows) -> dict:
    """Leaf-granularity document frequency: how many tickets reference each object leaf."""
    df: dict[str, int] = {}
    for r in rows:
        for lf in {leaf(o) for o in ci(r.get("objects"))}:
            df[lf] = df.get(lf, 0) + 1
    return df


def idf_factor(df_map: dict, n_docs: int, name: str) -> float:
    """Discount in (FLOOR, 1.0]: the rarest object -> 1.0, a ubiquitous one -> ~FLOOR. Never a bonus,
    so flat W_OBJECT stays the ceiling. Honors the kit's transparent-weights stance — no learned vector."""
    if not df_map or n_docs <= 0:
        return 1.0
    denom = math.log(n_docs / (1 + min(df_map.values())))
    if denom <= 0:
        return 1.0
    f = math.log(n_docs / (1 + df_map.get(leaf(name), 1))) / denom
    return max(OBJ_IDF_FLOOR, min(1.0, f))


def owners_index(rows) -> dict:
    """Lowercased id -> sorted lowercased owners having it — the corpus map ref resolution needs."""
    idx: dict = {}
    for r in rows:
        idx.setdefault(r["id"].lower(), set()).add(r["owner"].lower())
    return {k: sorted(v) for k, v in idx.items()}


def ref_names_pair(ref: str, referrer_owner: str, owners_by_id: dict) -> str | None:
    """The concrete lowercased `owner/id` a cross-ref string names, resolved from the REFERRING
    ticket's perspective by the locator's order: a qualified ref names exactly that pair; a bare ref
    names the referrer's own ticket first, else the single owner that has the id; a bare id two
    other owners could claim names NOTHING — the same never-a-guess rule the graph renderer applies."""
    owner, tid = split_ref(ref)
    if owner is not None:
        return f"{owner}/{tid}"
    cands = owners_by_id.get(tid, [])
    if referrer_owner in cands:
        return f"{referrer_owner}/{tid}"
    if len(cands) == 1:
        return f"{cands[0]}/{tid}"
    return None


def score_candidate(q_tokens, q_tags, q_objects, seed_id, seed_refs, r, weights, allow_ref, df_map, n_docs,
                    seed_owner=None, owners_by_id=None):
    """One candidate's score + breakdown. `allow_ref=False` disables the cross-ref signal (used by --eval,
    where cross_refs are the ground-truth labels and must not leak into scoring)."""
    r_tags, r_objects = ci(r.get("tags")), ci(r.get("objects"))
    r_tokens = tokenize(f"{r['title']} {r['summary']}")  # tags score via tag_hits only, not also as keywords
    obj_hits = object_hits(q_objects, r_objects)
    tag_hits = sorted(q_tags & r_tags)
    kw_hits = q_tokens & r_tokens
    ref_link = False
    if allow_ref and seed_id and seed_owner is not None:
        omap = owners_by_id or {}
        seed_key = f"{seed_owner.lower()}/{seed_id.lower()}"
        r_key = f"{r['owner']}/{r['id']}".lower()
        so, ro = seed_owner.lower(), r["owner"].lower()
        ref_link = (any(ref_names_pair(x, so, omap) == r_key for x in seed_refs)
                    or any(ref_names_pair(x, ro, omap) == seed_key for x in ci(r.get("cross_refs"))))
    obj_score = sum(weights["obj"] * idf_factor(df_map, n_docs, o) for o in obj_hits)
    score = (obj_score + weights["tag"] * len(tag_hits)
             + weights["ref"] * (1 if ref_link else 0) + weights["kw"] * min(len(kw_hits), KEYWORD_CAP))
    return score, obj_hits, tag_hits, kw_hits, ref_link


def sort_key(item, key_re=None):
    # self-contained total order: score, then date, ticket number, id, owner — all desc.
    # key_re makes the number strict, so slug ids don't get a phantom numeric tie-break and
    # ranking stays consistent with INDEX.md.
    s, r, _why = item
    return (s, r["date"] or "0000-00-00", ticket_number(r["id"], key_re), r["id"], r["owner"])


def verdict_line(top) -> str:
    """Advisory one-liner so PLAN can decide whether to read candidates. Scale-free (composition + gap),
    never an auto-skip."""
    if not top:
        return "verdict: no prior art found — likely greenfield."
    s0, _r0, why0 = top[0]
    s1 = top[1][0] if len(top) > 1 else 0.0
    strong = any(w.startswith("obj:") or w == "ref" for w in why0)
    kw_only = bool(why0) and all(w.startswith("kw:") for w in why0)
    if strong:
        v = "strong — top hit shares an object or cross-ref"
    elif s1 and s0 >= 2 * s1:
        v = "clear leader — top score dominates the runner-up"
    elif kw_only:
        v = "weak — top hit is keyword-only; may be greenfield"
    else:
        v = "moderate"
    return f"verdict: {v}. (You may skip reading candidates when weak/none.)"


def run_query(args, rows, df_map, n_docs, key_re=None) -> int:
    q_tokens, q_tags, q_objects = tokenize(args.query), ci(args.tags.split(",")), ci([args.object] if args.object else [])
    seed_id, seed_owner, seed_refs = None, None, set()
    if args.seed and "/" in args.seed:  # --for owner/id, the qualified ticket locator
        so, si = split_ref(args.seed)
        if args.owner and args.owner.lower() != so.lower():
            sys.exit(f"recall: --for {args.seed} names owner '{so}' but --owner says '{args.owner}'; drop one.")
        args.seed, args.owner = si, so
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

    reverse_only = bool(args.object) and not (args.seed or args.query or args.tags)
    omap = owners_index(rows)

    scored = []
    for r in rows:
        if seed_id and r["id"] == seed_id and r["owner"] == seed_owner:
            continue  # exclude only the chosen seed row (same id under another owner is a real candidate)
        score, obj_hits, tag_hits, kw_hits, ref_link = score_candidate(
            q_tokens, q_tags, q_objects, seed_id, seed_refs, r, DEFAULT_WEIGHTS, allow_ref=True,
            df_map=df_map, n_docs=n_docs, seed_owner=seed_owner, owners_by_id=omap)
        if reverse_only:
            if not obj_hits:
                continue
            score = float(W_OBJECT * len(obj_hits))  # reverse lookup is flat count — IDF would be constant here
        elif score <= 0:
            continue
        why = []
        if obj_hits: why.append("obj:" + ",".join(f"{o}~{idf_factor(df_map, n_docs, o):.2f}" for o in obj_hits))
        if tag_hits: why.append("tag:" + ",".join(tag_hits))
        if ref_link: why.append("ref")
        if kw_hits and not reverse_only: why.append(f"kw:{min(len(kw_hits), KEYWORD_CAP)}")
        scored.append((score, r, why))

    scored.sort(key=lambda it: sort_key(it, key_re), reverse=True)
    if args.min_score:
        scored = [x for x in scored if x[0] >= args.min_score]
    top = scored[: args.top]

    if args.json:
        print(json.dumps([
            {"id": r["id"], "owner": r["owner"], "score": round(s, 2), "why": why, "title": r["title"],
             "summary": r["summary"], "date": r["date"], "tags": r.get("tags"), "objects": r.get("objects"),
             "readme": r["link"], "url": r["url"]}
            for s, r, why in top], ensure_ascii=False, indent=2))
        return 0

    # A shared id is displayed as its owner/id locator — a bare label naming two tickets is exactly
    # the ambiguity the locator exists to remove.
    id_owners: dict = {}
    for r in rows:
        id_owners[r["id"]] = id_owners.get(r["id"], 0) + 1
    def label(owner, tid):
        return f"{owner}/{tid}" if id_owners.get(tid, 0) > 1 else tid

    header = (f"Reverse lookup: tickets touching {args.object}" if reverse_only
              else "Prior art" + (f" for {label(seed_owner, seed_id)}" if seed_id else "")) + f" — top {len(top)} of {len(scored)}"
    print(header)
    if not top:
        print("  (no matches)")
        if not reverse_only:
            print(verdict_line(top))
        return 0
    for s, r, why in top:
        print(f"  {label(r['owner'], r['id']):<10} score {s:>5.1f} [{' '.join(why)}]  {r['date'] or '—'}  {r['title'][:60]}")
        print(f"             {r['link']}")
    if not reverse_only:
        print(verdict_line(top))
        print("\nRead these READMEs and write a reuse brief: what to copy (which SQL/QC artifact + path),"
              " known gotchas, and what's different this time.")
    return 0


def run_eval(rows, df_map, n_docs, weights, top_k=5, key_re=None) -> dict:
    """Hold out each ticket's curated cross_refs and measure whether recall predicts them. The cross-ref
    signal is DISABLED (allow_ref=False) so the labels can't leak into scoring. Labels resolve by
    the locator's order via ref_names_pair() — the same semantics scoring uses — so a bare ref means
    the seed's own ticket first, then a unique other owner, and an ambiguous one labels nothing."""
    pairs_present = {f"{r['owner']}/{r['id']}".lower() for r in rows}
    omap = owners_index(rows)
    rr_sum = p1 = p3 = rec_sum = labeled = 0
    for seed in rows:
        seed_key = f"{seed['owner']}/{seed['id']}".lower()
        relevant = set()
        for x in ci(seed.get("cross_refs")):
            k = ref_names_pair(x, seed["owner"].lower(), omap)
            if k and k != seed_key and k in pairs_present:
                relevant.add(k)
        if not relevant:
            continue
        labeled += 1
        q_tokens = tokenize(f"{seed['title']} {seed['summary']}")
        q_tags, q_objects = ci(seed.get("tags")), ci(seed.get("objects"))
        ranked = []
        for r in rows:
            if r["id"] == seed["id"] and r["owner"] == seed["owner"]:
                continue
            score, *_ = score_candidate(q_tokens, q_tags, q_objects, None, set(), r, weights,
                                        allow_ref=False, df_map=df_map, n_docs=n_docs)
            ranked.append((score, r, []))
        ranked.sort(key=lambda it: sort_key(it, key_re), reverse=True)
        ordered = [f"{r['owner']}/{r['id']}".lower() for _s, r, _w in ranked]
        first = next((i + 1 for i, k in enumerate(ordered) if k in relevant), None)
        if first:
            rr_sum += 1.0 / first
        top_keys = ordered[:top_k]
        if top_keys and top_keys[0] in relevant:
            p1 += 1
        if any(k in relevant for k in top_keys[:3]):
            p3 += 1
        rec_sum += len(set(top_keys) & relevant) / len(relevant)
    if not labeled:
        return {"labeled": 0}
    return {"labeled": labeled, "mrr": rr_sum / labeled, "p_at_1": p1 / labeled,
            "p_at_3": p3 / labeled, "recall_at_5": rec_sum / labeled}


def main() -> int:
    ap = argparse.ArgumentParser(description="Rank prior tickets relevant to a new one (prior-art recall)")
    ap.add_argument("--for", dest="seed", help="seed ticket id (use its title/summary/tags/objects as the query)")
    ap.add_argument("--owner", help="disambiguate the seed when an id exists under multiple owners")
    ap.add_argument("--query", default="", help="free-text query")
    ap.add_argument("--tags", default="", help="comma-separated tags to match")
    ap.add_argument("--object", dest="object", default="", help="object name (also enables reverse lookup)")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--min-score", dest="min_score", type=float, default=0.0,
                    help="hide candidates scoring below this (manual filter; not a default cutoff)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--eval", action="store_true",
                    help="diagnostic: measure recall quality against curated cross_refs (read-only, never tunes)")
    ap.add_argument("--sweep", action="store_true", help="with --eval: print MRR under several weight settings")
    args = ap.parse_args()

    root = repo_root()
    rows = build_rows(root)
    key_re = id_key_regex(load_config(root))
    df_map, n_docs = object_df(rows), len(rows)

    if args.eval:
        base = run_eval(rows, df_map, n_docs, DEFAULT_WEIGHTS, key_re=key_re)
        if not base.get("labeled"):
            print("recall --eval: no tickets have cross_refs resolving in-corpus — nothing to score.")
            return 0
        print(f"Recall quality vs curated cross_refs (cross-ref signal held out; {base['labeled']} labeled seeds):")
        print(f"  MRR={base['mrr']:.3f}  P@1={base['p_at_1']:.3f}  P@3={base['p_at_3']:.3f}  recall@5={base['recall_at_5']:.3f}")
        if args.sweep:
            print("Weight sensitivity (obj,tag,ref,kw) — diagnostic only, NOT auto-applied:")
            for w in ({"obj": 4, "tag": 3, "ref": 5, "kw": 1}, {"obj": 4, "tag": 1, "ref": 5, "kw": 1},
                      {"obj": 4, "tag": 5, "ref": 5, "kw": 1}, {"obj": 4, "tag": 3, "ref": 5, "kw": 2},
                      {"obj": 0, "tag": 3, "ref": 5, "kw": 1}, {"obj": 4, "tag": 0, "ref": 5, "kw": 0}):
                m = run_eval(rows, df_map, n_docs, w, key_re=key_re)
                print(f"  ({w['obj']},{w['tag']},{w['ref']},{w['kw']}) -> MRR {m['mrr']:.3f}")
        return 0

    return run_query(args, rows, df_map, n_docs, key_re)


if __name__ == "__main__":
    raise SystemExit(main())
