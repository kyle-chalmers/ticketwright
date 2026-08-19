---
name: review
description: Independent quality review of a ticket's deliverables — re-runs queries and walks a tiered validation pyramid to an APPROVE / REQUEST-CHANGES verdict. Run before shipping.
argument-hint: <ticket-id> [--deep] [--warehouse <name>]
allowed-tools: [Read, Bash, Glob, Grep, Agent]
---

# /review

The **check** step of the lifecycle. An *independent* second pass over a ticket's deliverables —
re-runs queries, walks a tiered validation pyramid, sweeps for anti-patterns, and returns an
APPROVE / REQUEST-CHANGES verdict. Reads `.claude/config/stack.yaml`; warehouse specifics come from
the resolved target's adapter `dialect_notes`, so the same review runs against any warehouse — or
several, when a ticket spans more than one.
Read-only: it reviews and re-runs, it does not edit code (the build owns fixes).

## Phase 0 — Setup
1. Read `stack.yaml`. Resolve every warehouse **target** this ticket touches and verify each one
   (halt with that target's adapter auth notes if unreachable) — resolution order in
   `adapters/README.md` § Multi-target seams. Load each target's `dialect_notes`: the lint layer is
   parameterized **per file**, by the target its header names.
2. Read the ticket README, the spec (if any), and list `final_deliverables/` + `qc_queries/`.

## The validation pyramid (bottom = cheap/automated, top = human)

Layers ①–④ apply to query/export deliverables. When the repo has no warehouse seam — or a ticket's
deliverables are documents, models, or code rather than queries — skip the layers with nothing to
run and review at layer ⑤ plus a **claims-vs-evidence walk**: every number, claim, and filename the
README asserts must trace to a file in the ticket, and every stated method must match what the
artifacts actually do. The verdict discipline below is unchanged.

**① Dialect lint** (static, per the `dialect_notes` of *that file's* target — in a multi-target repo
a `.sql` with no target header is a **Should-fix** finding, and is linted against whatever the
canonical order resolves next — the ticket's declared target before the seam default)
- `= NULL` → must be `IS NULL`; missing div-by-zero guard; `SELECT *` in deliverables; functions on
  filtered columns; implicit cross-source type mismatches (missing `CAST`); hardcoded values that
  should be parameters; missing required schema/instance filters; `LEFT JOIN` predicate in `WHERE`
  that silently becomes an inner join; `NOT IN` with nullable columns; `UNION` vs `UNION ALL`;
  session-variable/`DECLARE` parameterization in a shipped or exported query (prefer a CTE params
  row — portable, single-statement, export-clean; session vars pollute `--format csv` output and
  don't survive into single-statement JDBC/ODBC clients).

**② Counts & dedup** (re-run independently)
- Re-run the row-count; compare to the documented count. **Duplicate detection is the primary test:**
  `COUNT(*)` vs `COUNT(DISTINCT <grain key>)` — any gap is a halt until explained.
- NULL-rate on critical/key columns; value-range sanity (no negative amounts where impossible).

**③ Cross-source reconciliation**
- Join-match rates (unmatched `LEFT JOIN` rows quantified, not hidden). Date ranges within scope.
- Reconcile totals against the source of truth (e.g. SUM vs the input file/feed) within tolerance.

**④ Independent re-run + anti-pattern sweep**
- Re-execute each deliverable **against the target its header names** — re-running one target's SQL
  on another is not a reproduction. Diff results to the committed output (byte-level
  for CSVs — `deterministic_outputs` requires explicit `ORDER BY`).
- Sweep the full anti-pattern set (correctness, performance, data-quality, dialect-specific,
  maintainability). Classify each finding Critical / Should-fix / Review.

**⑤ Human sign-off** — *the one layer a model cannot complete on its own*
- Output format check (CSV headers row 1, no preamble/blank rows; filenames carry record counts;
  **ASCII punctuation only in cell values** — no em/en dashes, smart quotes, or ellipsis chars, which
  render as mojibake in Excel/CSV viewers).
- README completeness (assumptions enumerated, QC results, business context).
- **Hand the deliverables to the human, then stop** (policy `human_review_handoff`; skip this whole
  bullet when it is `off`). Layers ①–④ prove the query is *internally* consistent; only a person can
  say the numbers are the right numbers. Do not emit a verdict before this:
  1. `bash "${CLAUDE_PLUGIN_ROOT:-.}/bin/tw" handoff.sh <final_deliverables + qc_queries paths>`
     — routes each file to the app that user chose. It exits 0 and stays silent when they have no
     viewer config; in that case say so **once** and continue, never block.
  2. If it produced no output and no config exists, offer the one-time setup: which app for `.sql`,
     which for `.csv`, this repo only or all their repos. Their answers are written to
     `.claude/config/viewer.local.yaml` (gitignored, per-user) or the user-level path — see
     `.claude/config/viewer.example.yaml`. "None / don't ask again" writes `enabled: false`.
  3. Print a short **what to look at** list — row counts, the grain key, and anything ②/③ flagged —
     so they know where to aim, not just that files opened.
  4. **Wait for explicit sign-off.** Under `all`, note what they already approved earlier in the
     build and focus this pass on what changed since; never skip the gate silently just because an
     earlier one fired.

## Tiers & halting
- **Hard-halt** findings (Critical, count mismatch, dup gap, reconciliation break) → verdict
  REQUEST-CHANGES with structured remediation.
- **Warn** findings (perf, style) → list but don't block.
- **Info** (distributions) → record.

## Deep mode (`--deep`) — adversarial panel
For high-blast-radius work (compliance/regulatory pulls, irreversible writes), replace the single
pass with a panel, using the host agent's own subagents (the `Agent` tool):
1. **Fan out** one independent `qc-reviewer` subagent per pyramid layer (① dialect-lint ·
   ② counts&dedup · ③ cross-source reconcile · ④ re-run + anti-pattern sweep) — each scoped to its
   layer, re-running its own queries, returning findings only. Run them in parallel.
2. **Adversarially verify** every reported finding before it counts: a second pass re-reads the
   cited `file:line` / re-runs the query and rules each finding confirmed / false-positive /
   **uncertain**. A finding it cannot reproduce is **uncertain, not dismissed** — silently dropping
   a Critical / count / reconcile finding is the expensive failure. Only a clear, demonstrated
   non-issue is ruled false-positive.
3. **Synthesize** confirmed findings (deduped across layers) into one verdict — and **carry
   uncertain findings into the verdict too**: any uncertain Critical / count / reconcile finding
   forces REQUEST-CHANGES (or explicit human sign-off), never a silent APPROVE.

Default (no flag) is the single `qc-reviewer` pass. `/ticket` recommends `--deep` automatically for
high-risk tickets (external/compliance deliverables, irreversible writes) — reach for it whenever
the cost of a missed defect is high.

## Phase N — Verdict
Emit the structured report (Summary · pyramid results per layer · findings by severity ·
verification queries run · **APPROVE** or **REQUEST-CHANGES**). Save it into the ticket's
`qc_queries/` for the audit trail. APPROVE ⇒ recommend `/ship <id>`.
