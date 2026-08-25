---
seam: warehouse
tool: snowflake
transport: both        # `snow` CLI for scripts/exports; Snowflake MCP for interactive/semantic
requires: [cli]        # stack.yaml seams.warehouse.{cli, default_warehouse, pii_role, dev_target}
user_keys: [connection]   # tier-3 overridable: the snow-CLI connection NAME is per-machine (config file location varies — see auth); default_warehouse / pii_role / dev_target are team decisions
dev_key: dev_db         # legacy spelling of dev_target, still honored
auth: |
  CLI:  a named connection in the snow CLI's config.toml (USERNAME_PASSWORD_MFA for CLI/MCP).
  Config-file precedence (state it precisely — both directions of the mistake are real):
    1. `SNOWFLAKE_HOME` env var or a `--config-file` flag, when set;
    2. `~/.snowflake/config.toml`, whenever that directory exists;
    3. otherwise the OS default — on macOS `~/Library/Application Support/snowflake/config.toml`
       (the common case on a fresh Mac).
  So a hand-made `~/.snowflake/config.toml` is either a shadow file that changes nothing (env var
  set) or a file that silently takes precedence over the working macOS-default config. Don't guess
  files — ask the CLI which connections are live (`snow connection list`; during onboarding use
  the names-only projection below, never the bare command).
  Verify: `snow connection test` (read-only).
  Duo lockout signature: instant 250001/370001 = locked (wait 15 min); hang = push pending.
---

# Snowflake adapter

Maps the `warehouse` verb contract to Snowflake via the `snow` CLI (preferred for repeatable scripts
and CSV export) and the Snowflake MCP (preferred for interactive exploration + the semantic layer).

**Write routing:** WRITES go through the CLI; the MCP transport is for read/exploration. The
`db_write_guard` hook inspects Bash-issued CLI commands only and cannot see MCP-issued SQL, so a
mutation routed through the MCP would bypass the mechanical gate — on that path the
`db_write_requires_approval` policy is guidance, not enforcement.

## Permission posture (MCP)

### Native control
The **role the MCP connection sessions as**, wherever that connection is configured: a CLI-backed
MCP server may reuse the CLI's named connection; a desktop/official connector configures its own
connection in its app settings; a homegrown server's settings live with its owner — for that shape
the posture below becomes a suggestion to forward ("pin this connection's role"). There is no
universal config file to point at, so the probe below **discovers** the connection's actual role
rather than asserting a role name (bring-your-own-role stands; this adapter never names one).

### Recommended setting (by policy)
With `db_write_requires_approval` on, the MCP path's discovered privileges should be **read-class
only on the team's configured objects** — then the policy holds by construction on the path
`db_write_guard` cannot see. Writes route through the CLI, where the guard can see them (the write
routing above). If the connection's role exceeds that and you own it, narrow it; if someone else
owns the server, forward the suggestion to them.

### Read-only probe
Run in-session over the MCP connection (all read-only introspection; the names-only precedent
above holds — never paste a full grant listing into a report, summary, or committed file):
```sql
SELECT CURRENT_ROLE();
SHOW GRANTS TO ROLE <the role CURRENT_ROLE() returned>;
SHOW GRANTS ON SCHEMA <each schema stack.yaml names>;
```
**The comparison rule.** Restricted to the team's configured objects (the databases/schemas
reachable from stack.yaml's warehouse keys — `default_warehouse`, `dev_target`, the schemas the
team reads): `status: matches` iff the grant set contains only read-class privileges (USAGE,
SELECT, REFERENCES, MONITOR, READ). ANY write-class privilege there (INSERT, UPDATE, DELETE,
TRUNCATE, CREATE …, MODIFY, OWNERSHIP, WRITE, ALL) ⇒ `status: exceeds-policy`. A probe failure,
insufficient visibility to run the introspection, or grants only on objects the stack does not
name ⇒ `status: unverified`. Only a recorded `matches` supports the enforcement table's NATIVE
(tool-side) cell. Record the outcome in gitignored `.claude/config/posture.local.yaml` — advisory,
never blocking.

