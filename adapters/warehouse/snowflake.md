---
seam: warehouse
tool: snowflake
transport: both        # `snow` CLI for scripts/exports; Snowflake MCP for interactive/semantic
requires: [cli]        # stack.yaml seams.warehouse.{cli, default_warehouse, pii_role, dev_db}
auth: |
  CLI:  ~/.snowflake/config.toml connection (USERNAME_PASSWORD_MFA for CLI/MCP).
  Verify: `snow connection test` (read-only).
  Duo lockout signature: instant 250001/370001 = locked (wait 15 min); hang = push pending.
---

# Snowflake adapter

Maps the `warehouse` verb contract to Snowflake via the `snow` CLI (preferred for repeatable scripts
and CSV export) and the Snowflake MCP (preferred for interactive exploration + the semantic layer).

## verb: query
```bash
snow sql -q "<SQL>" --format csv          # ad-hoc
snow sql -f <path/to/file.sql>            # bundled multi-statement (minimizes MFA prompts)
```
- **Bundle** multi-step work into one `.sql` run via `-f` (one MFA prompt, not many).
- CSV: always `--format csv`; **strip** the `status` / `Statement executed successfully.` preamble
  the multi-statement `-f` run prints ahead of the result. Robust, documented norm:
  `bin/split_and_export.sh --strip-only <csv>` (drops through the *last* "Statement executed
  successfully." then leading blanks) — and its split mode turns one multi-`SELECT` file into N CSVs.
- Set warehouse/role inside the SQL: `USE WAREHOUSE {default_warehouse}; USE ROLE {pii_role};`.
- **Deterministic exports:** always end exports with explicit `ORDER BY` (Snowflake doesn't preserve
  insertion order on `SELECT *`) — required for byte-identical golden replays.

## verb: describe
```bash
snow sql -q "DESCRIBE TABLE <schema.object>" --format csv
snow sql -q "SELECT GET_DDL('VIEW','<schema.object>')" --format csv
# semantic view: snow sql -q "DESCRIBE SEMANTIC VIEW <name>"
```
Discover objects via `INFORMATION_SCHEMA.TABLES` + `ACCOUNT_USAGE.OBJECT_DEPENDENCIES` (NOT
`SHOW VIEWS` — it misses dynamic tables / base tables).

## verb: dialect_notes  (read by qc-review's anti-pattern sweep)
- **Functions:** `IFF`, `NVL/COALESCE`, `NULLIF` (div-by-zero guard), `LISTAGG` (many-to-many),
  `DATE_TRUNC`. `=NULL` never matches — use `IS NULL`.
- **Sizing:** use a named virtual warehouse for heavy QC (e.g. `{default_warehouse}`), not slots.
- **Joins:** `CAST()` keys when joining across sources (NUMBER vs VARCHAR mismatches); apply any
  required tenant/schema filter your shared views expect; where a view unions migrated + native
  data, filter to the rows you actually want (e.g. a `IS_MIGRATED` / source flag).
- **Layering:** prefer your curated layers (e.g. `RAW → STAGING → ANALYTICS → REPORTING`); avoid
  legacy/raw schemas and point-in-time snapshot tables unless the work is compliance/historical.
- **Dynamic-table chains:** never interpose a regular view between dynamic tables (`target_lag='DOWNSTREAM'`).
- **Dev/deploy:** build dev objects in `{dev_db}`; promote with your multi-env deploy template (COPY GRANTS).

## gotchas
- Non-SELECT (UPDATE/CREATE/DELETE/DDL) ⇒ policy `db_write_requires_approval`: show the SQL, explain,
  wait for explicit `yes` before running.
