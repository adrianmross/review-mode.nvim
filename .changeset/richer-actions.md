---
release: patch
---

The action picker (`<leader>ra`, `:ReviewModeActions`) now lists every action,
grouped as Comment, Thread, Suggest, Files, Diff, Review, PR, Local and Session,
and shows the key bound to each beside it — so it doubles as the key reference,
and typing a key such as `rx` finds its action. New entries include the
context-aware comment, next/previous thread, hunk and file, mark viewed and go
to next, viewed sync and clear, base diff and diff layout, comment signs,
removing clean review worktrees, step out, refresh and end the review. Resolve
and unresolve are one toggle entry.
