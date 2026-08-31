# tests/emit — golden fixture trees for the runtime installer

Each `tests/emit/<runtime>/` directory is the EXACT set of files `bin/emit_runtime.py
--runtime <runtime>` must produce in a fresh project — `bin/selftest.sh` (sections 39 and 41) runs
the installer into `mktemp` projects with the Claude env vars unset and diffs the results against
these files byte-for-byte. A deliberate change to the emitted output therefore lands in the same
commit as a fixture regeneration; an accidental one turns the suite red.

What each tree holds mirrors the emission matrix (emit-vs-verify is decided by each adapter's
`reads_foreign_skills` / `skills_root` frontmatter, never by a runtime name in code):

- `codex-cli/` — the full skill emission under `.agents/skills/` (all skills model-invocable, so
  none carries a user-invocable-only warning block; a future gated skill would) plus the agent definition
  `.codex/agents/qc-reviewer.toml`. NO hook config: the hooks-config file location is not in the
  kit's research, so the installer prints the manual wiring line instead of guessing a path.
- `antigravity/` — the same `.agents/skills/` emission (one emission serves both runtimes; only
  the provenance header's re-run command differs), `.agents/agents/qc-reviewer.md`, and the hook
  config `.agents/hooks.json` (PreToolUse guard + PostToolUse index regen).
- `cursor/`, `devin/` — no skill files (these runtimes read the canonical `.claude/skills/` copy
  natively, so the installer verifies and emits no duplicate): cursor gets
  `.cursor/agents/qc-reviewer.md` plus `.cursor/hooks.json` (with `failClosed: true` — required
  configuration); devin gets `.devin/agents/qc-reviewer.md` only (its hooks-config location is
  unresearched, like codex-cli's).
- `opencode/` — the throw-to-deny plugin wrapper `.opencode/plugins/ticketwright-db-write-guard.js`
  (its plugin root is documented; nothing else is emitted).
- `cline/` — the enforcement-table honesty artifact `.clinerules/ticketwright-enforcement.md`
  (extracted from `templates/AGENTS.md.tmpl` between its markers — cline users don't read
  AGENTS.md); nothing else, and `.cline/` stays absent (selftest asserts it).

Regenerate after a deliberate output change (repeat per emitting runtime):

```bash
tmp=$(mktemp -d)
python3 bin/emit_runtime.py --runtime codex-cli --root "$tmp"
rm -rf tests/emit/codex-cli/.agents tests/emit/codex-cli/.codex
cp -R "$tmp/.agents" "$tmp/.codex" tests/emit/codex-cli/
rm -rf "$tmp"
```

For antigravity, copy `.agents` only. For the verify runtimes (cursor/devin/opencode/cline), first
vendor a fixture project
(`mkdir -p "$tmp/adapters" "$tmp/templates" "$tmp/bin" && cp bin/kit_paths.py "$tmp/bin/" &&
mkdir -p "$tmp/.claude" && cp -R .claude/skills "$tmp/.claude/skills"`), run the installer against
it, and copy the emitted `.cursor` / `.devin` / `.opencode` / `.clinerules` directory. The
enforcement-table markers in `templates/AGENTS.md.tmpl` feed the cline artifact, so an edit to
that block regenerates `cline/` in the same commit; `bin/opencode_tool_gate.js` feeds the
opencode wrapper the same way.

Things to know before touching these:

- **The fixtures embed the BODIES of `.claude/skills/*/SKILL.md` and `.claude/agents/*.md`.** Any
  edit to a canonical skill or agent file must regenerate these trees in the same commit, or the
  byte-for-byte diff turns red on an unrelated-looking change.
- **The provenance header embeds the kit version**, so a release commit that bumps
  `ticketwright/__init__.py` must regenerate the fixtures in the same change (day-to-day commits
  never bump the version — see AGENTS.md).
- **This directory ships nowhere.** It is deliberately absent from `pyproject.toml`'s wheel
  force-includes and sdist include list — fixtures are repo-only test material, not kit assets.
