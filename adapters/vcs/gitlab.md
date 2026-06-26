---
seam: vcs
tool: gitlab
transport: cli         # git + `glab` CLI
requires: [default_branch]   # stack.yaml seams.vcs.{default_branch, semantic_pr, worktree_root}
auth: |
  git credentials in keychain/credential-helper; `glab auth login` for merge requests.
  Verify: `glab auth status`.
---

# GitLab adapter

Maps the `vcs` verb contract to git + the GitLab CLI. Merge Requests (MRs) replace PRs; otherwise the
flow mirrors GitHub. Branch = ticket id; MR titles are semantic.

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
Types: feat, fix, docs, refactor, chore, test, ci. Small atomic commits per PIV step. Commit the
plan/spec artifact before implementing (policy `commit_plan_before_implement`).

## verb: open_pr
```bash
glab mr create --title "<type>: <TICKET-ID> <description>" \
  --description "Business Impact / Deliverables / Technical Notes / QC Results" \
  --target-branch {default_branch} --remove-source-branch
```
`semantic_pr: true` ⇒ keep the title semantic if a pipeline lint enforces it. Honor `word_limits.pr`.
External action ⇒ requires approval (policy `hard_halt_before_external_posts`).

## gotchas
- `glab` needs the host set for self-managed GitLab: `glab auth login --hostname <gitlab.company.com>`.
- MR approvals/merge-trains may gate the merge — surface required approvals rather than forcing.
