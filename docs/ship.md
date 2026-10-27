# What /ship does, step by step

`/ship` is the one skill that reaches outside your repo: it opens and merges a pull request, backs
the ticket up to your documents tool, comments on the ticket and drafts the chat message. This page
shows every step in the order it runs, what each one needs from the step before it, and the three
moments it waits for you.

![/ship in order. Before the go-ahead, inside your repo: 1 check who is shipping and that /review approved the work, 2 re-run the final queries, 3 tidy the files and refresh the ticket index, 4 pick where it goes and draft the comment and chat message with link placeholders. Hard halt: you read the delivery plan and say go ahead. After the go-ahead, in your tools: 5 commit, push and open the pull request, 6 merge the pull request (squash), after asking you first, 7 back up the ticket folder with unsent drafts left out, 8 comment on the ticket with links to the backup and the pull request, 9 draft the chat message with the same links, 10 move the ticket's status only once the pull request is merged. The PR link from step 5 and the file links from step 7 feed steps 8 and 9. With ship_merges_pr set to false the team merges by hand, step 6 is skipped and step 10 waits. Then, every time: 11 a short retro and 12 voice tuning, both proposals only.](https://raw.githubusercontent.com/kyle-chalmers/ticketwright/main/docs/images/ship-steps.png)

## The steps, in order

**Before the go-ahead.** Everything here stays inside your repo.

1. **Check who is shipping, and the review result.** An approval from `/review` lets the ship
   continue. Requested changes send you back to `/build`. With no review on file, `/ship` asks you
   to type `ship unreviewed`, and records that you did.
2. **Re-run the final queries.** The results must match the committed files exactly.
3. **Tidy the files and refresh the ticket index**, so the ticket is findable later.
4. **Pick where it goes, then draft.** The ticket's delivery plan decides which chat channel,
   recipients and documents folder it goes to; when it doesn't say, `/ship` asks you rather than
   guessing. The tracker comment and chat message are drafted now, with placeholders where the
   pull request and backup links will go.

**The hard halt.** `/ship` prints the delivery plan: every destination, every recipient, whether
it will merge, and the steps below. Nothing happens until you reply `go ahead`.

**After the go-ahead.**

5. **Commit, push and open the pull request.** Setup files changed along the way get their own
   commit on the same pull request.
6. **Merge the pull request, after asking you once more.** You choose **Merge now** or **Leave it
   open**. A merge is squashed into one commit on the main branch. If branch rules, a required
   review, a failing or unfinished check, or a conflict blocks it, `/ship` stops and tells you why,
   before anything is backed up or posted. It never uses an option that bypasses those rules.
7. **Back up the ticket folder** to your documents tool (Google Drive, SharePoint, or anything
   rclone reaches). It runs after the merge, so what is shared is the merged work. A raw meeting
   transcript in the folder stops the backup until you remove it or approve it. The unsent drafts
   in `comms/` are left out.
8. **Comment on the ticket**, with links to the backed-up files and the pull request.
9. **Draft the chat message** for the recipients in the plan, with the same links. It stays a
   draft for you to send, unless you said "send it".
10. **Move the ticket toward done**, only when the pull request merged. If it was left open, the
    status stays where it is.

**Then, every time.**

11. **A short retro.** If something went wrong, `/ship` names which part of the setup to fix.
12. **Voice tuning.** If you edited the drafts, it proposes how your voice profile could learn from
    the edits, and saves nothing until you confirm.

## Why this order

Each post links to something an earlier step creates, so the step that creates it runs first:

| Link | Created by | Used by |
|---|---|---|
| The pull request | step 5 | the comment (8) and the chat message (9) |
| The backed-up files | step 7 | the comment (8) and the chat message (9) |

The merge sits between them for two reasons. The backup should hold the merged, final work rather
than a branch that might still change. And when the merge is blocked, the ship stops before
anyone has been told the work is done.

## What you approve, and when

| Moment | What you say | What it covers |
|---|---|---|
| The delivery plan | `go ahead` | everything in the plan, in that order |
| Right before the merge | **Merge now** or **Leave it open** | landing the work on the main branch |
| The chat draft | "send it" (optional) | sending instead of leaving a draft |

The `review_verdict_guard` hook adds one more check outside `/ship`: it asks before any push, pull
request or merge of a ticket that has deliverables and no approving review on file.

## Merging by hand instead

Teams that review and merge pull requests themselves set this in `stack.yaml` (`/setup policies`
asks it):

```yaml
policies:
  ship_merges_pr: false
```

The delivery plan then says the merge is yours, `/ship` skips step 6, and the ticket is not moved
to done while its pull request is open. A missing setting means `/ship` merges after asking. A
value it cannot read means it doesn't merge, so a typo never adds a step you didn't choose.
