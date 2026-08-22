# PROMPT — Meetings as an intake source, and a `meetings` tool slot

STATUS: DRAFT for maintainer review. Not scheduled. Written 2026-08-22 at the close of the
waves-A-I change set (v3.6.0), codex-reviewed 2026-08-22 with findings folded in. This document
is SELF-CONTAINED: the planning document that used to carry the standing constraints
(`docs/PLANNED-CHANGES.md`) is retired, so everything an implementer needs is restated here.
Maintainer-context notes (not source-verifiable facts): the vendor field this targets includes
Zoom AI Companion, Teams Copilot, Fireflies, Otter, Fathom, and Granola; and codex reviews in
this repo run 15+ minutes, so gates are backgrounded with stdin closed.

## Why

Meetings are where analysis work is born: a stakeholder asks a question out loud, an AI
notetaker captures it, and the action item becomes a ticket. Today the kit's intake vocabulary
(`project.intake`, consumed by `/ticket`'s priming sweep of `source_materials/`) knows tracker,
email, and chat — a meeting transcript arrives only by someone hand-dropping a file. The
mission's "on whatever tools they already use" includes the tool that heard the meeting; the
vision's "written down and organized, and AI can trace it" is exactly what a captured decision
trail is.

## Two stages — ship stage 1 even if stage 2 stalls

### Stage 1 — intake vocabulary (near-free; the mechanism already exists)
Be clear about what this is: the TRANSPORT already exists as file-backed intake — a person drops
external material into `source_materials/` and priming reads it (tracker attachments already use
the same destination; see `.claude/skills/ticket/priming.md`). Stage 1 adds vocabulary and a
naming convention, not a mechanism:
- Add `meetings` to `project.intake`'s documented vocabulary in `.claude/config/stack.schema.md`
  (same row style as the existing entries; consumer unchanged).
- Document the convention in the schema and the Round-4 intake question's option list (one
  option added to an existing question — no new question): export the meeting notes or a curated
  transcript excerpt into the ticket's `source_materials/`, named
  `YYYY-MM-DD-<slug>-meeting.md`.
- The selftest case must be BEHAVIORAL, not a prose grep (the existing intake assertion checks
  that files mention the words — that is not the bar): drive a fixture ticket carrying a
  `source_materials/*-meeting.md` file through the priming path and assert the file is picked
  up, the way other sections drive real CLIs against fixture trees.

### Stage 2 — the `meetings` tool slot (judge it against the new-slot bar first)
THE BAR, stated here because it lives nowhere else now (it originated in the retired planning
document's PROMPT 8, not in the schema — do not cite the schema for it; the schema only says the
five contractual slots are not an exclusive list): a new slot KIND needs a stable
tool-independent verb contract, a distinct lifecycle responsibility, its own auth/verification
semantics, and enough common use that it isn't an option on an existing slot. The implementer's
FIRST deliverable is a written judgment of `meetings` against that bar, codex-reviewed. The
organizer's prior assessment, to be verified not assumed: it plausibly passes — the verb
contract is tool-independent (`fetch_transcript`, `search_meetings`, `extract_actions`), the
lifecycle responsibility is distinct (it feeds "Open the work" and the spec step of "Do the
work", upstream of everything else — those are the canonical phase names; use them), and it is
read-only, the smallest safety surface a slot can have. If the judgment comes out NO, ship
stage 1 and stop; write the reasons where the next person will look.

If YES, the implementation must cover ALL of this — a fixed-five-slots assumption is baked into
more surfaces than the adapter tree:
- `adapters/meetings/<tool>.md` for the launch tools (two or three), in the existing adapter
  format exactly (`seam: meetings`, `tool:`, `transport:`, `requires:`, `user_keys:`, `auth:`,
  one `## verb:` section per contract verb). Copy the closest read-only pattern.
- The verb contract in `adapters/README.md` with an exact per-slot verb count — `bin/selftest.sh`
  asserts counts by EXACT EQUALITY (`<seam>) echo N` in `verbs_expected`); every adapter
  implements every verb (one that cannot documents it and returns "unsupported").
- THREE-TIER RULES: provider/workspace/content-selection keys are TEAM-owned (tier 1); only
  adapter-declared credential/local-path keys (`user_keys:`) may come from tiers 2/3; every
  config consumer goes through `bin/effective_config.py`, never raw YAML.
- A TOOL-NEUTRAL MEETING-REFERENCE FORMAT, defined, not implied: what a ticket writes to name a
  meeting (recommend a `meeting:` line in the ticket README or a `source_materials/` stub with a
  `meeting_ref:` frontmatter key), its ID grammar, and the no-reference behavior (the slot stays
  silent — no speculative fetching). "When the ticket references a meeting" without this
  definition is not implementable.
- EVERY FIXED-FIVE-SLOT SURFACE gains the sixth: `/setup tool`'s allowed modes and argument
  hint, the re-entry text, `templates/AGENTS.md.tmpl`'s stack table (and the scaffold token
  guidance + the `vars.env` fixture feeding the zero-leftover-token check),
  `templates/plan.md.tmpl`, `.claude/hooks/session_context.py`'s banner, README's tool-slot
  table, `docs/architecture.md`'s slot-to-phase matrix, and the selftests that pin each. Grep
  for the five-slot enumerations rather than trusting this list to be complete.
