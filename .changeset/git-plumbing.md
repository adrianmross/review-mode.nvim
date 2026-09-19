---
release: patch
---

Reviews now work with file names that contain spaces or non-ASCII characters, with renamed files (their hunks, line counts and base-side diff), and with any git diff config (`diff.noprefix`, `diff.mnemonicPrefix`, `diff.external`); a deleted `-- comment` line no longer corrupts the unified diff, and the base-side diff and gitsigns base now read from the PR's merge base instead of the moved-on tip of the base branch.
