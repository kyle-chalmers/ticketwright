# Mode: `--voice` — bootstrap or refine a person's comms voice profile

Give the person running tickets a **voice profile** so `/ship` drafts tracker comments, chat, and PR
bodies that already sound like them. Requires an existing `stack.yaml`. Writes one file per person
at the `project.voice_profiles.path` (default `voices/{profile_id}.md`), rendered from
`templates/voice-profile.md.tmpl`.

> **Privacy — say this before writing anything.** A profile is **personal data** (a writing
> fingerprint) and the `voice_profiles.map` keys are **identity data** (work email / name) that land
> in the *committed* `stack.yaml`. On a public or mirrored repo, prefer `$USER` or a bare handle as
> the map key over a work email. Ingest only **short, already-sent exemplars** the person is fine
> sharing — never a full chat/PR/tracker thread, which can carry confidential content; capture
> *style cues* (how they open, hedge, sign off), not the source text. Profiles are committed by
> default; to keep one private, gitignore `voices/<id>.md`.

## Steps

1. **Identify the person.** Take the name from the argument, else resolve the current shipper:
   `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/bin/tw" resolve_user.py --json`. Settle on a
   short `profile_id` (their `assignee_dir` short-name is a fine default — but this keys on the
   *person*, not the ticket-owner folder).

2. **Wire the config (ask before writing).** Write `people/<id>.yaml` — TIER 2, person-scoped and
   committed — from `templates/person.yaml.tmpl`: `identities:` listing every identity
   `resolve_user.py` would see (`git config user.email`, `git config user.name`, and their `$USER`)
   plus a `voice:` block with `path` and `profile_id`. Enumerate every identity so resolution is
   deterministic on their machine. That file is what turns the feature on.
   **Do not write `project.voice_profiles` into `stack.yaml`.** That block puts one person's work
   email and display name into committed TEAM config — it is person data in a team artifact, which
   is the leak the three-tier split exists to remove. It is still READ, so an existing repo keeps
   working, but nothing should create a new one.
   While here, offer to set `seams.chat.include_self: true` so their chat messages also @-mention
   them (in addition to `always_include`, never replacing it).

3. **Render the seed.** `bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/bin/render.sh"
   templates/voice-profile.md.tmpl profile_id=<id> display_name="<name>" bootstrapped=<today>
   sources="<how built>"` → write to the resolved path. (Tracker-side enrichment — a display
   handle — happens here, once, via the tracker adapter if useful; write it into the frontmatter. Do
   **not** make `/ship` resolve it live.)

4. **Interview (≤5 short questions, `AskUserQuestion`).** Fill the template's sections: tone &
   register, bullets-vs-prose + greeting/sign-off, emoji, favored phrasings, banned words/tics.
   Keep answers terse — this is a style guide, not an essay.

5. **Optional: learn from exemplars.** Only with the privacy note above honored. From a few short
   approved samples, infer style cues and fold them into the sections. This is also the entry point
   for a deliberate refresh later (re-run `/setup --voice <name>` to update an existing profile).

6. **Confirm & save.** Show the rendered profile, confirm, save. Point them at `/ship`: the profile
   applies automatically on their next ship, *within* the hard comms rails (it never overrides word
   limits, hyperlinking, business-first segmentation, or the include-list).
