# SQL-template authoring rules + the render gate

Two hard rules for every `sql/*.tmpl` in a generated skill. Both have burned real runs; the
render gate (`bin/render_and_validate.sh`) enforces both mechanically.

## Rule 1 — Never put a token in a SQL comment
The renderer expands tokens everywhere, **including inside a `--` comment**. A multi-line value
(e.g. a long `VALUES` list) then spills past the `--` and the continuation rows are parsed as bare
SQL → compile error. Describe parameters in *prose*, not tokens:

```sql
-- step SQL — params described in prose, never as tokens   ✓
-- NOTE: substitutes {{vals}} before the run               ✗ (gate rejects this)
```

## Rule 2 — Quote any token used as a SQL string/date literal
`SET d = '{{asof}}'::DATE`, not `= {{asof}}`. Unquoted, `= 2026-06-30` is read as *arithmetic*
(= 1990), not a date → **silent wrong results**. The quotes live in the template, never injected at
call time. (The gate warns by default, fails under `--strict`.)

## The render gate — `bin/render_and_validate.sh`
Run it on every render (in the stamped skill's Phase 0/1, and once at stamp time). Stdlib-only, no
warehouse round-trip — cheap insurance. It asserts: zero leftover tokens · no token in a comment ·
balanced single-quotes / parens · flags an unquoted SQL literal. Halt on any error.

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" render_and_validate.sh sql/step.sql.tmpl asof=2026-06-30 src=T [--strict]
```

## Export helpers — `bin/split_and_export.sh`
Keeps multi-deliverable skills from re-improvising CSV plumbing:
- `--strip-only <file>` robustly drops the multi-statement CLI preamble (through the last
  `Statement executed successfully.`, then leading blanks) so the header is row 1;
- split mode turns one multi-`SELECT` file (delimited by `-- Query N` markers) into N runnable
  files — each carrying the shared preamble — and `--run` executes each via *your* warehouse verb
  and strips its CSV.
