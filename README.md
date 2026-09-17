# review-mode.nvim

Fast GitHub pull request review mode for ordinary Neovim buffers.

The goal is to keep review inside normal files instead of a dedicated diff UI:

- steps in and out like a real mode: the key layer flips, the review session stays loaded
- opens the first changed file when review mode starts
- uses Gitsigns against the PR base branch for gutter changes
- jumps between PR hunks, PR comments, and changed files
- shows changed files/folders in `nvim-tree`
- loads GitHub review comments asynchronously with a small disk cache
- renders comments as threads: author, association, age, reactions, replies,
  and suggestions shown as the diff they will apply
- opens a thread panel in a side split that follows the cursor, with replies
  drafted in a real buffer and confirmed before they are sent
- tracks viewed/unviewed PR files locally, with optional GitHub-backed viewed sync
- opens the base version of the current file in a side-by-side diff split
- creates line or visual-range PR comments and suggestions through `gh`
- opens quick PR actions for status, checks, browser handoff, URL copy, and thread resolution
- can use snacks.nvim or Telescope for action and viewed-file pickers, with `vim.ui.select` as fallback

## Requirements

- Neovim 0.10+
- `git`
- GitHub CLI `gh`, authenticated for the target repository
- a [Nerd Font](https://www.nerdfonts.com/) for the default comment sign; without one, set
  `comments.sign_text` to any character your font has
- optional: `lewis6991/gitsigns.nvim`
- optional: `nvim-tree/nvim-tree.lua`
- optional: `folke/snacks.nvim` or `nvim-telescope/telescope.nvim` for picker UI

The plugin assumes the current checkout is a PR branch and compares
`origin/<base>...HEAD`, where `<base>` comes from `gh pr view`.

## Install

With `lazy.nvim`:

```lua
{
  "adrianmross/review-mode.nvim",
  dependencies = {
    "lewis6991/gitsigns.nvim",
  },
  opts = {},
  keys = {
    { "<leader>rm", "<cmd>ReviewMode<cr>", desc = "Review mode (toggle)" },
    { "<leader>rN", "<cmd>ReviewModeStop<cr>", desc = "Review mode stop (end session)" },
    { "<leader>ra", "<cmd>ReviewModeActions<cr>", desc = "Review actions" },
    { "<leader>rd", "<cmd>ReviewModeOldToggle<cr>", desc = "Review diff" },
    { "<leader>rD", "<cmd>ReviewModeDiffLayoutToggle<cr>", desc = "Review diff layout" },
    { "<leader>rf", "<cmd>ReviewModeDiffFullToggle<cr>", desc = "Review diff full file" },
    { "<leader>rv", "<cmd>ReviewModeViewedToggle<cr>", desc = "Toggle file viewed" },
    { "<leader>rl", "<cmd>ReviewModeViewedList<cr>", desc = "Review viewed files list" },
    { "<leader>rV", "<cmd>ReviewModeViewedFeatureToggle<cr>", desc = "Review toggle viewed state" },
    { "<leader>rC", "<cmd>ReviewModeCommentsToggle<cr>", desc = "Review toggle comments" },
    { "<leader>rs", "<cmd>ReviewModeViewedSync<cr>", desc = "Review sync viewed" },
    { "<leader>rS", "<cmd>ReviewModeViewedSyncToggle<cr>", desc = "Review toggle viewed sync" },
    { "<leader>rc", "<cmd>ReviewModeThread<cr>", desc = "Review line comments" },
    { "<leader>rt", "<cmd>ReviewModePanel<cr>", desc = "Review thread panel" },
    { "<leader>rr", "<cmd>ReviewModeReply<cr>", desc = "Review reply" },
    { "<leader>rR", "<cmd>ReviewModeResolveThread<cr>", desc = "Review resolve thread" },
    {
      "<leader>rp",
      function()
        require("review_mode").comment()
      end,
      mode = { "n", "v" },
      desc = "Review comment",
    },
    -- ]h/[h, ]c/[c, ]f/[f, <Tab>, <S-Tab> and <Esc> come from the mode layer
    -- while you are in the mode; see "The Mode" below.
  },
}
```

Navigation keys are installed by the mode itself and removed when you step out,
so they only exist while you are reviewing:

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
      require "review_mode.integrations.nvim_tree",
      "Cut",
    },
  },
})
```

Unviewed changed files and closed parent folders are marked with `☐ N`, where
`N` is the number of unviewed changed files under that node. Viewed files and
closed folders are marked with `✓`; files and closed folders with unresolved
comments are also marked with ` N` (a Nerd Font comment glyph). An open
folder hides these folder markers because its children show the same state
inline. A folder switches to viewed after every changed file under it is
viewed.

## The Mode

Review mode separates the *mode* from the *session*, the way normal and insert
mode share one buffer:

| | keys | comment signs, tree markers | Gitsigns gutter | comments, viewed state, hunks |
|---|---|---|---|---|
| in the mode | review layer | shown | vs PR base | loaded |
| stepped out | yours back | still shown | vs index | still loaded |
| session ended | yours | cleared | vs index | dropped |

`:ReviewMode` toggles. Stepping out is instant and costs nothing — no `gh`
calls, no re-fetch — so you can drop out mid-review, stage and commit with your
own keys and a normal gutter, and step straight back in with the review intact.
`:ReviewModeStop` is what actually ends the session.

While you are in the mode, these keys are live and nothing else is touched. Any
mapping of yours that they shadow is saved on entry and restored on exit:

| key | action |
|---|---|
| `]h` / `[h` | next / previous PR hunk |
| `]c` / `[c` | next / previous PR comment |
| `]f` / `[f` | next / previous changed file |
| `gt` | toggle the thread panel |
| `<Tab>` | mark viewed and jump to the next unviewed file |
| `<S-Tab>` | toggle viewed |
| `<Esc>` | step out of the mode |

Replace them with `mode.keys`, or set `mode.keys = {}` to install none:

```lua
mode = {
  keys = {
    ["]h"] = "next_hunk",           -- any function name on the module
    ["<Esc>"] = "leave",
    ["gR"] = function() ... end,    -- or a function
  },
},
```

## The Thread Panel

`:ReviewModePanel` (or `gt` in the mode) opens a vertical split beside the file.
It follows the cursor: threads anchored to the current line, or every thread in
the file when the cursor is not on one. Each thread shows who wrote it, their
association with the repo, how long ago, the reply chain, emoji reactions, and
its resolved/outdated state. Fenced code inside a comment is drawn as code
rather than as more prose, and a `suggestion` block is drawn as the diff it
would apply — the lines it replaces above the lines it proposes.

Keys inside the panel:

| key | action |
|---|---|
| `r` | reply to the thread under the cursor |
| `c` | comment on the line the code window is on |
| `R` | resolve or unresolve the thread |
| `a` | apply the thread's suggestion to the buffer |
| `o` | open the comment on GitHub |
| `<CR>` | jump to the thread's line in the code window |
| `]c` / `[c` | next / previous thread in the panel |
| `gr` | reload comments from GitHub |
| `q` | close the panel |

### Replies are drafted, not typed into a prompt

`r`, `c`, `:ReviewModeCompose` and `:ReviewModeReply` open a real markdown
buffer instead of `vim.ui.input`, so a reply can be more than one line and can
be edited before it goes out. Nothing is sent until you confirm:

| key | action |
|---|---|
| `<C-s>` or `:w` | post, after a confirmation prompt showing what will be sent |
| `<C-r>` | quote the lines you have selected in the code window, with their path and line numbers |
| `<C-g>` | seed a ```suggestion block from the lines the draft is aimed at |
| `q` | discard the draft (confirmed if it is not empty) |

`<C-r>` is what lets a reply point at lines other than the one the thread is
anchored to: select the lines in the code window, come back to the draft, and
press it.

Resolved threads are hidden in the panel and the float unless a line has
nothing else on it; set `comments.show_resolved = true` to always show them.

## API

`review_mode.api` is the surface to build on. The rule that keeps it honest: the
bundled panel, picker and nvim-tree decorations use nothing else, so anything
they can do, your own UI can do too. `scripts/validate.sh` enforces it — if one
of them starts requiring a plugin internal, the build fails, because that means
the API is missing something.

```lua
local api = require("review_mode.api")

-- session
api.session()        --> { repo, pr, base, head, root, in_mode } or nil
api.is_active() / api.is_in_mode() / api.config() / api.root()

-- lifecycle
api.start() / api.stop() / api.enter() / api.leave() / api.toggle() / api.refresh()
api.review_pr({ pr = 123 }, function(ok, result) ... end)   -- review without checking out

-- files
api.files()          --> { { path, status, added, removed, viewed, comments, unresolved }, ... }
api.file(path)       --> one entry, or nil when the path is not in the PR
api.is_changed_file(path) / api.is_changed_dir(path)
api.is_viewed_file(path) / api.is_viewed_dir(path)
api.unviewed_count(path) / api.unresolved_count(path) / api.comment_count(path)
api.set_viewed(path, true)
api.hunks(path, function(hunks) ... end)   -- lazy, so it takes a callback

-- threads
api.threads({ path = "src/a.ts", line = 42, include_resolved = false })
api.comment({ path = ..., start_line = ..., end_line = ..., body = ... }, cb)
api.reply({ thread_id = ..., body = ... }, cb)          -- or comment_id = ... to skip the lookup
api.resolve(thread_id, true, cb)
api.reload_comments()

-- navigation ("hunk" | "comment" | "file")
api.goto_next("comment") / api.goto_prev("hunk")

-- rendering, so a custom UI reuses the thread renderer instead of reimplementing it
local lines, marks = api.render_threads(threads, { width = 60 })
api.apply_render(bufnr, namespace, lines, marks)
api.suggestion(comment)   --> the ```suggestion block as lines, or nil

-- events (see Hooks); returns an unsubscribe function
local unsubscribe = api.on("comments_loaded", function(ctx) ... end)
```

Writes take a `callback(ok, err)`. `api.reply` needs the id of the comment it
answers: pass `comment_id` directly, or a `thread_id` and it is looked up —
add `path` to limit that lookup to one file instead of every changed file. `api.unstable_state()` returns the raw session
table as an escape hatch — if you need it, that is a gap in the API worth
reporting.

A thread looks like:

```lua
{
  id = "PRRT_...",            -- GitHub thread id, or "comment:N" from the REST fallback
  path = "src/a.ts",
  line = 42, start_line = 40,
  is_resolved = false, is_outdated = false,
  comments = {
    { id = 1, author = "reviewer", association = "OWNER", created_at = "...",
      body = "...", url = "...", reactions = { { content = "THUMBS_UP", count = 2 } } },
  },
}
```

## Hooks

Two kinds, and they answer different questions.

**Observers** are told what happened. Every listener runs and the return value
is ignored. Each one is also a `User` autocommand, so use whichever style you
prefer.

| hook | autocommand | fires when |
|---|---|---|
| `on_start` | `ReviewModeStart` | a review session loads |
| `on_enter` | `ReviewModeEnter` | you step into the mode |
| `on_leave` | `ReviewModeLeave` | you step out, session intact |
| `on_stop` | `ReviewModeStop` | the session ends |
| `on_comments_loaded` | `ReviewModeCommentsLoaded` | review comments finish loading |
| `on_viewed_changed` | `ReviewModeViewedChanged` | viewed state changes |
| `on_panel_open` / `on_panel_close` | `ReviewModePanelOpen` / `Close` | the thread panel opens or closes |
| `on_comment_posted` | `ReviewModeCommentPosted` | you post a comment or reply |
| `on_thread_resolved` | `ReviewModeThreadResolved` | you resolve or unresolve a thread |
| `on_checkout_ready` | `ReviewModeCheckoutReady` | a PR worktree is ready to review |
| `on_checkout_removed` | `ReviewModeCheckoutRemoved` | a review worktree is removed |

**Overrides** are asked *how* something should be done, and what they return
replaces the built-in behavior. Return `nil` to fall back to the default, so an
override can decide case by case.

| hook | gets | returns |
|---|---|---|
| `open_panel_window` | `{ buf, position, width, origin }` | the window to show the panel in |
| `prepare_checkout` | `{ repo, pr, head, base, ref, root, default_path }` | the path of a worktree at `ref` to review in |

```lua
require("review_mode").setup({
  hooks = {
    on_start = function(ctx)
      vim.notify(("reviewing %s#%s"):format(ctx.repo, ctx.pr))
    end,
    on_comment_posted = function(ctx)
      vim.notify("posted a " .. ctx.kind .. " on " .. ctx.path)
    end,

    -- open the thread panel as a float instead of a split
    open_panel_window = function(ctx)
      return vim.api.nvim_open_win(ctx.buf, true, {
        relative = "editor",
        width = ctx.width,
        height = math.floor(vim.o.lines * 0.8),
        row = 1,
        col = vim.o.columns - ctx.width - 2,
        border = "rounded",
      })
    end,
  },
})
```

A hook that errors is reported once and then ignored — the review keeps working
and the built-in behavior still runs.

### Committing during a review

Review mode watches the reflog, so a commit you make mid-review (from Neovim, a
`:terminal`, fugitive, or another window entirely) is picked up on the next
`FocusGained`, `BufEnter` or `TermLeave`: the changed-file list and hunks are
rebuilt and the PR head SHA is re-fetched, so new comments anchor to a commit
GitHub knows about. Viewed state and loaded comments are kept. Set
`follow_head = false` to require `:ReviewModeRefresh` instead.

### Its own workspace (opt-in)

With `mode.workspace = "tab"` the review gets its own tabpage. Entering
switches to it, stepping out returns you to the tab you came from, and the
review layout survives in between — so you can flip between "my work" and "the
review" without either disturbing the other. Ending the session closes the tab.
The default, `"inplace"`, never touches your windows.

### Review a PR without checking it out

`:ReviewModeCheckout 123` (or a PR URL, or `api.review_pr`) reviews a PR
without touching your working tree or your branch. It fetches the PR head into
`refs/review-mode/pr/<n>` — `pull/<n>/head`, so PRs from forks work — gives it
a detached worktree of its own under
`stdpath("cache")/review-mode/worktrees/<owner>_<repo>/pr-<n>`, and opens the
review in its own tabpage with a tab-local `:tcd` into that worktree. Your own
checkout, branch, cwd and windows are left alone.

The files are real files on disk, not virtual read-only diff buffers, so LSP,
formatters, treesitter and the rest of your setup work on the PR exactly as
they do on your own code — that is the whole point of the plugin, and a PR you
did not check out should not be a lesser review.

Review worktrees are never removed for you. `:ReviewModeCheckoutClean [pr]`
removes the clean ones after a confirmation and refuses the dirty ones, listing
what is uncommitted in each; the worktree the current session is using is
refused too. A tree that has uncommitted changes is also never updated: a
second `:ReviewModeCheckout` on it reuses it as it stands and warns instead of
moving it to the new PR head. `checkout = { cleanup = "manual" }` is the only
cleanup mode.

If you manage worktrees with your own tool, route creation through it with the
`prepare_checkout` override and return the path to use. The worktree it makes
is yours, including its removal — `:ReviewModeCheckoutClean` only touches the
default cache location (the `wt` flags below are one tool's; returning `nil`
falls back to the built-in worktree, so a hook can decide case by case):

```lua
hooks = {
  -- create the review worktree with worktrunk instead
  prepare_checkout = function(ctx)
    local branch = "review/pr-" .. ctx.pr
    local args = { "wt", "switch", branch, "--no-cd", "-y", "-x", "echo", "--", "{{ worktree_path }}" }
    if vim.system({ "git", "rev-parse", "--verify", "--quiet", branch }, { cwd = ctx.root }):wait().code ~= 0 then
      vim.list_extend(args, { "--create", "--base", ctx.head })
    end
    local out = vim.system(args, { cwd = ctx.root, text = true }):wait()
    if out.code ~= 0 then
      return nil -- fall back to the built-in worktree
    end
    return vim.split(vim.trim(out.stdout), "\n")[1]
  end,
}
```

### Statusline and events

`vim.g.review_mode` is `"mode"`, `"session"`, or `nil`, and
`require("review_mode").statusline()` returns e.g. `REVIEW owner/repo#123 3/12`
(uppercase in the mode, lowercase when stepped out).

Review is a key layer over normal mode, not a real Vim mode, so `mode()` never
returns it and a statusline's stock mode component cannot show it on its own.
`require("review_mode").mode_text()` is a drop-in replacement for that
component: it returns `REVIEW` while the layer is live and you are in normal
mode, `REVIEW INSERT` (or `REVIEW VISUAL`, …) once you step into another mode,
and the plain mode name when there is no review. So you keep normal/insert
context while the slot still says you are reviewing.

With lualine:

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = {
    sections = {
      lualine_a = {
        { require("review_mode").mode_text },
      },
    },
  },
}
```

Pass `{ label = "PR", separator = "·" }` to change the wording. `statusline()`
is the longer form with the PR number and viewed count, for `lualine_c` or
`lualine_x`. The plugin also fires `User` autocommands for every event in
[Hooks](#hooks), so you can drive a statusline, a which-key group or a
colorscheme change yourself:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ReviewModeEnter",
  callback = function() vim.o.cursorline = true end,
})
```

