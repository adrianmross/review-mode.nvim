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
- batches comments into a pending review and submits it as comment, approval, or changes requested
- opens quick PR actions for status, checks, browser handoff, URL copy, and thread resolution
- can expose threads as `vim.diagnostic` entries and a quickfix list, so `]d`, `vim.diagnostic.open_float`, Trouble and `:cnext` work on review comments
- can use snacks.nvim or Telescope for action and viewed-file pickers, with `vim.ui.select` as fallback

## Requirements

- Neovim 0.10+
- `git`
- GitHub CLI `gh`, authenticated for the target repository
- for GitLab merge requests: GitLab CLI `glab`, authenticated for the target
  project (see [GitLab](#gitlab))
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
    -- The one key you bind yourself: it starts the review, so it has to exist
    -- before one does. Everything else is installed by the review; see
    -- "Keys" below.
    { "<leader>rm", "<cmd>ReviewMode<cr>", desc = "Review mode (toggle)" },
  },
}
```

Once a review is running you get `<leader>r…` keys for its actions and `]c`
`]r` `]f` to move through it — no `keys` block needed. See "Keys" under "The Mode".

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

### Keys

Keys come in two layers, split by whether they shadow something:

| layer | live | keys |
|---|---|---|
| **mode** | while you are in the mode | `]c` `]r` `]f` — these shadow real keys, so they go when you step out (`<leader>rm` steps in and out) |
| **session** | from `:ReviewMode` to `:ReviewModeStop`, in or out of the mode | `<leader>r…` — these shadow nothing in stock Vim, so they stay while you step out |

Either way, any mapping of yours a layer shadows is saved and put back when the
layer goes.

**Mode layer:**

| key | action |
|---|---|
| `]c` / `[c` | next / previous PR hunk (Vim's own change jump in a diff window) |
| `]r` / `[r` | next / previous PR comment thread |
| `]f` / `[f` | next / previous changed file |

**Session layer:**

| key | action |
|---|---|
| `<leader>rt` | toggle the thread panel |
| `<leader>rr` | comment: on a line you edited, suggests your edit; else replies to the thread on this line, or starts one where there is none (a visual range always starts one) |
| `<leader>rR` | start a new thread here, even over an existing one |
| `<leader>rx` | resolve / unresolve the thread on this line |
| `<leader>rf` | changed files, with viewed state and comment counts |
| `<leader>rv` | toggle this file viewed |
| `<leader>rd` / `<leader>rD` | base diff / diff layout — in either, unchanged lines are folds: `zR` / `zM` show and hide them, `zo` opens one |
| `<leader>ra` | actions picker: every action, grouped, with its key beside it |
| `<leader>rs` | pending review and submit |
| `<leader>rq` | end the review |

`r` is the comment letter throughout: `<leader>rr` comments, `]r` moves between
threads, and the panel's keys are the session keys without `<leader>r` (`r`,
`R`, `x`, `s`). A line with several threads asks which to reply to, or whether
to start another. `:ReviewModeComment` and `:ReviewModeReply` stay explicit.

Neither layer takes `<Tab>`/`<S-Tab>` or `gt`: buffer-cycling plugins such as
bufferline use the first two, `gt` is Vim's `:tabnext`, and a checkout review
opens in its own tabpage. `:ReviewModeViewedNext` / `:ReviewModeViewedToggle`
still do what `<Tab>`/`<S-Tab>` used to.

Override either layer through `mode.keys` / `session.keys`. Your table merges
over the defaults; `false` removes one key, and `{}` installs none:

```lua
mode = {
  keys = {
    ["]h"] = "next_hunk",           -- any function name on the module
    ["<Esc>"] = "leave",            -- the old step-out key, if you want it back
    ["gR"] = function() ... end,    -- or a function
  },
},
session = {
  keys = {
    ["<leader>rq"] = false,                          -- drop one
    ["<leader>rp"] = "toggle_panel",                 -- add or move one
    ["<leader>rc"] = { "comment", mode = { "n", "v" } }, -- always a new thread
  },
},
```

## The Thread Panel

`:ReviewModePanel` (or `<leader>rt` during a review) opens a vertical split beside the file.
It follows the cursor: threads anchored to the current line, or every thread in
the file when the cursor is not on one. Each thread shows who wrote it, their
association with the repo, how long ago, the reply chain, emoji reactions, and
its resolved/outdated state. Fenced code inside a comment is drawn as code
rather than as more prose, and a `suggestion` block is drawn as the diff it
would apply — the lines it replaces above the lines it proposes.

Keys inside the panel:

| key | action |
|---|---|
| `r` | reply to the thread under the cursor (a new thread when the panel is empty) |
| `R` | start a new thread on the line the code window is on |
| `x` | resolve or unresolve the thread |
| `a` | apply the thread's suggestion to the buffer as a trial; again to revert it |
| `o` | open the comment on GitHub |
| `<CR>` | jump to the thread's line in the code window |
| `]r` / `[r` | next / previous thread in the panel |
| `<C-l>` | reload comments from GitHub |
| `+` | react to the comment under the cursor |
| `e` | edit your comment under the cursor in a draft buffer |
| `dd` | delete your comment under the cursor, after a confirmation |
| `s` | open the pending review buffer |
| `q` | close the panel |
| `p` | preview the thread's suggestion in the code, without applying it (once applied: what it replaced) |
| `A` | apply every suggestion in the file, after a confirmation |

### Replies are drafted, not typed into a prompt

`r`, `R`, `:ReviewModeComment`, `:ReviewModeCompose` and `:ReviewModeReply` open
a real markdown buffer instead of `vim.ui.input` — `:ReviewModeComment` opens the
thread panel first and drafts under it (set `comments.compose = "prompt"` for
the old one-line prompt), so a reply can be more than one line and can
be edited before it goes out. Nothing is sent until you confirm:

| key | action |
|---|---|
| `<C-s>` or `:w` | post, after a confirmation prompt showing what will be sent |
| `<C-r>` | quote the lines you have selected in the code window, with their path and line numbers |
| `<C-g>` | edit the suggestion as code: the lines (or the draft's existing ```suggestion block) open in a buffer with the file's filetype; `:w` or `<C-s>` writes them back as the block, `q` cancels |
| `<C-p>` | queue the comment in the pending review instead of posting it (new comments only) |
| `q` | discard the draft (confirmed if it is not empty) |

