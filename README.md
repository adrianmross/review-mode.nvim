# pr-review.nvim

Fast GitHub PR review mode for ordinary Neovim buffers.

The goal is to keep review inside normal files instead of a dedicated diff UI:

- opens the first changed file when review mode starts
- uses Gitsigns against the PR base branch for gutter changes
- jumps between PR hunks, PR comments, and changed files
- shows changed files/folders in `nvim-tree`
- loads GitHub review comments asynchronously with a small disk cache
- tracks viewed/unviewed PR files locally, with optional GitHub-backed viewed sync
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
    { "<leader>rd", "<cmd>PrReviewOldToggle<cr>", desc = "Review diff" },
    { "<leader>rD", "<cmd>PrReviewDiffLayoutToggle<cr>", desc = "Review diff layout" },
    { "<leader>rf", "<cmd>PrReviewDiffFullToggle<cr>", desc = "Review diff full file" },
    { "<leader>rv", "<cmd>PrReviewViewedToggle<cr>", desc = "Toggle file viewed" },
    { "<leader>rl", "<cmd>PrReviewViewedList<cr>", desc = "Review viewed files list" },
    { "<leader>rV", "<cmd>PrReviewViewedFeatureToggle<cr>", desc = "Review toggle viewed state" },
    { "<leader>rC", "<cmd>PrReviewCommentsToggle<cr>", desc = "Review toggle comments" },
    { "<leader>rs", "<cmd>PrReviewViewedSync<cr>", desc = "Review sync viewed" },
    { "<leader>rS", "<cmd>PrReviewViewedSyncToggle<cr>", desc = "Review toggle viewed sync" },
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
    { "]h", "<cmd>PrReviewNextHunk<cr>", desc = "Next PR hunk" },
    { "[h", "<cmd>PrReviewPrevHunk<cr>", desc = "Previous PR hunk" },
    { "]c", "<cmd>PrReviewNextComment<cr>", desc = "Next PR comment" },
    { "[c", "<cmd>PrReviewPrevComment<cr>", desc = "Previous PR comment" },
    { "]f", "<cmd>PrReviewNextFile<cr>", desc = "Next changed file" },
    { "[f", "<cmd>PrReviewPrevFile<cr>", desc = "Previous changed file" },
  },
}
```

Suggested navigation uses hunk keys for changed regions and comment keys for
review discussion:

- `]h` / `[h` jump to the next/previous PR hunk
- `]c` / `[c` jump to the next/previous PR comment
- `]f` / `[f` jump to the next/previous changed file

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

Unviewed changed files and parent folders are marked with `☐ N`, where `N` is
the number of unviewed changed files under that node. Viewed files and folders
are marked with `✓`; files and folders with unresolved comments are also marked
with ` N`. A folder switches to viewed after every changed file under it is
viewed.

## Commands

- `:PrReviewStart` starts normal-buffer PR review mode
- `:PrReviewStop` stops review mode and clears plugin state
- `:PrReviewRefresh` reloads changed files and comments
- `:PrReviewNextHunk` jumps to the next PR hunk
- `:PrReviewPrevHunk` jumps to the previous PR hunk
- `:PrReviewNextComment` jumps to the next PR comment
- `:PrReviewPrevComment` jumps to the previous PR comment
- `:PrReviewNextFile` jumps to the next changed file
- `:PrReviewPrevFile` jumps to the previous changed file
- `:PrReviewOldToggle` toggles the base version or unified diff for the current file
- `:PrReviewDiffLayoutToggle` toggles the open diff between side-by-side and unified layout
- `:PrReviewDiffFullToggle` toggles the open diff between condensed context and full-file context
- `:PrReviewThread` shows comments on the current line
- `:PrReviewReply` replies to the latest comment on the current line
- `:PrReviewComment` creates a PR comment on the current line or visual range
- `:PrReviewViewedToggle` toggles viewed state for the current PR file
- `:PrReviewViewedNext` marks the current PR file viewed and jumps to the next unviewed file
- `:PrReviewViewedFeatureToggle` toggles viewed-state tracking on or off
- `:PrReviewCommentsToggle` toggles PR comments on or off
- `:PrReviewViewedList [all|viewed|unviewed]` opens a fuzzy PR file menu with diff stats and preview; press `Space` or `t` to toggle viewed state
- `:PrReviewViewedClear` clears local viewed state for the current PR
- `:PrReviewViewedSync` pulls viewed state from GitHub
- `:PrReviewViewedSyncToggle` toggles GitHub viewed-state sync
- `:PrReviewSummary` shows file, comment, thread, and viewed-sync counts.

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
    sign_text = "",
    sign_hl_group = "DiagnosticInfo",
    virtual_text = true,
  },
  diff = {
    fast_diffopt = "internal,filler,closeoff,indent-heuristic,linematch:0",
    full_file = false,
    layout = "side_by_side",
    partial_line_highlights = true,
    unified_context = 3,
    use_fast_diffopt = true,
  },
  gitsigns = {
    enabled = true,
  },
  nvim_tree = {
    enabled = true,
    show_comments = true,
    show_viewed = true,
  },
  viewed = {
    enabled = true,
    sync = false,
    state_path = nil,
  },
  performance = {
    ui_refresh_debounce_ms = 50,
    hunk_prefetch = {
      enabled = true,
      count = 8,
      concurrency = 2,
      focused_delay_ms = 0,
      gitsigns_delay_ms = 5,
    },
    background_hunk_scan = {
      enabled = true,
      max_files = 5000,
      delay_ms = 250,
    },
  },
  commands = true,
})
```

`PrReviewStart` loads PR metadata and changed-file status asynchronously. If
`GH_REVIEW_BASE` is set by a launcher, changed-file loading starts immediately
without waiting for GitHub metadata. Hunk locations are loaded lazily per file,
with immediate focused-file prefetch, opportunistic `gitsigns.nvim` hunk-cache
reuse, and an optional delayed background scan for PRs under
`performance.background_hunk_scan.max_files`.

External launchers can provide `GH_REVIEW_REPO`, `GH_REVIEW_PR`,
`GH_REVIEW_BASE`, and `GH_REVIEW_HEAD` to avoid startup discovery calls.

Viewed state is persisted in `stdpath("state")/pr-review-state.json` by
default. Set `viewed.sync = true` or run `:PrReviewViewedSyncToggle` to pull
GitHub's PR file viewed state at startup and push local viewed/unviewed toggles
back to GitHub.

The built-in side-by-side old-version split remains the default diff backend.
Set `diff.layout = "unified"` or run `:PrReviewDiffLayoutToggle` to use an
inline unified diff buffer in the current window instead. Closing unified mode
restores the original file buffer. Set `diff.full_file = true` or run
`:PrReviewDiffFullToggle` to show full-file context; condensed unified diffs use
`diff.unified_context` common lines around each hunk, and condensed side-by-side
diffs fold unchanged regions in both diff windows. When `diff.use_fast_diffopt`
is enabled, side-by-side diffs temporarily apply `diff.fast_diffopt`, then
restore the previous `diffopt` when the split closes. Unified diffs highlight
changed spans inside modified lines with `DiffText`; set
`diff.partial_line_highlights = false` to disable those inline spans.

## Notes

GitHub only accepts review comments on diff lines. If you comment on a line that
is not part of the PR diff, GitHub may reject the request.

## Release Workflow

Pull requests run the same validation as local development with
`devenv test --no-eval-cache`. Behavior, command, config, validation, and
release-infrastructure changes also need a release-bearing Conventional Commit
such as `fix:`/`feat:`/`perf:`, a `.changeset/*.md` file, or a direct
`CHANGELOG.md` update so release intent is visible during review.

Release Please owns the final release PR, changelog update, tag, and GitHub
Release. The current released version is tracked in
`.release-please-manifest.json`; `scripts/release-check.sh` verifies that the
manifest, latest changelog section, and release tag agree.

Local release checks:

```sh
devenv test --no-eval-cache
bash scripts/release-check.sh
```
