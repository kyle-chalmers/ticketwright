# Is this ticket a repeat? (the shared skillify check)

One decision, used in three places so none of them can skip a step: `/ticket` Phase 4 (the plan),
`/ship`'s retro, and the closing message of any session that worked a ticket. The second time a
team does the same analysis is the time to suggest a skill: by the third, the work has already
been copied twice. A suggestion is all this produces. It never runs `/skillify` itself.

## Run the check

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" recall.py --for <owner>/<id> --repeats --json
```

While scoping, before the ticket has SQL, add the fetched ticket text: `--text-file -` with the
description on stdin. The result is then `"strength": "provisional"` (tables read from the text);
once the ticket's SQL exists it is `"confirmed"` (tables read from `from`/`join` in the SQL, not
counting QC queries or the tables the ticket writes).

`repeats` lists the earlier tickets (as `<owner>/<id>`) that read **exactly the same set of
tables**. A ticket that reads one more or one fewer table is not on the list.

## Decide, in this order

1. **`suggest` is false: say nothing.** Either there is no earlier ticket on the same tables, or
   the team turned the suggestion off (the `skillify_everything` policy).
2. **Confirm the deliverable shape.** For each ticket in `repeats`, read its plan's Deliverables
   section and its final SQL. It is the same analysis only when the grain and the output are the
   same and what changed is parameter values (a date window, a top-N, a region). Same tables but a
   different question is not a repeat: say nothing.
3. **Check the skills it names.** For each entry in `skill_candidates`, read that skill's
   description and parameters. If one produces this deliverable, recommend running it instead
   (say which parameters this ticket would pass) and do not suggest `/skillify`. A candidate that
   reads the same tables but produces something else does not count. `match: provenance` means
   the skill was built from one of these tickets, which makes it likely but not certain.
4. **Otherwise suggest `/skillify`**, naming the pattern and the instance, and pass the
   `repeats` tickets plus this one as the skill's `built_from:` list (always `<owner>/<id>`).

Report a `notes` entry to the person when it names a skill whose `built_from:` could not be
matched to one ticket: that skill may be the one that fits.

## What to say

In a plan (`/ticket`), under **Builds on** and **Next step**:

<!-- ticketwright:user-facing:begin -->
> This is the 2nd instance of top videos by early views (after dana/TEST-5).
> After /ship: `/skillify top videos by early views` (a suggestion, not part of this plan).
<!-- ticketwright:user-facing:end -->

When a skill already does it:

<!-- ticketwright:user-facing:begin -->
> `/top-videos` already does this. Run it with the new window instead of rebuilding the query.
<!-- ticketwright:user-facing:end -->

At `/ship`'s retro, ask with the choices **Skillify it now** and **Not now**:

<!-- ticketwright:user-facing:begin -->
> This repeats dana/TEST-5. Skillify it?
<!-- ticketwright:user-facing:end -->

In a session's closing message, one line: the same suggestion or pointer, or nothing.
