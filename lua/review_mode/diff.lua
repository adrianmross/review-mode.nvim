-- The base-version diff: the side-by-side split, the unified diff buffer, and
-- the highlighting and folding that go with them.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local git = require("review_mode.git")

local state = core.state
local trim = util.trim
local system_async = util.system_async
local ensure_active = util.ensure_active
local current_relpath = util.current_relpath

local diff_ns = vim.api.nvim_create_namespace("review_mode_diff")
local diff_text_hl = "ReviewModeDiffText"
local diff_text_priority = 1000

local function restore_old_diffopt()
  if state.old_diffopt then
    vim.o.diffopt = state.old_diffopt
    state.old_diffopt = nil
  end
end

-- iwhiteall, not iwhite: it is what git diff -w (and GitHub's ?w=1) ignores, so
-- the split, the unified view and ]c agree on which changes are hidden.
local function apply_old_diffopt()
  local diffopt = state.config.diff.use_fast_diffopt and state.config.diff.fast_diffopt or vim.o.diffopt
  if state.config.diff.ignore_whitespace and not vim.tbl_contains(vim.split(diffopt, ","), "iwhiteall") then
    diffopt = diffopt .. ",iwhiteall"
  end
  if diffopt == vim.o.diffopt then
    return
  end

  state.old_diffopt = vim.o.diffopt
  local ok = pcall(function()
    vim.o.diffopt = diffopt
  end)
  if ok then
    return
  end

  vim.o.diffopt = state.old_diffopt
  state.old_diffopt = nil
end

-- :diffoff, not 'diff' = false: only :diffoff puts back what :diffthis changed
-- (scrollbind, cursorbind, wrap, the fold options)
local function disable_diff_for_window(win)
  if win and vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("diffoff")
    end)
  end
end

-- Taken before :diffthis or the unified buffer touch the window, so what comes
-- back on close is the user's own setting, not a diff-mode one.
local window_options = { "wrap", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "foldlevel", "foldenable" }

local function capture_window_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  state.old_window_options = state.old_window_options or {}
  if state.old_window_options[win] then
    return
  end

  local saved = {}
  for _, name in ipairs(window_options) do
    saved[name] = vim.wo[win][name]
  end
  state.old_window_options[win] = saved
end

local function restore_window_options()
  for win, options in pairs(state.old_window_options or {}) do
    if vim.api.nvim_win_is_valid(win) then
      for name, value in pairs(options) do
        pcall(function()
          vim.wo[win][name] = value
        end)
      end
    end
  end
  state.old_window_options = nil
end