`<C-r>` is what lets a reply point at lines other than the one the thread is
anchored to: select the lines in the code window, come back to the draft, and
press it.

A posted comment or reply shows in the panel and as a sign right away, marked
`sending…`, and becomes the real comment when GitHub answers. If the post fails
it disappears again and its text is left in the unnamed register, so `p` puts
it back into a new draft (GitHub only; GitLab and local reviews show the comment
once it is saved).

`e`, `dd`, `:ReviewModeEditComment` and `:ReviewModeDeleteComment` only act on
comments you wrote. GitHub says who that is only through the GraphQL query, so
comments loaded through the REST fallback are refused rather than guessed at.

Resolved threads are hidden in the panel and the float unless a line has
nothing else on it; set `comments.show_resolved = true` to always show them.

Resolving or unresolving a thread briefly marks the line it sat on, in the
colour of its new state, so the change is confirmed where you made it instead
of the comment merely disappearing. The mark rides the `thread_resolved` event,
so the panel's `x`, `:ReviewModeResolveThread`, `:ReviewModeUnresolveThread`
and the GitLab provider all show it, and it sits in its own namespace so it
never disturbs the comment signs or virtual text. `comments.resolve_flash_ms`
is how long it lasts in milliseconds; `0` turns it off.

### Reactions

`+` in the panel, or `:ReviewModeReact`, toggles one of GitHub's eight
reactions on a comment: your own reactions are highlighted
(`ReviewModeReactionOwn`) and marked in the picker, and picking one you already
added removes it. Reactions are not confirmed first, because they are cheap and
reversible.

Comments loaded through the REST fallback can only *gain* a reaction: removing
one needs the GraphQL id that the REST comment list does not carry, so removal
is refused with a message rather than silently doing nothing.

## Pending Reviews

A comment can wait for the rest of the review instead of going out on its own.
`<C-p>` in the draft buffer queues it; `:ReviewModePending` (or `s` in the
panel) opens the review buffer, which lists every queued comment, takes the
review body below the marker line, and submits the lot in one GitHub review:

| key | action |
|---|---|
| `<CR>` | jump to the draft's line |
| `dd` | drop the draft under the cursor |
| `<C-s>` / `<C-a>` / `<C-x>` | submit as comment / approve / request changes |
| `q` | close the buffer |

