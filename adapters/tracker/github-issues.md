---
seam: tracker
tool: github-issues
transport: cli         # `gh issue` (GitHub CLI); REST/GraphQL as fallback
requires: [repo]       # stack.yaml seams.tracker.{repo, done_label?}  (repo = "owner/name")
container_key: seams.tracker.repo   # which config key a ranked container fills (see rank_projects_by_activity)
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  `gh auth login` (or `GH_TOKEN`). Verify: `gh auth status`.
note: |
  GitHub Issues ids are per-repo integers (#123), so `key_prefix` is a branch/index display
  convention, not part of the id — set `ticket_url_template` to use the `{number}` token and pass the
  bare number to `gh issue`. "Epic" ≈ a tracking issue, a **milestone**, or a Project; "status"
  ≈ open/closed (+ optionally a Projects "Status" field or a label). If the same repo hosts code,
  this pairs naturally with the `vcs: github` adapter.
---

# GitHub Issues adapter

Maps the `tracker` verb contract to GitHub Issues via `gh`.

## verb: fetch_ticket
**In:** issue number. **Out:** title, body (markdown), state, assignees, labels, milestone.
```bash
gh issue view <number> --repo {repo} --json number,title,body,state,assignees,labels,milestone,url
```

## verb: create_ticket
```bash
gh issue create --repo {repo} --title "<summary>" --body "<markdown>" \
  --assignee "<login>" --label "<type>" --milestone "<epic>"
```
Returns the new issue URL (number is the id). Epic → `--milestone` or a parent tracking issue.

## verb: transition
```bash
gh issue close <number> --repo {repo}                       # map terminal_status → closed
gh issue edit <number> --repo {repo} --add-label "{done_label}"   # if you track status via labels/Projects
```

## verb: comment
```bash
gh issue comment <number> --repo {repo} --body "<markdown>"
```
Full markdown links render. Honor `word_limits.tracker_comment`; never post before human review.

## verb: search
```bash
gh issue list --repo {repo} --search "<query>" --state all --limit <n> \
  --json number,title,state
```
`--search` takes GitHub's issue search syntax (`is:open label:bug ...`).

## verb: search_history
Older tickets that look like some text, in one fixed shape. This is the tool-neutral twin of `search`,
which takes GitHub's own search syntax: the caller never writes a query. Read-only.
**In:** `<text>` (plain words), `<before>` (an ISO date, or empty for no cutoff), `<scope>` (the repo as
`owner/name`, default `{repo}`), `<limit>` (default 20), `<filter>` (optional, exactly one of
`project:<x>`, `label:<x>`, `parent:<x>`, `person:<x>`). **Out:** a JSON list of `{key, fetch_id, title,
description, labels, created, url, status}`, at most `<limit>` rows, `[]` when nothing matches.
`description` is cut to 600 characters, `labels` is a list of strings, `created` is an ISO date or `null`.
```bash
gh issue list --repo <scope> --search "<text> created:<<before>" --state all --limit <limit> \
  --json number,title,body,labels,createdAt,url,state
```
`created:<<before>` is `created:<` followed by the date, so a `<before>` of 2024-01-31 reads
`created:<2024-01-31`. An empty `<before>` means no date clause: drop `created:<<before>` from the search
string. Keep `<text>` to plain words: remove anything shaped like `word:`, which GitHub would read as a
search qualifier. `--state all` matters, since `gh issue list` shows open issues only by default.

Filters: `project:<x>` replaces `<scope>` (`--repo <x>`, an `owner/name`); `label:<x>` adds `--label "<x>"`;
`parent:<x>` adds `--milestone "<x>"`, with `<x>` a milestone title (the epic stand-in here: a tracking
issue's sub-issues cannot be searched this way, so a parent is always a milestone); `person:<x>` adds
`involves:<x>` to the search string (`<x>` is a GitHub login).

If `gh` is not signed in, the repo cannot be reached, or the tracker rejects the search, say so in one
plain sentence and return `[]`.

Output mapping: `key` is `{key_prefix}-<number>` (the branch and folder convention in the note above, `TEST-130`) and
`fetch_id` is the bare issue `number` (`130`), which is what `fetch_ticket` takes; `title` is `title`;
`description` is `body`; `labels` is the `name` of each entry in `labels`; `created` is `createdAt` cut to
`YYYY-MM-DD`; `url` is `url`; `status` is `state`. When `{key_prefix}` is unset, `key` is the bare number,
the same as `fetch_id`, so duplicate suppression still compares like with like.

## verb: download_attachments
GitHub stores issue attachments as URLs embedded in the body/comments. Parse them
(`gh issue view --json body,comments`), then `curl -L "<url>" -o <dest>/<name>` (silent if none).

## verb: rank_projects_by_activity
The ranked container is a **repo** under an owner — not a GitHub Project. **In:** `scope` (the owner
or org; there is no `owner` key in the seam, so split it off `repo`'s `owner/name` when one is
already configured), `window_days` (90), `limit` (5), `scan_cap` (200), `container_cap` (25).
**Out:** `{id, name, activity, last_activity, signal}` per repo, most active first, `id` = `owner/name`,
`signal: items_updated`.
```bash
gh search issues "updated:>=<YYYY-MM-DD>" --owner <scope> --limit <scan_cap> \
  --sort updated --order desc --json repository,updatedAt
```
`--owner` accepts a user **or** an organization; the `org:` search qualifier does not, and would
silently return nothing for a personal account.
One call: each hit already names its repo, so group client-side rather than looping repos.
**`--sort updated` is not optional.** `gh search issues` defaults to *best-match* relevance, so on an
org with more than `scan_cap` matching issues the truncated sample is an arbitrary slice — it can
omit the busiest repo entirely, which is the exact failure this verb exists to prevent. With the
sort, a saturated scan is at least the most recent `scan_cap` issues. Fall back
to enumerating first only when the search is unavailable:
```bash
gh repo list <scope> --source --no-archived --limit <container_cap> --json nameWithOwner
gh issue list --repo <owner/name> --state all --search "updated:>=<YYYY-MM-DD>" \
  --limit <scan_cap> --json number,updatedAt
```
`gh repo list` includes forks and archived repos by default — `--source --no-archived` is what keeps
dead mirrors out of the ranking. `gh issue list` defaults to open issues, so **`--state all`
matters**: a repo whose recent work all shipped and closed otherwise reads as dead.

Picking a repo sets `seams.tracker.repo`. It does **not** settle `done_label` — that depends on
whether the repo tracks status by label, by Projects field, or by open/closed.

Return `unavailable` with the reason when `gh auth status` fails or the token lacks org read scope.

## gotchas
- Ids are bare numbers — `fetch_ticket` takes `123`, not `TEST-123`.
- "Status" is open/closed unless you adopt a Projects Status field or label convention — set
  `done_label` (or map terminal_status → closed) so `transition` is unambiguous.
