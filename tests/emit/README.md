# tests/emit — golden fixture trees for the runtime installer

Each `tests/emit/<runtime>/` directory is the EXACT tree `bin/emit_runtime.py --runtime <runtime>`
must produce in a fresh project — `bin/selftest.sh` (section 39) runs the installer into a
`mktemp` project with the Claude env vars unset and diffs the result against these files
byte-for-byte. A deliberate change to the emitted output therefore lands in the same commit as a
fixture regeneration; an accidental one turns the suite red.

Regenerate after a deliberate output change:

```bash
tmp=$(mktemp -d)
python3 bin/emit_runtime.py --runtime codex-cli --root "$tmp"
rm -rf tests/emit/codex-cli/.agents && cp -R "$tmp/.agents" tests/emit/codex-cli/
rm -rf "$tmp"
```

Two things to know before touching these:

- **The provenance header embeds the kit version**, so a release commit that bumps
  `ticketwright/__init__.py` must regenerate the fixtures in the same change (day-to-day commits
  never bump the version — see AGENTS.md).
- **This directory ships nowhere.** It is deliberately absent from `pyproject.toml`'s wheel
  force-includes and sdist include list — fixtures are repo-only test material, not kit assets.