Each submit is confirmed first, showing the event and how many comments go with
it. `:ReviewModeSubmit [comment|approve|request_changes]` does the same without
the buffer. Queued comments show as pending threads in the panel and the float,
persist in `stdpath("state")/review-mode-reviews/` across Neovim restarts, and
are cleared only once GitHub accepts the review — a failed submission keeps
them. GitHub needs a review body for `request_changes`, and for a `comment`
review with no queued comments; approving needs neither.

Two limits: replies always post immediately, because the reviews endpoint only
batches new comments; and a pending review you started in the GitHub web UI is
separate from these drafts, so submitting here leaves that one open.

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
api.file_diff(path, function(diff, err) ... end)  -- the diff for one file, never blocking

-- threads
api.threads({ path = "src/a.ts", line = 42, include_resolved = false })
api.comment({ path = ..., start_line = ..., end_line = ..., body = ... }, cb)
api.reply({ thread_id = ..., body = ... }, cb)          -- or comment_id = ... to skip the lookup
api.resolve(thread_id, true, cb)
api.reload_comments()
api.react({ comment = thread.comments[1], content = "THUMBS_UP" }, cb)  -- toggles
api.reaction_contents                                   -- the eight contents and their emoji
api.edit_comment({ comment_id = ..., body = ... }, cb)  -- your own comments only
api.delete_comment(comment_id, cb)
api.can_modify_comment(comment_id)   --> true, or false and why not

-- navigation ("hunk" | "comment" | "file")
api.goto_next("comment") / api.goto_prev("hunk")