- `stack.yaml`: `seams.meetings` is OPTIONAL (like docstore) with a read-only `verify:`. A worked
  example in one existing `stack.example.*.yaml`; if a NEW example file is added instead, it
  needs a `pyproject.toml` force-include entry and the example-enumeration assertions updated —
  and if the worked-stack COUNT moves, `ROADMAP.md`'s asserted count line is the authoritative
  copy, reconciled in the same commit.
- `/ticket`'s priming step gains one tool-agnostic line calling the verbs. THE GOLDEN RULE
  binds: no tool names in skills — selftest section 3 greps for leaks and fails on one.

## ⛔ Transcript privacy — enforceable, not prose

Meeting transcripts are the most PII- and confidentiality-dense artifact the kit would touch.
The principle: CURATED EXCERPTS AND ACTION ITEMS ARE COMMITTED; RAW FULL TRANSCRIPTS ARE NOT,
BY DEFAULT. The same spirit as the voice-profile rule ("short approved exemplars — never full
confidential threads"). But prose alone is not a gate — the repo itself distinguishes prose
wiring pins from behavior they cannot prove, and today NOTHING enforces this: `/ship`'s PII
review covers `final_deliverables/` only, the `source_materials` gitignore line ships commented
out, and docstore backup is folder-wide unless deliverables are split. So the deliverable is an
ENFORCEABLE source-material policy:
- Raw-transcript paths ignored by default: an ACTIVE gitignore pattern for
  `source_materials/*transcript*` and `source_materials/private/` in `templates/gitignore.tmpl`
  (the current CSV-family patterns do NOT cover markdown — do not claim they do), with `git
  add -f` plus an explicit approval as the documented opt-in.
- Curated-excerpt naming stated in the convention (the `*-meeting.md` name is the committed,
  curated form).
- `/ship`'s staged-file inspection extended to `source_materials/` (flag anything matching the
  raw-transcript patterns before commit), and raw-transcript paths excluded from docstore backup
  unless separately approved — wire this through the existing delivery-plan per-deliverable
  split, not a new mechanism.
- The rule carried verbatim in EVERY meetings adapter's `fetch_transcript` verb documentation
  (not "both" — the launch count may be three), plus a behavioral selftest case: a fixture with
  a raw transcript in `source_materials/` trips the staged-file flag.

## Standing constraints (carried over; the retired planning doc no longer states them for you)
- `bash bin/selftest.sh` must print `0 failed` — AND CHECK ITS EXIT CODE, never just the printed
  tail. It treats docs as tested artifacts: adapter/seam counts are derived from the tree and
  asserted as literals in `docs/architecture.md` (`**<N> adapters**`) and `ROADMAP.md`
  (`- <N> adapters across <M> seams`); every shipped adapter is listed in `adapters/README.md`
  § "Adapters shipped"; `seam:`/`tool:` frontmatter is required; MCP names use the templated
  `mcp__{mcp}__` form. Add a hand-numbered section (read the highest ON CURRENT MAIN first).
  The suite is read-only, offline, credential-free — no live meeting provider in any test;
  fixtures and mocks only.
- Existing `stack.yaml` files in the wild must keep working — a new required key that breaks
  shipped example configs is a regression.
- THIS REPO IS PUBLIC: fixture identifiers only, in files AND commit messages.
- Stdlib only; any new CLI takes `--root` and needs no Claude env vars. No version bump (release
  commits only; the release ritual regenerates `tests/emit/` fixtures because provenance headers
  embed the version).
- User-facing prose says "tool slot"; `seam` stays the internal/config word.
- Conventional-commit title; CHANGELOG entry; update README/docs where behavior claims change.
- Branch from current main; squash-merge; surgical edits in shared files. Editing any
  `.claude/skills/*` file requires regenerating the emitted fixtures per `tests/emit/README.md`
  in the same commit.

## Gates (non-optional, the house pattern)
Run codex twice and put both verdicts verbatim in the PR body — on the PLAN before coding and on
the DIFF before the PR (`codex exec --skip-git-repo-check -C . "…cite file:line…"`, backgrounded
with stdin closed, verdict collected from the output file). Verify its findings against source;
it has been wrong in this project. The diff review must specifically answer: can any path commit
or back up a raw transcript without the explicit per-file opt-in?

## Evidence-of-done
- Stage 1: schema row present; interview option present; the BEHAVIORAL priming case passes.
- Stage 2 (if judged YES): the written bar-judgment in the PR; verb-count line + adapters green
  under the frontmatter and isolation greps; every five-slot surface extended and its pin green;
  the enforceable privacy policy demonstrated by the staged-file fixture case; count literals
  reconciled; selftest `0 failed`, exit code checked.
