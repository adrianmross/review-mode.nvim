---
release: minor
---

`]f` / `[f`, the next-unviewed jump, the changed-files picker and `api.files()` now walk a PR in a reading order instead of alphabetically: code first, with a file that another changed file mentions ahead of the file that mentions it, then docs and lockfiles, then tests. The links come from a whole-word match of each changed file's name in the others' first 64 KiB, so there is no LSP and no process per file, and a cycle falls back to git's order. Set `files = { order = "diff" }` to keep git's order.
