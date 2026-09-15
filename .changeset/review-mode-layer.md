---
release: minor
---

Make review mode behave like a real mode: the key layer and the review session
are now separate. `:ReviewMode` toggles, `:ReviewModeLeave` steps out while
keeping comments, viewed state and hunks loaded, and `:ReviewModeStop` still
ends the session. Stepping out restores any mapping the layer shadowed and puts
the Gitsigns gutter back to the index, so you can commit mid-review and step
back in without a reload. Adds an opt-in `mode.workspace = "tab"` workspace,
`vim.g.review_mode`, `statusline()`, and `User ReviewModeStart/Enter/Leave/Stop`
events.

Note: `:ReviewMode` now toggles rather than always (re)starting the session.
