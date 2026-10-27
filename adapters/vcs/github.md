---
seam: vcs
tool: github
transport: cli         # git + gh
requires: [default_branch]  # stack.yaml seams.vcs.{default_branch, semantic_pr, worktree_root}
user_keys: []             # tier-3 overridable: nothing here is machine-local; every key selects data or wires the seam
auth: |
  git credentials in keychain; `gh auth login` for PRs.
  Verify: `gh auth status`.
---

# GitHub adapter

Maps the `vcs` verb contract to git + the GitHub CLI. Branch = ticket ID; PR titles are semantic.

## verb: branch
```bash
git checkout {default_branch} && git pull origin {default_branch}
git checkout -b <TICKET-ID>                 # branch name IS the ticket id
```

## verb: worktree   (isolates one ticket from other work in flight)
```bash
git worktree add "{worktree_root}/<name>" -b <TICKET-ID>
```
A fresh worktree keeps this ticket's files apart from other tickets in flight. (This repo's
worktree-manager scripts under `~/.claude/skills/worktree-manager/` can also be used.)

## verb: commit
Stage only files you changed (never `git add .`); semantic message.
```bash
git add <paths>
git commit -m "$(cat <<'EOF'
<type>: <TICKET-ID> <description>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Types: feat, fix, docs, refactor, chore, test, ci. Small atomic commits per build step (git-log-is-memory).
Commit the **plan/spec artifact before implementing** (policy `commit_plan_before_implement`).

## verb: open_pr
```bash
git push -u origin <TICKET-ID>      # gh pr create is interactive if the branch isn't pushed yet
gh pr create --title "<type>: <TICKET-ID> <description>" \
  --body "Business Impact / Deliverables / Technical Notes / QC Results"
```
`semantic_pr: true` ⇒ non-semantic titles fail the Semantic-PR check. Honor `word_limits.pr` (<200).
External action ⇒ requires approval (policy `hard_halt_before_external_posts`).

## verb: merge_pr
**In:** the PR number from `open_pr`, and the commit sha `/ship` pushed.
```bash
gh pr merge <PR-NUMBER> --squash --match-head-commit <SHA>
gh pr view <PR-NUMBER> --json state,mergedAt   # verify: state MERGED
```
Squash is the kit's merge style: one commit per ticket on `{default_branch}`. `--match-head-commit`
refuses the merge if anything was pushed to the branch after the person confirmed it, so the merge
lands exactly what they saw. External action ⇒ requires approval (policy
`hard_halt_before_external_posts`), and `/ship` asks again right before this step (policy
`ship_merges_pr`). When branch protection, a required review, a failing or pending check, or a
conflict blocks it, `gh` usually exits non-zero with the reason: report that reason and stop. On a
branch with a merge queue, or when required checks have not finished, `gh` can instead queue the PR
or turn on auto-merge and exit 0 without merging, so the verify line decides: anything but `MERGED`
means blocked. Never retry with `--admin` or `--auto`, which bypass or defer exactly the checks the
team set.

## gotchas
- `gh pr create` prompts interactively (which can hang an agent) unless the branch is already pushed
  — push first, as above.
- Branch protection / required status checks may gate the merge — surface the required reviews/checks
  rather than force-merging.
