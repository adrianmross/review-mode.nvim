---
release: patch
---

Hide whitespace-only changes, like GitHub's "Hide whitespace". Set
`diff.ignore_whitespace = true` or run `:ReviewModeDiffWhitespaceToggle` (also in
the actions picker under Diff): side-by-side diffs ignore whitespace
(`iwhiteall`), unified diffs and `]c` / `[c` hunk navigation use `git diff -w`,
and toggling re-renders the open diff. Files whose only changes are whitespace
stay listed and are marked `(whitespace only)` in the changed-files picker.
