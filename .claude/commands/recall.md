---
description: Prior-art recall — find the closest prior tickets to a new one and write a reuse brief (PLAN phase)
argument-hint: <ticket-id> | "<topic>" | --object <NAME>   (empty = current branch's ticket)
allowed-tools: [Read, Bash, Glob, Grep, Agent]
---

# /recall

Mine the ticket archive for prior work you can **reuse** — so you don't rebuild what's already built.
A deterministic engine ranks candidates; you read the top few and write a reuse brief. Run this in
PLAN (it's the engine `/prime-ticket` uses for "related prior tickets").

## Resolve
- A **ticket id** (`$ARGUMENTS`, else the current branch via `!git branch --show-current`), a
  free-text **topic**, or `--object <NAME>` for a reverse lookup ("which tickets touched this object?").

## Steps
1. **Rank candidates** (deterministic, instant — reads `tickets/index_data.json` + ticket SQL):
   ```
   !python3 bin/recall.py --for <id>          # or: --query "<topic>"  |  --tags a,b  |  --object <NAME>
   ```
   Add `--json` for structured output. Scoring is transparent: object match ×4, tag ×3, cross-ref
   link +5, keyword overlap ×1; recency is a tiebreak. The seed ticket is excluded.
2. **Read the top 2–4** candidate READMEs (and their `final_deliverables/` + `qc_queries/` listings).
   If there are many, spawn read-only `Agent`/Explore passes in parallel — they return findings only,
   never write.
3. **Write a reuse brief** (≤ ~200 words): the closest prior work, **what to copy** (which SQL/QC
   artifact + path), known **gotchas** carried by those tickets, and **what's different** this time.

## Why
The index is only valuable if it's mined. This turns "we have a catalog" into "we never rebuild what
we've built" — and the rank→read-top-K shape is the retrieval path that scales past the point where
the whole index fits in a session's context, with **no vector store** (the kit's KISS stance).
