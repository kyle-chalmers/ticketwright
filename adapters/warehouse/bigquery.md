---
seam: warehouse
tool: bigquery
transport: cli         # `bq` CLI (gcloud SDK)
requires: [project, dataset]   # stack.yaml seams.warehouse.{project, dataset, dev_dataset}
auth: |
  gcloud auth (ADC) + `bq` in PATH.
  Verify: `bq query --use_legacy_sql=false --dry_run "SELECT 1"` (read-only, no cost).
---

# BigQuery adapter (reference for the abstraction proof)

Maps the `warehouse` verb contract to Google BigQuery via `bq`. Same verbs as Snowflake — only the
commands and `dialect_notes` differ, so `qc-review`/`spec-and-build`/`build-context-pack` run
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

## verb: dialect_notes  (read by qc-review)
- **Functions:** `IFNULL`/`COALESCE`, `SAFE_DIVIDE(a,b)` (div-by-zero), `SAFE_CAST`,
  `STRING_AGG` (vs LISTAGG), `ARRAY_AGG`. Standard SQL (`--use_legacy_sql=false`) always.
- **Sizing:** on-demand (bytes scanned) or slots — partition + cluster columns to prune scans;
  filtering a partition column is the main "warehouse size" lever.
- **Joins:** type-match with `CAST`/`SAFE_CAST`; mind `STRING` vs `INT64` keys.
- **Partition pruning** is the analog of clustered-column filtering; `SELECT *` on wide tables is
  the expensive anti-pattern (scans all columns) — list columns.
- **Dev/deploy:** dev objects in `{dev_dataset}`; promote via scripted `CREATE OR REPLACE`.

## gotchas
- Non-SELECT/DDL ⇒ policy `db_write_requires_approval`.
- Watch query cost — surface estimated bytes before running anything large.
