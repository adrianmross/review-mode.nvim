---
release: minor
---

Review two local refs with `:ReviewModeLocal [<base>] [<head>]`: no PR, no
remote and no network. The base defaults to the merge base with the repo's
default branch and the head to the working tree, and the changed-file list, hunk
navigation, the diff views, viewed state, the panel, diagnostics and quickfix
all work as usual.

Local reviews keep their comments in `<git-dir>/review-mode/<branch>.json`,
which is per-worktree and per-branch and never tracked by git, in the same
normalized shape GitHub and GitLab comments load into. `:ReviewModeLocalComments`
lists them all in a `review-mode://local` buffer, and `api.local_comment()`
alongside the existing thread calls makes the whole loop reachable from a
headless Neovim, so a coding agent can read and write review comments too.
