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
local viewed_state = require("review_mode.viewed")

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
  "highlights_changed",
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
  -- suggestions
  "suggestion_accepted",
  "suggestion_reverted",
  -- CI annotations
  "ci_loaded",
  -- follow HEAD: { from = <old sha>, to = <new sha> }
  "head_moved",
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
    provider = state.provider,
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
  local changed = (stats.additions or 0) + (stats.deletions or 0) > 0
  return {
    path = path,
    status = state.files[path],
    added = stats.additions or 0,
    removed = stats.deletions or 0,
    viewed = state.viewed[path] == true,
    comments = #(state.comments[path] or {}),
    unresolved = M.unresolved_count(path),
    -- known only once its hunks load: lines changed, yet none survive git diff -w
    whitespace_only = state.config.diff.ignore_whitespace
      and changed
      and state.hunks_loaded[path] == true
      and #(state.hunks[path] or {}) == 0,
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

--- viewed, total hunks marked viewed in a file; nil when its hunks are not
--- loaded, viewed tracking is off, or there is no path. A hunk is remembered by
--- its content, so a push that changes it brings it back unviewed.
function M.hunk_progress(path)
  return viewed_state.hunk_progress(path)
end

-- Review progress ------------------------------------------------------------

--- How far a file is reviewed, 0..1: 1 once it is viewed, else the share of its
--- hunks viewed (0 until they load, or with viewed tracking off).
function M.review_fraction(path)
  if state.viewed[path] then
    return 1
  end
  local seen, total = M.hunk_progress(path)
  if seen and total and total > 0 then
    return seen / total
  end
  return 0
end

--- Comment threads on a file, resolved ones included: total, resolved.
function M.thread_counts(path)
  local total, resolved = 0, 0
  for _, thread in ipairs(M.threads({ path = path, include_resolved = true })) do
    total = total + 1
    if thread.is_resolved then
      resolved = resolved + 1
    end
  end
  return total, resolved
end

--- How much of the review is done, 0..100, each file weighed by its changed
--- lines (a 400-line file counts for more than a 2-line one), rounded down so
--- 100 means everything is viewed. Cheap enough for a statusline: no threads.
function M.review_percent()
  local weight, done = 0, 0
  for _, path in ipairs(state.file_order) do
    local entry = M.file(path) or {}
    -- a rename or mode change has no lines; let it weigh like one
    local lines = math.max((entry.added or 0) + (entry.removed or 0), 1)
    weight = weight + lines
    done = done + lines * M.review_fraction(path)
  end
  return weight > 0 and math.floor(done / weight * 100) or 0
end

--- The whole review at a glance:
--- { percent, files, files_viewed, files_left, threads, resolved, added, removed },
--- percent as review_percent() gives it.
function M.review_progress()
  local progress = { files = 0, files_viewed = 0, threads = 0, resolved = 0, added = 0, removed = 0 }
  for _, path in ipairs(state.file_order) do
    local entry = M.file(path) or {}
    local added, removed = entry.added or 0, entry.removed or 0
    local threads, resolved = M.thread_counts(path)
    progress.files = progress.files + 1
    progress.files_viewed = progress.files_viewed + (state.viewed[path] and 1 or 0)
    progress.threads = progress.threads + threads
    progress.resolved = progress.resolved + resolved
    progress.added = progress.added + added
    progress.removed = progress.removed + removed
  end
  progress.files_left = progress.files - progress.files_viewed
  progress.percent = M.review_percent()
  return progress
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
    core.diff_range(),
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
  if state.provider == "local" then
    return require("review_mode.providers.local").edit_comment(opts, callback)
  end
  return github.edit_comment(opts, callback)
end

--- Delete your own comment. Emits "comment_deleted" and reloads comments.
--- callback(ok, err).
function M.delete_comment(comment_id, callback)
  if state.provider == "local" then
    return require("review_mode.providers.local").delete_comment(comment_id, callback)
  end
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
  unresolved = { "next_unresolved", "prev_unresolved" },
  file = { "next_file", "prev_file" },
}