## Commands

- `:ReviewMode` toggles Review Mode, starting the review session if there is none
- `:ReviewModeEnter` steps into the mode without reloading the session
- `:ReviewModeLeave` steps out of the mode, keeping the session loaded
- `:ReviewModeActions` opens an action picker for common PR actions, using the configured picker provider
- `:ReviewModeBrowser` opens the current PR in your browser
- `:ReviewModeCopyUrl` copies the current PR URL to registers
- `:ReviewModeChecks` shows `gh pr checks` output in a floating preview
- `:ReviewModeStatus` shows current PR status in a floating preview
- `:ReviewModeStop` stops review mode and clears plugin state
- `:ReviewModeRefresh` reloads changed files and comments
- `:ReviewModeNextHunk` jumps to the next PR hunk
- `:ReviewModePrevHunk` jumps to the previous PR hunk
- `:ReviewModeNextComment` jumps to the next PR comment
- `:ReviewModePrevComment` jumps to the previous PR comment
- `:ReviewModeNextFile` jumps to the next changed file
- `:ReviewModePrevFile` jumps to the previous changed file
- `:ReviewModeOldToggle` toggles the base version or unified diff for the current file
- `:ReviewModeDiffLayoutToggle` switches between side-by-side and unified layout, opening the diff if none is open
- `:ReviewModeDiffFullToggle` switches between condensed context and full-file context, opening the diff if none is open
- `:ReviewModeThread` shows comments on the current line
- `:ReviewModePanel` toggles the thread panel beside the current file
- `:ReviewModeCompose` drafts a PR comment for the current line or visual range
- `:ReviewModeApplySuggestion` applies the suggestion on the current line to the buffer
- `:ReviewModeReply` replies to the latest comment on the current line
- `:ReviewModeResolveThread` resolves the PR review thread on the current line
- `:ReviewModeUnresolveThread` unresolves the PR review thread on the current line
- `:ReviewModeComment` creates a PR comment on the current line or visual range
- `:ReviewModeSuggest` creates a GitHub suggestion comment on the current line or visual range
- `:ReviewModeViewedToggle` toggles viewed state for the current PR file
- `:ReviewModeViewedNext` marks the current PR file viewed and jumps to the next unviewed file
- `:ReviewModeViewedFeatureToggle` toggles viewed-state tracking on or off
- `:ReviewModeCommentsToggle` toggles PR comments on or off
- `:ReviewModeViewedList [all|viewed|unviewed]` opens a PR file list with diff stats; snacks.nvim and Telescope add a diff preview and toggle viewed state with `<Tab>`/`<C-t>`
- `:ReviewModeViewedClear` clears local viewed state for the current PR
- `:ReviewModeViewedSync` pulls viewed state from GitHub
- `:ReviewModeViewedSyncToggle` toggles GitHub viewed-state sync
- `:ReviewModeSummary` shows file, comment, thread, and viewed-sync counts
- `:ReviewModeCheckout <number|url>` reviews a PR in its own worktree without checking it out
- `:ReviewModeCheckoutClean [pr]` removes clean review worktrees, after a confirmation.

