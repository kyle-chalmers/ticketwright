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
  moment). **Before binding, run step 0.5** — on a fresh machine the git identity may be entirely
  unset, and binding first records a weaker identity than the one they are about to configure.
  Then `whoami.py --bind <id>`: it pins this machine and appends their identity to their
  own `people/<id>.yaml`, creating the file when they are new. The person's own answer is
  authority — never guess from a folder name or git config.
- `ambiguous` → offer exactly the candidates whoami names, then bind the answer.
- `conflict` → read whoami's warning aloud: the machine pin and this repo's git identity disagree.
  Fix whichever side is stale (re-bind, or correct the git config) before continuing.

## 0.5 · Git identity — set it before binding
`!git config user.email; git config user.name` — on a fresh machine both can be unset, which
leaves `$USER` as the only identity candidate (this happened live) and, separately, breaks the
commits `/ship` makes. If either is unset, have the person set them now — repo-local is fine:
`git config user.email "<their email>"` and `git config user.name "<their name>"`. Then bind (or
re-run step 0): the identity recorded is now one this machine actually resolves by.

## 1 · Install prerequisites
**First, the two that make everything after them pointless.** Both probes are read-only:

- **Is this a clone?** `!git rev-parse --show-toplevel` — a non-zero exit means there is no
  repository here. **Halt**: "There is no `.git` in this folder. If it came from a Download-ZIP
  button (the folder name usually ends in `-main`), Ticketwright cannot branch, commit, or open a
  PR from it. Clone the repo instead — `git clone <the repository's URL>` — then re-run this
  inside the clone."
- **Is the kit installed and usable here?**
  `!python3 "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/plugin_doctor.py" --json` — a
  read-only pass over the install prerequisites; it installs nothing and makes no network call.
  Report every finding that is not `ok` with its `fix` lines **verbatim** — they are exact
  commands. A `fail` on `scope_supported` (the agent CLI is too old to install a plugin for one
  repo), `repo_install` (nothing is installed for this repository) or `install_payload` (the
  install record points at a directory that does not exist) is a **halt**: none of it is fixable
  by anything this flow writes, and the fix text names the route out — including the in-session
  install and the update command for how the CLI was installed. `warn`/`unknown` findings are
  reported and the flow continues; on a vendored or pip install the install checks answer
  `unknown`, which is the expected answer there. If the script is absent (an older kit copy), say
  so in one line and carry on.

Then check the rest: `for c in <the CLIs named by the configured tool slots> yq jq git; do
command -v $c >/dev/null && echo "✓ $c" || echo "✗ $c (install)"; done`. For each missing tool give
the install command (Homebrew / winget / apt as appropriate). Scope note: `yq` is needed only by
the kit's own `selftest.sh` (step 5 runs it once, as a kit-integrity check) — no skill in a
configured repo invokes it day to day, so a missing `yq` blocks that one check, nothing else. When
`yq_present` is not `ok`, print the doctor's platform install command and **offer to run it now**,
before step 5 needs it — and say what step 5 costs: several minutes, longer than a typical tool
timeout, judged by its **exit code**, not by how green the tail of its output looks.

## 2 · Authenticate each configured tool
For every configured tool slot, open its adapter's `auth:` notes and walk the person through
signing in — tracker CLI/MCP auth, warehouse connection, chat MCP connect, docstore mount,
meetings provider access, vcs
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
then `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/verify_stack.sh"`. Three rules make the
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
- **Probe MCP-only tool slots in-session — verify_stack.sh cannot.** A seam with `transport: mcp`
  and `verify: null` has no shell surface, so the script reports it as *unverified*, not OK. For
  each such slot: call ONE read-only tool from that MCP server in this session (the adapter's
  `auth:` notes name a suitable probe), and record the outcome — reachable or unreachable — next
  to that slot in the checklist. An unverified MCP slot is not done until this probe has run.
- **Check each MCP slot's permission posture — discover, compare, record.** For every slot whose
  resolved transport includes MCP, the verifier printed a `▸ posture[<slot>]` pointer naming that
  adapter's "Permission posture (MCP)" section. Run the section's read-only probe in-session,
  apply its comparison rule, and record the outcome per slot — `matches` (the discovered
  privileges satisfy the rule), `exceeds-policy` (the probe found more than the policy expects),
  or `unverified` (the probe failed, or the control cannot be introspected in-session — chat and
  tracker connector grants always cap here). `matches` is writable ONLY when the adapter's
  comparison rule held — never as a hopeful default. Where the fix lives depends on the connection
  shape: an official connector → its app settings; a CLI-configured server → its config file; a
  homegrown server → a suggestion you forward to its owner. Advisory means advisory: the person
  may own neither the server nor the grant — an unexpected posture is said and recorded in the
  report as `exceeds-policy`/`unverified`, never a block. Write the record to the gitignored,
  display-only file (never resolver-merged; never secrets, never listing output — names only):
  ```yaml
  # .claude/config/posture.local.yaml — gitignored, display-only, never resolver-merged
  schema_version: 1
  checked:
    <unit label>:
      control: <what was probed, names only>
      status: matches | exceeds-policy | unverified
      checked: YYYY-MM-DD
  ```
Walk any ✗/⚠ with the relevant adapter's auth notes until green. A docstore mount check that
fails (`✗ UNREACHABLE` on a
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
