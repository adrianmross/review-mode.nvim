---
release: patch
---

Checkouts, GitLab and the inbox now work beyond one github.com clone.
`:ReviewModeCheckout` fetches a PR's head and base from the repo the PR lives
in, not `origin`, and refuses a head that is not the one GitHub reports. It
accepts GitHub Enterprise URLs and never falls back to a placeholder repo. Each
local clone gets its own review trees, and a tree belonging to another clone is
never reused. `:ReviewModeCheckoutClean` accepts `#12` and reports a tree
deleted by hand as prunable instead of crashing. On GitLab, a review started
with a repo or MR keeps them. New threads are placed on the MR's own diff, and
a failed diff fails the comment. Notes on removed lines sit on the base side,
and `line_range` starts are read. Discussions are paged without mangling bodies
like `[x] [y]`, and `glab` is pointed at a self-hosted instance's own host.
A branch with no MR, or a remote on no GitHub host (Codeberg, Gitea), now falls
back to a local review. Local reviews in two clones keep separate viewed state,
comment caches no longer mix GitLab, GitHub Enterprise and github.com, and a
typo'd `:ReviewModeLocal` head is an error. The inbox shows ages correctly
during DST, lists up to 100 PRs, and checks the repo's own forge. Blast radius
reports language-server errors, and converts columns in each server's encoding.
A base branch named like `20250101-release` is no longer taken for a commit.
