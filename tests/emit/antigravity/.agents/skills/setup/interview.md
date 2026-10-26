# The `/setup` interview — Phase 2, in rounds

Six rounds. **Rounds 1–4 always run; rounds 5–6 are individually skippable**, each skip labeled
with its cost at that round's header. Phase 1 detection has already produced the facts these
questions depend on, never ask something a probe already answered. How a question is shown (the
runtime's question tool, or a numbered list one at a time) and the option rules (recommended first,
"None / we don't have one", multi-select, "All of these", "Show more", nothing invented) are in
[SKILL.md](SKILL.md) § "How setup talks to the person"; this file says what to ask.

**The rounds are about the person's work, in their words.** Each round opens with one line saying
what it covers and why, and the questions name things the way a data team does. The mapping to the
kit's config is this file's job, never the person's:

| The person is asked | It configures |
|---|---|
| Who are you, and who else is on the team? (round 1) | `people/<id>.yaml`, the machine pin |
| How does work reach you? (round 2) | the tracker, `project.intake` |
| Where does your data live? (round 3) | the warehouse, its default, the dev target |
| How do you share results, and where are finished files kept? (round 4) | chat, docstore, VCS |
| What do you work on, and what has the team written down about it? (round 5) | `domain`, `team_docs` |
| When should I ask before acting? (round 6) | the two policies |

When an answer needs something the kit configures in a particular way (one meeting provider that
fetches notes automatically, say), set it up and say what was done in one plain line of the plan.
Never turn a kit limit into a choice the person must make ("only one of these can …").

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

One key deserves a precision note wherever it applies: a slot's **`mcp:` value must be the
runtime's exact tool prefix** — the `<name>` in `mcp__<name>__*` — because adapters render tool
names from it. **Read it from your own tool list; never ask the person to type it.** They see a
connector's display name, not its prefix, and a friendly name that matches no connected server
makes every rendered tool name point at nothing, with no error until a skill tries to call one.
When the connector is not connected yet, write `mcp: TODO` with a comment saying to connect it and
re-run `/setup tool <slot>`, and list it as a thing to finish.
Before writing it, check the adapter with
`bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" adapter_surface.py --adapter <path>`.
When it says this agent uses its own tool names, the adapter already names this agent's server
and the slot's `mcp:` value is not used here. Then keep an existing `mcp:` value (a teammate on
another agent needs it), and on a fresh repo write `mcp: TODO` with a comment naming the agents
that still need it. Never write this agent's own prefix there: the next teammate on another agent
would get tool names that point at nothing.
Never edit an adapter to match the tool names in this session: a name the command prints that the
session does not have is a gap to report for the kit, listed as a thing to finish.

## Suggestions from past usage (opt-in, counts only)

Ranking options by what the person actually uses saves them reading long lists, and it is also the
easiest way for setup to overreach. So it is one explicit question, asked once, the first time a
ranking would help (usually round 2):

<!-- ticketwright:user-facing:begin -->
Can I look at your recent activity to put the options you use most at the top? I'd only count which projects and datasets you've used recently. I won't read any messages, notes or file contents.
<!-- ticketwright:user-facing:end -->

- **Yes** → use only the counts-only verbs the adapters define for this
  (`rank_projects_by_activity` for the tracker today). A tool with no such verb gets no ranking:
  show its options in their natural order. Never improvise a usage query against a mailbox, a
  notes tool or a drive.