local function clear_old_diff_highlights()
  for _, bufnr in ipairs({ state.old_buf, state.old_target_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    end
  end
end

-- Condensed and full file are fold states in both layouts, so zR / zM / zo / zc
-- work on a review diff as on any other: side by side folds with Vim's own diff
-- folds, unified with manual folds over the unchanged stretches.
local function apply_diff_context()
  local condensed = not state.config.diff.full_file
  local previous_win = vim.api.nvim_get_current_win()
  for _, win in ipairs({ state.old_target_win, state.old_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      capture_window_options(win)
      pcall(function()
        if state.old_layout == "side_by_side" then
          vim.wo[win].foldmethod = "diff"
        end
        -- folding stays on either way, so zc / zo still work in a full diff
        vim.wo[win].foldenable = true
        vim.api.nvim_set_current_win(win)
        vim.cmd(condensed and "silent! normal! zM" or "silent! normal! zR")
      end)
    end
  end
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

function M.close_old_view()
  if state.old_closing then
    return
  end

  state.old_closing = true
  disable_diff_for_window(state.old_target_win)
  disable_diff_for_window(state.old_win)
  clear_old_diff_highlights()

  if state.old_layout == "unified" then
    -- only while the window still shows the diff: once something else was
    -- opened there, putting the reviewed file back would replace that
    if
      state.old_target_win
      and vim.api.nvim_win_is_valid(state.old_target_win)
      and vim.api.nvim_win_get_buf(state.old_target_win) == state.old_buf
      and state.old_target_buf
      and vim.api.nvim_buf_is_valid(state.old_target_buf)
    then
      pcall(vim.api.nvim_win_set_buf, state.old_target_win, state.old_target_buf)
    end
  elseif state.old_win and vim.api.nvim_win_is_valid(state.old_win) then
    -- can fail (E1312 while a window is closing, E444 for the last window);
    -- the view is torn down either way
    pcall(vim.api.nvim_win_close, state.old_win, true)
  end
  restore_window_options()

  if state.old_buf and vim.api.nvim_buf_is_valid(state.old_buf) then
    pcall(vim.api.nvim_buf_delete, state.old_buf, { force = true })
  end

  state.old_win = nil
  state.old_buf = nil
  state.old_target_win = nil
  state.old_target_buf = nil
  state.old_loading = false
  state.old_layout = nil
  state.old_path = nil
  state.old_closing = false
  restore_old_diffopt()
end

-- Unchanged runs in a whole-file unified diff that sit more than `context` lines
-- from any change, as { first, last } rows (1-based). Header lines never fold.
local function unified_fold_ranges(lines, context)
  local body = nil
  local changed = {}
  for index, line in ipairs(lines) do
    if not body and line:find("^@@") then
      body = index + 1
    elseif body and (line:find("^[+-]") or line:find("^@@")) then
      changed[#changed + 1] = index
    end
  end
  if not body then
    return {}
  end

  local keep = {}
  for _, row in ipairs(changed) do
    for near = row - context, row + context do
      keep[near] = true
    end
  end

  local ranges, first = {}, nil
  for row = body, #lines + 1 do
    if row <= #lines and not keep[row] then
      first = first or row
    elseif first then
      -- a one-line fold hides nothing
      if row - 1 > first then
        ranges[#ranges + 1] = { first, row - 1 }
      end
      first = nil
    end
  end
  return ranges
end

M._unified_fold_ranges = unified_fold_ranges

-- eol: whether the file ends in a newline. Written without one, every file
-- would diff as "\ No newline at end of file".
local function write_temp_diff_file(tmpdir, side, path, lines, eol)
  local rel = vim.fs.joinpath(side, path)
  local file = vim.fs.joinpath(tmpdir, rel)
  local dir = vim.fs.dirname(file)
  if dir then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile(lines, file, eol and "" or "b")
  return rel
end

local function unified_diff_lines(diff, path)
  local lines = util.split_blob_lines(diff)
  if #lines == 0 then
    return { "No differences: " .. path }
  end

  -- headers only: inside a hunk "--- x" is a deleted "-- x" line
  local header = true
  for index, line in ipairs(lines) do
    if line:find("^@@ ") then
      header = false
    elseif not header then
      break
    elseif line:find("^diff %-%-git ") then
      lines[index] = "diff --git base/" .. path .. " head/" .. path
    elseif line:find("^%-%-%- ") and line ~= "--- /dev/null" then
      lines[index] = "--- base/" .. path
    elseif line:find("^%+%+%+ ") and line ~= "+++ /dev/null" then
      lines[index] = "+++ head/" .. path
    end
  end

  return lines
end

local function ensure_diff_highlights()
  pcall(vim.api.nvim_set_hl, 0, diff_text_hl, { default = true, link = "DiffText" })
end

-- Only meaningful inside a hunk body. File headers ("--- a/x", "+++ b/x") live
-- before the first @@, and a changed line can itself start with "--" or "++".
local function is_deleted_diff_line(line)
  return line:sub(1, 1) == "-"
end

local function is_added_diff_line(line)
  return line:sub(1, 1) == "+"
end

local function changed_line_ranges(old_text, new_text)
  local old_len = #old_text
  local new_len = #new_text
  local prefix = 0
  local min_len = math.min(old_len, new_len)

  while prefix < min_len and old_text:byte(prefix + 1) == new_text:byte(prefix + 1) do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < min_len - prefix and old_text:byte(old_len - suffix) == new_text:byte(new_len - suffix) do
    suffix = suffix + 1
  end

  return prefix, old_len - suffix, new_len - suffix
end

local function highlight_changed_range(bufnr, row, start_col, end_col)
  if start_col >= end_col then
    return
  end

  vim.api.nvim_buf_set_extmark(bufnr, diff_ns, row, start_col, {
    end_col = end_col,
    hl_group = diff_text_hl,
    hl_mode = "replace",
    priority = diff_text_priority,
  })
end

local function highlight_partial_line_pair(old_buf, old_row, old_line, new_buf, new_row, new_line, col_offset)
  local prefix, old_end, new_end = changed_line_ranges(old_line, new_line)
  highlight_changed_range(old_buf, old_row, prefix + col_offset, old_end + col_offset)
  highlight_changed_range(new_buf, new_row, prefix + col_offset, new_end + col_offset)
end

local function highlight_partial_diff_pair(bufnr, old_row, old_line, new_row, new_line)
  highlight_partial_line_pair(bufnr, old_row, old_line:sub(2), bufnr, new_row, new_line:sub(2), 1)
end

local function apply_partial_diff_highlights(bufnr)
  if not state.config.diff.partial_line_highlights then
    return
  end

  ensure_diff_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local index = 1
  while index <= #lines and not lines[index]:match("^@@") do
    index = index + 1
  end

  while index <= #lines do
    if is_deleted_diff_line(lines[index]) then
      local deleted = {}
      while index <= #lines and is_deleted_diff_line(lines[index]) do
        deleted[#deleted + 1] = { row = index - 1, line = lines[index] }
        index = index + 1
      end

      local added = {}
      while index <= #lines and is_added_diff_line(lines[index]) do
        added[#added + 1] = { row = index - 1, line = lines[index] }
        index = index + 1
      end

      for pair_index = 1, math.min(#deleted, #added) do
        highlight_partial_diff_pair(
          bufnr,
          deleted[pair_index].row,
          deleted[pair_index].line,
          added[pair_index].row,
          added[pair_index].line
        )
      end
    else
      index = index + 1
    end
  end
end

local function buffer_text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function apply_side_by_side_partial_diff_highlights(old_buf, old_lines, new_buf, new_lines)
  if not state.config.diff.partial_line_highlights then
    return
  end

  ensure_diff_highlights()
  vim.api.nvim_buf_clear_namespace(old_buf, diff_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(new_buf, diff_ns, 0, -1)

  local hunks = vim.diff(buffer_text(old_lines), buffer_text(new_lines), {
    result_type = "indices",
    ctxlen = 0,
    ignore_whitespace = state.config.diff.ignore_whitespace,
  })

  for _, hunk in ipairs(hunks or {}) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
    for offset = 0, math.min(old_count, new_count) - 1 do
      highlight_partial_line_pair(
        old_buf,
        old_start + offset - 1,
        old_lines[old_start + offset],
        new_buf,
        new_start + offset - 1,
        new_lines[new_start + offset],
        0
      )
    end
  end
end

--- Side by side: a read-only scratch buffer holding opts.lines, against the
--- real file in opts.win. The base version is one caller and the suggestion
--- preview is another, so the window, fold and partial-highlight handling below
--- is written once and both get it.
---
--- opts: path, win, buf, lines, name, filetype?
function M.open_scratch_side_by_side(opts)
  M.close_old_view()

  local current_win, current_buf = opts.win, opts.buf
  capture_window_options(current_win)
  vim.api.nvim_set_current_win(current_win)
  vim.cmd("vsplit")
  state.old_win = vim.api.nvim_get_current_win()
  -- the split starts with the file window's options: save them now, before
  -- :diffthis changes them, so a close that falls back to restoring this
  -- window never puts diff-mode options back
  capture_window_options(state.old_win)
  state.old_target_win = current_win
  state.old_target_buf = current_buf
  state.old_buf = vim.api.nvim_create_buf(false, true)
  state.old_layout = "side_by_side"
  state.old_path = opts.path
  vim.api.nvim_win_set_buf(state.old_win, state.old_buf)
  vim.api.nvim_buf_set_name(state.old_buf, opts.name)
  local other_lines = opts.lines or {}
  vim.api.nvim_buf_set_lines(state.old_buf, 0, -1, false, other_lines)
  vim.bo[state.old_buf].buftype = "nofile"
  vim.bo[state.old_buf].bufhidden = "wipe"
  vim.bo[state.old_buf].modifiable = false
  vim.bo[state.old_buf].readonly = true
  vim.bo[state.old_buf].filetype = opts.filetype or vim.bo[current_buf].filetype

  apply_old_diffopt()

  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(current_win)
  vim.cmd("diffthis")
  apply_side_by_side_partial_diff_highlights(
    state.old_buf,
    other_lines,
    current_buf,
    vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
  )
  apply_diff_context()
  vim.api.nvim_set_current_win(current_win)
end

local function open_old_side_by_side(path, current_win, current_buf, current_filetype, base_content, base_missing)
  M.open_scratch_side_by_side({
    path = path,
    win = current_win,
    buf = current_buf,
    filetype = current_filetype,
    lines = base_missing and {} or util.split_blob_lines(base_content),
    name = "pr-base://" .. core.base_ref() .. "/" .. path,
  })
end

function M.is_added_file(path)
  return (state.files[path] or ""):match("^A") ~= nil
end

local function open_old_unified(path, current_win, current_buf, base_content, generation, base_missing)
  local tmpdir = vim.fn.tempname()
  -- as :write would save it
  local head_eol = vim.bo[current_buf].eol or (vim.bo[current_buf].fixeol and not vim.bo[current_buf].binary)
  local head_rel =
    write_temp_diff_file(tmpdir, "head", path, vim.api.nvim_buf_get_lines(current_buf, 0, -1, false), head_eol)
  local base_rel = base_missing and "/dev/null"
    or write_temp_diff_file(tmpdir, "base", path, util.split_blob_lines(base_content), base_content:sub(-1) == "\n")
  -- the whole file, always: condensing is folding, so zR shows it all
  local args = { "--no-index", "--unified=1000000" }
  if state.config.diff.ignore_whitespace then
    args[#args + 1] = "-w"
  end
  args = git.diff(vim.list_extend(args, { "--", base_rel, head_rel }))
  vim.system(args, { text = true, cwd = tmpdir }, function(result)
    vim.schedule(function()
      pcall(vim.fn.delete, tmpdir, "rf")
      if not core.is_current(generation) then
        return
      end

      state.old_loading = false
      if result.code ~= 0 and result.code ~= 1 then
        vim.notify(
          "Review Mode unified diff: " .. trim(result.stderr ~= "" and result.stderr or result.stdout),
          vim.log.levels.WARN
        )
        return
      end

      if not vim.api.nvim_win_is_valid(current_win) or not vim.api.nvim_buf_is_valid(current_buf) then
        vim.notify("Review Mode unified diff: target window is no longer valid", vim.log.levels.WARN)
        return
      end

      M.close_old_view()

      vim.api.nvim_set_current_win(current_win)
      state.old_target_win = current_win
      state.old_target_buf = current_buf
      state.old_buf = vim.api.nvim_create_buf(false, true)
      state.old_layout = "unified"
      state.old_path = path
      vim.api.nvim_win_set_buf(current_win, state.old_buf)
      vim.api.nvim_buf_set_name(state.old_buf, "pr-diff://" .. core.base_ref() .. "/" .. path)
      local lines = unified_diff_lines(result.stdout or "", path)
      vim.api.nvim_buf_set_lines(state.old_buf, 0, -1, false, lines)
      apply_partial_diff_highlights(state.old_buf)
      vim.bo[state.old_buf].buftype = "nofile"
      vim.bo[state.old_buf].bufhidden = "wipe"
      vim.bo[state.old_buf].modifiable = false
      vim.bo[state.old_buf].readonly = true
      vim.bo[state.old_buf].filetype = "diff"
      vim.api.nvim_set_current_win(current_win)

      capture_window_options(current_win)
      vim.wo[current_win].foldmethod = "manual"
      vim.cmd("silent! normal! zE")
      for _, range in ipairs(unified_fold_ranges(lines, state.config.diff.unified_context)) do
        vim.cmd(string.format("silent! %d,%dfold", range[1], range[2]))
      end
      apply_diff_context()
    end)
  end)
end

local function open_old_view(path, current_win, current_buf)
  local current_filetype = vim.bo[current_buf].filetype
  local generation = state.generation
  state.old_loading = true

  system_async(
    -- the merge base, under the name the file had there
    { "git", "show", core.base_rev() .. ":" .. core.base_path(path) },
    { cwd = state.root, raw = true },
    function(content, err)
      if not core.is_current(generation) then
        return
      end

      local base_missing = false
      if content == nil then
        if M.is_added_file(path) then
          content = ""
          base_missing = true
        else
          state.old_loading = false
          vim.notify("Review Mode old version: " .. tostring(err or "file not present at base"), vim.log.levels.WARN)
          return
        end
      end

      if not vim.api.nvim_win_is_valid(current_win) or not vim.api.nvim_buf_is_valid(current_buf) then
        state.old_loading = false
        vim.notify("Review Mode old version: target window is no longer valid", vim.log.levels.WARN)
        return
      end

      if state.config.diff.layout == "unified" then
        open_old_unified(path, current_win, current_buf, content, generation, base_missing)
        return
      end

      state.old_loading = false
      open_old_side_by_side(path, current_win, current_buf, current_filetype, content, base_missing)
    end
  )
end

function M.refresh_old_view()
  if not M.old_view_is_open() then
    return false
  end

  local path = state.old_path
  local target_win = state.old_target_win
  if not path or not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return false
  end

  local target_buf = state.old_target_buf
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = vim.api.nvim_win_get_buf(target_win)
  end
  M.close_old_view()
  open_old_view(path, target_win, target_buf)
  return true
end

function M.old_view_is_open()
  if state.old_layout == "side_by_side" then
    return state.old_win and vim.api.nvim_win_is_valid(state.old_win)
  end
  if state.old_layout == "unified" then
    -- the window alone is not enough: ]f or :edit put another buffer in it
    return state.old_target_win
      and vim.api.nvim_win_is_valid(state.old_target_win)
      and vim.api.nvim_win_get_buf(state.old_target_win) == state.old_buf
  end
  return false
end

function M.close_side_by_side_pair_for_buffer(bufnr)
  if state.old_closing or state.old_layout ~= "side_by_side" then
    return
  end

  if bufnr ~= state.old_buf and bufnr ~= state.old_target_buf then
    return
  end

  vim.schedule(function()
    if state.old_closing or state.old_layout ~= "side_by_side" then
      return
    end
    if bufnr == state.old_buf or bufnr == state.old_target_buf then
      M.close_old_view()
    end
  end)
end

function M.close_side_by_side_pair_for_window(winid)
  if state.old_closing or state.old_layout ~= "side_by_side" then
    return
  end

  if winid ~= state.old_win and winid ~= state.old_target_win then
    return
  end

  vim.schedule(function()
    if state.old_closing or state.old_layout ~= "side_by_side" then
      return
    end
    M.close_old_view()
  end)
end

-- On BufEnter: the view is stale once its window shows another buffer, or is
-- gone. Always closed on the next tick -- closing a window from inside the
-- BufEnter of a :q or :close fails (E1312).
local function view_is_stale()
  if state.old_closing or not state.old_layout then
    return false
  end
  local win = state.old_target_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  local expected = state.old_layout == "unified" and state.old_buf or state.old_target_buf
  return vim.api.nvim_win_get_buf(win) ~= expected
end

function M.close_stale_side_by_side_pair()
  if not view_is_stale() then
    return
  end

  vim.schedule(function()
    if view_is_stale() then
      M.close_old_view()
    end
  end)
end

function M.old_toggle()
  if not ensure_active() then
    return
  end

  if M.old_view_is_open() then
    M.close_old_view()
    return
  end

  local path = current_relpath()
  if not path then
    vim.notify("Review Mode old version: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  if state.old_loading then
    vim.notify("Review Mode old version: base file is still loading", vim.log.levels.INFO)
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  open_old_view(path, current_win, current_buf)
end

-- Both of these say how the diff should look, so with no diff open they used to
-- flip a setting, announce it, and change nothing on screen. Show the diff
-- instead, and when that is not possible say so rather than claiming success.
local function show_old_view_in_new_shape()
  if M.refresh_old_view() then
    return true
  end
  if not state.active or state.old_loading then
    return false
  end

  local path = current_relpath()
  if not path or not state.files[path] then
    return false
  end

  open_old_view(path, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
  return true
end

local function notify_diff_setting(label, shown)
  if shown then
    vim.notify(label)
    return
  end
  vim.notify(label .. " (applies to the next diff you open)", vim.log.levels.WARN)
end

function M.toggle_diff_layout()
  state.config.diff.layout = state.config.diff.layout == "side_by_side" and "unified" or "side_by_side"
  local label = "Review Mode diff layout: " .. (state.config.diff.layout == "unified" and "unified" or "side-by-side")
  notify_diff_setting(label, show_old_view_in_new_shape())
  util.redraw_status()
end

--- Open or close every unchanged fold (zR / zM), and open the next diff the
--- same way.
function M.toggle_diff_full_file()
  state.config.diff.full_file = not state.config.diff.full_file
  local label = "Review Mode diff context: " .. (state.config.diff.full_file and "full file" or "condensed")
  if M.old_view_is_open() then
    apply_diff_context()
    vim.notify(label)
    util.redraw_status()
    return
  end
  notify_diff_setting(label, show_old_view_in_new_shape())
  util.redraw_status()
end

--- Hide or show whitespace-only changes (git diff -w). Hunks were computed with
--- the old setting, so they are dropped and reload lazily on the next ]c.
function M.toggle_diff_whitespace()
  state.config.diff.ignore_whitespace = not state.config.diff.ignore_whitespace
  -- ponytail: a hunk load already in flight lands with the old setting; give
  -- hunk loads their own generation if that ever shows up in practice
  state.hunks = {}
  state.hunks_loaded = {}
  state.prefetch_seen = {}
  local label = "Review Mode diff whitespace: " .. (state.config.diff.ignore_whitespace and "hidden" or "shown")
  notify_diff_setting(label, show_old_view_in_new_shape())
  util.redraw_status()
end

return M
