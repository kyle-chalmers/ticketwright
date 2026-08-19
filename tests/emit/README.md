# tests/emit — golden fixture trees for the runtime installer

Each `tests/emit/<runtime>/` directory is the EXACT set of files `bin/emit_runtime.py
--runtime <runtime>` must produce in a fresh project — `bin/selftest.sh` (sections 39 and 41) runs
the installer into `mktemp` projects with the Claude env vars unset and diffs the results against
these files byte-for-byte. A deliberate change to the emitted output therefore lands in the same
commit as a fixture regeneration; an accidental one turns the suite red.

What each tree holds mirrors the emission matrix (emit-vs-verify is decided by each adapter's
`reads_foreign_skills` / `skills_root` frontmatter, never by a runtime name in code):

- `codex-cli/` — the full skill emission under `.agents/skills/` (user-invocable-only skills
  included, each carrying its topmost warning block) plus the agent definition
  `.codex/agents/qc-reviewer.toml`.
- `antigravity/` — the same `.agents/skills/` emission (one emission serves both runtimes; only
  the provenance header's re-run command differs) plus `.agents/agents/qc-reviewer.md`.
- `cursor/`, `devin/` — agent definitions only (`.cursor/agents/`, `.devin/agents/`): these
  runtimes read the canonical `.claude/skills/` copy natively, so the installer verifies and
  emits NO skill files. opencode and cline have no fixture tree because they emit nothing at all
  (selftest asserts that as absence).

Regenerate after a deliberate output change (repeat per emitting runtime):

```bash
tmp=$(mktemp -d)
python3 bin/emit_runtime.py --runtime codex-cli --root "$tmp"
rm -rf tests/emit/codex-cli/.agents tests/emit/codex-cli/.codex
cp -R "$tmp/.agents" "$tmp/.codex" tests/emit/codex-cli/
rm -rf "$tmp"
```

For antigravity, copy `.agents` only. For cursor/devin, first vendor a fixture project
(`mkdir -p "$tmp/adapters" "$tmp/templates" "$tmp/bin" && cp bin/kit_paths.py "$tmp/bin/" &&
mkdir -p "$tmp/.claude" && cp -R .claude/skills "$tmp/.claude/skills"`), run the installer against
it, and copy the emitted `.cursor`/`.devin` directory.

Things to know before touching these:

- **The fixtures embed the BODIES of `.claude/skills/*/SKILL.md` and `.claude/agents/*.md`.** Any
  edit to a canonical skill or agent file must regenerate these trees in the same commit, or the
  byte-for-byte diff turns red on an unrelated-looking change.
- **The provenance header embeds the kit version**, so a release commit that bumps
  `ticketwright/__init__.py` must regenerate the fixtures in the same change (day-to-day commits
  never bump the version — see AGENTS.md).
- **This directory ships nowhere.** It is deliberately absent from `pyproject.toml`'s wheel
  force-includes and sdist include list — fixtures are repo-only test material, not kit assets.