- **No** → plain lists. Nothing is lost: the person picks as usual.
- Either way, what setup reads during the interview stays names and counts. Message bodies, meeting
  notes and file contents are never read during setup, whatever the answer.

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
     `<identity>`. Who are you?", offering every id under `people/` plus "someone new"). On a
     fresh repo, recommend an id made from the git name (the first name, lowercased: "Alice
     Smith" → `alice`) as the first option, with free text for another; then
     `whoami.py --bind <id>`, and say what that saved: "I've noted who you are in a file on
     this machine that git ignores, and added you to the team list." Confirming-rather-than-asking describes the *resolved* path only;
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

## Round 2: How work reaches you

Open with: "First, how does work reach your team? This decides where tickets come from and what I
check when a new one starts."

3. **"How does work reach you?"** Multi-select: requests in a tracker (name each detected one:
   "Jira at <site>", "GitHub Issues on this repo", …), email, meeting notes or transcripts, chat
   messages, and "people just ask me (no tracker)". Recommend what detection found.
   - A tracker picked → that tool fills the tracker. More than one tracker picked → ask which one
     holds the tickets this repo works from; the others are noted as places requests also arrive
     (tracker routing is one tool per repo today; say so in one line of the plan, not here).
   - "People just ask me" with no tracker → the `local` tracker: the ticket folder itself. Set
     `id_mode: slug` and `ticket_url_template: null`, and skip the key questions below.
   - Email, meeting notes or chat picked → add each to `project.intake` (`email`, `meetings`,
     `chat`). Say what that means while you have their attention: drop the request into the
     ticket's `source_materials/` (meeting notes as `YYYY-MM-DD-<slug>-meeting.md`, trimmed to
     decisions and action items) and `/ticket` reads it when work starts. Raw full transcripts stay
     out of git by default and are checked before any commit or backup, mention that the check
     reads filenames and document shape, **not meaning**, so it is not a substitute for reading what
     gets committed.
   - **Meeting notes picked → one follow-up:** "Want tickets to point at a meeting by its id, so
     `/ticket` fetches the notes itself instead of someone exporting a file each time?" Offer each
     connected provider that has a meetings adapter, plus "No, we'll export notes by hand". A
     provider picked configures `seams.meetings` now (provider, adapter path, its required keys, a
     read-only `verify:`, `null` for an MCP-only transport, with the standard warning). One
     provider fetches automatically; if they use several, the one they use most is the recommended
     pick and the rest are exported by hand, say that in one plan line. A provider with no
     adapter is offered as "export by hand" only, never as if it fetched. The slot stays OPTIONAL
     and read-only; curated excerpts are committed, raw transcripts are not; `/setup tool meetings`
     adds or changes it later.
   - **MCP transport? surface the posture.** When the tracker's transport includes MCP, show the
     chosen adapter's "Permission posture (MCP)" section (the native control + the recommended
     setting) and carry its read-only probe's outcome into the Phase-4 report next to that slot's
     verify_stack result. A tracker connector's grant is not introspectable in-session, so the
     outcome caps at the recorded third state, say where a human confirms it.
4. **Which project holds the tickets?** Always from the tracker's own list, never invented. Call
   the tracker adapter's `rank_projects_by_activity` verb (with the person's yes from § Suggestions
   from past usage; without it, its listing step alone). Its first step lists the projects; show
   them **even when no activity is found**, most active first when ranked, otherwise as listed,
   with "Show more" past the limit. The adapter's `container_key:` frontmatter names which config
   key the chosen project fills (the ticket key prefix, for Jira). Where the verb reports
   `unsupported` or `unavailable`, ask plainly and **check a typed key against whatever the tracker
   can list** before writing it. A key that is not in the tracker yet gets: "I don't see <KEY> on
   <site>. Create it first and I'll check again, or pick one that exists?" Write it only if they
   say it will exist, with a `# TODO` and an item in the Phase-4 list.
5. **`ticket_url_template`** — how every `tickets/INDEX.md` row links back to the tracker. A dead
   index link is the textbook silent-wrong failure: the catalog renders confidently either way.
   Derive it where the adapter's shape allows (an issues-style tracker needs the repo and the
   `{id}`/number token) and confirm it as the recommended option; where it is not derivable, ask
   for it, and accept "no link" as `null`.
6. **`terminal_status`**: "What does your workflow call a finished ticket?" Offer `Done`,
   `Closed`, `Resolved` and free text. There is no tool-agnostic way to detect workflow states, so
   never phrase this as confirming a detected value.

`default_epic` is **not asked**: it is null-defaultable, most trackers have no epic concept, and a
parent id nobody has yet is noise. It stays a commented default in `stack.yaml`.

## Round 3: Where your data lives

Open with: "Next, where your data lives. This decides where queries run and where test tables go so
they never touch real data."

