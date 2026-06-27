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

---

# Hardening review — v1.1 (2026-06-27)

The v1.1 diff (prior-art recall · object reverse-index · deep QC) went through the same two-track
review before merge: an adversarial **subagent panel** (dimension finders → every finding re-checked
against the file/CLI before counting) plus an **external-model (Codex)** whole-diff pass, then synthesis.

## Findings (all resolved)

**High**
- Deep QC (`qc-review --deep`) defaulted *unreproducible* findings to false-positive — for a QC harness
  that silently drops a Critical/count/reconcile finding. Now ruled **uncertain**, carried into the
  verdict, and forces REQUEST-CHANGES (or human sign-off) rather than a silent APPROVE.
- `recall.py` excluded the seed by id alone, dropping a same-id ticket under a *different owner* — a real
  candidate. Now excludes only the exact (id, owner) seed row.

**Medium**
- `extract_objects()` ran the SQL regex over `*.py`, indexing `from os.path import join` as object
  `os.path` → now skips Python import lines.
- `/recall --object VW_X` matched fully-qualified objects exactly, so an unqualified leaf missed
  `BI.ANALYTICS.VW_X` → leaf-aware matching.
- Seed lookup was case-sensitive and silently picked the first of an ambiguous multi-owner match → now
  case-insensitive and errors listing the owners.
- PostToolUse hook skipped `index_data.json` as if generated; editing the *source* store didn't
  re-render → now only the two generated artifacts are skipped.
- Close/commit docs staged `INDEX.md` + `index_data.json` but not the new `OBJECTS.md`, risking a CI
  staleness failure on the documented flow → all three staged.

**Low**
- `recall.py` sort wasn't a strict total order (ties unstable) → id+owner added to the sort key.
- Recall double-counted tags (as both a tag hit and a keyword) → tags scored once.
- Default permission allow-list missed `recall.py` / `enrich_ticket.py` → added.

## Verification after fixes
- `bin/selftest.sh`: **65 checks, 0 failed** on stock macOS **bash 3.2** (adds recall ranking, reverse +
  leaf-match lookup, OBJECTS.md render/gate, Python-import exclusion, multi-owner seed disambiguation).
- Targeted regression tests for each confirmed bug ship in §11 of the self-test.
