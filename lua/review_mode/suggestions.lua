-- Seeing a suggestion in the code before you take it.
--
-- Four ways to look at the same thing, over one core: an entry is a thread's
-- ```suggestion block plus the line range it replaces.
--
--   * preview   virt_lines under the range, the range itself painted as a
--               deletion. No windows, no buffer writes.
--   * split     the same comparison in diff.lua's side-by-side machinery.
--   * accept    write it into the buffer as a *trial*: unsaved, marked, and
--               revertible. The applied range is tracked by an extmark, so a
--               revert restores the original lines even after the user has
--               edited elsewhere in the file.
--   * accept_all  every suggestion in one file, applied bottom-up.
--
-- Trials are buffer state, not review state: they die with a buffer reload and
-- with the session, and once the buffer is written they are an ordinary edit
-- the plugin no longer knows anything about.
local M = {}

local hooks = require("review_mode.hooks")
local util = require("review_mode.util")
local comments_ui = require("review_mode.comments")
local diff = require("review_mode.diff")

local preview_ns = vim.api.nvim_create_namespace("review_mode_suggestion_preview")
local trial_ns = vim.api.nvim_create_namespace("review_mode_suggestion_trial")

-- live trials, oldest first
local trials = {}
local last_trial_id = 0

-- extmark ids of the open inline previews, by buffer and thread id
local previews = {}

-- the thread whose side-by-side preview is open, if any
local split_thread = nil

-- defined with the trials below; the previews need them first
local trial_range, trial_for_thread

-- Resolved at call time so requiring this module never cycles through the API.
local function review_api()
  return require("review_mode.api")
end

-- Entries ---------------------------------------------------------------------

--- The suggestion a thread carries, as a replacement for a line range, or nil.
--- Already-normalized entries pass through, so every entry point takes either.
function M.entry(thread)
  if not thread or thread.lines then
    return thread
  end

  local lines
  for _, comment in ipairs(thread.comments or {}) do
    lines = comments_ui.suggestion_body(comment) or lines
  end
  if not lines or not thread.line then
    return nil
  end

  return {
    id = thread.id,
    thread = thread,
    path = thread.path,
    start_line = math.max(1, thread.start_line or thread.line),
    end_line = thread.line,
    lines = lines,
  }
end

--- Every suggestion-bearing thread in a file, first line first -- or, with no
--- path, in the whole review, grouped by file.
---
--- The whole-review case asks for comment_paths() rather than letting
--- api.threads walk the changed-file list: a local review can anchor a comment
--- to a path the review did not change, and an agent asking what suggestions
--- exist must not quietly miss those. comment_paths() already yields each path
--- once, changed files first in review order, so the grouping is stable and
--- nothing is listed twice.
function M.list(path)
  local api = review_api()
  local paths = path and { path } or api.comment_paths()

  local out = {}
  for _, target in ipairs(paths) do
    local found = {}
    for _, thread in ipairs(api.threads({ path = target })) do
      local entry = M.entry(thread)
      if entry then
        found[#found + 1] = entry
      end
    end
    table.sort(found, function(left, right)
      return left.start_line < right.start_line
    end)
    vim.list_extend(out, found)
  end
  return out
end

-- Buffers ---------------------------------------------------------------------

local function buffer_for(path, bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end

  local current = vim.api.nvim_get_current_buf()
  if util.buf_relpath(current) == path then
    return current
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and util.buf_relpath(buf) == path then
      return buf
    end
  end
  return nil
end

-- The lines the suggestion stands in for, clamped to the buffer as it is now.
local function anchored_range(entry, bufnr)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local last = math.min(entry.end_line or 0, count)
  if last < 1 then
    return nil
  end
  return math.max(1, math.min(entry.start_line or last, last)), last
end

-- Resolve "which suggestion, in which buffer" once for every entry point.
local function resolve(entry, bufnr)
  entry = M.entry(entry)
  if not entry then
    return nil, nil, "no suggestion in this thread"
  end

  bufnr = buffer_for(entry.path, bufnr)
  if not bufnr then
    return nil, nil, string.format("no open buffer for %s", tostring(entry.path))
  end
  return entry, bufnr, nil
end

-- Preview ---------------------------------------------------------------------

--- Toggle the inline preview for one suggestion. Returns true when it is now
--- shown, false when it was taken down, or nil and an error.
function M.preview(entry, bufnr)
  local err
  entry, bufnr, err = resolve(entry, bufnr)
  if not entry then
    return nil, err
  end

  local open = (previews[bufnr] or {})[entry.id]
  if open then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, preview_ns, open)
    previews[bufnr][entry.id] = nil
    return false
  end

  review_api().ensure_highlights()
  -- Applied already: the suggestion is in the text, so show what it replaced,
  -- above it, as the deletion half of a diff.
  local trial = trial_for_thread(bufnr, entry.id)
  if trial then
    local start_row = trial_range(trial)
    local virt_lines = {}
    for _, line in ipairs(trial.original) do
      virt_lines[#virt_lines + 1] = { { line, "ReviewModeSuggestionDelete" } }
    end
    if #virt_lines == 0 then
      virt_lines[1] = { { "(this trial only added lines)", "ReviewModeHint" } }
    end
    local id = vim.api.nvim_buf_set_extmark(bufnr, preview_ns, start_row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
    })
    previews[bufnr] = previews[bufnr] or {}
    previews[bufnr][entry.id] = id
    return true
  end

  local first, last = anchored_range(entry, bufnr)
  if not first then
    return nil, "suggestion is not anchored to a line here"
  end

  local virt_lines = {}
  for _, line in ipairs(entry.lines) do
    virt_lines[#virt_lines + 1] = { { line, "ReviewModeSuggestionAdd" } }
  end
  if #virt_lines == 0 then
    virt_lines[1] = { { "(suggests removing these lines)", "ReviewModeHint" } }
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, preview_ns, first - 1, 0, {
    end_row = last - 1,
    end_col = #(vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""),
    hl_group = "ReviewModeSuggestionDelete",
    virt_lines = virt_lines,
  })
  previews[bufnr] = previews[bufnr] or {}
  previews[bufnr][entry.id] = id
  return true
end

--- Drop every inline preview, in one buffer or in all of them.
function M.clear_previews(bufnr)
  for buf in pairs(previews) do
    if not bufnr or buf == bufnr then
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, preview_ns, 0, -1)
      end
      previews[buf] = nil
    end
  end
end

--- Toggle the side-by-side preview: the file with this suggestion applied
--- against the file as it stands. Reuses diff.lua's base-version machinery, so
--- it replaces an open base diff and |:ReviewModeOldToggle| closes it again.
function M.preview_split(entry, bufnr)
  local err
  entry, bufnr, err = resolve(entry, bufnr)
  if not entry then
    return nil, err
  end

  if split_thread == entry.id and diff.old_view_is_open() then
    diff.close_old_view()
    split_thread = nil
    return false
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil, string.format("%s is not in a window", tostring(entry.path))
  end

  -- the other side: the file with the suggestion in, or, once it is applied,
  -- the file with the lines it replaced put back
  local first, last, replacement, name
  local trial = trial_for_thread(bufnr, entry.id)
  if trial then
    local start_row, finish = trial_range(trial)
    first, last, replacement, name = start_row + 1, finish, trial.original, "pr-suggestion-original://"
  else
    first, last = anchored_range(entry, bufnr)
    if not first then
      return nil, "suggestion is not anchored to a line here"
    end
    replacement, name = entry.lines, "pr-suggestion://"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local other = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(other, replacement)
  vim.list_extend(other, vim.list_slice(lines, last + 1, #lines))

  diff.open_scratch_side_by_side({
    path = entry.path,
    win = win,
    buf = bufnr,
    lines = other,
    name = name .. entry.path,
  })
  split_thread = entry.id
  return true
end

-- Trials ----------------------------------------------------------------------

-- A trial's rows now, as (start_row, finish): 0-based start, exclusive end,
-- so an all-deleting trial is the empty range (start_row, start_row).
trial_range = function(trial)
  local mark = vim.api.nvim_buf_get_extmark_by_id(trial.buf, trial_ns, trial.mark, { details = true })
  local start_row = mark[1]
  if not start_row then
    return nil
  end
  local details = mark[3] or {}
  return start_row, #trial.lines > 0 and ((details.end_row or start_row) + 1) or start_row
end

local function mark_alive(trial)
  if not vim.api.nvim_buf_is_valid(trial.buf) then
    return false
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(trial.buf, trial_ns, trial.mark, {})
  return mark ~= nil and mark[1] ~= nil
end

local function prune()
  local live = {}
  for _, trial in ipairs(trials) do
    if mark_alive(trial) then
      live[#live + 1] = trial
    end
  end
  trials = live
  return live
end

--- The live trials, oldest first, each with the line it now sits on.
function M.trials()
  local out = {}
  for _, trial in ipairs(prune()) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(trial.buf, trial_ns, trial.mark, {})
    out[#out + 1] = {
      id = trial.id,
      buf = trial.buf,
      path = trial.path,
      thread_id = trial.thread_id,
      line = (mark[1] or 0) + 1,
      added = #trial.lines,
      removed = #trial.original,
    }
  end
  return out
end

trial_for_thread = function(bufnr, thread_id)
  for _, trial in ipairs(prune()) do
    if trial.buf == bufnr and trial.thread_id == thread_id then
      return trial
    end
  end
  return nil
end

local function forget_trials(bufnr)
  for _, trial in ipairs(trials) do
    if not bufnr or trial.buf == bufnr then
      if vim.api.nvim_buf_is_valid(trial.buf) then
        vim.api.nvim_buf_clear_namespace(trial.buf, trial_ns, 0, -1)
      end
      trial.mark = -1
    end
  end
  prune()
end

-- A reload replaces the text a trial was tracking, and a stopped session has no
-- suggestion left to revert to, so in both cases the trial is forgotten and
-- whatever is in the buffer is the user's own edit from then on.
--
-- Extmarks outlive a reload, so this cannot wait for prune() to notice dead
-- marks: without it the sign and the label would stay behind on lines that are
-- no longer the trial, and a revert would write the old lines into re-read text.
-- Registered once, at the bottom of this file, so every local it reaches for
-- exists by then.
local function watch_buffers()
  local group = vim.api.nvim_create_augroup("review_mode_suggestion_trials", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufUnload" }, {
    group = group,
    callback = function(args)
      forget_trials(args.buf)
      M.clear_previews(args.buf)
    end,
  })
  hooks.on("stop", function()
    forget_trials(nil)
    M.clear_previews()
    split_thread = nil
  end)
end

--- Write a suggestion into the buffer as a trial: unsaved, marked, revertible.
--- Returns the trial, or nil and an error.
function M.accept(entry, bufnr)
  local err
  entry, bufnr, err = resolve(entry, bufnr)
  if not entry then
    return nil, err
  end

  if trial_for_thread(bufnr, entry.id) then
    return nil, "this suggestion is already applied as a trial"
  end

  -- a preview drawn over the lines about to be replaced would stay behind on
  -- the applied text, painted as a deletion with the suggestion again below it
  local open = (previews[bufnr] or {})[entry.id]
  if open then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, preview_ns, open)
    previews[bufnr][entry.id] = nil
  end
  if split_thread == entry.id and diff.old_view_is_open() then
    diff.close_old_view()
    split_thread = nil
  end

  local first, last = anchored_range(entry, bufnr)
  if not first then
    return nil, "suggestion is not anchored to a line here"
  end

  local original = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, entry.lines)
  review_api().ensure_highlights()

  -- The mark spans what was written, with gravity set so edits inside it widen
  -- the range and edits above it carry the whole thing down.
  local end_row = #entry.lines > 0 and (first + #entry.lines - 2) or (first - 1)
  local end_col = #(vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or "")
  local mark = vim.api.nvim_buf_set_extmark(bufnr, trial_ns, first - 1, 0, {
    end_row = end_row,
    end_col = #entry.lines > 0 and end_col or 0,
    hl_group = #entry.lines > 0 and "ReviewModeSuggestionAdd" or nil,
    sign_text = "T",
    sign_hl_group = "ReviewModeSuggestionAdd",
    virt_text = { { " trial suggestion", "ReviewModeHint" } },
    virt_text_pos = "eol",
    right_gravity = false,
    end_right_gravity = true,
  })

  last_trial_id = last_trial_id + 1
  local trial = {
    id = last_trial_id,
    buf = bufnr,
    path = entry.path,
    thread_id = entry.id,
    mark = mark,
    original = original,
    lines = entry.lines,
  }
  trials[#trials + 1] = trial

  local public = {
    id = trial.id,
    buf = bufnr,
    path = entry.path,
    thread_id = entry.id,
    line = first,
    added = #entry.lines,
    removed = #original,
  }
  hooks.emit("suggestion_accepted", public)
  return public
end

local function find_trial(id)
  local live = prune()
  if type(id) == "number" then
    for _, trial in ipairs(live) do
      if trial.id == id then
        return trial
      end
    end
    return nil
  end

  -- No id: the trial under the cursor, else the most recent one in this buffer,
  -- else the most recent anywhere.
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local in_buffer = nil
  for _, trial in ipairs(live) do
    if trial.buf == bufnr then
      in_buffer = trial
      local mark = vim.api.nvim_buf_get_extmark_by_id(trial.buf, trial_ns, trial.mark, { details = true })
      local start_row, details = mark[1], mark[3] or {}
      if start_row and row >= start_row and row <= (details.end_row or start_row) then
        return trial
      end
    end
  end
  return in_buffer or live[#live]
end

--- Put the original lines back. id is a trial id, or nil for the trial under
--- the cursor. Returns the reverted trial, or nil and an error.
function M.revert(id)
  local trial = find_trial(id)
  if not trial then
    return nil, "no trial suggestion to revert"
  end

  -- Where the mark sits now, not where the suggestion was anchored: the user
  -- may have added or removed lines above it since.
  local start_row, finish = trial_range(trial)
  if not start_row then
    return nil, "this trial is no longer tracked"
  end
  -- a preview of what this trial replaced has nothing left to show
  local open = (previews[trial.buf] or {})[trial.thread_id]
  if open then
    pcall(vim.api.nvim_buf_del_extmark, trial.buf, preview_ns, open)
    previews[trial.buf][trial.thread_id] = nil
  end
  if split_thread == trial.thread_id and diff.old_view_is_open() then
    diff.close_old_view()
    split_thread = nil
  end
  vim.api.nvim_buf_set_lines(trial.buf, start_row, finish, false, trial.original)
  pcall(vim.api.nvim_buf_del_extmark, trial.buf, trial_ns, trial.mark)
  trial.mark = -1
  prune()

  local public = {
    id = trial.id,
    buf = trial.buf,
    path = trial.path,
    thread_id = trial.thread_id,
    line = start_row + 1,
    added = #trial.lines,
    removed = #trial.original,
  }
  hooks.emit("suggestion_reverted", public)
  return public
end

--- Accept every suggestion in one file. Returns how many were applied and the
--- first error, if any.
---
--- Bottom-up, and that is the whole trick: a suggestion can replace one line
--- with three, so applying the top one first moves every line number below it
--- and the next suggestion lands on the wrong lines. Starting at the bottom
--- means nothing above an application has moved yet.
function M.accept_all(path, bufnr)
  local entries = M.list(path)
  table.sort(entries, function(left, right)
    return left.start_line > right.start_line
  end)

  local applied, err = 0, nil
  for _, entry in ipairs(entries) do
    local trial, entry_err = M.accept(entry, bufnr)
    if trial then
      applied = applied + 1
    else
      err = err or entry_err
    end
  end
  return applied, err
end

--- Suggestions on a line, for "the one under the cursor".
function M.at(path, line)
  local out = {}
  for _, entry in ipairs(M.list(path)) do
    if line >= entry.start_line and line <= entry.end_line then
      out[#out + 1] = entry
    end
  end
  return out
end

watch_buffers()

return M