-- rendering, so a custom UI reuses the thread renderer instead of reimplementing it
local lines, marks = api.render_threads(threads, { width = 60 })
api.apply_render(bufnr, namespace, lines, marks)
api.suggestion(comment)   --> the ```suggestion block as lines, or nil

-- pending review
api.pending()                       --> { { id, path, start_line, end_line, side, body, created_at }, ... }
api.add_pending({ path = ..., start_line = ..., end_line = ..., body = ... })
api.remove_pending(id) / api.discard_pending()
api.submit_review({ event = "COMMENT", body = "..." }, cb)   -- or APPROVE, REQUEST_CHANGES

-- events (see Hooks); returns an unsubscribe function
local unsubscribe = api.on("comments_loaded", function(ctx) ... end)

-- quickfix (see Diagnostics and Quickfix)
api.quickfix_items({ filter = "all" })   --> the items, without setting the list
api.set_quickfix({ filter = "unresolved", open = false })

-- CI annotations on the PR head (see Diagnostics and Quickfix)
api.ci_annotations("init.lua")   --> { { check, start_line, end_line, severity, message }, ... }
api.reload_ci()                  -- refetch; fires ci_loaded

-- API call accounting (see Fewer GitHub API calls)
api.request_stats()   --> { calls = <gh processes spawned>, not_modified = <304 answers> }

-- suggestions (see Suggestions)
api.suggestions("src/a.ts")          --> { { id, thread, path, start_line, end_line, lines }, ... }
api.suggestions()                    --> every suggestion in the review, grouped by file, including
                                     --  paths a local review carries comments on but did not change
api.suggestions_at("src/a.ts", 42)   --> the ones anchored over a line
api.preview_suggestion(entry)                        -- toggle virtual lines in the file
api.preview_suggestion(entry, { layout = "split" })  -- toggle the side-by-side view
api.accept_suggestion(entry)   --> the trial { id, buf, path, thread_id, line, added, removed }
api.accept_all_suggestions("src/a.ts")   --> how many were applied, and the first error
api.revert_suggestion(trial_id)          -- or nil for the trial under the cursor
api.suggestion_trials()                  --> the trials applied but not saved
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
      body = "...", url = "...",
      reactions = { { content = "THUMBS_UP", count = 2, viewer_has_reacted = true } } },
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
| `on_reaction_changed` | `ReviewModeReactionChanged` | you add or remove a reaction (`{ comment_id, content, added }`) |
| `on_comment_edited` | `ReviewModeCommentEdited` | you edit one of your comments |
| `on_comment_deleted` | `ReviewModeCommentDeleted` | you delete one of your comments |
| `on_pending_changed` | `ReviewModePendingChanged` | a pending review comment is added, dropped, or submitted |
| `on_review_submitted` | `ReviewModeReviewSubmitted` | a review is submitted (`{ event, count }`) |
| `on_suggestion_accepted` | `ReviewModeSuggestionAccepted` | a suggestion is applied as a trial (`{ id, path, line, thread_id, added, removed }`) |
| `on_suggestion_reverted` | `ReviewModeSuggestionReverted` | a trial suggestion is reverted |
| `on_ci_loaded` | `ReviewModeCiLoaded` | CI annotations for the PR head are fetched (or cleared) |

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
- `:ReviewModeActions` opens a picker of every action, grouped (Comment, Thread, Suggest, Files, Diff, Review, PR, Local, Session) and showing the key bound to each, so typing `rx` finds resolve; using the configured picker provider
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
- `:ReviewModeDiffFullToggle` opens or closes every unchanged fold in the diff (as `zR` / `zM`) and sets how the next one opens, opening the diff if none is open
- `:ReviewModeThread` shows comments on the current line
- `:ReviewModePanel` toggles the thread panel beside the current file
- `:ReviewModeCompose` drafts a PR comment for the current line or visual range
- `:ReviewModeApplySuggestion` applies the suggestion on the current line to the buffer
- `:ReviewModeReply` replies to the latest comment on the current line
- `:ReviewModeResolveThread` resolves the PR review thread on the current line
- `:ReviewModeUnresolveThread` unresolves the PR review thread on the current line
- `:ReviewModeReact [THUMBS_UP]` toggles a reaction on the latest comment on the current line, asking which one when no argument is given
- `:ReviewModeEditComment` edits your most recent comment on the current line in a draft buffer
- `:ReviewModeDeleteComment` deletes your most recent comment on the current line, after a confirmation
- `:ReviewModeComment` creates a PR comment on the current line or visual range
- `:ReviewModeSuggest` suggests your edit on the current line, or drafts a suggestion over the line or visual range starting from the lines as they are
- `:ReviewModeSuggestEdits` queues every edit in the current file as a pending suggestion, and undoes the edits
- `:ReviewModeViewedToggle` toggles viewed state for the current PR file
- `:ReviewModeViewedNext` marks the current PR file viewed and jumps to the next unviewed file
- `:ReviewModeViewedFeatureToggle` toggles viewed-state tracking on or off
- `:ReviewModeCommentsToggle` toggles PR comments on or off
- `:ReviewModeViewedList [all|viewed|unviewed]` opens a PR file list with diff stats; snacks.nvim and Telescope add a diff preview and toggle viewed state with `<Tab>`/`<C-t>`
- `:ReviewModeViewedClear` clears local viewed state for the current PR
- `:ReviewModeViewedSync` pulls viewed state from GitHub
- `:ReviewModeViewedSyncToggle` toggles GitHub viewed-state sync
- `:ReviewModePending` opens the pending review buffer
- `:ReviewModeSubmit [comment|approve|request_changes]` submits the pending review, confirmed first
- `:ReviewModeSummary` shows file, comment, thread, and viewed-sync counts.
- `:ReviewModeCheckout <number|url>` reviews a PR in its own worktree without checking it out
- `:ReviewModeCheckoutClean [pr]` removes clean review worktrees, after a confirmation.
- `:ReviewModeQuickfix [unresolved|all]` fills the quickfix list with review threads and opens it
- `:ReviewModeDiagnosticsToggle` toggles review threads as diagnostics
- `:ReviewModeCIToggle` toggles CI check-run annotations as diagnostics
- `:ReviewModeLocal [<base>] [<head>]` reviews two local refs, with no PR and no network
- `:ReviewModeLocalComments` opens the local comments buffer
- `:ReviewModeSuggestionPreview [inline|split]` toggles a preview of the suggestion on the current line, in the code or side by side
- `:ReviewModeSuggestionAcceptAll` applies every suggestion in the current file as trials, after a confirmation
- `:ReviewModeSuggestionRevert [id]` reverts a trial suggestion: the one under the cursor, or one from `:ReviewModeSuggestionList`
- `:ReviewModeSuggestionList` lists the trial suggestions that are applied but not saved

## Suggestions

### Writing one: edit the code

The easiest way to write a suggestion is to make the change. Edit the PR's code
in the file, with your LSP, formatter and completion, then press `<leader>rr` on
an edited line: the draft opens with the ```` ```suggestion ```` block already
filled in from your edit, and you write a message above it. Post it (`<C-s>`) or
queue it into the pending review (`<C-p>`), and your edit is undone: the change
lives on as the suggestion, and the file matches the PR again.

