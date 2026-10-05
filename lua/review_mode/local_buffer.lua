-- The local comments buffer: every comment in a local review, in one place.
--
-- A UI module like panel.lua and review_buffer.lua: review data reaches it only
-- through review_mode.api (plus util and hooks), and scripts/validate.sh
-- enforces that.
--
-- Threads are drawn with api.render_threads, the same call the panel uses, so a
-- thread looks the same wherever you read it. The only thing this buffer adds is
-- the grouping: one header per file, with its thread count.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local name = "review-mode://local"
local hint = "<CR> jump · r reply · R resolve · e edit · dd delete · q close"

local ns = vim.api.nvim_create_namespace("review_mode_local_buffer")

-- this UI's own state: buf, and what each buffer line refers to
local ui = { buf = nil, rows = {} }

local function buf_valid()
  return ui.buf ~= nil and vim.api.nvim_buf_is_valid(ui.buf)
end

local function window()
  return buf_valid() and vim.fn.win_findbuf(ui.buf)[1] or nil
end

local function width(win)
  return math.max(40, (win and vim.api.nvim_win_get_width(win) or 80) - 2)
end

local function render()
  if not buf_valid() then
    return
  end

  local win = window()
  local lines, marks, entries = {}, {}, {}
  local total = 0

  for _, path in ipairs(api.comment_paths()) do
    local threads = api.threads({ path = path, include_resolved = true })
    if #threads > 0 then
      total = total + #threads
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = string.format("%s (%d)", path, #threads)
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #path, hl_group = "ReviewModeThreadPath" }
      -- a header is where the carry below stops, so the cursor on one acts on
      -- nothing rather than on the file above it
      entries[#lines] = false

      local body, body_marks, rows, comment_rows = api.render_threads(threads, { width = width(win) })
      local offset = #lines
      vim.list_extend(lines, body)
      for _, mark in ipairs(body_marks) do
        mark.row = mark.row + offset
        marks[#marks + 1] = mark
      end
      for _, thread in ipairs(threads) do
        local row = rows[thread.id]
        if row then
          entries[offset + row + 1] = { thread = thread }
        end
        for _, comment in ipairs(thread.comments or {}) do
          local comment_row = comment.id and comment_rows[comment.id]
          if comment_row then
            entries[offset + comment_row + 1] = { thread = thread, comment = comment }
          end
        end
      end
    end
  end

  if #lines == 0 then
    lines[#lines + 1] = "No local comments yet"
    marks[#marks + 1] = { row = 0, col = 0, end_col = -1, hl_group = "ReviewModeHint" }
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Comment on a line with :ReviewModeComment, or from an agent with"
    lines[#lines + 1] = 'require("review_mode.api").local_comment({ path = ..., line = ..., body = ... })'
  end

  -- a thread spans many lines; carry the last entry forward so the keys work
  -- anywhere inside it, and reset at each file header
  local carry = nil
  ui.rows = {}
  for index = 1, #lines do
    if entries[index] == false then
      carry = nil
    elseif entries[index] then
      carry = entries[index]
    end
    ui.rows[index] = carry
  end

  api.ensure_highlights()
  api.apply_render(ui.buf, ns, lines, marks)

  -- the buffer's own window, never whichever window happens to be current
  if win and vim.api.nvim_win_is_valid(win) then
    local store = api.local_store()
    vim.wo[win].winbar =
      string.format("Local comments (%d)%s  │  %s", total, store and ("  " .. vim.fs.basename(store)) or "", hint)
  end
end

local function at_cursor()
  return ui.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function with_thread(fn)
  return function()
    local entry = at_cursor()
    if not entry then
      vim.notify("Review Mode local: no thread on this line", vim.log.levels.WARN)
      return
    end
    fn(entry)
  end
end

local function report(ok, err)
  if not ok then
    vim.notify("Review Mode local: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
  end
end

local function jump(entry)
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= current and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      vim.api.nvim_set_current_win(win)
      return api.goto_file(entry.thread.path, entry.thread.line)
    end
  end
  vim.cmd("aboveleft split")
  api.goto_file(entry.thread.path, entry.thread.line)
end

local function reply(entry)
  vim.ui.input({ prompt = "Reply: " }, function(input)
    local body = util.trim(input or "")
    if body ~= "" then
      api.reply({ thread_id = entry.thread.id, body = body }, report)
    end
  end)
end

local function resolve(entry)
  api.resolve(entry.thread.id, not entry.thread.is_resolved, report)
end

local function edit(entry)
  if not entry.comment then
    vim.notify("Review Mode local: put the cursor on a comment to edit it", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Edit: ", default = entry.comment.body }, function(input)
    local body = util.trim(input or "")
    if body ~= "" and body ~= entry.comment.body then
      api.edit_comment({ comment_id = entry.comment.id, body = body }, report)
    end
  end)
end

local function delete(entry)
  if not entry.comment then
    vim.notify("Review Mode local: put the cursor on a comment to delete it", vim.log.levels.WARN)
    return
  end
  local preview = tostring(entry.comment.body or ""):match("[^\n]*")
  if vim.fn.confirm("Delete this comment?\n\n  " .. preview, "&Delete\n&Cancel", 2) == 1 then
    api.delete_comment(entry.comment.id, report)
  end
end

function M.close()
  if not buf_valid() then
    return
  end
  -- bufhidden = "wipe": closing the last window reclaims the buffer
  for _, win in ipairs(vim.fn.win_findbuf(ui.buf)) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.open()
  if not api.is_active() then
    vim.notify("Review Mode local: start a review first (:ReviewModeLocal)", vim.log.levels.WARN)
    return
  end

  if buf_valid() then
    local win = vim.fn.win_findbuf(ui.buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright sbuffer " .. ui.buf)
    end
    render()
    return
  end

  vim.cmd("botright split")
  vim.api.nvim_win_set_height(0, math.max(10, math.floor(vim.o.lines * 0.4)))
  local bufnr = vim.api.nvim_create_buf(false, true)
  ui.buf = bufnr
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "review-mode-local"
  vim.wo.wrap = false

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
  map("<CR>", with_thread(jump))
  map("r", with_thread(reply))
  map("R", with_thread(resolve))
  map("e", with_thread(edit))
  map("dd", with_thread(delete))
  map("q", M.close)

  render()
end

-- Registered after render is defined, or the closure would capture a global.
for _, event in ipairs({ "comments_loaded", "comment_posted", "comment_edited", "comment_deleted", "thread_resolved" }) do
  hooks.on(event, function()
    render()
  end)
end

return M
