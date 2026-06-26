---
seam: tracker
tool: github-issues
transport: cli         # `gh issue` (GitHub CLI); REST/GraphQL as fallback
requires: [repo]       # stack.yaml seams.tracker.{repo, done_label?}  (repo = "owner/name")
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

## gotchas
- Ids are bare numbers — `fetch_ticket` takes `123`, not `PROJ-123`.
- "Status" is open/closed unless you adopt a Projects Status field or label convention — set
  `done_label` (or map terminal_status → closed) so `transition` is unambiguous.