`:ReviewModeSuggestEdits` (also in the actions picker) does every edit in the
file at once, queueing each into the pending review, where
`:ReviewModePending` lets you add messages before submitting.

Edits are what the buffer says that HEAD, the PR head, does not. A pure
insertion takes the line above into the suggestion, since it has no line of its
own; a deletion suggests nothing in place of the lines. GitHub only takes a
suggestion on lines inside the PR diff (the changes and three lines around
them), so an edit elsewhere is refused with a message rather than posted
somewhere else. Lines you applied as trial suggestions are not your edits and
are left out.

### Reading one

A `suggestion` block in a review comment is a concrete replacement for the lines
it hangs off. Four ways to deal with one, over the same core. None of it is
GitHub-specific: a local review's threads carry suggestion blocks too, and the
same keys work on them.

**See it in the code.** `p` in the panel, or `:ReviewModeSuggestionPreview`,
draws the suggested lines as virtual lines directly under the lines they would
replace, in the panel's diff colours, with the replaced range painted as a
deletion. Nothing is written and no window opens; press it again to take it down.

**See it side by side.** `:ReviewModeSuggestionPreview split` puts the file with
the suggestion applied against the file as it stands, in the same side-by-side
diff the base version uses, folds and partial-line highlights included. It
replaces an open base diff, and toggling it again closes it.

**Try it for real.** `a` in the panel, or `:ReviewModeApplySuggestion`, writes
the suggestion into the buffer and leaves it there, unsaved, with a `T` sign and
a "trial suggestion" label so it is obvious which lines are not yours. Run the
code, see how it behaves, then press `a` again (or `:ReviewModeSuggestionRevert`)
to put the original lines back. Several trials can be live at once, and
`:ReviewModeSuggestionList` shows them with their ids.

Once a suggestion is applied, `p` shows the other half: the lines it replaced,
as deletions above the applied ones, and the split view compares against the
original. Applying takes down any preview of that suggestion first, so nothing
is drawn twice.

Reverting does not lean on `u`. The applied range is tracked with an extmark, so
it restores exactly the lines the suggestion replaced, wherever they have moved
to since, and edits you have made elsewhere in the file are left alone.

**Take them all.** `A` in the panel, or `:ReviewModeSuggestionAcceptAll`, applies
every suggestion in the current file after a confirmation saying how many and in
which file. They go in bottom-up, because a suggestion can replace one line with
three: applying the top one first would move every line number below it and land
the next suggestion on the wrong lines.

Trials are buffer state, not review state, and the plugin does not track git:

- **Save or commit with a trial live and it becomes an ordinary edit.** Nothing
  is unwound, and reverting afterwards only changes the buffer again -- it does
  not touch what you wrote to disk or committed.
- Reloading the buffer (`:e!`, or an autoread re-read) drops its trials and
  previews. Whatever the file holds at that point is what you have.
- Stopping the session forgets every trial for the same reason. It does not undo
  them.

## Diagnostics and Quickfix

Review threads can also be published as `vim.diagnostic` entries in their own
namespace, one per visible thread in each changed-file buffer. Everything built
on diagnostics then works on review comments for free: `]d` / `[d`,
`vim.diagnostic.open_float`, `vim.diagnostic.setloclist`, Trouble, and the
diagnostic counts in your statusline. `user_data` carries the thread id and the
comment URL.

It is off by default (`comments.diagnostics.enabled = true` to turn it on),
because once on, review comments join your LSP diagnostics in every one of those
places, and that should be your decision rather than an upgrade's.

The namespace draws nothing by default:

```lua
comments = {
  diagnostics = {
    enabled = false,
    severity = { unresolved = "INFO", outdated = "HINT", resolved = "HINT" },
    display = { signs = false, virtual_text = false, underline = false },
  },
},
```

The plugin already draws its own comment signs (and end-of-line text, if you
turn `comments.virtual_text` on), so letting the namespace draw as well would
show every thread twice. With `display` off the diagnostics feed navigation,
floats and counts only. If you would rather have the diagnostic display, turn the
entries in `display` on and leave `comments.virtual_text` off.

`:ReviewModeQuickfix` fills the quickfix list with every thread across the PR —
`unresolved` (the default, unless `comments.show_resolved` is set) or `all`,
which appends `[resolved]` to resolved threads. `api.quickfix_items()` returns
the same items without touching the list.

