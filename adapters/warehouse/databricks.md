---
seam: warehouse
tool: databricks
transport: both        # `dbsqlcli` / Statement Execution API for SQL; a Databricks SQL MCP for interactive
requires: [warehouse_id, catalog, schema]   # stack.yaml seams.warehouse.{warehouse_id, catalog, schema, dev_catalog, profile}
auth: |
  A Databricks SQL warehouse + a token. Either: `dbsqlcli` (pip install databricks-sql-cli) configured
  via `~/.dbsqlclirc` or env (`DBSQLCLI_HOST_NAME`, `DBSQLCLI_HTTP_PATH`, `DBSQLCLI_ACCESS_TOKEN`); or
  the `databricks` CLI profile (~/.databrickscfg) for the Statement Execution API; or a SQL MCP.
  Verify: `databricks --profile {profile} current-user me` (read-only).
note: |
  The `databricks` CLI has NO ad-hoc "run this SQL" command (`databricks sql` is API CRUD, not a query
  runner). Execute SQL via `dbsqlcli`, the Statement Execution API, or the SQL MCP — all below.
---

# Databricks adapter

Maps the `warehouse` verb contract to Databricks (Unity Catalog, Spark SQL). Same verbs as Snowflake;
only commands + `dialect_notes` differ, so `qc-review` / `spec-and-build` / `build-context-pack` run
unchanged.

## verb: query
```bash
# Preferred: databricks-sql-cli (returns rows; --csv-friendly via -e + redirection)
dbsqlcli -e "<SQL>"                                   # ad-hoc
dbsqlcli -e "$(cat path/to/file.sql)"                 # bundled
# Or the Statement Execution API (no extra tool; good for CI):
databricks --profile {profile} api post /api/2.0/sql/statements \
  --json '{"warehouse_id":"{warehouse_id}","statement":"<SQL>","wait_timeout":"30s"}'
# Or route through the Databricks SQL MCP for interactive exploration.
```
- Deterministic exports: explicit `ORDER BY` (Spark result order is not guaranteed).
- Reference objects three-part: `{catalog}.{schema}.<object>`.
- The Statement API is async beyond `wait_timeout`: poll `GET /api/2.0/sql/statements/<id>` until
  `status.state=SUCCEEDED`, then read `result`.

## verb: describe
```bash
dbsqlcli -e "DESCRIBE TABLE EXTENDED {catalog}.{schema}.<obj>"
dbsqlcli -e "SHOW CREATE TABLE {catalog}.{schema}.<obj>"     # DDL
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
- **Pause before any prod job deploy** — stop for human confirmation before writing prod job
  definitions or PR-ing to a jobs repo.
- The `databricks` CLI is for workspace/API management; SQL runs through `dbsqlcli` / the SQL API / MCP.
