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

-- this UI's own state. Draft rows and the body marker are tracked by extmarks,
-- not line numbers, so they follow the text when lines are added above them.
local ui = { buf = nil, drafts = {}, marker = nil }
local ns = vim.api.nvim_create_namespace("review_mode_review_buffer")

local function buf_valid()
  return ui.buf ~= nil and vim.api.nvim_buf_is_valid(ui.buf)
end

-- The first row (0-based) of the review body. When the marker line itself was
-- deleted, its extmark has moved onto the line that followed it -- the body's
-- first line -- so the body is still found and never overwritten.
local function body_start()
  local marker = vim.fn.index(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), body_marker)
  if marker >= 0 then
    return marker + 1, true
  end
  local mark = ui.marker and vim.api.nvim_buf_get_extmark_by_id(ui.buf, ns, ui.marker, {})
  if mark and mark[1] then
    return mark[1], false
  end
  return nil, false
end

local function body_lines()
  if not buf_valid() then
    return {}
  end
  local start = body_start()
  return start and vim.api.nvim_buf_get_lines(ui.buf, start, -1, false) or {}
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
  local rows = {}
  for _, draft in ipairs(drafts) do
    local where = draft.start_line == draft.end_line and tostring(draft.end_line)
      or string.format("%d-%d", draft.start_line, draft.end_line)
    lines[#lines + 1] = string.format("  %s:%s  %s", draft.path, where, draft.body:match("[^\n]*"))
    rows[#lines - 1] = draft
  end
  if #drafts == 0 then
    lines[#lines + 1] = "  (none)"
  end
  vim.list_extend(lines, { "", body_marker })

  -- only the part above the body is ours; the body stays untouched. A missing
  -- marker is put back where it was, never by rewriting the whole buffer.
  local start, found = body_start()
  if not start then
    lines[#lines + 1] = ""
    vim.api.nvim_buf_set_lines(ui.buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(ui.buf, 0, start, false, lines)
    if not found and vim.api.nvim_buf_line_count(ui.buf) == #lines then
      vim.api.nvim_buf_set_lines(ui.buf, -1, -1, false, { "" })
    end
  end

  vim.api.nvim_buf_clear_namespace(ui.buf, ns, 0, -1)
  ui.drafts = {}
  for row, draft in pairs(rows) do
    ui.drafts[vim.api.nvim_buf_set_extmark(ui.buf, ns, row, 0, { invalidate = true })] = draft
  end
  ui.marker = vim.api.nvim_buf_set_extmark(ui.buf, ns, #lines - 1, 0, {})
end

local function draft_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    if ui.drafts[mark[1]] and not mark[4].invalid then
      return ui.drafts[mark[1]]
    end
  end
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
  -- a queued draft is typed work, and removing it cannot be undone with u
  local where = string.format("%s:%d", draft.path, draft.end_line)
  local prompt = string.format("Drop this pending comment?\n\n  %s  %s\n", where, draft.body:match("[^\n]*"))
  if vim.fn.confirm(prompt, "&Drop\n&Keep", 2) ~= 1 then
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

local function plural(count, word)
  return string.format("%d %s%s", count, word, count == 1 and "" or "s")
end

-- What an approval would gloss over, one line per non-zero count. Only APPROVE
-- gets it: approving says you have looked at all of it, so an unviewed file or
-- an unanswered CI failure contradicts the verdict. A COMMENT or
-- REQUEST_CHANGES review is routinely sent with the rest of the diff still
-- unread, and a warning that always fires is one you learn to ignore.
local function readiness_lines(event)
  local review = api.config().review
  if event ~= "APPROVE" or type(review) ~= "table" or review.submit_check ~= true then
    return {}
  end
  local counts = api.review_readiness()
  local lines = {}
  if counts.unviewed_files > 0 then
    lines[#lines + 1] = plural(counts.unviewed_files, "file") .. " not viewed"
    if counts.unviewed_hunks > 0 then
      lines[#lines] = lines[#lines] .. " (" .. plural(counts.unviewed_hunks, "hunk") .. ")"
    end
  end
  if counts.ci_failures > 0 then
    lines[#lines + 1] = plural(counts.ci_failures, "CI failure") .. " on changed lines, not commented on"
  end
  if counts.unresolved_threads > 0 then
    lines[#lines + 1] = plural(counts.unresolved_threads, "unresolved thread")
  end
  return lines
end

--- Submit the pending review. `kind` is comment, approve or request_changes;
--- the body comes from the review buffer when it is open. Always confirmed.
function M.submit(kind)
  local event = events[tostring(kind or "comment"):lower()]
  if not event then
    vim.notify("Review Mode: submit as comment, approve or request_changes", vim.log.levels.WARN)
    return
  end

  -- a local review (or GitLab) has nothing to submit to: say so up front
  -- rather than confirm a submission that cannot happen
  local provider = (api.session() or {}).provider
  if provider == "local" or provider == "gitlab" then
    return api.submit_review({ event = event })
  end

  local count = #api.pending()
  local body = M.body()
  local notes = readiness_lines(event)
  local prompt = string.format(
    "Submit review as %s with %d pending comment%s?%s%s",
    event,
    count,
    count == 1 and "" or "s",
    #notes > 0 and ("\n\n  " .. table.concat(notes, "\n  ")) or "",
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