### CI failures

GitHub check runs carry annotations with a file and line — lint errors, failing
assertions, type errors. On a GitHub review they land as diagnostics too, in a
namespace of their own (`review_mode_ci`, source `review-mode CI`), so `]d`
walks CI failures inside the diff and they toggle apart from the threads.
`failure` is an ERROR, `warning` a WARN, `notice` an INFO, and the message reads
`[check name] title: message`. Unlike the thread namespace this one keeps
`vim.diagnostic`'s own display: nothing else draws CI failures.

They are fetched in the background when the review starts, on
`:ReviewModeRefresh`: one request for the head's
check runs, then one per run that reports annotations, so a green PR costs a
single call. They are not refetched when HEAD moves mid-review; refresh for
that. `:ReviewModeCIToggle` (or "Toggle CI diagnostics" in the actions
picker) turns them off and on; `ci = { diagnostics = false }` stops the fetch
altogether. Local and GitLab reviews skip it.

## gh-dash / Worktree Handoff

For external launchers, set `GH_REVIEW_REPO` and `GH_REVIEW_PR` before opening
Neovim, then run `+ReviewMode`:

```sh
GH_REVIEW_REPO=adrianmross/example GH_REVIEW_PR=123 nvim +ReviewMode
```

If those variables are not set, the plugin asks `gh` for the current repo and PR.

## GitLab

Merge requests are reviewed the same way pull requests are: the provider is
picked from the `origin` remote, so a `gitlab.com` checkout just works.

```lua
require("review_mode").setup({
  provider = "auto",          -- "auto" | "github" | "gitlab"
  gitlab_hosts = { "git.corp.example" }, -- self-hosted instances "auto" should treat as GitLab
})
```

Requirements: `glab`, authenticated for the project. `auto` reads the host of
`git remote get-url origin` — anything containing `gitlab`, or listed in
`gitlab_hosts`, is GitLab. A launcher can hand the session over instead, the
same way `GH_REVIEW_*` does:

```sh
GL_REVIEW_MR=123 nvim +ReviewMode
```

`GL_REVIEW_REPO`, `GL_REVIEW_BASE` and `GL_REVIEW_HEAD` skip the matching
startup lookups. Setting `GL_REVIEW_MR` also selects the GitLab provider.

What works: MR metadata, diff discussions loaded as threads (signs, panel,
tree, `api.threads`), starting a thread on a line or range, replying, and
resolving/unresolving. Threads are GitLab discussions, so `api.reply` and
`api.resolve` take a discussion id where GitHub takes a review thread id.

GitHub-only for now, and reported as "not supported on GitLab yet" rather than
falling through to `gh`: viewed-state sync, reactions, editing and deleting
comments, pending comments and review submission, reviewing in a separate
checkout (`:ReviewModeCheckout`), `:ReviewModeStatus` and `:ReviewModeChecks`.
Review comments as diagnostics and the quickfix list are forge-independent and
work on GitLab too. Local
viewed state, the diff views and navigation are forge-independent and work as
usual. A comment on a range anchors to its last line, and `:ReviewModeSuggest`
posts GitHub's suggestion syntax, which GitLab does not read the same way.

## Local Reviews

`:ReviewModeLocal` reviews two refs in this checkout. No PR, no remote, no
network, no `gh`:

```vim
:ReviewModeLocal                  " the merge base with the default branch, vs the working tree
:ReviewModeLocal develop          " vs the working tree
:ReviewModeLocal main feature     " two refs
:ReviewModeLocal main..feature    " the same, as a range
```

The base is always resolved to the merge base with the head, so a local review
compares what a PR would. With no `<head>` the right-hand side is the **working
tree**, so uncommitted edits are part of the review. Naming a `<head>` diffs that
ref instead; the buffers you edit are still the working tree, the same as for a
PR whose head is not checked out.

Everything else is what it always was: the changed-file list, hunk navigation,
the side-by-side and unified diffs, viewed state, the thread panel, diagnostics
and the quickfix list. `provider = "local"` picks it explicitly, and a repo with
no `origin` remote picks it on its own. The PR-only actions (`:ReviewModeChecks`,
`:ReviewModeStatus`, `:ReviewModeBrowser`, `:ReviewModeCopyUrl`) say they are not
supported in a local review rather than asking `gh` about your branch.

### `:ReviewMode` on a branch with no PR

