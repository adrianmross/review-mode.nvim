-- Your edits, as suggestions.
--
-- Write the change in the file itself, with your LSP and formatter, and this
-- turns each edited hunk into a ```suggestion``` for the lines it replaces. The
-- baseline is HEAD, the PR head in a checkout review, so an edit is whatever
-- the buffer says that HEAD does not.
--
-- An edit, as returned here:
--   start_line, end_line  the PR-head lines the suggestion replaces (GitHub's)
--   lines                 what the suggestion puts there
--   in_diff               whether GitHub can anchor it: a suggestion has to sit
--                         inside one hunk of the PR diff
--   buf, mark, original   where the edit is in the buffer, and the HEAD lines
--                         that undo() writes back once it is a suggestion
local M = {}

local core = require("review_mode.state")
local state = core.state
local util = require("review_mode.util")

local ns = vim.api.nvim_create_namespace("review_mode_edits")

-- GitHub shows three lines of context around each change and accepts a
-- comment on any line it shows.
local DIFF_CONTEXT = 3

local function git_lines(args)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = state.root, text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return util.split_blob_lines(result.stdout or "")
end

local function joined(lines)
  return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
end

-- The ranges of PR-head lines a comment can land on: each hunk of the PR diff
-- widened by its context, overlapping windows merged, as GitHub draws them.
local function diff_windows(path, head)
  local merge_base = git_lines({ "merge-base", core.base_ref(), "HEAD" })
  if not merge_base or not merge_base[1] then
    -- fail closed: with no base to diff against, no line is known to be in
    -- the PR diff, and guessing would post suggestions GitHub rejects
    return {}
  end
  -- a path missing at the base is an added file: every line is in the diff
  local base = git_lines({ "show", merge_base[1] .. ":" .. path }) or {}
  local windows = {}
  for _, hunk in ipairs(vim.diff(joined(base), joined(head), { result_type = "indices" })) do
    local first = math.max(1, hunk[3] - DIFF_CONTEXT + (hunk[4] == 0 and 1 or 0))
    local last = math.min(#head, hunk[3] + math.max(hunk[4], 1) - 1 + DIFF_CONTEXT)
    local previous = windows[#windows]
    if previous and first <= previous[2] + 1 then
      previous[2] = math.max(previous[2], last)
    else
      windows[#windows + 1] = { first, last }
    end
  end
  return windows
end

local function inside(windows, first, last)
  for _, window in ipairs(windows) do
    if first >= window[1] and last <= window[2] then
      return true
    end
  end
  return false
end

local function overlaps(ranges, first_row, finish_row)
  for _, range in ipairs(ranges) do
    -- an empty edit range still sits at a row, so treat it as that one row
    if first_row < math.max(range[2], range[1] + 1) and range[1] < math.max(finish_row, first_row + 1) then
      return true
    end
  end
  return false
end

--- The edited hunks in a buffer, top to bottom. Hunks inside a trial
--- suggestion are left out: those lines are the reviewer's, not yours.
function M.list(bufnr, path)
  local head = git_lines({ "show", "HEAD:" .. path })
  if not head then
    return {}
  end
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = vim.diff(joined(head), joined(current), { result_type = "indices" })
  if #hunks == 0 then
    return {}
  end
  local trials = require("review_mode.suggestions").trial_ranges(bufnr)
  -- only now, with edits to place, is the PR diff worth two more git calls
  local windows = state.provider ~= "local" and diff_windows(path, head) or nil

  local out = {}
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    -- buffer rows the edit occupies, 0-based and end-exclusive; a pure
    -- deletion is the empty range where the lines used to be
    local first_row = count_b > 0 and start_b - 1 or start_b
    local finish_row = first_row + count_b

    if not overlaps(trials, first_row, finish_row) then
      local lines = vim.list_slice(current, start_b, start_b + count_b - 1)
      local first, last = start_a, start_a + count_a - 1
      if count_a == 0 then
        -- a pure insertion has no line of its own to hang on: take the line
        -- above it (or below, at the top of the file) into the suggestion
        if start_a >= 1 then
          first, last = start_a, start_a
          table.insert(lines, 1, head[start_a])
        else
          first, last = 1, 1
          lines[#lines + 1] = head[1]
        end
      end

      out[#out + 1] = {
        path = path,
        buf = bufnr,
        start_line = first,
        end_line = last,
        lines = lines,
        original = vim.list_slice(head, start_a + (count_a == 0 and 1 or 0), start_a + count_a - 1),
        first_row = first_row,
        finish_row = finish_row,
        in_diff = windows == nil or inside(windows, first, last),
      }
    end
  end
  return out
end

-- A file whose edits are about to become suggestions. saved: the file on disk
-- differs from HEAD, so some edits were written. clean: the buffer is what is
-- on disk, so once its edits are undone writing it loses nothing of yours;
-- compared by content, not 'modified', which misses a buffer gone stale.
local function edited_file(path, bufnr, saved)
  return {
    path = path,
    buf = bufnr,
    saved = saved,
    clean = saved and vim.deep_equal(
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      vim.fn.readfile(vim.api.nvim_buf_get_name(bufnr))
    ),
  }
end

--- The files you have edited, as { path, buf, saved, clean }: opts.buf alone,
--- or every file the PR changes that differs from HEAD in a buffer or on disk,
--- loading a buffer for a file that has none so list() can read it. Also
--- returns the edited paths the PR does not change: no suggestion can land
--- there.
function M.edited_files(opts)
  local saved = {}
  for _, path in ipairs(git_lines({ "diff", "--name-only", "HEAD" }) or {}) do
    saved[path] = true
  end
  if opts and opts.buf then
    local path = util.buf_relpath(opts.buf)
    return path and { edited_file(path, opts.buf, saved[path] == true) } or {}, {}
  end

  local edited = vim.deepcopy(saved)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and util.buf_relpath(bufnr)
    if path then
      edited[path] = true
    end
  end

  local files, outside = {}, {}
  for _, path in ipairs(state.file_order) do
    if edited[path] then
      local bufnr = vim.fn.bufadd(state.root .. "/" .. path)
      vim.fn.bufload(bufnr)
      files[#files + 1] = edited_file(path, bufnr, saved[path] == true)
    end
  end
  for path in pairs(edited) do
    if not state.file_index[path] then
      outside[#outside + 1] = path
    end
  end
  table.sort(outside)
  return files, outside
end

--- The edit covering a buffer line, if any.
function M.at(bufnr, path, line)
  local row = line - 1
  for _, edit in ipairs(M.list(bufnr, path)) do
    -- a deletion leaves nothing to stand on, so the lines either side count
    local first = edit.finish_row > edit.first_row and edit.first_row or edit.first_row - 1
    local finish = math.max(edit.finish_row, edit.first_row + 1)
    if row >= first and row < finish then
      return edit
    end
  end
  return nil
end

--- The body of a suggestion comment for an edit.
function M.body(edit, message)
  local lines = {}
  if message and message ~= "" then
    lines = { message, "" }
  end
  lines[#lines + 1] = "```suggestion"
  vim.list_extend(lines, edit.lines)
  lines[#lines + 1] = "```"
  return table.concat(lines, "\n")
end

--- Pin an edit's buffer range, so undo() finds it after later edits move it.
function M.track(edit)
  if edit.mark then
    return edit
  end
  local end_row = edit.finish_row > edit.first_row and edit.finish_row - 1 or edit.first_row
  local end_col = edit.finish_row > edit.first_row
      and #(vim.api.nvim_buf_get_lines(edit.buf, end_row, end_row + 1, false)[1] or "")
    or 0
  edit.mark = vim.api.nvim_buf_set_extmark(edit.buf, ns, edit.first_row, 0, {
    end_row = end_row,
    end_col = end_col,
    right_gravity = false,
    end_right_gravity = true,
    -- a deletion at the end of the file sits one row past the last line
    strict = false,
  })
  return edit
end

--- Put HEAD's lines back where an edit is: it lives on as a suggestion now.
function M.undo(edit)
  if not vim.api.nvim_buf_is_valid(edit.buf) then
    return false
  end
  local first_row, finish_row = edit.first_row, edit.finish_row
  if edit.mark then
    local mark = vim.api.nvim_buf_get_extmark_by_id(edit.buf, ns, edit.mark, { details = true })
    if not mark[1] then
      return false
    end
    first_row = mark[1]
    finish_row = edit.finish_row > edit.first_row and ((mark[3].end_row or first_row) + 1) or first_row
    pcall(vim.api.nvim_buf_del_extmark, edit.buf, ns, edit.mark)
  end
  vim.api.nvim_buf_set_lines(edit.buf, first_row, finish_row, false, edit.original)
  return true
end

return M
