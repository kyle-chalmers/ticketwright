# Hardening review — 2026-06

Before the first public release, the kit went through a **multi-agent review** combining three
independent passes. This record documents the method and the outcome (all findings were fixed).

## Method

| Pass | How | Outcome |
|---|---|---|
| **Subagent panel** | 7 dimension reviewers (tracker / warehouse / chat·docstore·vcs adapter accuracy; abstraction integrity; ticket-index correctness; portability & safety; docs & security). **Every finding was adversarially re-checked against the actual file/CLI** before counting. | 29 raised → 26 confirmed, 0 surviving false-positives |
| **External model (Codex)** | Whole-repo review, command accuracy **cross-checked against official docs** (Azure Boards/Repos, GitHub Issues, AWS Redshift Data API, PostgreSQL `psql`, Microsoft `sqlcmd`). | Corroborated the panel + ~10 unique findings |
| **Synthesis** | Merged + de-duped; two additional residual-identifier leaks caught during synthesis. | One consolidated fix set |

Independent perspectives were additive: the **Databricks BLOCKER** and the **Azure integer-ID design
gap** below were not surfaced by self-review alone.

## Findings (all resolved)

**Blocker**
- `databricks sql query` is not a real CLI command → rewrote `query`/`describe` to `dbsqlcli` / the
  SQL Statement Execution API / a SQL MCP.

**High**
- `acli jira jql` → real `acli jira workitem search --jql`.
- `sqlcmd --format csv` invalid → `-s"," -W` (go-sqlcmd has no `csv` format).
- Slack MCP params `channel`/`text` → `channel_id`/`message`; markdown links not Slack mrkdwn.
- Redshift conflated serverless workgroup vs provisioned cluster → split config + both command forms.
- Azure Boards / GitHub Issues use integer IDs that broke the `{id}` URL template → added a `{number}`
  URL token + adapter notes.
- Fresh-clone `--check` failed (no `INDEX.md` when zero tickets) → passes on an empty repo.
- `db_write_guard` missed `dbsqlcli` and `sqlcmd -i <file>` / stdin redirects → now gated + scanned.

**Medium**
- `jira_url` field in the index store → renamed to `ticket_url` (back-compat input kept).
- Docstore backup used a dangerous `rm -rf "<ID>"*` wildcard → exact-path delete only.
- `render.sh` crashed on bash 3.2 with zero vars (empty array under `set -u`) and returned exit 1 in
  non-strict mode → guarded + non-strict now exits 0.
- Index sort wasn't a strict total order; `key_prefixes` block-list + quoted scalars weren't parsed.
- Abstraction-rule wording clarified (skills must not *invoke* tools; illustrative prose + the
  `configure-workspace` detection probe are sanctioned).

**Low / security**
- Residual identifiers scrubbed (two bare "Kyle" examples a name-only scrub had missed; a `DI-XXXX`
  placeholder; a work-repo "storage-only" gotcha). Doc counts/links corrected.

## Verification after fixes
- `bin/selftest.sh`: **55 checks, 0 failed**, on stock macOS **bash 3.2** (validates all 3 example
  stacks, all 19 adapters, the hooks, and the ticket index incl. new edge cases).
- Targeted tests: `{number}` URL token, block-list prefixes, empty-repo `--check`, `ticket_url` field.
- Repo scrub clean (only the intentional `LICENSE` copyright + deliberate `jira_url` back-compat reads).

CI (`.github/workflows/ci.yml`) runs the self-test + index staleness gate on every push and PR.
