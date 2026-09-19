---
release: patch
---

`:ReviewModeBlastRadius` lists the callers of the current file's changed functions that the PR did not touch. It finds the functions whose signature the PR changes with treesitter, asks your language server for their references, drops the ones on lines the PR rewrote, and fills the quickfix list with the rest, so "this PR changes `parse()` and four callers weren't updated" shows up before merge. `!` includes body-only changes; it is also in the actions picker, and runs only when asked.
