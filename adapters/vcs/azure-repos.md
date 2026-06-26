---
seam: vcs
tool: azure-repos
transport: cli         # git + `az repos` (Azure CLI + azure-devops extension)
requires: [default_branch]   # stack.yaml seams.vcs.{default_branch, semantic_pr, worktree_root, org, project, repo}
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
git checkout {default_branch} && git pull origin {default_branch}
git checkout -b <TICKET-ID>
```

## verb: worktree   (the Plan→Implement context reset)
```bash
git worktree add "{worktree_root}/<name>" -b <TICKET-ID>
```

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
Types: feat, fix, docs, refactor, chore, test, ci. Small atomic commits per PIV step; commit the
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

## gotchas
- `--work-items` ties the PR to the Azure Boards item (the tracker side) — use the bare integer id.
- Branch policies (required reviewers, build validation) may gate completion — surface required
  approvals rather than force-completing the PR.
- Self-hosted Azure DevOps Server uses `--organization https://<server>/<collection>`.
