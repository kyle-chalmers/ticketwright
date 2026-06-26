---
seam: warehouse
tool: databricks
transport: both        # `databricks` CLI (profiles, e.g. biprod/bidev) + a Databricks SQL MCP
requires: [profile, catalog, schema]   # stack.yaml seams.warehouse.{profile, catalog, schema, dev_catalog}
auth: |
  databricks CLI profile configured (~/.databrickscfg) or a SQL MCP connected.
  Verify: `databricks --profile {profile} current-user me`.
---

# Databricks adapter

Maps the `warehouse` verb contract to Databricks (Unity Catalog, Spark SQL). Same verbs as Snowflake;
only commands + `dialect_notes` differ, so `qc-review` / `spec-and-build` / `build-context-pack` run
unchanged.

## verb: query
```bash
databricks --profile {profile} sql query --query "<SQL>"          # ad-hoc
databricks --profile {profile} sql query --file <path/to/file.sql> # bundled
```
- Deterministic exports: explicit `ORDER BY` (Spark result order is not guaranteed).
- Reference objects three-part: `{catalog}.{schema}.<object>`.

## verb: describe
```bash
databricks --profile {profile} sql query --query "DESCRIBE TABLE EXTENDED {catalog}.{schema}.<obj>"
databricks --profile {profile} sql query --query "SHOW CREATE TABLE {catalog}.{schema}.<obj>"   # DDL
```
Inventory: `SHOW TABLES IN {catalog}.{schema}`. Lineage: Unity Catalog `system.access.table_lineage`
/ `information_schema` (not a naive `SHOW TABLES`, which misses views' upstreams).

## verb: dialect_notes  (read by qc-review)
- **Functions:** `coalesce`/`nvl`, `try_divide(a,b)` (div-by-zero → NULL), `try_cast`, `collect_list`
  / `array_agg` (vs LISTAGG), `date_trunc`. `= NULL` never matches — use `IS NULL`.
- **Sizing:** SQL warehouse / cluster size + **partitioning / Z-ORDER / liquid clustering**; pruning
  the partition (or clustered) column is the main scan lever. `SELECT *` on wide Delta tables is the
  costly anti-pattern — list columns.
- **Joins:** type-match keys with `cast`/`try_cast`; mind `STRING` vs `BIGINT`. Broadcast small dims.
- **Dev/deploy:** dev objects in `{dev_catalog}`; promote with scripted `CREATE OR REPLACE`.

## gotchas
- Non-SELECT / DDL ⇒ policy `db_write_requires_approval` (show SQL, explain, wait).
- **Pause before any prod job deploy** — saved rule: stop for human confirmation before writing
  `databricks/job_definitions/prod/*.json` or PR-ing to the jobs repo.
- Profiles: `biprod` (prod), `bidev` (dev) — pick deliberately.
