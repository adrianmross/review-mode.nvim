---
release: patch
---

The test suite can now fail for every way a fixture used to pass without running its assertions: errors in scheduled callbacks and autocmds, unstubbed `vim.ui.select`/`vim.ui.input`/`vim.fn.confirm` prompts, fixtures that exit before their last line, and duplicate help tags. Runs no longer read the developer's git or Neovim config, and clean up their temp directories on success.
