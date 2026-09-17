---
release: minor
---

Review a PR without checking it out. `:ReviewModeCheckout <number|url>` and
`api.review_pr` fetch the PR head into `refs/review-mode/pr/<n>` (via
`pull/<n>/head`, so fork PRs work), give it a detached worktree under
`stdpath("cache")/review-mode/worktrees/`, and start the session there in its
own tabpage with a tab-local cwd — the files stay ordinary files on disk, so
LSP keeps working, and your checkout, branch and working tree are untouched.

A review worktree with uncommitted changes is never updated and never removed:
reviewing its PR again reuses it as it stands and warns.
`:ReviewModeCheckoutClean [pr]` removes the clean ones after a confirmation and
lists why it refused the rest. The `prepare_checkout` override routes worktree
creation through your own tool, and `checkout_ready` / `checkout_removed` report
when a worktree appears or goes away.
