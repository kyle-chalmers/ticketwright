---
seam: viewer
tool: xdg-open
transport: cli          # freedesktop.org MIME associations
requires: []            # routes are per-user config, not stack.yaml — see viewer.example.yaml
auth: |
  Needs `xdg-utils` (usually preinstalled on a desktop distro) and a running desktop session.
  Verify: `command -v xdg-open`.
---

# Linux `xdg-open` adapter

Maps the `viewer` verb contract to freedesktop.org desktop integration. This is the seam that hands
a finished artifact to a **human's own application** so they can look at the real thing before
signing off.

Unlike every other seam, viewer config is **per-user and gitignored**. `bin/handoff.sh` resolves
it; see `.claude/config/viewer.example.yaml` for the file shape.

## verb: open
**In:** one or more paths. **Out:** each path handed to the application its glob route names.

`xdg-open` itself takes no "open with this app" flag — it only follows MIME associations. To route
a specific application, name its launcher directly:

```bash
gtk-launch datagrip.desktop query.sql     # a routed application (.desktop name, no path)
setsid datagrip query.sql &                # or the binary, detached from this shell
xdg-open report.md                         # no route matched → the MIME default
```

Config keys this adapter expects:

```yaml
open_cmd:    'gtk-launch {app} {path}'   # {app} is a .desktop id, e.g. datagrip.desktop
default_cmd: 'xdg-open {path}'
```

List available `.desktop` ids with `ls /usr/share/applications ~/.local/share/applications`.
If `gtk-launch` is unavailable, `open_cmd: 'setsid {app} {path} &'` naming the binary also works.

## verb: reveal
**In:** a path. **Out:** the enclosing folder opened in the file manager.

```bash
xdg-open "$(dirname final_deliverables/01-summary.csv)"
# or, with file selected (Nautilus/Dolphin/Nemo all speak this D-Bus interface):
dbus-send --session --dest=org.freedesktop.FileManager1 --type=method_call \
  /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems \
  array:string:"file://$PWD/final_deliverables/01-summary.csv" string:""
```

```yaml
reveal_cmd: 'xdg-open {path}'   # {path} is the FILE; this adapter opens its parent directory
```

## gotchas
- **Headless sessions have nothing to open into.** Over plain SSH with no `$DISPLAY` /
  `$WAYLAND_DISPLAY`, `xdg-open` either errors or silently opens a terminal browser. `handoff.sh`
  already refuses to launch anything when no interactive session is detected; do not work around
  that check.
- `xdg-open` forks and returns immediately, so a non-zero exit is rare even when nothing appeared.
  Treat success as "the request was accepted", never as "a human saw it".
- Snap and Flatpak applications are sandboxed and may not see paths outside `$HOME`. Ticket
  deliverables normally live under the repo, so keep the repo in `$HOME` or grant the portal
  permission.
- `.desktop` ids differ by distro and install method (`datagrip.desktop` vs
  `jetbrains-datagrip.desktop`). Confirm once, then record it in your per-user viewer config.
