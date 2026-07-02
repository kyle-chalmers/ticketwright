# `--teammate` mode — onboard a person to an already-configured repo

Reads `.claude/config/stack.yaml` and the adapters to produce a **personalized, tool-specific
checklist** and walk it with them. If `stack.yaml` is absent, stop — run plain `/setup` first.

## 1 · Install prerequisites
Check what's present: `for c in <the CLIs named in stack.yaml seams> yq jq git; do command -v $c
>/dev/null && echo "✓ $c" || echo "✗ $c (install)"; done`. For each missing tool give the install
command (Homebrew / winget / apt as appropriate).

## 2 · Authenticate each configured tool
For every seam, open its adapter's `auth:` notes and walk the person through signing in — tracker
CLI/MCP auth, warehouse connection (`config.toml`/ADC), chat MCP connect, docstore mount, vcs auth
login. Pure instructions — the person runs the auth themselves.

## 3 · Verify connectivity
Run `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/selftest.sh"` first (the kit itself),
then `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/verify_stack.sh"`. Walk any ✗/⚠ with
the relevant adapter's auth notes until green (MCP-only seams: confirm the server is connected this
session). Mention the `db_write_guard` hook so they know destructive warehouse statements prompt
for confirmation **by design**.

## 4 · Read the map
Point them at, in order: `AGENTS.md` (the rules — read end to end),
`documentation/AI_LAYER_INDEX.md` (what exists), and the `documentation/` knowledge pack (built by
`/refresh context`) for domain grounding. Summarize the lifecycle: **`/ticket` → `/spec-and-build`
→ `/review` → `/ship`** — context loads automatically inside `/ticket`.

## 5 · Guided first-ticket dry run
Pick a real, small ticket (or have them name one) and run `/ticket <id>` in **dry-run spirit** —
set up the workspace and prime context, but stop before any external action so they see the flow
end to end safely. Explain the hard-halt gates and the DB-write approval protocol as you go.
Finish with a checklist of done vs outstanding, and hand them their first real ticket.
