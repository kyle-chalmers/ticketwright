---
seam: viewer
tool: macos-open
transport: cli          # LaunchServices via /usr/bin/open
requires: []            # routes are per-user config, not stack.yaml — see viewer.example.yaml
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  No auth. `open` ships with macOS.
  Verify: `command -v open`.
---

# macOS `open` adapter

Maps the `viewer` verb contract to macOS LaunchServices. This is the seam that hands a finished
artifact to a **human's own application** — a SQL file to their IDE, a result CSV to their
spreadsheet app — so they can look at the real thing before signing off.

Unlike every other seam, viewer config is **per-user and gitignored** (which app a person wants is
a personal choice, not a repo convention). `bin/handoff.sh` resolves it; see
`.claude/config/viewer.example.yaml` for the file shape.

## verb: open
**In:** one or more paths. **Out:** each path handed to the application its glob route names.

```bash
open -a "DataGrip" query.sql              # a routed application
open -a "Microsoft Excel" a.csv b.csv     # one launch for many files of the same route
open report.md                            # no route matched → the OS default association
```

Config keys this adapter expects:

```yaml
open_cmd:    'open -a {app} {path}'   # {app} and {path} arrive pre-quoted
default_cmd: 'open {path}'            # used when no route matches
```

`{path}` expands to **all** paths sharing one route, so a batch of CSVs is a single launch rather
than one window per file.

## verb: reveal
**In:** a path. **Out:** the enclosing folder opened in Finder with the file selected.

```bash
open -R final_deliverables/01-summary.csv
```

```yaml
reveal_cmd: 'open -R {path}'
```

## verb: check_app
**In:** an app name from a route. **Out:** exit 0 when this computer has the app, non-zero when it
does not. Launches nothing and reveals nothing.

```yaml
app_check_cmd: 'a={app}; a="${a%.app}.app"; for d in /Applications /Applications/Utilities /System/Applications /System/Applications/Utilities "$HOME/Applications"; do [ -d "$d/$a" ] && exit 0; done; mdfind -name "$a" 2>/dev/null | grep -qF "/$a"'
```

It looks for `<name>.app` in the usual application folders, then asks Spotlight. `open -Ra` is
not used: `-R` reveals the app in Finder, which opens a window. With Spotlight indexing turned
off, an app outside those folders reads as not found; the person can keep the name anyway.

## gotchas
- **Excel holds a lock on an open `.csv`.** If a build re-exports a file the user still has open,
  the write fails or lands in a temp copy. When re-running an export, say so rather than silently
  overwriting.
- `open -a` matches the application's **display name** (`Microsoft Excel`, not `excel`). A wrong
  name fails with `Unable to find application named …` — a non-zero exit `handoff.sh` reports and
  moves past, never aborting the rest of the batch.
- `open` returns as soon as LaunchServices accepts the request, not when the app finishes loading.
  It is not a signal that the human has actually looked at anything — the waiting is the skill's
  job, not this command's.
- A first launch of a large IDE can take many seconds. Hand files over *before* printing the
  "what to look at" summary so the app warms up while the person reads.
