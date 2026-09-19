---
release: patch
---

Mark individual hunks viewed with `<leader>rh` or `:ReviewModeHunkViewedToggle`. Hunk marks are kept locally, keyed by the hunk's content, so after a push only the hunks that actually changed come back unviewed. The changed-files picker shows how many hunks of a file you have viewed, viewed hunks get a quiet sign, and `viewed.skip_viewed_hunks = true` makes `]c` / `[c` skip them. Viewing the last hunk of a file marks the file viewed, and un-viewing a hunk un-views the file, syncing to GitHub the same way `<leader>rv` does.
