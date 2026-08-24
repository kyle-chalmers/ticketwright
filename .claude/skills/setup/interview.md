# The `/setup` interview — Phase 2, in rounds

Six rounds. **Rounds 1–4 always run; rounds 5–6 are individually skippable**, each skip labeled
with its cost at that round's header. Phase 1 detection has already produced the facts these
questions depend on — never ask something a probe already answered. Every question is prose the
person answers in chat: runtimes that render structured options show chips, every other runtime
shows a numbered list. Present detected answers pre-selected and defaults visible.

## The rule that decides what gets asked

> **ASK when a wrong or absent value still yields a confident-looking output. Leave it a commented
> default when a wrong or absent value fails loudly at `verify_stack.sh` or on first use.**

A dead catalog link, a generic persona, a message with no stakeholders attached — nothing errors,
so nobody notices for weeks. Those get questions. A key whose absence makes a verb visibly fail
the first time someone uses it can stay a commented default.

Corollary: **ask for every key the chosen adapter's `requires:` frontmatter lists** (only those —
the extra keys an adapter's frontmatter *comments* mention are optional, not required). "I'll fill
it in later" is always a valid answer: write the key as a `# TODO` and keep going.
`verify_stack.sh` names every unset required key as a warning on every run, so a deferred key is a
tracked choice, not a silent hole.

Never promise a question count, in this file or in any report — a stated number becomes the
binding constraint on correctness, which is exactly the defect this round structure replaced.

## Round 1 — Who

First because it costs almost nothing, it grounds every later answer, and the privacy warning
below has to land **before** anyone types a colleague's work email.