## Per-person setup notes (consumed by the onboarding flow; not verbs)
- **Enumerate connections by NAME only.** Never run bare `snow connection list` during
  onboarding — it masks passwords but still prints account, user, and role into the transcript.
  Project the names and nothing else:
  ```bash
  snow connection list --format JSON \
    | python3 -c "import json,sys;[print(c['connection_name']) for c in json.load(sys.stdin)]"
  ```
  Offer every named connection, not just the default, and never paste a full listing into a
  report, summary, PR body, or committed file.
- **Expected-target evidence.** `snow connection test` proves reachability, not that the person's
  CHOSEN connection reaches the team's data. Bind both in one probe — name the connection
  explicitly so the check cannot silently run through the CLI default:
  ```bash
  snow sql -q "USE WAREHOUSE {default_warehouse}" -c {connection}
  ```
  A connection pointed at a different account fails it, and an interactive MFA prompt here is a
  normal first-run outcome.
- **Fallback when `{default_warehouse}` is still an unanswered TODO** (a fresh repo, before the
  team decides the warehouse) — the probe above is unrunnable, but you can still evidence where
  the connection lands:
  ```bash
  snow sql -q "SELECT CURRENT_ACCOUNT(), CURRENT_ROLE(), CURRENT_WAREHOUSE();" -c {connection}
  snow sql -q "SELECT CURRENT_AVAILABLE_ROLES();" -c {connection}
  ```
  That names the account, the active role/warehouse, and every role on offer — enough to confirm
  the right target (or catch the wrong one) before the team fills in `default_warehouse`.

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

## verb: dialect_notes  (read by the review skill's anti-pattern sweep)
- **Functions:** `IFF`, `NVL/COALESCE`, `NULLIF` (div-by-zero guard), `LISTAGG` (many-to-many),
  `DATE_TRUNC`. `=NULL` never matches — use `IS NULL`.
- **Sizing:** use a named virtual warehouse for heavy QC (e.g. `{default_warehouse}`), not slots.
- **Joins:** `CAST()` keys when joining across sources (NUMBER vs VARCHAR mismatches); apply any
  required tenant/schema filter your shared views expect; where a view unions migrated + native
  data, filter to the rows you actually want (e.g. a `IS_MIGRATED` / source flag).
- **Layering:** prefer your curated layers (e.g. `RAW → STAGING → ANALYTICS → REPORTING`); avoid
  legacy/raw schemas and point-in-time snapshot tables unless the work is compliance/historical.
- **Dynamic-table chains:** never interpose a regular view between dynamic tables (`target_lag='DOWNSTREAM'`).
- **Dev/deploy:** build dev objects in `{dev_target}`; promote with your multi-env deploy template (COPY GRANTS).
- **Portable params — prefer CTE params over session variables / Scripting `DECLARE`.** A `SET v=…; $v`
  session variable (or a Snowflake Scripting `DECLARE`) is script/session-scoped: it doesn't survive
  into a separate JDBC/ODBC statement (DataGrip, Simba), and multi-statement `snow -f` runs emit the
  "Statement executed successfully." preamble you then have to strip. Prefer a self-contained CTE
  params row — `WITH params AS (SELECT '2026-06-30'::DATE AS anchor) SELECT … CROSS JOIN params` — so
  the query is one portable, export-clean statement.

## gotchas
- Mutations are tiered by policy `db_write_requires_approval` (`off` | `high_risk` | `all`):
  high-risk SQL (DROP/DELETE/UPDATE/TRUNCATE/MERGE/GRANT/`CREATE OR REPLACE`/non-ADD `ALTER`)
  ⇒ show the SQL, explain, wait for explicit `yes`. Additive SQL (plain CREATE, INSERT INTO,
  `ALTER … ADD`, COMMENT ON) runs without asking unless the policy is `all`.
