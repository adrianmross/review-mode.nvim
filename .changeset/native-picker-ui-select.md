---
release: minor
---

Replace the built-in floating viewed-file picker with `vim.ui.select`. The
`"native"` provider keeps the same file labels but no longer has a diff
preview, live filtering or an in-picker viewed toggle; install snacks.nvim or
Telescope for those.
