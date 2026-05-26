# pr-review.nvim

Fast GitHub PR review mode for ordinary Neovim buffers.

The goal is to keep review inside normal files instead of a dedicated diff UI:

- opens the first changed file when review mode starts
- uses Gitsigns against the PR base branch for gutter changes
- jumps between PR hunks and changed files
- shows changed files/folders in `nvim-tree`
- loads GitHub review comments asynchronously with a small disk cache
- opens the base version of the current file in a side-by-side diff split
- creates line or visual-range PR comments through `gh`

## Requirements

- Neovim 0.10+
- `git`
- GitHub CLI `gh`, authenticated for the target repository
- optional: `lewis6991/gitsigns.nvim`
- optional: `nvim-tree/nvim-tree.lua`

The plugin assumes the current checkout is a PR branch and compares
`origin/<base>...HEAD`, where `<base>` comes from `gh pr view`.

## Install

With `lazy.nvim`:

```lua
{
  "adrianmross/pr-review.nvim",
  dependencies = {
    "lewis6991/gitsigns.nvim",
  },
  opts = {},
  keys = {
    { "<leader>rm", "<cmd>PrReviewStart<cr>", desc = "Review mode" },
    { "<leader>rN", "<cmd>PrReviewStop<cr>", desc = "Review mode stop" },
    { "<leader>rb", "<cmd>PrReviewOldToggle<cr>", desc = "Review base file" },
    { "<leader>rc", "<cmd>PrReviewThread<cr>", desc = "Review line comments" },
    { "<leader>rr", "<cmd>PrReviewReply<cr>", desc = "Review reply" },
    {
      "<leader>rp",
      function()
        require("pr_review").comment()
      end,
      mode = { "n", "v" },
      desc = "Review comment",
    },
    { "]c", "<cmd>PrReviewNextChange<cr>", desc = "Next PR change" },
    { "[c", "<cmd>PrReviewPrevChange<cr>", desc = "Previous PR change" },
    { "]f", "<cmd>PrReviewNextFile<cr>", desc = "Next changed file" },
    { "[f", "<cmd>PrReviewPrevFile<cr>", desc = "Previous changed file" },
  },
}
```

## nvim-tree Integration

To decorate changed files and parent directories in `nvim-tree`, include the
decorator in your `nvim-tree` setup:

```lua
require("nvim-tree").setup({
  renderer = {
    decorators = {
      "Git",
      "Open",
      "Hidden",
      "Modified",
      "Bookmark",
      "Diagnostics",
      "Copied",
      require "pr_review.integrations.nvim_tree",
      "Cut",
    },
  },
})
```

Changed files are marked with `●`; changed parent folders are marked with `•`.

## Commands

- `:PrReviewStart` starts normal-buffer PR review mode
- `:PrReviewStop` stops review mode and clears plugin state
- `:PrReviewRefresh` reloads changed files and comments
- `:PrReviewNextChange` jumps to the next PR hunk
- `:PrReviewPrevChange` jumps to the previous PR hunk
- `:PrReviewNextFile` jumps to the next changed file
- `:PrReviewPrevFile` jumps to the previous changed file
- `:PrReviewOldToggle` toggles the base version of the current file in a diff split
- `:PrReviewThread` shows comments on the current line
- `:PrReviewReply` replies to the latest comment on the current line
- `:PrReviewComment` creates a PR comment on the current line or visual range

## gh-dash / Worktree Handoff

For external launchers, set `GH_REVIEW_REPO` and `GH_REVIEW_PR` before opening
Neovim, then run `+PrReviewStart`:

```sh
GH_REVIEW_REPO=adrianmross/example GH_REVIEW_PR=123 nvim +PrReviewStart
```

If those variables are not set, the plugin asks `gh` for the current repo and PR.

## Options

```lua
require("pr_review").setup({
  auto_open_first_change = true,
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
  },
  gitsigns = {
    enabled = true,
  },
  nvim_tree = {
    enabled = true,
  },
  commands = true,
})
```

## Notes

GitHub only accepts review comments on diff lines. If you comment on a line that
is not part of the PR diff, GitHub may reject the request.
