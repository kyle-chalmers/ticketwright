---
name: qc-review
description: Independent quality review of a ticket's deliverables via an explicit validation pyramid — dialect lint, counts/dedup, cross-source reconcile, independent re-run + anti-pattern sweep, human sign-off. The VALIDATE phase.
argument-hint: <ticket-id> [--deep]
allowed-tools: [Read, Bash, Glob, Grep, Agent]
---

# /qc-review

The **VALIDATE** phase. An *independent* second pass over a ticket's deliverables — re-runs queries,
walks a tiered validation pyramid, sweeps for anti-patterns, and returns an APPROVE / REQUEST-CHANGES
verdict. Reads `.claude/config/stack.yaml`; warehouse specifics come from the adapter's
`dialect_notes`, so the same review runs on Snowflake, BigQuery, or Databricks.

Generalizes a thorough independent data-quality review (50+ checks). Read-only: it reviews and
re-runs, it does not edit code (the build owns fixes).

## Phase 0 — Setup
1. Read `stack.yaml`; verify the warehouse seam (halt with auth notes if unreachable). Load
   `seams.warehouse.dialect_notes` from the adapter — it parameterizes the lint layer.
2. Read the ticket README, the spec (if any), and list `final_deliverables/` + `qc_queries/`.

## The validation pyramid (bottom = cheap/automated, top = human)

**① Dialect lint** (static, per `dialect_notes`)
- `= NULL` → must be `IS NULL`; missing div-by-zero guard; `SELECT *` in deliverables; functions on
  filtered columns; implicit cross-source type mismatches (missing `CAST`); hardcoded values that
  should be parameters; missing required schema/instance filters; `LEFT JOIN` predicate in `WHERE`
  that silently becomes an inner join; `NOT IN` with nullable columns; `UNION` vs `UNION ALL`.

**② Counts & dedup** (re-run independently)
- Re-run the row-count; compare to the documented count. **Duplicate detection is the primary test:**
  `COUNT(*)` vs `COUNT(DISTINCT <grain key>)` — any gap is a halt until explained.
- NULL-rate on critical/key columns; value-range sanity (no negative amounts where impossible).

**③ Cross-source reconciliation**
- Join-match rates (unmatched `LEFT JOIN` rows quantified, not hidden). Date ranges within scope.
- Reconcile totals against the source of truth (e.g. SUM vs the input file/feed) within tolerance.

**④ Independent re-run + anti-pattern sweep**
- Re-execute the main deliverable query end-to-end; diff results to the committed output (byte-level
  for CSVs — `deterministic_outputs` requires explicit `ORDER BY`).
- Sweep the full anti-pattern set (correctness, performance, data-quality, dialect-specific,
  maintainability). Classify each finding Critical / Should-fix / Review.

**⑤ Human sign-off**
- Output format check (CSV headers row 1, no preamble/blank rows; filenames carry record counts).
- README completeness (assumptions enumerated, QC results, business context). Flag for the human.

## Tiers & halting
- **Hard-halt** findings (Critical, count mismatch, dup gap, reconciliation break) → verdict
  REQUEST-CHANGES with structured remediation.
- **Warn** findings (perf, style) → list but don't block.
- **Info** (distributions) → record.

## Deep mode (`--deep`) — adversarial panel
For high-blast-radius work (compliance/regulatory pulls, irreversible writes), replace the single pass
with a panel, using the host agent's own subagents (the `Agent` tool):
1. **Fan out** one independent `qc-reviewer` subagent per pyramid layer (① dialect-lint · ② counts&dedup ·
   ③ cross-source reconcile · ④ re-run + anti-pattern sweep) — each scoped to its layer, re-running its
   own queries, returning findings only. Run them in parallel.
2. **Adversarially verify** every reported finding before it counts: a second pass re-reads the cited
   `file:line` / re-runs the query and rules each finding confirmed / false-positive / **uncertain**.
   A finding it cannot reproduce is **uncertain, not dismissed** — for a QC harness, silently dropping
   a Critical / count / reconcile finding is the expensive failure. Only a clear, demonstrated
   non-issue is ruled false-positive.
3. **Synthesize** confirmed findings (deduped across layers) into one verdict — and **carry uncertain
   findings into the verdict too**: any uncertain Critical / count / reconcile finding forces
   REQUEST-CHANGES (or explicit human sign-off), never a silent APPROVE.

This is the same dimensions → find → adversarially-verify pattern used to harden the kit itself; it
catches plausible-but-wrong findings a single reviewer would wave through. Default (no flag) is the
single `qc-reviewer` pass — reach for `--deep` only when the cost of a missed defect is high.

## Phase N — Verdict
Emit the structured report (Summary · pyramid results per layer · findings by severity ·
verification queries run · **APPROVE** or **REQUEST-CHANGES**). Save it into the ticket's
`qc_queries/` for the audit trail. APPROVE ⇒ recommend `/deliver-ticket <id>`.