7. **"Where does your data live?"** Multi-select, detected warehouses first (each with what was
   detected, e.g. "command-line tool signed in"), plus "No database, we work from files". None is
   fine: non-data repos work, and the skills skip query re-runs cleanly.
   - **More than one picked** → the `targets:` shape (`stack.schema.md` § "Named targets", worked
     example `stack.example.multi-warehouse.yaml`), then ask **"Which do you use most?"** for the
     default (listed first).
   - **One target per connection, not per dataset.** A configured dataset / catalog / schema is
     only where *unqualified* table names resolve: any other dataset on the same connection is still
     reachable by its full name. Say that in one line, then ask which one they use most for the
     default. Add a second target only when the connection itself differs (another account,
     workspace or project the CLI reaches separately), never one per catalog.
   - **MCP transport? surface the posture.** When the warehouse's transport includes MCP, show the
     chosen adapter's "Permission posture (MCP)" section, for a warehouse the probe is a real
     read-only privilege introspection with a written comparison rule, so its outcome is worth
     carrying into the Phase-4 report next to that slot's verify_stack result.
8. **The chosen adapter's required keys.** Tier-1 values only: which data the *team* reads. Offer
   them from the warehouse's own read-only listing where the CLI can list (projects, datasets,
   catalogs, SQL warehouses), with "Show more" and free text; never invent one. A listing that
   fails (an expired login) is a "sign in, then I'll list them" step with the exact sign-in command
   the adapter's auth notes give, **not** a request to type IDs by hand. Never a named profile,
   connection, or local path in `stack.yaml`, those are machine values the person flow writes
   into `.claude/config/connections.local.yaml`; if detection surfaced one, display it and route it
   there.
9. **`dev_target`**: "Where should test tables go, so test work never touches real data?" This
   *is* a team value (target selection may never be personal). Options: a listed dev dataset /
   schema if one exists, free text, and **"We don't have one"**, which writes `dev_target: null`
   with the comment `# no dev environment: on purpose, not a TODO` so nobody later reads it as
   forgotten.

## Round 4: How you share results, and where files are kept

Open with: "Last of the required questions: how finished work leaves your hands. Nothing is ever
sent without you seeing it first."

10. **"How do you share results with the people who asked?"** Multi-select: each detected chat
    or email tool ("Slack", "Microsoft Teams", "Gmail", "Outlook", whichever are connected or
    detected), plus "A shared folder only", "A pull request only", and "We don't share from here".
    Who receives a result, and where, varies per analysis, so **never ask for a standing channel or
    a fixed recipient list** here: the destination and recipients are chosen per result at `/ship`
    and recorded in that ticket's `delivery-plan.yaml`, and `/ship` stops and asks when a ticket
    has none. Write what they picked:
    - **One tool** → a tool-only single mapping: tool + transport + the adapter's required
      connection keys, `default_mode: draft`, no `default_channel`, no `always_include`.
    - **Two or more tools** → the `targets:` shape with one target per tool, each marked
      `destination: per_ticket` (chosen per ticket, never a standing destination), each with its
      own `audience:` naming the tool (`email`, `slack`, `teams`), `default_mode: draft` on every
      target, and the adapter's sender key where it declares one (ask the email tools' **sending
      identity**: "Which mailbox should drafts come from?", offering the addresses detection saw
      plus free text). `default:` is the one they use most. The ticket's delivery plan names the
      audience, so each result goes out through the tool that ticket chose.
    - **Email alone** → the same single mapping, with `identity:` and `default_mode: draft` set
      explicitly, because an email cannot be unsent.
    - A team that genuinely wants **fixed, pre-declared audiences** (internal channel vs client
      mailbox, each with its own standing recipient list) adopts the standing-destination form in
      `stack.example.multi-audience.yaml`, an extension, never the interview's default.
    - **MCP transport? surface the posture.** When a chosen tool's transport includes MCP, show its
      adapter's "Permission posture (MCP)" section and carry its read-only probe's outcome into the
      Phase-4 report next to its verify_stack result. A chat connector's grant is not
      introspectable in-session, the posture record caps at the third state and the draft/send
      policies stay guidance on that path; the section names the settings surface where a human
      confirms the grant.