## gh-dash / Worktree Handoff

For external launchers, set `GH_REVIEW_REPO` and `GH_REVIEW_PR` before opening
Neovim, then run `+ReviewMode`:

```sh
GH_REVIEW_REPO=adrianmross/example GH_REVIEW_PR=123 nvim +ReviewMode
```

If those variables are not set, the plugin asks `gh` for the current repo and PR.

## Picker Providers

The default `picker.provider = "auto"` uses snacks.nvim when available, then
Telescope, then the built-in `vim.ui.select`. Set `picker.provider = "native"`,
`"snacks"`, or `"telescope"` to prefer a specific provider. `:ReviewModeActions`
uses the provider for the action list, and `:ReviewModeViewedList` uses it for
changed-file selection.

The `"native"` provider is plain `vim.ui.select`, so it shows the same
`viewed / +N / -N / comments / path` labels but has no diff preview, no live
filtering and no in-picker viewed toggle. Anything that configures
`vim.ui.select` (dressing.nvim, snacks.input, mini.pick) styles it for free.
Install snacks.nvim or Telescope for the preview and toggle keymaps.

## Options

```lua
require("review_mode").setup({
  auto_open_first_change = true,
  follow_head = true,
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
    sign_text = "", -- Nerd Font glyph, override if your font lacks it
    sign_hl_group = "DiagnosticInfo",
    virtual_text = true,
    show_resolved = false,
  },
  panel = {
    auto_open = false,
    follow_cursor = true,
    position = "right", -- "right" | "left"
    width = 60,
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
  mode = {
    enabled = true,
    workspace = "inplace",
    signs_when_out = true,
    gitsigns_follows = true,
    keys = { ... },
  },
  picker = {
    provider = "auto", -- "auto" | "native" | "snacks" | "telescope"
  },
  hooks = {}, -- see "Hooks" above
  checkout = {
    cleanup = "manual", -- review worktrees are only removed by :ReviewModeCheckoutClean
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

`ReviewMode` loads PR metadata and changed-file status asynchronously. If
`GH_REVIEW_BASE` is set by a launcher, changed-file loading starts immediately
without waiting for GitHub metadata. Hunk locations are loaded lazily per file,
with immediate focused-file prefetch, opportunistic `gitsigns.nvim` hunk-cache
reuse, and an optional delayed background scan for PRs under
`performance.background_hunk_scan.max_files`.

External launchers can provide `GH_REVIEW_REPO`, `GH_REVIEW_PR`,
`GH_REVIEW_BASE`, and `GH_REVIEW_HEAD` to avoid startup discovery calls.

Viewed state is persisted in `stdpath("state")/review-mode-state.json` by
default. Set `viewed.sync = true` or run `:ReviewModeViewedSyncToggle` to pull
GitHub's PR file viewed state at startup and push local viewed/unviewed toggles
back to GitHub.

The built-in side-by-side old-version split remains the default diff backend.
Set `diff.layout = "unified"` or run `:ReviewModeDiffLayoutToggle` to use an
inline unified diff buffer in the current window instead. Closing unified mode
restores the original file buffer. Set `diff.full_file = true` or run
`:ReviewModeDiffFullToggle` to show full-file context; condensed unified diffs use
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