`:ReviewMode` falls back to a local review when the branch has no PR yet — the
point where you want to check your own work, or an agent's, before opening one.
It says so (`no PR for "feat/x", reviewing it locally`), and the statusline reads
`REVIEW local repo@ref` instead of `REVIEW repo#123`, so a local review is never
mistaken for a PR review. Open the PR later and `:ReviewMode` picks it up; the
local comments stay in `.git/`, keyed by branch.

It falls back **only** when `gh` answers that there is no PR. Any other failure
— an expired token, the network, a rate limit — is still reported as an error,
because falling back then would review a branch that may well have a PR, without
its comments, and look like it worked. A PR named with `GH_REVIEW_PR` is never a
fallback candidate either. Set `no_pr = "error"` to be told instead.

`gh` exits `1` for both "no PR" and a real failure, so this keys on its wording;
the test suite pins that string so a `gh` change fails loudly.

### Comments on disk

A local review has no forge to keep comments on, so it keeps them in a file:

```text
<git-dir>/review-mode/<branch-or-head>.json
```

`<git-dir>` is what `git rev-parse --git-dir` answers: `.git` in a normal
checkout, and `.git/worktrees/<name>` in a linked worktree. That is deliberate —
it is the per-worktree git dir, not the shared `--git-common-dir` — so parallel
worktrees of the same repo never see each other's review comments, and the
filename keys them by branch on top of that. Nothing is ever tracked by git.

The file is indented, with a stable key order, because it is meant to be read:

```json
{
  "next_id": 3,
  "threads": [
    {
      "comments": [
        {
          "author": "agent",
          "body": "why two?",
          "created_at": "2026-09-17T09:41:02Z",
          "id": "c1"
        }
      ],
      "id": "t1",
      "line": 2,
      "path": "file.txt",
      "resolved": false,
      "start_line": 2
    }
  ],
  "version": 1
}
```

Comments load into the same normalized shape GitHub and GitLab comments load
into, so signs, virtual text, the panel, `api.threads()`, diagnostics and
quickfix work on them unchanged. `:ReviewModeLocalComments` opens a
`review-mode://local` buffer listing every one of them, grouped by file with
counts: `<CR>` jumps, `r` replies, `x` resolves, `e` edits, `dd` deletes.

### For agents

The whole loop is reachable from a headless Neovim, which is the point of the
on-disk store: an agent can leave review comments a human reads in the editor,
and read the ones a human left.

```bash
# leave a comment
nvim --headless -u NONE -c 'lua require("review_mode").setup()' \
  -c 'lua require("review_mode.api").review_local({ "main" })' \
  -c 'lua require("review_mode.api").local_comment({
        path = "lua/review_mode/api.lua", start_line = 40, end_line = 44,
        body = "This reads the state table directly.", author = "agent" })' \
  -c qa

# read what is there
nvim --headless -u NONE -c 'lua require("review_mode").setup()' \
  -c 'lua local api = require("review_mode.api")
      api.review_local({ "main" })
      print(vim.inspect(api.threads({})))' \
  -c qa
```

| Call | Does |
| --- | --- |
| `api.review_local(args)` | starts the session; `args` is `{}`, `{ base }`, `{ base, head }` or `{ "base..head" }` |
| `api.local_comment(opts, cb)` | creates a thread: `path`, `start_line`, `end_line` (or `line`), `body`, `author`; `cb(true, thread)` |
| `api.threads(opts)` | reads them back, the same call the panel uses |
| `api.reply({ thread_id, body }, cb)` | adds to a thread |
| `api.resolve(thread_id, resolved, cb)` | resolves or unresolves one |
| `api.edit_comment({ comment_id, body }, cb)` | replaces a body |
| `api.delete_comment(comment_id, cb)` | removes a comment, and its thread when it was the last one |
| `api.local_store()` | the JSON file's path, for reading or writing it directly |

