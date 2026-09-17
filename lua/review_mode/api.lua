-- The public API.
--
-- This is the surface other code is meant to build on: review data reaches the
-- bundled panel, picker and nvim-tree decorations only through here, never
-- through state, github, viewed, comments or diff. That rule is the point — if
-- the built-in UI cannot reach past this module, then anything it can do, your
-- own UI can do too. (review_mode.util and review_mode.hooks are shared
-- infrastructure carrying no review data, so a UI may require them directly;
-- this module deliberately does not re-export them, because a passthrough would
-- blur the boundary. scripts/validate.sh enforces the list.)
--
-- Everything here is stable. The modules behind it are not: functions that
-- still live in init.lua are reached through a lazy require inside the call, so
-- internals can keep moving without this file's signatures changing.
local M = {}

local core = require("review_mode.state")
local hooks = require("review_mode.hooks")
local util = require("review_mode.util")
local comments_ui = require("review_mode.comments")
local github = require("review_mode.github")
local review = require("review_mode.review")

local state = core.state

-- Resolved at call time, not load time, so requiring the API never cycles back
-- through the plugin entry point.
local function plugin()
  return require("review_mode")
end

M.events = {
  "start",
  "enter",
  "leave",
  "stop",
  "comments_loaded",
  "viewed_changed",
  "panel_open",
  "panel_close",
  "comment_posted",
  "thread_resolved",
  "checkout_ready",
  "checkout_removed",
  "reaction_changed",
  -- edit and delete
  "comment_edited",
  "comment_deleted",
  -- pending review
  "pending_changed",
  "review_submitted",
}

-- Session ---------------------------------------------------------------------

--- The current review session, or nil when none is loaded.
function M.session()
  if not state.active then
    return nil
  end
  return {
    repo = state.repo,
    pr = state.pr,
    base = state.base,
    head = state.head,
    root = state.root,
    in_mode = state.in_mode,
  }
end

function M.is_in_mode()
  return state.in_mode == true
end

function M.config()
  return state.config
end

-- Lifecycle -------------------------------------------------------------------

function M.start()
  return plugin().start()
end

function M.stop()
  return plugin().stop()
end

function M.enter()
  return plugin().enter()
end

function M.leave()
  return plugin().leave()
end

function M.toggle()
  return plugin().toggle()
end

function M.refresh()
  return plugin().refresh()
end

--- Review a PR without checking it out: fetch it into a detached worktree and
--- start the session there in its own tabpage. opts = { pr = number|url,
--- repo = "owner/repo"? }. callback(ok, result_or_err), result.path is the tree.
function M.review_pr(opts, callback)
  return plugin().review_pr(opts, callback)
end

-- Files -----------------------------------------------------------------------

local function file_entry(path)
  local stats = state.file_stats[path] or {}
  return {
    path = path,
    status = state.files[path],
    added = stats.additions or 0,
    removed = stats.deletions or 0,
    viewed = state.viewed[path] == true,
    comments = #(state.comments[path] or {}),
    unresolved = M.unresolved_count(path),
  }
end