1. **The person at the keyboard.** Run `whoami` now if Phase 1's routing didn't (a fresh repo has
   no `people/` yet, so expect `miss` there — that is the normal fresh-setup path, not an error):
   - `resolved` → **confirm rather than ask**, with the one-line display ("Working as Alice Smith
     (alice) — new analyses go in `tickets/alice/` unless told otherwise").
   - `miss` → run the self-healing bind interview: ask one question ("I don't recognize
     `<identity>`. Who are you?", offering every id under `people/` plus "someone new"), then
     `whoami.py --bind <id>`. Confirming-rather-than-asking describes the *resolved* path only —
     never suppress this interview; it is what makes identity self-healing.
   - `ambiguous` → ask which of the named candidates they are. Never rank, never guess.
2. **The roster: ask explicitly who else is on the team.** A first-class question, not a
   by-product of the bootstrap — the bootstrap covers the *upgraded-repo* path (seed from what the
   repo already knows, then confirm); this question covers the *fresh-setup* path, where there is
   nothing to seed from. Both write the same shape: one **identity-free tier-2 placeholder per
   person named** — `people/<id>.yaml` holding `display_name:` and nothing more, per the scope
   invariant in [SKILL.md](SKILL.md).
   - **Placeholders are FILES, never folders.** Do not create empty `tickets/<name>/` directories:
     git cannot track an empty directory, so they silently vanish on clone, and the index renderer
     never prunes them. The person's ticket folder appears with their first ticket.
   - **Public-remote privacy warning, before any email is typed.** Phase 1's origin probe says
     whether the remote sits on a public code host — actual visibility cannot be established
     offline, so when it does, warn once and phrase it conditionally ("if this repo is public,
     prefer handles or short names over work emails as ids and display names"), the same
     convention `whoami --bind`'s own warning uses. Never claim to know the repo is public.

## Round 2 — Where work comes from

3. **Tracker** (detected options first) — or *none*, which selects the `local` tracker: the ticket
   folder itself. Choosing *none* sets `id_mode: slug` and `ticket_url_template: null`, and skips
   the key-prefix question.
   - **Offer ranked options, not a blank.** Call the tracker adapter's
     `rank_projects_by_activity` verb (auth plus an account-level scope is all it needs) and
     present the returned containers most-active-first — the adapter's `container_key:`
     frontmatter names which config key the chosen container fills. Where the verb reports
     `unsupported` or `unavailable`, **fall back silently to a plain question** — the ranking is a
     convenience, never an error to surface.
4. **Ticket key prefix** — the chosen container's key is the default. Skipped entirely for the
   `local` tracker, where the folder name is the id.
5. **`ticket_url_template`** — how every `tickets/INDEX.md` row links back to the tracker. A dead
   index link is the textbook silent-wrong failure: the catalog renders confidently either way.
   Derive it where the adapter's shape allows (an issues-style tracker needs the repo and the
   `{id}`/number token) and confirm; where it is not derivable, ask for it, and accept "no link"
   as `null`.
6. **`terminal_status`** — ask plainly ("What does your workflow call the done state — `Done`,
   `Closed`, something else?"). There is no tool-agnostic way to detect workflow states, so never
   phrase this as confirming a detected value.

`default_epic` is **not asked**: it is null-defaultable, most trackers have no epic concept, and a
parent id nobody has yet is noise. It stays a commented default in `stack.yaml`.

## Round 3 — Where the data lives

7. **Warehouse** (detected options first) — or *none*; non-data repos are fine, and the skills
   degrade cleanly.
8. **The chosen adapter's required keys** — tier-1 values only: which data the *team* reads.
   Never a named profile, connection, or local path — those are machine-tier values the person
   flow writes into `.claude/config/connections.local.yaml`; if detection surfaced one, display
   it and route it there.
9. **`dev_target`** — where dev DDL goes. This *is* a team value (target selection may never be
   personal), and its absence means dev work has no separate home from prod.
10. **More than one warehouse?** If yes, branch into the `targets:` shape —
    `stack.schema.md` § "Named targets" has the schema and a worked example ships as
    `stack.example.multi-warehouse.yaml`.

## Round 4 — Where work goes

11. **VCS — confirm, don't ask.** Phase 1 read `origin`, which yields the host, and the default
    branch from `git symbolic-ref refs/remotes/origin/HEAD`. Show the conclusion and let the
    person correct it.
12. **Docstore** (or *none*). Split the destination the way the tiers require: the **team folder
    identity** (e.g. `drive_folder` — which destination) is tier 1 and goes in `stack.yaml`; the
    **machine mount root** (where it is mounted on this machine) is tier 3. If Phase 1 detected a
    mount root, display it and route it to the person flow — never write it to `stack.yaml`.
    A team that cannot run a desktop sync agent is not stuck: the `rclone` adapter fills this slot
    with no mount at all (`remote_path` tier 1, the remote NAME tier 3). Mount install steps and the
    mountless route both live at <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>.
13. **Chat** (or *none*), then its destination — **per-adapter**: read the chosen adapter's
    frontmatter for the key its verbs interpolate as the default destination (adapters differ on
    the key name; one generic question writes the wrong key for one of them). Then
    **`always_include`** — the fixed stakeholder list every message carries (the "never solo-DM a
    stakeholder" rule). When chat is configured, this list must not be empty.
    - *This chat question is not final.* A later release adds per-target routing (multiple chat
      destinations with declared audiences); write the block as a plain single mapping so adding
      a `targets:` entry later is an extension, not a rewrite.
14. **Email — one question, covering both directions:** "Does email carry work *into* this team,
    *out* to stakeholders, both, or neither?" Never split intake and delivery into separate
    rounds — that reads as being asked about email twice.
    - **In (or both):** add `email` to `project.intake`. The consumer is `/ticket`'s priming
      step, which reads `source_materials/` for material a human dropped in — intake beyond the
      tracker arrives as files, not API calls.
    - **Add one more option to this same question, never a new one:** "…and does an AI notetaker
      (meeting notes or transcripts) carry work in?" The anti-split rule above is why it rides
      here — a separate meetings round reads as being asked about intake twice. A yes adds
      `meetings` to `project.intake`. Say what the convention is while you have their attention:
      export the notes or a curated excerpt to the ticket's `source_materials/` as
      `YYYY-MM-DD-<slug>-meeting.md`, trimmed to decisions and action items. Raw full transcripts
      stay out of git by default and are gated before any commit or docstore copy — mention that
      the gate reads filenames and document shape, **not meaning**, so it is not a substitute for
      reading what gets committed.
    - **Out (or both):** the email adapters ship (`adapters/chat/gmail.md` /
      `adapters/chat/outlook.md`), but activating email delivery means converting the chat slot
      to `targets:` form with a declared audience on EVERY target — a deliberate config change,
      not an interview side effect. So run the configuration questions now and record the
      answers: **which provider** (`gmail` | `outlook`), the **sending identity** (or shared
      mailbox — the adapters' `sender_key: identity`), and the **declared audience** plus its
      recipient list (which becomes that target's `always_include`). Write them into a commented
      `seams.chat.targets.email` block ending with a `# TODO` that names what is missing — the
      activation — and points at `stack.example.multi-audience.yaml` (the activated form). Say
      plainly, here and in the Phase-4 report, that email is **configured but not yet
      activated**: no draft will send until someone converts the slot.

## Round 5 — How you work (skippable)

**Offer the skip at this header, labeled with its cost:** "Skip this and `AGENTS.md` ships the
generic persona (`generalist`, `data analysis`) and lists no analysis tools."

15. **Role + domain, as one question** — and be honest about the blast radius: `role` fills
    exactly one token, `{{role_focus}}`, from a three-to-six-line `templates/roles/<role>.md`
    snippet; `domain` fills one word in one sentence. Nothing else reads either.
16. **Analysis tools** — "Which tools does the team do the actual analysis in?" (transformation
    frameworks, notebooks, spreadsheets, BI apps — whatever applies). Write the answer to
    `project.analysis_tools`, a tier-1 list rendered into `AGENTS.md` as descriptive context for
    the agent. It is **not a tool slot**: nothing verifies it and nothing executes from it. Do
    **not** add anything from this answer to `permissions.allow` — that file is runtime-specific,
    invisible to `verify_stack.sh`, and does not travel to a teammate's environment.

## Round 6 — House rules (skippable)

**Offer the skip at this header, labeled with its cost:** "Skip this and both policies keep their
shipped defaults — destructive warehouse SQL prompts only for high-risk statements, and
deliverables open for human sign-off at `/review` only."

17. **`db_write_requires_approval`** (`off` | `high_risk` | `all`) and
    **`human_review_handoff`** (`off` | `review` | `all`) — the two policies whose default is
    plausibly wrong for a given team. The other eight policies stay commented defaults with their
    "when to change this" notes; asking all ten is the wall the old question cap existed to
    prevent.

## Skipping a round

- **Per-round only.** Never offer a global "answer the first rounds and I'll take defaults for
  the rest" — offered up front, it asks the person to waive rounds they have not seen, and "took
  defaults" silently becomes indistinguishable from "chose".
- **A skip is written down twice**, so deferring is trackable:
  1. an explicit TODO line in `stack.yaml`, e.g.
     `# TODO(setup): round 5 skipped — role/domain/analysis_tools at defaults; finish with /setup role`
     (round 6: `# TODO(setup): round 6 skipped — policies at defaults; finish with /setup policies`);
  2. a **punch list** section in the Phase-4 report, one entry per skipped round, each naming its
     re-entry command.
- **Re-entry commands exist** — a promise with no mechanism is worse than no promise:
  `/setup role` re-runs round 5, `/setup policies` re-runs round 6, `/setup team` re-runs
  round 1's roster question (new teammates later), and `/setup tool <chat|docstore|warehouse>`
  adds a tool slot that was declined in rounds 3–4.

## What a completed interview writes (worked shape, fixture values)

```yaml
project:
  key_prefix: ENG
  assignee_dir: alice
  ticket_path: "tickets/{assignee}/{id}"
  terminal_status: Done
  ticket_url_template: "https://tracker.acme.example/browse/{id}"
  intake: [tracker, email, meetings]  # round 4: email + an AI notetaker carry work in
  role: analyst                       # round 5
  domain: data analysis
  analysis_tools: [notebooks, spreadsheets]
seams:
  tracker:
    tool: jira
    adapter: adapters/tracker/jira.md
    transport: cli
    site: tracker.acme.example        # asked because the adapter's requires: lists it
    cli: "<your tracker's CLI>"       # ditto — a deferred answer would be a `# TODO` here
    verify: null
  warehouse:
    tool: postgres
    adapter: adapters/warehouse/postgres.md
    transport: cli
    conn: "service=analytics"         # asked because the adapter's requires: lists it
    dev_target: analytics_dev         # round 3: dev DDL has a home
    verify: null
  docstore:
    tool: gdrive
    adapter: adapters/docstore/gdrive.md
    transport: cli
    drive_folder: "Shared drives/Tickets"   # tier 1: WHICH destination.
                                            # WHERE it is mounted is tier 3 (mount_root in
                                            # .claude/config/connections.local.yaml) — never here.
    verify: null
  chat:
    tool: slack
    adapter: adapters/chat/slack.md
    transport: mcp
    mcp: chatserver
    default_channel: C0XXXXXXXXX      # this adapter's destination key; others differ
    default_mode: draft
    always_include: [Alice]           # never empty when chat is configured
    verify: null
    # targets:                        # round 4: email delivery, configured but NOT YET ACTIVATED
    #   email:
    #     provider: gmail             # gmail | outlook
    #     identity: reports@acme.example
    #     audience: stakeholders
    #     always_include: [pm@acme.example]
    #     # TODO: not yet activated — nothing sends. Activating means converting this chat
    #     # slot to `targets:` form (a declared audience on EVERY target, `provider:` becomes
    #     # `tool:` + `adapter:`, `default_mode: draft` set explicitly on the email target).
    #     # The activated form is stack.example.multi-audience.yaml.
  vcs:
    tool: github
    adapter: adapters/vcs/github.md
    transport: cli
    default_branch: main              # round 4: confirmed from origin, not asked
    verify: null
policies:
  db_write_requires_approval: high_risk   # round 6 (or its # TODO(setup) line when skipped)
  human_review_handoff: review
```

Everything not shown stays exactly as the default-mode Phase 3 writes it today: optional blocks
commented, all remaining policies at their defaults with one-line "when to change this" notes.