Ids are the `t<n>` and `c<n>` the store shows. `author` defaults to the repo's
`git config user.name`, and falls back to `"agent"` when git has no name set —
it is never a GitHub login, because there is no GitHub here.

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
  no_pr = "local", -- "local" | "error": what :ReviewMode does with no PR
  provider = "auto", -- "auto" | "github" | "gitlab"
  gitlab_hosts = {}, -- self-hosted GitLab hosts for provider = "auto"
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
    conditional_requests = true, -- revalidate the REST comment list with If-None-Match
    sign_text = "", -- Nerd Font glyph, override if your font lacks it
    sign_hl_group = "DiagnosticInfo",
    virtual_text = false, -- end-of-line summary beside each comment sign
    compose = "panel", -- "panel" | "prompt": where :ReviewModeComment drafts
    show_resolved = false,
    resolve_flash_ms = 1200, -- 0 turns the resolve/unresolve confirmation off
    diagnostics = {
      enabled = false,
      severity = { unresolved = "INFO", outdated = "HINT", resolved = "HINT" },
      display = { signs = false, virtual_text = false, underline = false },
    },
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
  ci = {
    diagnostics = true, -- CI check-run annotations as diagnostics (GitHub)
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
    gh_metadata_cache = "10m", -- `gh api --cache` duration; "0" turns it off
  },
  commands = true,
})
```

### Fewer GitHub API calls

Two knobs keep a review off the rate limit.

`comments.conditional_requests` (default `true`) revalidates the REST comment
list with `If-None-Match` instead of re-downloading it once
`comments.cache_ttl_seconds` is up. GitHub answers an unchanged page with
`304 Not Modified`, which costs nothing against the rate limit at all, and the
cached comments are served with their timestamp refreshed. GitHub's ETags are
per page, not per collection, so one ETag and one payload are stored per page
and each page is revalidated on its own: a page that answers `200` is replaced
while its neighbours keep serving from the cache. The GraphQL review-thread
query is the primary comment path and is a `POST`, which GitHub does not answer
with `304`; it still goes by `comments.cache_ttl_seconds`.

`performance.gh_metadata_cache` (default `"10m"`) is the duration passed to
`gh api --cache` for reads that repeat and cannot go stale in a way that
misleads - today the PR's GraphQL node id, which never changes. The PR head SHA
is deliberately not cached (it is re-read precisely to notice that HEAD moved),
nor are `:ReviewModeStatus` and `:ReviewModeChecks`, which are run to see what
changed. Note that `--cache` is a flag of `gh api` alone; `gh pr view` and
`gh repo view` do not accept it.

`:ReviewModeSummary` and `review_mode.api.request_stats()` report how many `gh`
invocations the session has spent and how many were answered `304`.

`ReviewMode` loads PR metadata and changed-file status asynchronously. If
`GH_REVIEW_BASE` is set by a launcher, changed-file loading starts immediately
without waiting for GitHub metadata. Hunk locations are loaded lazily per file,
with immediate focused-file prefetch, opportunistic `gitsigns.nvim` hunk-cache
reuse, and an optional delayed background scan for PRs under
`performance.background_hunk_scan.max_files`.

On a warm cache the comment signs are drawn from `stdpath("cache")` before any
`gh` call returns: each branch remembers the PR it last resolved to, so even a
plain `:ReviewMode` shows that PR's cached comments at once and reconciles when
`gh pr view` answers. `scripts/validate.sh` holds this to a budget: with every
`gh` call slowed by 3s, the first comment sign of a warm start must appear
within `REVIEW_MODE_STARTUP_BUDGET_MS` (default 500 ms; ~20 ms measured). The
measured time is printed on every run.

External launchers can provide `GH_REVIEW_REPO`, `GH_REVIEW_PR`,
`GH_REVIEW_BASE`, and `GH_REVIEW_HEAD` to avoid startup discovery calls, or
`GL_REVIEW_MR`, `GL_REVIEW_REPO`, `GL_REVIEW_BASE` and `GL_REVIEW_HEAD` for
GitLab.

Viewed state is persisted in `stdpath("state")/review-mode-state.json` by
default. Set `viewed.sync = true` or run `:ReviewModeViewedSyncToggle` to pull
GitHub's PR file viewed state at startup and push local viewed/unviewed toggles
back to GitHub.

The built-in side-by-side old-version split remains the default diff backend.
Set `diff.layout = "unified"` or run `:ReviewModeDiffLayoutToggle` to use an
inline unified diff buffer in the current window instead. Closing unified mode
restores the original file buffer. Both layouts hold the whole file and fold
the unchanged regions, so Vim's fold keys condense and expand them: `zR` shows
everything, `zM` condenses again, `zo` / `zc` open or close one gap. Unified
diffs keep `diff.unified_context` lines visible around each change;
`diff.full_file = true` opens diffs with every fold open. When `diff.use_fast_diffopt`
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
