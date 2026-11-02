# Launcher fixtures

`v1/` holds the project launcher exactly as `/setup` copied it into user repos before launcher
stamps existed (`bin/tw` and `bin/kit_paths.py` from v4.9.3). Those copies know only a kit whose
scripts live in `bin/`.

Selftest section 31b runs them against fixture kits in both layouts, and checks that
`refresh_launcher.py` replaces them. Never edit these files: they stand for copies already
committed in users' repos, which the kit can no longer change.
