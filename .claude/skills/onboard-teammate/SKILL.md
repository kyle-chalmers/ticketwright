---
name: onboard-teammate
description: Onboard a new team member to a configured ticket-work repo — install prerequisites, authenticate each configured tool, verify connectivity, read the key docs, then a guided first-ticket dry run.
argument-hint: [name] (optional, for a personalized checklist)
allowed-tools: [Read, Bash, Glob, AskUserQuestion]
---

# /onboard-teammate

Gets a new person productive on an **already-configured** repo. Reads `.claude/config/stack.yaml`
and the adapters to produce a **personalized, tool-specific checklist** and walk it with them. The
same AI layer that primes the agent onboards the human (onboarding symmetry).

## Phase 0 — Read the config
1. Read `.claude/config/stack.yaml`. If absent, stop and point to `/configure-workspace` (the repo
   isn't configured yet). Note each seam's `tool` + `adapter`.

## Phase 1 — Install prerequisites
2. Check what's present: `!for c in <the CLIs named in stack.yaml seams> yq jq git; do command -v $c >/dev/null && echo "✓ $c" || echo "✗ $c (install)"; done`
3. For each missing tool, give the install command (Homebrew/winget/apt as appropriate) and the
   common analysis utilities the repo expects. (Generalizes a prerequisites / install guide.)

## Phase 2 — Authenticate each configured tool
4. For every seam, open its adapter's `auth:` notes and walk the person through signing in — e.g.
   tracker CLI/MCP auth, warehouse connection (`config.toml`/ADC), chat MCP connect, docstore mount,
   vcs `gh/glab auth login`. Pure instructions — the person runs the auth themselves.

## Phase 3 — Verify connectivity
5. Run `!bash bin/selftest.sh` first (confirms the kit itself is intact + hooks work), then
   `!bash bin/verify_stack.sh`. Walk through any ✗/⚠ with the relevant adapter's auth notes until
   green (MCP-only seams: confirm the server is connected this session). Mention the `db_write_guard`
   hook so they know destructive warehouse statements will prompt for confirmation by design.

## Phase 4 — Read the map
6. Point them at, in order: `AGENTS.md` (the rules — read end to end), `documentation/AI_LAYER_INDEX.md`
   (what skills/commands exist), and the context pack (`/build-context-pack` output) for domain
   grounding. Summarize the PIV loop: `start-ticket` → `spec-and-build` → `qc-review` →
   `deliver-ticket`, with `/prime-*` for context.

## Phase 5 — Guided first-ticket dry run
7. Pick a real, small ticket (or have them name one) and run `/start-ticket <id>` **in dry-run
   spirit** — set up the workspace and prime context, but stop before any external action so they see
   the flow end to end safely. Explain the hard-halt gates and the db-write approval protocol as you go.
8. **Report** a checklist of what's done vs outstanding, and hand them the "first real ticket" next step.

## Generalizes
`prerequisite_installations.md` + the README "Getting Started" + the auth/verify steps — now driven
by whatever tools `stack.yaml` actually names.
