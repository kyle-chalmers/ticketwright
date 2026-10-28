---
seam: vcs
tool: gitlab
transport: cli         # git + `glab` CLI
requires: [default_branch]   # stack.yaml seams.vcs.{default_branch, semantic_pr, worktree_root}
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  git credentials in keychain/credential-helper; `glab auth login` for merge requests.
  Verify: `glab auth status`.
---

# GitLab adapter

Maps the `vcs` verb contract to git + the GitLab CLI. Merge Requests (MRs) replace PRs; otherwise the
flow mirrors GitHub. Branch = ticket id; MR titles are semantic.

## verb: branch
```bash
git fetch origin {default_branch}
git switch -c <TICKET-ID> --no-track origin/{default_branch}   # branch name IS the ticket id
```
This never checks out `{default_branch}` itself. In a linked worktree (where agent apps start
sessions by default) that branch is already checked out in the main checkout, and git refuses
a second checkout of it. With no remote yet, branch from the local one:
`git switch -c <TICKET-ID> {default_branch}`.

## verb: worktree   (isolates one ticket from other work in flight)
```bash
git worktree add "{worktree_root}/<name>" -b <TICKET-ID>
```
Skip this verb when the session already runs in a linked worktree (`kit_paths.py --json` reports
`worktree.linked: true`): that worktree already isolates the ticket, so use `branch` in place
rather than nesting a second worktree inside it.

## verb: commit
Stage only files you changed (never `git add .`); semantic message + trailer.
```bash
git add <paths>
git commit -m "$(cat <<'EOF'
<type>: <TICKET-ID> <description>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Types: feat, fix, docs, refactor, chore, test, ci. Small atomic commits per build step. Commit the
plan/spec artifact before implementing (policy `commit_plan_before_implement`).

## verb: open_pr
```bash
glab mr create --title "<type>: <TICKET-ID> <description>" \
  --description "Business Impact / Deliverables / Technical Notes / QC Results" \
  --target-branch {default_branch} --remove-source-branch
```
`semantic_pr: true` ⇒ keep the title semantic if a pipeline lint enforces it. Honor `word_limits.pr`.
External action ⇒ requires approval (policy `hard_halt_before_external_posts`).

## verb: merge_pr
**In:** the MR number from `open_pr`, and the commit sha `/ship` pushed.
```bash
glab mr merge <MR-NUMBER> --squash --sha <SHA> --auto-merge=false --yes
glab mr view <MR-NUMBER> --output json   # verify: "state": "merged"
```
Squash is the kit's merge style: one commit per ticket on `{default_branch}`. `--sha` refuses the
merge if anything was pushed after the person confirmed it. `--yes` only skips `glab`'s own prompt,
because `/ship` already asked right before this step (policy `ship_merges_pr`). External action ⇒
requires approval (policy `hard_halt_before_external_posts`). When required approvals, a pipeline,
a merge train or a conflict blocks it, report what `glab` says and stop. `--auto-merge=false` is
required, not decoration: `glab` turns auto-merge ON by default while a pipeline runs, so without
it the command can schedule the merge, exit 0 and leave the MR open. If the verify line does not
say `merged`, the merge did not happen: treat it as blocked.

## gotchas
- `glab` needs the host set for self-managed GitLab: `glab auth login --hostname <gitlab.company.com>`.
- MR approvals/merge-trains may gate the merge — surface required approvals rather than forcing.
