---
name: qc-review
description: Independent quality review of a ticket's deliverables via an explicit validation pyramid — dialect lint, counts/dedup, cross-source reconcile, independent re-run + anti-pattern sweep, human sign-off. The VALIDATE phase.
argument-hint: <ticket-id>
allowed-tools: [Read, Bash, Glob, Grep]
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

## Phase N — Verdict
Emit the structured report (Summary · pyramid results per layer · findings by severity ·
verification queries run · **APPROVE** or **REQUEST-CHANGES**). Save it into the ticket's
`qc_queries/` for the audit trail. APPROVE ⇒ recommend `/deliver-ticket <id>`.
