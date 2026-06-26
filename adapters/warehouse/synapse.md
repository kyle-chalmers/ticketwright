---
seam: warehouse
tool: synapse
transport: cli         # `sqlcmd` (go-sqlcmd) — also covers Azure SQL / SQL Server / Fabric Warehouse
requires: [server, database]   # stack.yaml seams.warehouse.{server, database, dev_schema}
auth: |
  `sqlcmd` (go-sqlcmd) with Azure AD: `-G --authentication-method ActiveDirectoryDefault` after
  `az login` (or a service principal / `ActiveDirectoryInteractive`). Verify:
  `sqlcmd -S {server} -d {database} -G --authentication-method ActiveDirectoryDefault -Q "SELECT 1"`.
---

# Azure Synapse / Azure SQL adapter (T-SQL)

Maps the `warehouse` verb contract to T-SQL backends — Synapse (dedicated SQL pool / serverless),
Azure SQL Database, SQL Server, or Fabric Warehouse — via `sqlcmd`. Only commands + `dialect_notes`
differ from the other warehouses, so the data skills run unchanged.

## verb: query
```bash
sqlcmd -S {server} -d {database} -G --authentication-method ActiveDirectoryDefault \
       -s"," -W -Q "<T-SQL>"            # comma-separated + trimmed; add `-h -1` to drop the header row
sqlcmd -S {server} -d {database} -G --authentication-method ActiveDirectoryDefault \
       -s"," -W -i <file.sql>
```
- CSV via `-s"," -W` (column separator + trim trailing spaces); `-h -1` suppresses the header.
  go-sqlcmd's `--format` only supports `horizontal`/`vertical`/`json` — there is **no** `csv` value
  (pipe `--format json` through a JSON→CSV step if you prefer). Deterministic exports: explicit
  `ORDER BY` (T-SQL only guarantees order with an outer `ORDER BY`).

## verb: describe
```bash
# columns:  sqlcmd ... -Q "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='<t>'"
# view DDL: sqlcmd ... -Q "SELECT definition FROM sys.sql_modules WHERE object_id=OBJECT_ID('<schema.view>')"  -- portable; sp_helptext is SQL-Server/Azure-SQL only (not Synapse pools)
```
Inventory via `information_schema.tables` / `sys.objects`.

## verb: dialect_notes  (read by qc-review)
- **Functions:** `ISNULL`/`COALESCE`, `NULLIF`, `TRY_CAST`/`TRY_CONVERT`, `STRING_AGG(x, ',')`
  (2017+/Synapse), `TOP n` (not `LIMIT`), `GETDATE()`/`SYSDATETIME()`. `[bracketed]` identifiers.
- **Sizing/perf (Synapse dedicated):** table **distribution** (`HASH` on the join key / `ROUND_ROBIN`
  / `REPLICATE` for small dims) is the main lever; avoid data movement by aligning distributions.
  Resource classes govern memory. Serverless: cost = bytes scanned (partition/prune).
- **Joins:** type-match keys (`TRY_CAST`); matching HASH distribution avoids shuffles.
- **Anti-patterns:** `SELECT *` (columnstore scans all columns); row-by-row cursors; missing `ORDER BY`.
- **Dev/deploy:** dev objects in `{dev_schema}`; promote views with `CREATE OR ALTER VIEW`. For
  tables: `CTAS` (`CREATE TABLE … AS SELECT`) on Synapse dedicated / Fabric; on Azure SQL DB /
  SQL Server use `SELECT … INTO` instead (they don't support CTAS).

## gotchas
- Non-SELECT/DDL ⇒ policy `db_write_requires_approval`.
- Synapse dedicated pools don't support every T-SQL construct (e.g. some `MERGE`/constraint features)
  — check the pool type before assuming.
