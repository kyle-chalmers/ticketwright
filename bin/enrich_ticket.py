#!/usr/bin/env python3
"""Refresh the curated index summary for one or more tickets — run at ticket close.

The deterministic renderer + PostToolUse hook keep `tickets/INDEX.md` *complete* (a new
ticket appears immediately as a `▱` row). This script does the LLM half: it reads a
ticket's README, has a model write the one-line summary / status / date / tags / cross-refs,
upserts that into `tickets/index_data.json`, and re-renders — turning `▱` into a curated row.

It runs the model headlessly via `claude -p` (default model: sonnet, plenty for a one-liner),
so it works whether invoked by an agent at close or by a human at the terminal. id/owner are
always taken from disk, never from the model. This is a Claude-Code-specific convenience (like
the kit's hooks); the agent-agnostic path is the build-ticket-index skill, where the host agent
writes the record itself and pipes it to `ingest_index_records.py --from-json -`.

Usage:
  enrich_ticket.py ENG-123 [ENG-124 ...]   # enrich specific ticket(s)
  enrich_ticket.py --branch                # enrich the ticket named in the current git branch
  enrich_ticket.py ENG-123 --model opus    # override the model

Then commit tickets/INDEX.md + tickets/OBJECTS.md + tickets/index_data.json with the ticket.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

from build_ticket_index import discover, repo_root, load_config, key_regex

PROMPT = """You are writing one catalog record for a single ticket in this repo. The ticket's \
README is below.

Output ONLY a single minified JSON object (no prose, no code fence) with these keys:
- "status": one of "Completed","Deployed","In Review","In Progress","Blocked","Unknown" \
(Deployed if it shipped a data object/view/table/job; Completed if a deliverable was handed off; \
In Review if awaiting PR/stakeholder; In Progress if planned not delivered; Blocked if blocked).
- "date": best delivered/completed date as "YYYY-MM-DD", or null. Prefer an explicit \
Completed/Deployed/Filed date, else the most recent Update/Follow-up date. Never invent one.
- "summary": ONE line, <=180 chars, leading with what was delivered + key number(s)/outcome. \
Concrete, no "This ticket...".
- "tags": 1-4 short kebab-case topic tags describing the work (reuse common ones across tickets).
- "cross_refs": array of other ticket IDs referenced in the body (dedup, exclude this ticket).
- "objects": array of fully-qualified data objects the ticket read or wrote (e.g. "SCHEMA.VIEW", \
"db.schema.table"); [] if none / not a data ticket.
- "title": the H1 text with any leading "<KEY>-NNN:" stripped.

README for {tid}:
---
{readme}
---
Output the JSON object now."""


def extract_json(text: str) -> dict:
    i, j = text.find("{"), text.rfind("}")
    if i == -1 or j == -1 or j < i:
        raise ValueError("no JSON object found in model output")
    return json.loads(text[i:j + 1])


def enrich_one(loc: dict, model: str) -> dict | None:
    tid, owner, readme = loc["id"], loc["owner"], loc["readme"]
    if not readme:
        print(f"  {owner}/{tid}: no README — skipped (stays deterministic/▱).", file=sys.stderr)
        return None
    body = readme.read_text(errors="replace")[:24000]
    prompt = PROMPT.format(tid=tid, readme=body)
    try:
        out = subprocess.run(
            ["claude", "-p", "--model", model, prompt],
            capture_output=True, text=True, timeout=240,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"  {owner}/{tid}: claude CLI failed ({e}).", file=sys.stderr)
        return None
    if out.returncode != 0:
        print(f"  {owner}/{tid}: claude exited {out.returncode}: {out.stderr.strip()[:200]}", file=sys.stderr)
        return None
    try:
        rec = extract_json(out.stdout)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"  {owner}/{tid}: could not parse model output ({e}).", file=sys.stderr)
        return None
    # id/owner are authoritative from disk — never trust the model for these.
    rec["id"], rec["owner"] = tid, owner
    print(f"  {owner}/{tid}: {rec.get('status','?')} · {rec.get('date') or '—'} · {rec.get('summary','')[:80]}")
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh curated index summaries for ticket(s)")
    ap.add_argument("ids", nargs="*", help="ticket ids, e.g. ENG-123")
    ap.add_argument("--branch", action="store_true", help="use the ticket id in the current git branch")
    ap.add_argument("--model", default="sonnet", help="model for the summary (default: sonnet)")
    args = ap.parse_args()

    root = repo_root()
    locs_by_owner_id = {(t["owner"], t["id"]): t for t in discover(root)}

    ids = list(args.ids)
    if args.branch:
        try:
            br = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                                capture_output=True, text=True, cwd=root).stdout
            m = key_regex(load_config(root)["prefixes"]).search(br)
            if m:
                ids.append(m.group(0))
        except OSError:
            pass
    if not ids:
        sys.exit("No ticket ids given. Pass ids (e.g. ENG-123) or --branch.")

    targets = []
    for tid in ids:
        matches = [loc for (_, i), loc in locs_by_owner_id.items() if i == tid]
        if not matches:
            print(f"  {tid}: no ticket folder found — skipped.", file=sys.stderr)
            continue
        targets.extend(matches)  # if an id exists under 2 owners, enrich both

    print(f"Enriching {len(targets)} ticket(s) via claude -p --model {args.model}...", file=sys.stderr)
    records = [r for r in (enrich_one(loc, args.model) for loc in targets) if r]
    if not records:
        print("Nothing enriched.", file=sys.stderr)
        return 1

    ingest = root / "bin" / "ingest_index_records.py"
    render = root / "bin" / "build_ticket_index.py"
    subprocess.run([sys.executable, str(ingest), "--from-json", "-"],
                   input=json.dumps({"records": records}), text=True, check=True)
    subprocess.run([sys.executable, str(render)], check=True)
    print("Done. Commit tickets/INDEX.md + tickets/OBJECTS.md + tickets/index_data.json with the ticket.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
