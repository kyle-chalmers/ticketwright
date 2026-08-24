# `--teammate` — the per-person flow (onboard a person to an already-configured repo)

Entered automatically when Phase 1 finds a committed stack but `whoami` does not recognize the
person; `/setup --teammate` is the explicit re-run. Reads `.claude/config/stack.yaml` and the
adapters to produce a **personalized, tool-specific checklist** and walk it with them. If
`stack.yaml` is absent, stop — run plain `/setup` first.

**Tiers 2 and 3 — a person's portable file (`people/<id>.yaml`) and their machine file
(`.claude/config/connections.local.yaml`) — are written only by a person's own flow.** This flow
is that writer, including the `whoami --bind` it runs (the bootstrap in SKILL.md invokes the same
bind for the person present — still their own answer, so still person-authorized). Two narrow
carve-outs, named so the claim stays honest: the just-in-time viewer interview at the `/review`
gate keeps writing viewer config, and team setup may seed identity-free `display_name:`-only
placeholders under the scope invariant. Nothing else writes these tiers, and this flow **never
edits committed `stack.yaml`**: when a team value looks wrong, say so and point at
`/setup tool <name>` — a team decision does not get fixed from inside one person's onboarding.
Every question below is prose the person answers in chat, never a structured tool-call payload.

## 0 · Who is this?
`!python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/whoami.py" --root . --json`
- `resolved` → show the one-line "Working as …" display and continue.
- `miss` → ask, in prose: "I don't recognize `<identity>`. Who are you?" — offering every id under
  `people/` as a candidate plus "someone new" (the roster of placeholders exists for exactly this
  moment). Then `whoami.py --bind <id>`: it pins this machine and appends their identity to their
  own `people/<id>.yaml`, creating the file when they are new. The person's own answer is
  authority — never guess from a folder name or git config.
- `ambiguous` → offer exactly the candidates whoami names, then bind the answer.
- `conflict` → read whoami's warning aloud: the machine pin and this repo's git identity disagree.
  Fix whichever side is stale (re-bind, or correct the git config) before continuing.

## 1 · Install prerequisites
Check what's present: `for c in <the CLIs named by the configured tool slots> yq jq git; do
command -v $c >/dev/null && echo "✓ $c" || echo "✗ $c (install)"; done`. For each missing tool give
the install command (Homebrew / winget / apt as appropriate).

## 2 · Authenticate each configured tool
For every configured tool slot, open its adapter's `auth:` notes and walk the person through
signing in — tracker CLI/MCP auth, warehouse connection, chat MCP connect, docstore mount, vcs
auth login. Pure instructions — the person runs the auth themselves.

## 3 · Detect this person's machine — now, not at repo-setup time
Repo-setup-time detection described the machine of whoever configured the repo. This person's
machine is a different machine: detect it fresh, at this moment. For each tool slot whose adapter
declares personal keys (`user_keys:` frontmatter), enumerate **all** of the person's named
profiles/connections for that tool — the adapter's per-person setup notes name where they live
and how to list them. Never trust the default profile alone: a real setup hit an expired token on
the default profile while another profile worked fine, which reads as "tool unavailable" on a
perfectly healthy machine.

> ⛔ **Names only.** A tool's local config file can hold plaintext secrets, and even a "list
> connections" command that masks passwords still prints account, user, and role. Read and repeat
> profile/connection **names** only — never echo, copy, log, or paste the file's contents or a
> listing command's full output into a report, a summary, a PR body, or any committed file.

Then ask (in prose) which profile/connection fills each personal key. "The team defaults are
fine" is a valid answer, recorded as such in the next step.

## 4 · Write their machine file — a versioned document, not a bag of keys
Write `.claude/config/connections.local.yaml` (tier 3, gitignored). File existence alone cannot
distinguish empty, half-finished, "I chose team defaults", or stale-after-the-stack-changed — so
this flow always writes the full versioned shape (a writer convention `bin/effective_config.py`
understands and polices):
- `schema_version: 1`
- `mode:` — `defaults` (they accepted team defaults; the file must then carry no tool-slot overrides —
  the resolver rejects the combination) or `overrides` (personal values follow)
- `stack_fingerprint:` — the sha256 of the stack file this was completed against:
  `!python3 -c "import hashlib;print(hashlib.sha256(open('.claude/config/stack.yaml','rb').read()).hexdigest())"`
  — the resolver hashes the same bytes and reports `stale` once the team stack changes
- `person: <id>` — already pinned by `--bind`; keep it
- under `seams.<slot>…`: ONLY values for keys the adapter declares in `user_keys:` — the resolver
  refuses anything else, and `policies:` is never mergeable from a personal file.
Confirm it resolves:
`!python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/effective_config.py" --root . --json`
must report no errors, with each override attributed to the machine tier.

## 5 · Verify connectivity — bound to the expected target
Run `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/selftest.sh"` first (the kit itself),
then `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/verify_stack.sh"`. Two rules make the
result mean something:
- **Bind the check to the target.** "The CLI responded" is not proof the person reached the right
  place — a personal profile can point at an entirely different account or workspace. Use the
  expected-target evidence in each adapter's per-person setup notes (a read-only probe showing the
  data committed `stack.yaml` names is actually visible from their connection) and say the
  comparison out loud: "your connection reaches the team's configured data" — or name the
  mismatch.
- **Expect an auth challenge.** Every verify was green on the machine that configured the repo
  because of a cached session; this person has none, so an interactive sign-in or MFA prompt
  mid-verify is a NORMAL outcome. Narrate it ("your tool is asking you to sign in — finish that
  and we'll re-run"), never report it as a failure.
Walk any ✗/⚠ with the relevant adapter's auth notes until green (MCP-only tool slots: confirm the
server is connected this session). A docstore mount check that fails (`✗ UNREACHABLE` on a
`test -d`) has its own guide — install steps per OS, the `mount_root` tier split, and the mountless
`rclone` route: <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>. Mention the `db_write_guard` hook so they know destructive
warehouse statements prompt for confirmation **by design**.

Then run `/setup viewer` with them. The repo's `human_review_handoff` policy already decides *when*
work pauses for a human to eyeball deliverables; this is where **they** pick which of their own apps
those files open in. It is per-user and gitignored, so whoever configured the repo could not answer
it on their behalf — and skipping it just means the gate prints paths instead of opening anything.

## 6 · Read the map
Point them at, in order: `AGENTS.md` (the rules — read end to end),
`documentation/AI_LAYER_INDEX.md` (what exists), and the `documentation/` knowledge pack (built by
`/refresh context`) for domain grounding. Summarize the lifecycle: **`/ticket` → `/spec-and-build`
→ `/review` → `/ship`** — context loads automatically inside `/ticket`.

## 7 · Guided first-ticket dry run
Pick a real, small ticket (or have them name one) and run `/ticket <id>` in **dry-run spirit** —
set up the workspace and prime context, but stop before any external action so they see the flow
end to end safely. Explain the hard-halt gates and the DB-write approval protocol as you go.
Finish with a checklist of done vs outstanding, and hand them their first real ticket.
