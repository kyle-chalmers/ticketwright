---
seam: tracker
tool: github-issues
transport: cli         # `gh issue` (GitHub CLI); REST/GraphQL as fallback
requires: [repo]       # stack.yaml seams.tracker.{repo, done_label?}  (repo = "owner/name")
container_key: seams.tracker.repo   # which config key a ranked container fills (see rank_projects_by_activity)
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
gh search issues "org:<scope> updated:>=<YYYY-MM-DD>" --limit <scan_cap> \
  --json repository,updatedAt
```
One call: each hit already names its repo, so group client-side rather than looping repos. Fall back
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
- Ids are bare numbers — `fetch_ticket` takes `123`, not `ENG-123`.
- "Status" is open/closed unless you adopt a Projects Status field or label convention — set
  `done_label` (or map terminal_status → closed) so `transition` is unambiguous.
