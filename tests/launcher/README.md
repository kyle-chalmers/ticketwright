# Launcher fixtures

`v1/` holds the project launcher exactly as `/setup` copied it into user repos before launcher
stamps existed (`bin/tw` and `bin/kit_paths.py` from v4.9.3). Those copies know only a kit whose
scripts live in `bin/`.

Selftest section 31b runs them against fixture kits in both layouts, and checks that
`refresh_launcher.py` replaces them. Never edit these files: they stand for copies already
committed in users' repos, which the kit can no longer change.

`old-init/install.sh` is `bin/install.sh` from v4.9.3, byte for byte: one file an older
`ticketwright init` copied into a repo's `bin/`. Selftest section 31c uses it to check that today's
`init` removes a file only when its bytes match a version Ticketwright shipped
(`tools/old_layout.py`). Never edit it either.
