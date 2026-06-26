---
seam: warehouse
tool: postgres
transport: cli         # `psql`
requires: [conn]       # stack.yaml seams.warehouse.{conn, dev_schema}  (conn = libpq URL or service name)
auth: |
  libpq env (`PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`) or a connection URL in `{conn}`; `~/.pgpass`
  for non-interactive. Verify: `psql "{conn}" -c "SELECT 1"` (read-only).
---

# PostgreSQL adapter

Maps the `warehouse` verb contract to PostgreSQL via `psql`. Same three verbs as every warehouse —
only commands + `dialect_notes` differ, so the data skills run unchanged.

## verb: query
```bash
psql "{conn}" --csv -c "<SQL>"            # ad-hoc, CSV (header row 1)
psql "{conn}" --csv -f <file.sql>         # bundled multi-statement
```
- `--csv` emits clean CSV (no `psql` table borders). Add `-t` to drop the header if needed.
- Deterministic exports: explicit `ORDER BY` (row order is otherwise unspecified).

## verb: describe
```bash
psql "{conn}" -c "\d+ <schema.table>"                     # columns, types, indexes
psql "{conn}" -c "SELECT pg_get_viewdef('<schema.view>', true)"   # view DDL
```
Inventory: `\dt <schema>.*`; lineage via `information_schema` / `pg_depend`.

## verb: dialect_notes  (read by qc-review)
- **Functions:** `COALESCE`, `NULLIF(a,0)` (div-by-zero guard), `string_agg(x, ',')` (vs LISTAGG),
  `array_agg`, `date_trunc`. `= NULL` never matches — use `IS NULL`. Cast with `::type` or `CAST()`.
- **Sizing:** no "warehouse size" — performance is **indexes** + query plans. Use `EXPLAIN (ANALYZE,
  BUFFERS)`; ensure join/filter columns are indexed; beware sequential scans on big tables.
- **Joins:** type-match keys (`int` vs `text` won't use an index); `CAST` explicitly.
- **Anti-patterns:** `SELECT *` in shipped queries; functions on indexed columns in `WHERE` (kills
  index use); missing `ORDER BY` on exports.
- **Dev/deploy:** build dev objects in `{dev_schema}` (or set `search_path`); promote with scripted
  `CREATE OR REPLACE` / migrations.

## gotchas
- Non-SELECT (UPDATE/INSERT/DELETE/DDL) ⇒ policy `db_write_requires_approval`.
- Wrap multi-statement deploys in a transaction (`BEGIN; … COMMIT;`) so a failure rolls back.