11. **"Where should finished files be kept?"** (the docstore, or *none*): a synced drive folder,
    a cloud folder reached without a desktop app, or "Just this repository". Split the answer the
    way the tiers require: the **team folder** (e.g. `drive_folder`, which destination) is tier 1
    and goes in `stack.yaml`; the **mount root** (where that drive sits on this machine) is tier 3.
    - **Offer folders that exist.** A new folder in a shared drive is visible to everyone the
      drive is shared with: say so on that option. Ask once before looking inside someone's drive ("Can I list the
      folders at the top of your drive to pick from?"), then list **folder names only**, never file
      names; offer "Create a new folder: <name>" as an option they type. Folder names can't contain any of
      `;` `|` `&` `$` `<` `>` `(` `)`, a backslash or a backtick, check a typed name now and offer a clean spelling ("Sales and Ops
      Tickets") rather than finding out after the files are written.
    - If Phase 1 found a mount root, display it and route it to the machine file, never to
      `stack.yaml`. A team that cannot run a desktop sync agent is not stuck:
      the `rclone` adapter fills this slot with no mount at all (`remote_path` tier 1, the remote NAME tier 3). Mount
      install steps and the mountless route both live at
      <https://github.com/kyle-chalmers/ticketwright/blob/main/docs/drive-mount.md>.
    - The same offer applies when the stack is *already* configured but `mount_root` cannot be
      resolved on this machine, the sync agent isn't installed, or (increasingly common) it needs
      an IT device approval that hasn't landed yet. Don't dead-end there: offer the mountless route
      on the spot, the `rclone` adapter fills this slot with no mount, same tier split as above,
      and note they can switch back to the mounted slot once the approval comes through.
12. **Code hosting, confirm, don't ask.** Phase 1's probe gave the origin host and the default
    branch (and whether that branch came from the remote or is the current branch because nothing
    has been pushed). Show the conclusion as the recommended option and let the person correct it.
    No remote yet: confirm the host they intend to use, and leave the remote for later unless they
    already said yes to creating one in Phase 1.

Older configs and the commented email block: a repo set up before per-ticket targets existed may
carry a commented `seams.chat.targets.email` block whose header says email is **configured but not
yet activated**, with the provider, sending identity and audience recorded. When you meet one, offer
to activate it in the current form (a `destination: per_ticket` target, as above) and point at
`stack.example.multi-audience.yaml` for the standing-destination alternative; never activate it
silently. Ask for each chosen adapter's required keys as you go (gmail and outlook both declare a
sender key).

## Round 5 — How you work (skippable)

**Offer the skip at this header, labeled with its cost:** "Skip this and `AGENTS.md` ships the
generic domain (`data analysis`) and lists no team standards or context docs."

**The default interview never asks for a role.** `project.role` stays `generalist`. The role
picks only the persona paragraph in `AGENTS.md` (the `{{role_focus}}` token, from a
three-to-six-line `templates/roles/<role>.md` snippet), and the review checks those paragraphs
mention already run for every role, so the question costs more than it changes. It is a team
setting, not a personal one. A team that wants a sharper persona sets it with `/setup role`,
which asks question 13a and then re-runs this round.

13. **Domain**: "In a few words, what does the team analyze?" (free text, `data analysis` when
    left blank). Be honest about the blast radius: `domain` fills one word in one sentence of
    `AGENTS.md`. Nothing else reads it.

    13a. **Role (only under `/setup role`)**: "What kind of work does this repo mostly do?",
    with the roles as options: **Generalist** (recommended, the default), **Analyst**
    (questions answered with queries, metrics and reports), **Engineer** (pipelines, models,
    data infrastructure), **Scientist** (experiments, statistics, modeling). Ask about the
    repo's work, not the person: the answer is committed team config that every teammate
    gets. Write it to `project.role`.
14. **Standards** (optional): "Does your team have written rules for how analysis is done here,
    such as a style guide, a review checklist or metric conventions? Paste links or paths." Offer
    **None yet** first, as an ordinary answer. Detection may suggest files it found in the repo
    (under `docs/` or `documentation/`, a contributing guide); confirm each one rather than
    assuming it is a standard. Say what the answer does: `/build` follows these docs, and
    `/review` checks deliverables against them, reporting a broken rule as a finding.
15. **Team context** (optional): "Is there anything else written down that the agent should know
    about the team or its data, such as a team wiki, onboarding notes, a data dictionary or
    metric definitions?" Offer **None yet** first. Say what the answer does: `/ticket` reads
    these while planning, and nothing is graded against them.

    For both: a link is read live each time it is needed, so there is one source of truth and
    nothing is copied into the repo. Say plainly that each teammate needs access to a linked doc,
    and that a doc the agent cannot open is reported as unreadable, never as checked. Write the
    answers to `project.team_docs.standards` and `project.team_docs.context`, each item a path or
    URL, or `{location: …, note: <a few words>}` when the link does not say what it is.
    `bin/team_docs.py` is the one reader of this key.

    The old analysis-tools question is gone: a tool name told the agent little, and "we build
    metrics in dbt" belongs in the standards doc, with its reason. `project.analysis_tools` still
    renders for repos that have it; setup no longer writes it.