--- Every changed file in the PR, in the order the review walks them.
function M.files()
  local out = {}
  for _, path in ipairs(state.file_order) do
    out[#out + 1] = file_entry(path)
  end
  return out
end

--- One changed file, or nil when the path is not part of the PR.
function M.file(path)
  if not path or not state.files[path] then
    return nil
  end
  return file_entry(path)
end

--- Mark a file viewed or unviewed. Emits "viewed_changed" and, when GitHub sync
--- is on, queues the change for GitHub.
function M.set_viewed(path, viewed)
  return plugin().set_viewed(path, viewed)
end

--- Hunk ranges for a file. Loading is lazy, so this takes a callback.
function M.hunks(path, callback)
  return plugin().with_hunks(path, callback)
end

function M.is_active()
  return state.active
end

--- The ref the review compares against, e.g. "origin/main".
function M.base_ref()
  return core.base_ref()
end

function M.root()
  return state.root
end

function M.is_changed_file(path)
  return state.files[path] ~= nil
end

function M.is_changed_dir(path)
  return state.dirs[path] == true
end

function M.is_viewed_file(path)
  return state.config.viewed.enabled and state.viewed[path] == true
end

local function unresolved_file_comment_count(path)
  local count = 0
  for _, comment in ipairs(state.comments[path] or {}) do
    if comment.is_resolved ~= true then
      count = count + 1
    end
  end
  return count
end

-- nvim-tree asks every visible node for its counts on every render, so walking
-- file_order per directory made a render O(nodes * changed files). Roll the
-- per-directory totals up once instead.
--
-- The memo lives for one event-loop turn: a render is synchronous, and the bulk
-- rewrites of state.viewed/state.comments all happen inside async callbacks,
-- which are turns of their own. set_viewed_path clears it directly because a
-- toggle can be followed by a read in the same turn.
local function dir_totals()
  if state.dir_totals then
    return state.dir_totals
  end

  local totals = { changed = {}, unviewed = {}, unresolved = {} }
  for _, file in ipairs(state.file_order) do
    local unviewed = state.viewed[file] and 0 or 1
    local unresolved = unresolved_file_comment_count(file)
    local dir = vim.fs.dirname(file)
    while dir and dir ~= "." and dir ~= "" do
      totals.changed[dir] = (totals.changed[dir] or 0) + 1
      totals.unviewed[dir] = (totals.unviewed[dir] or 0) + unviewed
      totals.unresolved[dir] = (totals.unresolved[dir] or 0) + unresolved
      dir = vim.fs.dirname(dir)
    end
  end

  state.dir_totals = totals
  vim.schedule(function()
    state.dir_totals = nil
  end)
  return totals
end

function M.unviewed_count(path)
  if not state.config.viewed.enabled or not path then
    return 0
  end

  if state.files[path] then
    return state.viewed[path] and 0 or 1
  end

  if not state.dirs[path] then
    return 0
  end

  return dir_totals().unviewed[path] or 0
end

function M.is_viewed_dir(path)
  if not state.config.viewed.enabled or not state.dirs[path] then
    return false
  end

  local totals = dir_totals()
  return (totals.changed[path] or 0) > 0 and (totals.unviewed[path] or 0) == 0
end

function M.comment_count(path)
  return #(state.comments[path] or {})
end

function M.unresolved_count(path)
  if not state.config.comments.enabled or not path then
    return 0
  end

  if state.files[path] then
    return unresolved_file_comment_count(path)
  end

  if not state.dirs[path] then
    return 0
  end

  return dir_totals().unresolved[path] or 0
end

--- The configured comment sign glyph.
function M.comment_sign()
  local comments_config = state.config.comments or {}
  return comments_config.sign_text or core.defaults.comments.sign_text
end

--- The sign glyph with a count, e.g. " 3", as the tree and picker render it.
function M.comment_count_label(count)
  return string.format("%s %d", M.comment_sign(), count)
end

--- Open a changed file at a line.
function M.goto_file(path, line)
  return plugin().goto_file(path, line)
end

--- The PR diff for one file, as raw text. Async: git is slow enough on a large
--- file to stall a picker preview. callback(diff, err).
function M.file_diff(path, callback)
  util.system_async({
    "git",
    "diff",
    "--find-renames",
    "--no-ext-diff",
    "--no-color",
    M.base_ref() .. "...HEAD",
    "--",
    path,
  }, { cwd = state.root, raw = true }, callback)
end

-- Threads ---------------------------------------------------------------------

--- Comment threads, newest comment last within each thread.
---
--- opts.path             restrict to one file (defaults to every file)
--- opts.line             only threads anchored to this line
--- opts.include_resolved keep resolved threads (default false)
function M.threads(opts)
  opts = opts or {}
  local paths = opts.path and { opts.path } or state.file_order
  local out = {}

  for _, path in ipairs(paths) do
    local threads = comments_ui.threads(review.with_pending(state.comments[path], path), path)
    if opts.line then
      threads = comments_ui.on_line(threads, opts.line)
    end
    threads = comments_ui.visible(threads, opts.include_resolved == true)
    for _, thread in ipairs(threads) do
      out[#out + 1] = thread
    end
  end

  return out
end

--- Start a new thread on a line or range. callback(ok, err).
function M.comment(opts, callback)
  return plugin().submit_comment(opts, callback)
end

--- Add to an existing thread. callback(ok, err).
function M.reply(opts, callback)
  return plugin().submit_reply(opts, callback)
end

--- Resolve or unresolve a thread. Needs a GitHub thread id, so threads loaded
--- through the REST fallback cannot be resolved.
function M.resolve(thread_id, resolved, callback)
  return plugin().set_thread_resolved_by_id(thread_id, resolved ~= false, callback)
end

-- Edit and delete ---------------------------------------------------------------

--- True when the viewer may edit or delete this comment; otherwise false and
--- why not. Comments loaded through the REST fallback carry no authorship, so
--- they are always refused.
function M.can_modify_comment(comment_id)
  local comment, err = github.own_comment(comment_id)
  return comment ~= nil, err
end

--- Replace the body of your own comment. opts: comment_id, body.
--- Emits "comment_edited" and reloads comments. callback(ok, err).
function M.edit_comment(opts, callback)
  return github.edit_comment(opts, callback)
end

--- Delete your own comment. Emits "comment_deleted" and reloads comments.
--- callback(ok, err).
function M.delete_comment(comment_id, callback)
  return github.delete_comment(comment_id, callback)
end

--- Reload comments from GitHub, bypassing the disk cache.
function M.reload_comments()
  return github.load_comments_async({ force = true })
end

-- Reactions ---------------------------------------------------------------------

--- The eight reactions GitHub accepts, as { content = "THUMBS_UP", emoji = ... }.
M.reaction_contents = comments_ui.reaction_contents

--- Toggle a reaction on a comment from M.threads: removed when you already
--- reacted with it, added otherwise. Emits "reaction_changed". callback(ok, err).
---
--- opts.comment  a thread comment
--- opts.content  one of M.reaction_contents, e.g. "THUMBS_UP"
---
--- Comments loaded through the REST fallback can gain a reaction but not lose
--- one: removal needs a GraphQL id.
function M.react(opts, callback)
  opts = opts or {}
  return github.toggle_reaction(opts.comment, opts.content, callback)
end

-- Navigation ------------------------------------------------------------------

local jumps = {
  hunk = { "next_hunk", "prev_hunk" },
  comment = { "next_comment", "prev_comment" },
  file = { "next_file", "prev_file" },
}

--- kind is "hunk", "comment" or "file".
function M.goto_next(kind)
  local names = jumps[kind] or jumps.hunk
  return plugin()[names[1]]()
end

function M.goto_prev(kind)
  local names = jumps[kind] or jumps.hunk
  return plugin()[names[2]]()
end

-- Rendering -------------------------------------------------------------------

--- Turn threads into buffer lines plus extmark specs, the same way the built-in
--- panel does. Returns lines, marks, rows-by-thread-id, header-rows-by-comment-id.
function M.render_threads(threads, opts)
  return comments_ui.render(threads, opts)
end

--- Write rendered lines and marks into a scratch buffer.
function M.apply_render(bufnr, namespace, lines, marks)
  return comments_ui.apply(bufnr, namespace, lines, marks)
end

--- The suggestion block in a comment, as a list of lines, or nil.
function M.suggestion(comment)
  return comments_ui.suggestion_body(comment)
end

--- Make sure comments are available: serve the disk cache if it is warm and
--- kick off a fetch when there is nothing loaded yet.
function M.ensure_comments()
  if vim.tbl_isempty(state.comments) then
    github.hydrate_comments()
  end
  if vim.tbl_isempty(state.comments) then
    github.load_comments_async({})
  end
end

--- Register the thread highlight groups (idempotent). A custom UI that uses
--- render_threads wants these defined too.
function M.ensure_highlights()
  if state.thread_highlights_set then
    return
  end
  state.thread_highlights_set = true

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("review_mode_highlights", { clear = true }),
    callback = function()
      state.thread_highlights_set = false
      vim.schedule(function()
        M.ensure_highlights()
        hooks.emit("highlights_changed", {})
      end)
    end,
  })

  for group, link in pairs(comments_ui.highlights) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