--- kind is "hunk", "comment", "unresolved" or "file".
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

--- What the review has not covered yet, counted from state already loaded (it
--- never fetches): { unviewed_files, unviewed_hunks, ci_failures,
--- unresolved_threads, pending }. unviewed_hunks counts not-viewed hunks in the
--- unviewed files whose hunks have loaded; ci_failures counts CI failure
--- annotations on a changed line with no comment of yours over it, and stays 0
--- until CI annotations load. The APPROVE confirmation lists the non-zero ones
--- (review.submit_check).
function M.review_readiness()
  return review.readiness()
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

-- CI annotations --------------------------------------------------------------

--- Check-run annotations on the PR head for one file: a list of
--- { check, start_line, end_line, severity, message }.
function M.ci_annotations(path)
  return require("review_mode.ci").annotations(path)
end

--- Refetch CI annotations for the PR head ("ci_loaded" fires when done).
function M.reload_ci()
  return require("review_mode.ci").load_async()
end

-- Local reviews ---------------------------------------------------------------
--
-- A local review compares two refs in this checkout, with no PR and no network,
-- and keeps its comments in a JSON file under the repo's git dir. Everything
-- else on this page -- threads, replies, resolve, edit, delete, signs, the
-- panel, diagnostics, quickfix -- works against it unchanged, which is what
-- makes the whole loop reachable from a headless Neovim:
--
--   nvim --headless -c 'lua require("review_mode.api").review_local({ "main" })' \
--        -c 'lua require("review_mode.api").local_comment({ path = "init.lua",
--              line = 10, body = "why?", author = "agent" })' -c qa

--- Start a local review. `args` is {}, { base }, { base, head } or
--- { "base..head" }; base defaults to the merge base with the repo's default
--- branch, and head defaults to the working tree.
function M.review_local(args)
  return plugin().review_local(args)
end

--- Create a local comment thread on disk. opts: path, start_line, end_line (or
--- line), body, author (defaults to git user.name, else "agent").
--- callback(true, thread) on success, callback(false, err) otherwise.
---
--- Only for local reviews; a PR comment goes through M.comment.
function M.local_comment(opts, callback)
  return require("review_mode.providers.local").add_comment(opts, callback)
end

--- The file a local review keeps its comments in, or nil when the session is
--- not a local one. It is stable enough to read and write from outside Neovim.
function M.local_store()
  return state.local_store
end

