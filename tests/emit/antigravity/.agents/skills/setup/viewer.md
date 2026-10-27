# The viewer interview: which app opens each kind of deliverable (person-scoped)

One interview, asked from three places: `/setup` (after round 6 of the default path, and in
`/setup --teammate`), the `/setup viewer` re-run, and `/review`'s hand-off the first time it finds
no usable viewer. All three ask the same questions in the same words, so a person who skipped it at
setup meets the same choice at review.

Which app opens a `.sql` is a personal choice, so the answers go to a gitignored per-person file and
each teammate answers for themselves. This interview never touches `stack.yaml`. It writes through
the existing viewer config (`.claude/config/viewer.example.yaml` is the shape, `bin/handoff.sh`
reads it), and adds no setting of its own.

## 1. Say what the review stage is for, in one sentence

Before the first question, say this:

<!-- ticketwright:user-facing:begin -->
> At the end of each ticket I open the finished files in your own apps, so you can check the numbers are right before anything is shared. Pick which app opens each kind of file.
<!-- ticketwright:user-facing:end -->

When the repo's `human_review_handoff` policy is `off`, say instead that files are not opened for
review in this repo, and ask only whether to set this up anyway for a later change of policy. When
it is `all`, add that files also open while building.

## 2. Where it applies, or not at all

"Should these choices apply to this repo only, or to every ticket repo you work in?"

- **This repo only** (recommended on a first setup): writes `.claude/config/viewer.local.yaml`.
- **Every ticket repo**: writes `${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml`.
- **Don't open files for me**: writes `enabled: false` to `.claude/config/viewer.local.yaml`, and
  review never asks again (`/setup viewer` changes it later). Skip steps 3 and 4, and in step 5
  write only `enabled: false`.

Both files are outside what git commits.

## 3. Which kinds of files

Detect first: list the file extensions already under `tickets/*/*/final_deliverables/` and
`tickets/*/*/qc_queries/` in this repo (read-only). Ask one multi-select question, "Which kinds of
files will you check at review?". It does not depend on step 2's answer, so with a question tool it
can go in the same call. The fixed options, those found in this repo first and marked with how many
were found:

- **Tables and spreadsheets** (`.csv`, `.tsv`, `.xlsx`)
- **Queries** (`.sql`)
- **Write-ups** (`.md`, `.pdf`)
- **All of these**

A kind found in this repo that none of these covers (for example `.parquet`) is one more option,
paged with setup's "Show more" rule when it does not fit. Free text adds any other extension.

A kind left unpicked is not blocked: its files open with the computer's usual app for that file
type, the same as any file with no route. Say so once, after the answer.

## 4. One question per picked kind: which app

Ask one question per kind, in the order picked. These questions do not depend on each other, so
with a question tool group them up to the limit per call. Options:

- **Your computer's usual app for this file type** (recommended): writes no route, so the file
  opens the way double-clicking it would.
- **A specific app**: ask one follow-up for its name as their computer shows it (on macOS, the name
  in the Applications folder). A name typed straight into the question tool's own "Other" counts
  the same. Never offer an app name this run has not seen.

A typed name is checked in step 5, once the file is written, so the person hears about a name the
computer does not know now rather than at their first review.

## 5. Write and check

Before writing, read the current plan:

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" effective_config.py --viewer-plan
```

Its `source` is the file that wins today. The order is fixed: this repo's
`.claude/config/viewer.local.yaml`, then the person's own `people/<id>.yaml` paired with
`connections.local.yaml`, then the every-repo file, then a team-wide `viewer:` block in
`stack.yaml`. So when the person picked **Every ticket repo** but a file higher in that order exists
here, the new file would be ignored: name that file, say it is what review uses now, and ask
whether to remove it (this repo's `viewer.local.yaml`) or keep it. Never delete it without the yes;
never edit `people/<id>.yaml` or `stack.yaml` from here.

Write the file from `.claude/config/viewer.example.yaml`: keep its shape, take the
platform-matching `tool:`, `adapter:`, `open_cmd`, `default_cmd`, `reveal_cmd`, `app_check_cmd`
(when the block has one) and `verify` from the block for this OS, and write one `routes:` entry per glob that got a specific app (`*.csv`,
`*.tsv` and `*.xlsx` for Tables and spreadsheets; `*.md` and `*.pdf` for Write-ups). Kinds that got
the usual app get no route. Then check without launching anything:

- Run `--viewer-plan` again. Its `source` must be the file just written; when it is not, say which
  file wins instead. Show its `routes`.
- When this repo already has a ticket file of a picked kind, also run
  `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" handoff.sh --dry-run <that file>`,
  which prints the command it would open with. `handoff.sh` skips a path that does not exist, so on
  a fresh repo the plan's `routes` are the check; never create a file to have something to point
  it at.
- When any kind got a specific app, run
  `bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" handoff.sh --check-apps`.
  It asks the computer whether it has each app, and launches nothing. Exit 0: every app was found;
  say nothing more. Exit 1: for each `NOT FOUND: <name>` line, say this, then ask one question with
  three answers: type the name again, use the computer's usual app for that kind (remove its
  route), or keep the name as typed. Rewrite the file and run the check again after a new name.

<!-- ticketwright:user-facing:begin -->
> Your computer can't find an app called "<name>". Check how the name is spelled where your computer lists its apps, or use your computer's usual app for these files instead.
<!-- ticketwright:user-facing:end -->

  Exit 3: this computer has no way to check app names, so the names were not checked. Say so in
  one line: a misspelled name makes that file fail to open at review, and review says which one.

Never commit the viewer file.

In the default `/setup` path this file is a Phase 3 write like any other: it is listed in the plan
("your own review apps, this machine only, not committed") and written only after the yes, by
Phase 3's step 5c.