end

M.highlights = comments_ui.highlights

--- Windows currently showing the plugin's diff buffer, so a UI can avoid
--- treating one as the code window.
---
--- Deliberately by buffer, not by stored window id: side-by-side keeps the real
--- file in old_target_win, and excluding that would leave a UI with no code
--- window to follow. Unified swaps the diff buffer into that same window, and
--- then it should be excluded.
function M.diff_windows()
  local wins = {}
  if not state.old_buf or not vim.api.nvim_buf_is_valid(state.old_buf) then
    return wins
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == state.old_buf then
      wins[#wins + 1] = win
    end
  end
  return wins
end

--- Open the PR, or a specific comment, in the browser.
function M.open_url(url, callback)
  return util.open_url(url, callback)
end

-- Pending review --------------------------------------------------------------

--- Draft comments queued for the next review on this PR, oldest first:
--- { { id, path, start_line, end_line, side, body, created_at }, ... }
--- They persist across restarts and show in api.threads as pending comments.
function M.pending()
  return review.list()
end

--- Queue a new comment instead of posting it. opts: path, start_line, end_line
--- (or line), body. Returns the draft, or nil and an error. Replies cannot be
--- queued: the reviews endpoint only accepts new comments.
function M.add_pending(opts)
  return review.add(opts)
end

function M.remove_pending(id)
  return review.remove(id)
end

function M.discard_pending()
  return review.discard()
end

--- Submit every pending draft as one review. opts.event is "COMMENT",
--- "APPROVE" or "REQUEST_CHANGES"; opts.body is the review summary, required
--- for REQUEST_CHANGES and for a COMMENT with no drafts. Drafts are cleared only
--- once GitHub accepts the review. callback(ok, err).
function M.submit_review(opts, callback)
  return review.submit(opts, callback)
end

-- Events ----------------------------------------------------------------------

--- Subscribe to one of M.events. Returns a function that unsubscribes.
function M.on(event, fn)
  return hooks.on(event, fn)
end

-- Diagnostics and quickfix ----------------------------------------------------

--- Quickfix items for review threads, without setting the list.
--- opts.filter is "unresolved" or "all" (defaults to comments.show_resolved).
function M.quickfix_items(opts)
  return require("review_mode.diagnostics").quickfix_items(opts)
end

--- Fill the quickfix list with review threads and open it (opts.open = false
--- to only set it).
function M.set_quickfix(opts)
  return require("review_mode.diagnostics").set_quickfix(opts)
end

-- Escape hatches --------------------------------------------------------------

--- The raw session table. Unstable on purpose: reach for it only when the API
--- above is missing something, and tell me what that was.
function M.unstable_state()
  return state
end

return M
