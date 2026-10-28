---
seam: vcs
tool: azure-repos
transport: cli         # git + `az repos` (Azure CLI + azure-devops extension)
requires: [default_branch]   # stack.yaml seams.vcs.{default_branch, semantic_pr, worktree_root, org, project, repo}
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  `az login` + `az extension add --name azure-devops`; git creds via Git Credential Manager or a PAT.
  Set defaults: `az devops configure --defaults organization=https://dev.azure.com/{org} project={project}`.
  Verify: `az repos list --query "[].name"` (or `az devops project show`).
---

# Azure Repos adapter

Maps the `vcs` verb contract to git + the `az repos` CLI (Azure DevOps Pull Requests). Mirrors the
GitHub/GitLab flow; "PR" = Azure DevOps Pull Request. Pairs with the `azure-devops` tracker when the
whole stack is Microsoft.

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
Types: feat, fix, docs, refactor, chore, test, ci. Small atomic commits per build step; commit the
plan/spec artifact before implementing (policy `commit_plan_before_implement`).

## verb: open_pr
```bash
git push -u origin <TICKET-ID>
az repos pr create --repository {repo} --source-branch <TICKET-ID> --target-branch {default_branch} \
  --title "<type>: <TICKET-ID> <description>" \
  --description "Business Impact / Deliverables / Technical Notes / QC Results" \
  --work-items <ticket-number>          # links the PR to the Boards work item
```
`semantic_pr: true` ⇒ keep the title semantic if branch policies lint it. Honor `word_limits.pr`.
External action ⇒ requires approval (policy `hard_halt_before_external_posts`).

## verb: merge_pr
**In:** the PR id from `open_pr`.
```bash
az repos pr update --id <PR-ID> --status completed --squash true --delete-source-branch false
az repos pr show --id <PR-ID> --query status -o tsv   # verify: completed
```
Squash is the kit's merge style: one commit per ticket on `{default_branch}`. External action ⇒
requires approval (policy `hard_halt_before_external_posts`), and `/ship` asks again right before
this step (policy `ship_merges_pr`). Azure has no head-commit pin on completion, so check
`az repos pr show --id <PR-ID> --query lastMergeSourceCommit.commitId -o tsv` against the sha
`/ship` pushed first, and stop if they differ. When branch policies (required reviewers, build
validation) block completion, the status stays `active`: report which policy is pending and stop.
Completion is asynchronous, so check the status once more after a few seconds before calling it
blocked; anything but `completed` on that second check is blocked.
Never set `--bypass-policy` or `--auto-complete`.

## gotchas
- `--work-items` ties the PR to the Azure Boards item (the tracker side) — use the bare integer id.
- Branch policies (required reviewers, build validation) may gate completion — surface required
  approvals rather than force-completing the PR.
- Self-hosted Azure DevOps Server uses `--organization https://<server>/<collection>`.
