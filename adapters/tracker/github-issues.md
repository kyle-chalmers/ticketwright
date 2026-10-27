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
gh issue view <number> --repo {repo} --json number,title,body,state,assignees,author,labels,milestone,url
```
**People, for `/ship`'s audience suggestions:** `reporter` is `author.login`. `watchers`: not available (`gh` does not list an issue's subscribers).

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
Take the target from a move `list_transitions` returned (its `via` is what this call needs), never a
status typed from memory: the moves differ per workflow.

## verb: list_transitions
**In:** issue number. **Out:** `{current, transitions: [{to, via, category}], free_form: false}`
(shape in `adapters/README.md` § tracker).
```bash
gh issue view <number> --repo {repo} --json state,stateReason
```
An issue has two states, so there is one move at a time: `to` is the state it lands in and `via`
the `gh issue` subcommand that makes it. `OPEN` gives `{to: "closed", via: "close", category:
"done"}`; `CLOSED` gives `{to: "open", via: "reopen", category: "todo"}`. `current` is `open` or `closed`, in
lower case, so set `project.terminal_status: closed` for this tracker. A team that tracks progress
through labels or a Projects board has no workflow `gh issue` can read: say so rather than listing
labels as statuses.

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

**By `ids`** (the index status read): `gh issue view <number> --repo {repo} --json
number,title,state` per number, or for a long list one `gh issue list --repo {repo} --state all
--limit 1000 --json number,title,state` filtered to the numbers asked for.

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
