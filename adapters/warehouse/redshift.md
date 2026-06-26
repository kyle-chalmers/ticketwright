---
seam: warehouse
tool: redshift
transport: cli         # `aws redshift-data` (Data API) or `psql` (Redshift speaks the pg wire protocol)
requires: [database]   # stack.yaml seams.warehouse.{database, workgroup_name | cluster_identifier, dev_schema}
auth: |
  Data API: AWS creds (`aws sts get-caller-identity`) + Secrets Manager/IAM for the DB. **Serverless**
  passes `--workgroup-name {workgroup_name}`; **provisioned** passes `--cluster-identifier
  {cluster_identifier}` (+ `--db-user`). Or `psql` with the endpoint creds. Verify (serverless):
  `aws redshift-data list-databases --database {database} --workgroup-name {workgroup_name}` — or `psql … -c "SELECT 1"`.
---

# Amazon Redshift adapter

Maps the `warehouse` verb contract to Redshift. Two transports: the **Data API** (no driver, good for
CI/Serverless) and **`psql`** (Redshift is Postgres-wire-compatible). Pick one per `{conn}`.

## verb: query
```bash
# Data API (async: execute → wait → fetch). Serverless:
id=$(aws redshift-data execute-statement --database {database} \
      --workgroup-name {workgroup_name} --sql "<SQL>" --query Id --output text)
# Provisioned cluster instead: --cluster-identifier {cluster_identifier} --db-user <user>
aws redshift-data describe-statement --id "$id" --query Status   # poll until FINISHED
aws redshift-data get-statement-result --id "$id"                 # JSON rows
# or direct: psql "host=<endpoint> dbname={database} ..." --csv -c "<SQL>"
```
- Deterministic exports: explicit `ORDER BY`.

## verb: describe
```bash
# columns:  SELECT * FROM svv_columns WHERE table_name='<t>' AND table_schema='<s>';
# DDL:      SELECT pg_get_viewdef('<schema.view>', true);  -- or pg_table_def for tables
```
Inventory via `svv_tables` / `svv_columns`.

## verb: dialect_notes  (read by qc-review)
- **Functions:** `NVL`/`COALESCE`, `NULLIF`, `LISTAGG(x, ',') WITHIN GROUP (ORDER BY …)`,
  `DATE_TRUNC`. Postgres-derived SQL, but a reduced function set vs Postgres.
- **Sizing/perf:** the real levers are **DISTKEY** (join co-location) and **SORTKEY** (range-scan
  pruning) + column compression (ENCODE). Columnar store ⇒ `SELECT *` scans every column — list them.
  Run `VACUUM`/`ANALYZE` after big loads; check `EXPLAIN`.
- **Joins:** matching DISTKEY avoids data redistribution (the main cost); type-match keys.
- **Dev/deploy:** dev objects in `{dev_schema}`; promote with scripted `CREATE TABLE AS` / `CREATE OR
  REPLACE VIEW`.

## gotchas
- Data API is **async** — always poll `describe-statement` to `FINISHED` before `get-statement-result`.
- Non-SELECT/DDL ⇒ policy `db_write_requires_approval`.