--- Every path that carries comments in this session: the review's changed files
--- first, in review order, then any other path a comment is anchored to.
function M.comment_paths()
  local seen, paths = {}, {}
  for _, path in ipairs(state.file_order) do
    if state.comments[path] and #state.comments[path] > 0 then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end

  local extra = {}
  for path, list in pairs(state.comments) do
    if not seen[path] and #list > 0 then
      extra[#extra + 1] = path
    end
  end
  table.sort(extra)
  return vim.list_extend(paths, extra)
end

-- End local reviews -------------------------------------------------------------

-- API call accounting ----------------------------------------------------------

--- How much this session has spent on the forge CLI:
--- { calls = <gh/glab processes spawned>, not_modified = <304 answers> }.
--- Counts processes, not network requests: a call served from `gh --cache`
--- still shows in `calls`. A 304 is free -- it costs nothing against the rate
--- limit -- so `not_modified` is the share of comment fetches that cost nothing.
--- :ReviewModeSummary prints the same two numbers.
function M.request_stats()
  return util.request_stats()
end

-- End API call accounting ------------------------------------------------------

-- Suggestions -----------------------------------------------------------------

local function suggestions()
  return require("review_mode.suggestions")
end

--- Suggestion-bearing threads in a file (or in the whole review when path is
--- nil), first line first. An entry is { id, thread, path, start_line,
--- end_line, lines } -- lines being what the suggestion puts in place of the
--- range.
function M.suggestions(path)
  return suggestions().list(path)
end

--- The suggestions anchored over one line.
function M.suggestions_at(path, line)
  return suggestions().at(path, line)
end

--- Toggle a preview of one suggestion, which may be a thread from M.threads or
--- an entry from M.suggestions. opts.layout is "inline" (virtual lines under
--- the range it would replace, the default) or "split" (side by side against
--- the file with the suggestion applied); opts.buf picks the buffer when the
--- file is not the current one. Returns true when the preview is now up, false
--- when it was taken down, or nil and an error.
function M.preview_suggestion(entry, opts)
  opts = opts or {}
  if opts.layout == "split" then
    return suggestions().preview_split(entry, opts.buf)
  end
  return suggestions().preview(entry, opts.buf)
end

--- Write a suggestion into the buffer as a trial: unsaved, visibly marked, and
--- revertible through M.revert_suggestion. Emits "suggestion_accepted".
--- Returns { id, buf, path, thread_id, line, added, removed }, or nil and err.
function M.accept_suggestion(entry, opts)
  opts = opts or {}
  return suggestions().accept(entry, opts.buf)
end

--- Accept every suggestion in one file. Applied bottom-up, so an earlier
--- application never moves the lines a later one is anchored to. Returns how
--- many were applied, and the first error if any were refused.
function M.accept_all_suggestions(path, opts)
  opts = opts or {}
  return suggestions().accept_all(path, opts.buf)
end

--- Undo a trial, restoring the exact lines it replaced even when the file has
--- been edited around it since. id is an id from M.suggestion_trials, or nil
--- for the trial under the cursor. Emits "suggestion_reverted".
function M.revert_suggestion(id)
  return suggestions().revert(id)
end

--- The trials that are applied but not saved:
--- { { id, buf, path, thread_id, line, added, removed }, ... }.
function M.suggestion_trials()
  return suggestions().trials()
end

--- What committing the live trials would do, for a confirmation. The plan is
--- opaque: pass it to M.commit_suggestions unchanged. Its stable fields are
--- trials = { { id, path, line, thread_id, suggester }, ... } and message,
--- suggester being { login, id, name, is_viewer }; the rest is internal. Or nil and why nothing can
--- be committed: no trials, staged changes, or a trial the user's own edits
--- reach into.
function M.suggestion_commit_plan()
  return suggestions().commit_plan()
end

--- Commit a plan from M.suggestion_commit_plan: only the trial lines, onto
--- HEAD, with a Co-authored-by trailer per suggester (GitHub reviews only).
--- Local only; nothing is pushed. Writes the buffers and forgets the trials.
--- Returns { sha, unwritten }, or nil and an error.
function M.commit_suggestions(plan)
  return suggestions().commit(plan)
end

-- Your edits, as suggestions: each hunk of the buffer that differs from HEAD,
-- as { path, start_line, end_line, lines, in_diff, ... }. opts.buf picks the
-- buffer (default: the current one).
local function edits()
  return require("review_mode.edits")
end

local function edit_buffer(opts)
  local bufnr = (opts or {}).buf or vim.api.nvim_get_current_buf()
  return bufnr, util.buf_relpath(bufnr)
end

--- The edited hunks in a buffer, top to bottom, trial suggestions left out.
function M.edits(opts)
  local bufnr, path = edit_buffer(opts)
  return path and edits().list(bufnr, path) or {}
end

--- The edit covering a line, or nil.
function M.edit_at(line, opts)
  local bufnr, path = edit_buffer(opts)
  return path and edits().at(bufnr, path, line) or nil
end

--- The comment body that suggests an edit, with an optional message above it.
function M.edit_suggestion_body(edit, message)
  return edits().body(edit, message)
end

--- Pin an edit to its buffer range, so a later undo_edit finds it.
function M.track_edit(edit)
  return edits().track(edit)
end

--- Put HEAD's lines back over an edit, once it lives on as a suggestion.
function M.undo_edit(edit)
  return edits().undo(edit)
end

-- End suggestions ---------------------------------------------------------------

-- Escape hatches --------------------------------------------------------------

--- The raw session table. Unstable on purpose: reach for it only when the API
--- above is missing something, and tell me what that was.
function M.unstable_state()
  return state
end

return M