## Round 6 — House rules (skippable)

**Offer the skip at this header, labeled with its cost:** "Skip this and both policies keep their
shipped defaults — destructive warehouse SQL prompts only for high-risk statements, and
deliverables open for human sign-off at `/review` only."

16. **`db_write_requires_approval`** (`off` | `high_risk` | `all`) and
    **`human_review_handoff`** (`off` | `review` | `all`) — the two policies whose default is
    plausibly wrong for a given team. The other eight policies stay commented defaults with their
    "when to change this" notes; asking all ten is the wall the old question cap existed to
    prevent. Ask them in plain words, with the options already explained, so the person never has to
    ask what one means:
    - "When should I ask you before changing data in your warehouse? Reading data never asks."
      - **Before risky changes** (recommended, `high_risk`): asks before anything that changes or
        removes existing data or permissions (updating or deleting rows, dropping or replacing
        tables, changing columns, granting access) and before anything it can't recognize. Adding
        new things (creating a new table, inserting rows) runs without asking.
      - **Before any change** (`all`): also asks before creating tables or inserting rows.
      - **Never** (`off`).
      Say where the check applies: commands run in the terminal. A database connector inside the
      AI app follows that connector's own permissions instead.
    - "When should finished files open on your screen for you to look over?"
      - **At the final check** (recommended, `review`): the SQL and CSV deliverables open once,
        when `/review` finishes, for your sign-off.
      - **Every time** (`all`): also while building (each query before its first run, each
        export after it's written).
      - **Never** (`off`): you open files yourself.

## Skipping a round

- **Per-round only.** Never offer a global "answer the first rounds and I'll take defaults for
  the rest" — offered up front, it asks the person to waive rounds they have not seen, and "took
  defaults" silently becomes indistinguishable from "chose".
- **A skip is written down twice**, so deferring is trackable:
  1. an explicit TODO line in `stack.yaml`, e.g.
     `# TODO(setup): round 5 skipped — domain/team_docs at defaults; finish with /setup role`
     (round 6: `# TODO(setup): round 6 skipped — policies at defaults; finish with /setup policies`);
  2. a **punch list** section in the Phase-4 report, one entry per skipped round, each naming its
     re-entry command.
- **Re-entry commands exist** — a promise with no mechanism is worse than no promise:
  `/setup role` asks the role and re-runs round 5, `/setup policies` re-runs round 6, `/setup team` re-runs
  round 1's roster question (new teammates later), and `/setup tool <tracker|warehouse|chat|docstore|meetings|vcs>`
  adds a tool slot that was declined in rounds 3–4.

## What a completed interview writes (worked shape, fixture values)

```yaml
project:
  key_prefix: TEST
  assignee_dir: alice
  ticket_path: "tickets/{assignee}/{id}"
  terminal_status: Done
  ticket_url_template: "https://tracker.acme.example/browse/{id}"
  intake: [tracker, email, meetings]  # round 2: email + meeting notes also carry work in
  domain: data analysis               # round 5 (role is not asked; generalist unless /setup role)
  team_docs:                          # round 5, both lists optional
    standards:
      - location: https://wiki.acme.example/analytics/sql-style
        note: SQL style guide
    context: [docs/metric-definitions.md]
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
  # chat — TOOL-ONLY: the tool + transport, no standing destination. The destination + recipients
  # are declared per-communication in each ticket's delivery-plan.yaml (chat.channel + recipients),
  # asked at /ship; routing halts when a ticket declares none.
  chat:
    tool: slack
    adapter: adapters/chat/slack.md
    transport: mcp
    mcp: chatserver
    default_mode: draft               # policy, not a destination — the draft/send default stays here
    verify: null
    # Two or more ways of sharing results → `targets:` with one `destination: per_ticket` target per
    # tool instead (round 4, item 10); one tool stays this single mapping.
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
