---
seam: viewer
tool: windows-start
transport: cli          # cmd.exe START / Explorer shell verbs
requires: []            # routes are per-user config, not stack.yaml — see viewer.example.yaml
auth: |
  Runs from Git Bash, MSYS2, or WSL with interop enabled. No auth.
  Verify: `command -v cmd.exe` (WSL/Git Bash) or `command -v explorer.exe`.
---

# Windows `start` adapter

Maps the `viewer` verb contract to the Windows shell. This is the seam that hands a finished
artifact to a **human's own application** so they can look at the real thing before signing off.

Unlike every other seam, viewer config is **per-user and gitignored**. `bin/handoff.sh` resolves
it; see `.claude/config/viewer.example.yaml` for the file shape.

## verb: open
**In:** one or more paths. **Out:** each path handed to the application its glob route names.

```bash
cmd.exe /c start "" "C:\path\to\datagrip64.exe" query.sql   # a routed application
cmd.exe /c start "" report.md                               # no route → the file association
```

Config keys this adapter expects:

```yaml
open_cmd:    'cmd.exe /c start "" {app} {path}'
default_cmd: 'cmd.exe /c start "" {path}'
```

The empty `""` is **required**: `start` treats a lone quoted first argument as the new window's
title, so omitting it makes a quoted program path vanish into a window title and nothing opens.

## verb: reveal
**In:** a path. **Out:** Explorer opened with the file selected.

```bash
explorer.exe /select,"C:\repo\final_deliverables\01-summary.csv"
```

```yaml
reveal_cmd: 'explorer.exe /select,{path}'
```

## gotchas
- **Under WSL, Windows applications cannot read Linux paths.** A repo at `/home/you/work` is
  invisible to Excel. Translate with `wslpath -w` first, or keep ticket repos on `/mnt/c/...`.
  This is the single most common failure on this adapter.
- `explorer.exe /select,` takes **no space** after the comma, and exits non-zero even when it
  succeeds — `handoff.sh` reports the code and moves on rather than aborting the batch.
- **Excel holds a lock on an open `.csv`**, so a re-export while the user has the file open will
  fail. Say so instead of silently overwriting.
- Paths with spaces need quoting on the Windows side, not just the shell side; `handoff.sh` quotes
  for the shell, so prefer configuring `open_cmd` exactly as shown above.
- `start` returns as soon as the request is handed off. It is not a signal that a human looked at
  anything — the waiting is the skill's job.
