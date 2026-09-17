-- The review buffer: pending drafts, the review body, and submission.
--
-- A UI module like panel.lua: review data reaches it only through
-- review_mode.api (plus util and hooks), and scripts/validate.sh enforces that.
--
-- The buffer is ordinary text. Everything below the body marker is the review
-- summary, so it is edited with normal Vim motions; the draft list above it is
-- redrawn whenever the pending set changes, keeping whatever body was typed.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local name = "review-mode://review"
local body_marker = "── Review body (everything below is sent with the review) ──"
local hint = "<CR> jump · dd drop · C-s comment · C-a approve · C-x request changes · q close"

local events = { comment = "COMMENT", approve = "APPROVE", request_changes = "REQUEST_CHANGES" }

-- this UI's own state
local ui = { buf = nil, rows = {} }

local function buf_valid()
  return ui.buf ~= nil and vim.api.nvim_buf_is_valid(ui.buf)
end

local function body_lines()
  if not buf_valid() then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line == body_marker then
      return vim.list_slice(lines, index + 1)
    end
  end
  return {}
end

--- The review body as typed in the buffer, or "" when it is not open.
function M.body()
  return util.trim(table.concat(body_lines(), "\n"))
end

local function render()
  if not buf_valid() then
    return
  end

  local session = api.session()
  local drafts = api.pending()
  local lines = {
    session and string.format("# Review %s#%s", session.repo or "?", session.pr or "?") or "# Review (no session)",
    "",
    string.format("Pending comments (%d)", #drafts),
  }
  ui.rows = {}
  for _, draft in ipairs(drafts) do
    local where = draft.start_line == draft.end_line and tostring(draft.end_line)
      or string.format("%d-%d", draft.start_line, draft.end_line)
    lines[#lines + 1] = string.format("  %s:%s  %s", draft.path, where, draft.body:match("[^\n]*"))
    ui.rows[#lines] = draft
  end
  if #drafts == 0 then
    lines[#lines + 1] = "  (none)"
  end
  vim.list_extend(lines, { "", body_marker })

  -- only the part above the marker is ours; the body below stays untouched
  local current = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
  local marker = vim.fn.index(current, body_marker)
  if marker < 0 then
    lines[#lines + 1] = ""
    vim.api.nvim_buf_set_lines(ui.buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(ui.buf, 0, marker + 1, false, lines)
  end
end

local function draft_at_cursor()
  return ui.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function jump()
  local draft = draft_at_cursor()
  if not draft then
    return
  end
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= current and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      vim.api.nvim_set_current_win(win)
      return api.goto_file(draft.path, draft.end_line)
    end
  end
  vim.cmd("aboveleft split")
  api.goto_file(draft.path, draft.end_line)
end

local function drop()
  local draft = draft_at_cursor()
  if not draft then
    vim.cmd("normal! " .. vim.v.count1 .. "dd")
    return
  end
  api.remove_pending(draft.id)
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

--- Submit the pending review. `kind` is comment, approve or request_changes;
--- the body comes from the review buffer when it is open. Always confirmed.
function M.submit(kind)
  local event = events[tostring(kind or "comment"):lower()]
  if not event then
    vim.notify("Review Mode: submit as comment, approve or request_changes", vim.log.levels.WARN)
    return
  end

  local count = #api.pending()
  local body = M.body()
  local prompt = string.format(
    "Submit review as %s with %d pending comment%s?%s",
    event,
    count,
    count == 1 and "" or "s",
    body ~= "" and ("\n\n  " .. body:match("[^\n]*")) or ""
  )
  if vim.fn.confirm(prompt, "&Submit\n&Cancel", 2) ~= 1 then
    return
  end

  api.submit_review({ event = event, body = body }, function(ok, err)
    if not ok then
      vim.notify("Review Mode review failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("Submitted review (%s, %d comment%s)", event, count, count == 1 and "" or "s"))
    M.close()
  end)
end

function M.open()
  if not api.is_active() then
    vim.notify("Review Mode review: start Review Mode first", vim.log.levels.WARN)
    return
  end

  if buf_valid() then
    local win = vim.fn.win_findbuf(ui.buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright sbuffer " .. ui.buf)
      vim.wo.winbar = "Review  │  " .. hint
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
  vim.bo[bufnr].filetype = "markdown"
  vim.wo.winbar = "Review  │  " .. hint
  vim.wo.wrap = true

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
  map("<CR>", jump)
  map("dd", drop)
  map("q", M.close)
  map("<C-s>", function()
    M.submit("comment")
  end)
  map("<C-a>", function()
    M.submit("approve")
  end)
  map("<C-x>", function()
    M.submit("request_changes")
  end)

  render()
  -- land on the body, which is the part you type into
  pcall(vim.api.nvim_win_set_cursor, 0, { vim.api.nvim_buf_line_count(bufnr), 0 })
end

-- Registered after render is defined, or the closure would capture a global.
hooks.on("pending_changed", function()
  render()
end)

return M
