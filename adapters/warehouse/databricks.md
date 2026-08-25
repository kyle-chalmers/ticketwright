---
seam: warehouse
tool: databricks
transport: both        # `dbsqlcli` / Statement Execution API for SQL; a Databricks SQL MCP for interactive
requires: [warehouse_id, catalog, schema]   # stack.yaml seams.warehouse.{warehouse_id, catalog, schema, dev_target, profile}
user_keys: [profile]      # tier-3 overridable: the ~/.databrickscfg profile NAME only. `host` is NOT personal: a workspace host IS which data you read
dev_key: dev_catalog    # legacy spelling of dev_target, still honored
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
only commands + `dialect_notes` differ, so `review` / `spec-and-build` / `refresh context` run
unchanged.

## Per-person setup notes (consumed by the onboarding flow; not verbs)
- **Enumerate profiles by NAME only.** `grep -E '^\[' ~/.databrickscfg | tr -d '[]'` lists every
  profile name without printing values — the file can hold a plaintext OAuth client secret, so
  never cat it or paste its contents anywhere. Offer **every** name, not just `DEFAULT`: an
  expired token on `DEFAULT` beside a healthy second profile is a real, observed failure mode
  that reads as "Databricks unavailable".
- **Expected-target evidence.** `databricks --profile {profile} current-user me` proves the
  profile authenticates, not that it reaches the team's workspace. Bind the probe to the SAME
  profile the person chose — use the Statement Execution API form of the query verb, which takes
  `--profile` (`dbsqlcli` binds no profile, so it can silently validate a different config):
  ```bash
  databricks --profile {profile} api post /api/2.0/sql/statements \
    --json '{"warehouse_id":"{warehouse_id}","statement":"SHOW SCHEMAS IN {catalog} LIKE '\''{schema}'\''","wait_timeout":"30s"}'
  ```
  Expect one row — a profile pointed at the wrong workspace fails this even though
  `current-user me` passed.

## Permission posture (MCP)

### Native control
The **principal the MCP connection authenticates as** (a token's owner or a service principal) and
that principal's Unity Catalog grants — wherever that connection is configured: a CLI-backed MCP
server may reuse a named profile; a desktop/official connector configures its own credentials; a
homegrown server's settings live with its owner — for that shape the posture below becomes a
suggestion to forward ("scope this connection's token/grants to read"). There is no universal
config file to point at, so the probe below **discovers** the session's actual principal and
grants rather than asserting either.

### Recommended setting (by policy)
With `db_write_requires_approval` on, the MCP path's discovered privileges should be **read-class
only on the team's configured catalog/schema** — then the policy holds by construction on the path
`db_write_guard` cannot see. Writes route through the CLI/API forms above, where the guard can see
them. If the grant exceeds that and you own it, narrow it; if someone else owns the server,
forward the suggestion to them.

### Read-only probe
Run in-session over the MCP connection (read-only introspection; enumerate names only — never
paste a full grant listing into a report, summary, or committed file):
```sql
SELECT current_user();                    -- the session principal the MCP connection runs as
SHOW GRANTS ON SCHEMA {catalog}.{schema}; -- DIRECT grants on the schema (all principals listed)
SHOW GRANTS ON CATALOG {catalog};         -- DIRECT grants at catalog level (privileges inherit downward)
-- the information_schema *_privileges views carry the same DIRECT-grant rows:
--   SELECT grantee, privilege_type FROM {catalog}.information_schema.schema_privileges;
```
**The comparison rule — cap-biased, because inheritance is real.** Unity Catalog privileges
inherit downward (catalog → schema → table) and group grants apply to every member, while every
surface above lists **direct** grants only — so a clean direct-grant listing can never prove the
session principal is read-only. Restricted to the team's configured objects (`{catalog}`,
`{schema}`, `dev_target`):
- ANY write-class entry visible for the session principal (or a group it is known to belong to) —
  MODIFY, CREATE, ALL PRIVILEGES, ownership — at catalog or schema level ⇒
  `status: exceeds-policy`. A violation the probe CAN see is always reportable.
- `status: matches` is writable ONLY from an EFFECTIVE-permission surface — one that resolves
  inherited and group grants down to the session principal (Unity Catalog's effective-permissions
  introspection, where the connection can read it) — showing read-class privileges only
  (SELECT, USE CATALOG, USE SCHEMA, BROWSE). Name the surface that answered in the record's
  `control:` line.
- Everything else ⇒ `status: unverified` — including the common case where the direct-grant
  listings look clean but effective privileges are unobservable from this session. Record that
  cap and why; never upgrade partial visibility to `matches`.
Only a recorded `matches` supports the enforcement table's NATIVE (tool-side) cell. Record the
outcome in gitignored `.claude/config/posture.local.yaml` — advisory, never blocking.

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
- **Write routing:** WRITES go through the CLI/API forms above; the MCP transport is for
  read/exploration. The `db_write_guard` hook inspects Bash-issued CLI commands only and cannot
  see MCP-issued SQL, so a mutation routed through the MCP would bypass the mechanical gate — on
  that path the `db_write_requires_approval` policy is guidance, not enforcement.
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

## verb: dialect_notes  (read by the review skill)
- **Functions:** `coalesce`/`nvl`, `try_divide(a,b)` (div-by-zero → NULL), `try_cast`, `collect_list`
  / `array_agg` (vs LISTAGG), `date_trunc`. `= NULL` never matches — use `IS NULL`.
- **Sizing:** SQL warehouse / cluster size + **partitioning / Z-ORDER / liquid clustering**; pruning
  the partition (or clustered) column is the main scan lever. `SELECT *` on wide Delta tables is the
  costly anti-pattern — list columns.
- **Joins:** type-match keys with `cast`/`try_cast`; mind `STRING` vs `BIGINT`. Broadcast small dims.
- **Dev/deploy:** dev objects in `{dev_target}`; promote with scripted `CREATE OR REPLACE`.
- **Portable params:** prefer a CTE params row (`WITH params AS (SELECT DATE '2026-06-30' AS anchor) … CROSS JOIN params`) over a session `DECLARE VARIABLE`/`SET VAR` when the SQL must run as one portable, export-clean statement.

## gotchas
- Mutations are tiered by policy `db_write_requires_approval` (`off` | `high_risk` | `all`):
  high-risk SQL (DROP/DELETE/UPDATE/TRUNCATE/MERGE/GRANT/`CREATE OR REPLACE`/non-ADD `ALTER`)
  ⇒ show the SQL, explain, wait for explicit `yes`. Additive SQL (plain CREATE, INSERT INTO,
  `ALTER … ADD`, COMMENT ON) runs without asking unless the policy is `all`.
- **Pause before any prod job deploy** — stop for human confirmation before writing prod job
  definitions or PR-ing to a jobs repo.
- The `databricks` CLI is for workspace/API management; SQL runs through `dbsqlcli` / the SQL API / MCP.
