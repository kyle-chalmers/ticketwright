---
seam: warehouse
tool: bigquery
transport: cli         # `bq` CLI (gcloud SDK)
requires: [project, dataset]   # stack.yaml seams.warehouse.{project, dataset, dev_target}
dev_key: dev_dataset    # legacy spelling of dev_target, still honored
auth: |
  gcloud auth (ADC) + `bq` in PATH.
  Verify: `bq query --use_legacy_sql=false --dry_run "SELECT 1"` (read-only, no cost).
---

# BigQuery adapter (reference for the abstraction proof)

Maps the `warehouse` verb contract to Google BigQuery via `bq`. Same verbs as Snowflake — only the
commands and `dialect_notes` differ, so `review`/`spec-and-build`/`refresh context` run
unchanged.

## verb: query
```bash
bq query --use_legacy_sql=false --format=csv "<SQL>"
bq query --use_legacy_sql=false --format=csv < file.sql
```
- Deterministic exports: explicit `ORDER BY` (BQ result order is not guaranteed).
- Cost guard: `--dry_run` to estimate bytes; `--maximum_bytes_billed` to cap.

## verb: describe
```bash
bq show --schema --format=prettyjson {project}:{dataset}.<table>
bq show --format=prettyjson {project}:{dataset}.<view>     # has the view DDL ("query" field)
```
Object inventory: `bq ls {dataset}`; lineage via `INFORMATION_SCHEMA.*` views.

## verb: dialect_notes  (read by the review skill)
- **Functions:** `IFNULL`/`COALESCE`, `SAFE_DIVIDE(a,b)` (div-by-zero), `SAFE_CAST`,
  `STRING_AGG` (vs LISTAGG), `ARRAY_AGG`. Standard SQL (`--use_legacy_sql=false`) always.
- **Sizing:** on-demand (bytes scanned) or slots — partition + cluster columns to prune scans;
  filtering a partition column is the main "warehouse size" lever.
- **Joins:** type-match with `CAST`/`SAFE_CAST`; mind `STRING` vs `INT64` keys.
- **Partition pruning** is the analog of clustered-column filtering; `SELECT *` on wide tables is
  the expensive anti-pattern (scans all columns) — list columns.
- **Dev/deploy:** dev objects in `{dev_target}`; promote via scripted `CREATE OR REPLACE`.
- **Portable params — prefer CTE params over session `DECLARE`.** Don't parameterize with scripting
  (`DECLARE d DATE DEFAULT '…'; … WHERE dt <= d`): a `bq --format=csv` run echoes each statement's
  status into the CSV (polluting the export), and a `DECLARE`d variable is out of scope for the next
  statement in single-statement JDBC/ODBC clients (DataGrip, Simba). Use a self-contained CTE params
  row instead — one statement, export-clean, portable:
  `WITH params AS (SELECT DATE '2026-06-30' AS anchor) SELECT … FROM t CROSS JOIN params WHERE dt <= params.anchor`.

## gotchas
- Non-SELECT/DDL ⇒ policy `db_write_requires_approval`.
- Watch query cost — surface estimated bytes before running anything large.
