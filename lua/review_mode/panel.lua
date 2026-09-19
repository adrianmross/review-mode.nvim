-- The thread panel and its draft buffer.
--
-- Review data reaches this module only through review_mode.api -- never through
-- state, github, viewed, comments or diff -- which is the rule that keeps the
-- API honest: everything the built-in panel does, your own UI can do too.
-- review_mode.util and review_mode.hooks are the exception, and not a loophole:
-- they are shared infrastructure (process calls, buffer paths, the event bus)
-- that carry no review data, and any third-party UI may require them too.
-- scripts/validate.sh enforces exactly that list.
--
-- Its window state is local here rather than in the shared session table,
-- because it belongs to this UI and not to the review.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local trim = util.trim
local current_relpath = util.current_relpath
local buf_relpath = util.buf_relpath

local panel_ns = vim.api.nvim_create_namespace("review_mode_panel")

-- this UI's own state
local ui = {}

-- Thread panel ---------------------------------------------------------------

-- The thread renderer emits its own highlights, so the float must not be
-- handed to markdown: open it raw and paint the marks on top.
local function open_thread_preview(lines, marks, width)
  local bufnr, winid = vim.lsp.util.open_floating_preview(lines, "review-thread", {
    border = "rounded",
    focusable = true,
    max_width = width,
    max_height = math.floor(vim.o.lines * 0.6),
  })
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- open_floating_preview sets 'syntax', not 'filetype'
    vim.bo[bufnr].filetype = "review-thread"
    api.apply_render(bufnr, panel_ns, lines, marks)
  end
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].wrap = false
  end
  return bufnr, winid
end

function M.show_thread()
  local path = current_relpath()
  if not path then
    return
  end

  api.ensure_comments()
  api.ensure_highlights()

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local threads = api.threads({ path = path, line = line })
  local width = math.floor(vim.o.columns * 0.6)

  for _, thread in ipairs(threads) do
    if thread.line and api.suggestion(thread.comments[1]) then
      local last = math.min(thread.line, vim.api.nvim_buf_line_count(bufnr))
      thread.original_lines = vim.api.nvim_buf_get_lines(bufnr, math.max(1, thread.start_line or last) - 1, last, false)
    end
  end

  local lines, marks = api.render_threads(threads, {
    width = width,
    empty = string.format("No PR comments on %s:%d", path, line),
  })
  open_thread_preview(lines, marks, width)
end

local function write_render(bufnr, lines, marks)
  api.apply_render(bufnr, panel_ns, lines, marks)
end

local function panel_is_open()
  return ui.panel_win ~= nil and vim.api.nvim_win_is_valid(ui.panel_win)
end

local function composer_is_open()
  return ui.composer_win ~= nil and vim.api.nvim_win_is_valid(ui.composer_win)
end

-- The panel follows whatever ordinary window the user is in, so it must never
-- treat itself, the composer, or a diff scratch buffer as the source.
local function panel_code_win()
  local current = vim.api.nvim_get_current_win()
  local candidates = { current }
  vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(0))

  local diff_owned = {}
  for _, win in ipairs(api.diff_windows()) do
    diff_owned[win] = true
  end

  for _, win in ipairs(candidates) do
    if
      vim.api.nvim_win_is_valid(win)
      and win ~= ui.panel_win
      and win ~= ui.composer_win
      and not diff_owned[win]
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    then
      return win
    end
  end
  return nil
end

local function panel_target()
  local win = panel_code_win()
  if not win then
    return nil
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  local path = buf_relpath(bufnr)
  if not path then
    return nil
  end

  return { win = win, buf = bufnr, path = path, line = vim.api.nvim_win_get_cursor(win)[1] }
end

-- A suggestion replaces the lines it hangs off, so pull those lines out of the
-- real buffer and let the renderer draw the replacement as a diff.
local function suggestion_context(target, thread)
  if not target or not thread or not thread.line then
    return nil
  end

  local last = math.min(thread.line, vim.api.nvim_buf_line_count(target.buf))
  local first = math.max(1, thread.start_line or last)
  if first > last then
    return nil
  end
  return vim.api.nvim_buf_get_lines(target.buf, first - 1, last, false)
end

local panel_hint = "r reply · R new thread · e edit · dd delete · + react · "
  .. "x resolve · a apply · s review · o open · <CR> jump · q close"
  .. " · p preview · A accept all"

local function render_panel()
  if not panel_is_open() then
    return
  end

  api.ensure_highlights()
  local width = vim.api.nvim_win_get_width(ui.panel_win)
  local target = panel_target()
  local threads, empty = {}, "No PR file in focus"

  if target then
    empty = string.format("No PR comments in %s", target.path)
    local on_line = api.threads({ path = target.path, line = target.line })
    if #on_line > 0 then
      threads = on_line
      for _, thread in ipairs(threads) do
        if api.suggestion(thread.comments[1]) then
          thread.original_lines = suggestion_context(target, thread)
        end
      end
    else
      threads = api.threads({ path = target.path, include_resolved = api.config().comments.show_resolved })
    end
  end

  local lines, marks, rows, comment_rows = api.render_threads(threads, {
    width = width,
    empty = empty,
    hint = panel_hint,
  })

  write_render(ui.panel_buf, lines, marks)
  ui.panel_threads = threads
  ui.panel_rows = rows
  ui.panel_comment_rows = comment_rows
  ui.panel_target = target

  if vim.api.nvim_get_current_win() ~= ui.panel_win then
    -- Park the panel view on the thread nearest the cursor instead of the top
    -- of a long file's worth of threads.
    local row = 0
    for _, thread in ipairs(threads) do
      if target and thread.line and target.line >= thread.line then
        row = rows[thread.id] or row
      end
    end
    pcall(vim.api.nvim_win_set_cursor, ui.panel_win, { row + 1, 0 })
  end
end

function M.schedule_refresh()
  if ui.panel_refresh_pending or not panel_is_open() then
    return
  end

  ui.panel_refresh_pending = true
  vim.defer_fn(function()
    ui.panel_refresh_pending = false
    render_panel()
  end, api.config().performance.ui_refresh_debounce_ms)
end

local function panel_thread_at_cursor()
  local threads = ui.panel_threads or {}
  if #threads == 0 then
    return nil
  end
  if vim.api.nvim_get_current_win() ~= ui.panel_win then
    return threads[1]
  end

  local row = vim.api.nvim_win_get_cursor(ui.panel_win)[1] - 1
  local best, best_row = nil, -1
  for _, thread in ipairs(threads) do
    local thread_row = (ui.panel_rows or {})[thread.id]
    if thread_row and thread_row <= row and thread_row > best_row then
      best, best_row = thread, thread_row
    end
  end
  return best or threads[1]
end

-- The comment whose header is at or above the cursor, within the thread under
-- it. Outside the panel there is no cursor to go by, so take the latest.
local function panel_comment_at_cursor()
  local thread = panel_thread_at_cursor()
  local comments = thread and thread.comments or {}
  if #comments == 0 or vim.api.nvim_get_current_win() ~= ui.panel_win then
    return thread, comments[#comments]
  end

  local row = vim.api.nvim_win_get_cursor(ui.panel_win)[1] - 1
  local best = comments[1]
  for _, comment in ipairs(comments) do
    local comment_row = (ui.panel_comment_rows or {})[comment.id]
    if comment_row and comment_row <= row then
      best = comment
    end
  end
  return thread, best
end

-- Composer -------------------------------------------------------------------

-- Both scratch buffers are bufhidden = "wipe", so closing the window is what
-- reclaims them. Deleting the buffer as well tears down a buffer that is
-- already being wiped, which crashes Neovim.
local function close_composer()
  local win, bufnr = ui.composer_win, ui.composer_buf
  local source = ui.composer_source
  -- only when the draft had focus: closing the panel from the code window must
  -- not move the cursor anywhere
  local was_current = win ~= nil and win == vim.api.nvim_get_current_win()
  ui.composer_win, ui.composer_buf, ui.composer_source = nil, nil, nil
  ui.composer_submit, ui.composer_prompt, ui.composer_pend = nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  elseif bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  -- The draft is a split under the panel, so Vim would hand focus to the panel.
  -- Posting or discarding a comment should leave you back in the code.
  if was_current and source and source.win and vim.api.nvim_win_is_valid(source.win) then
    vim.api.nvim_set_current_win(source.win)
  end
end

local function composer_body()
  if not ui.composer_buf or not vim.api.nvim_buf_is_valid(ui.composer_buf) then
    return ""
  end
  return trim(table.concat(vim.api.nvim_buf_get_lines(ui.composer_buf, 0, -1, false), "\n"))
end

--- Pull the code the user is talking about into the draft, so a reply can
--- point at lines other than the one the thread is anchored to.
function M.composer_reference()
  local source = ui.composer_source
  if not source or not vim.api.nvim_buf_is_valid(source.buf) or not composer_is_open() then
    return
  end

  local first = vim.api.nvim_buf_get_mark(source.buf, "<")[1]
  local last = vim.api.nvim_buf_get_mark(source.buf, ">")[1]
  if first < 1 or last < first then
    first, last = source.line, source.line
  end
  last = math.min(last, vim.api.nvim_buf_line_count(source.buf))
  first = math.min(first, last)

  local body = vim.api.nvim_buf_get_lines(source.buf, first - 1, last, false)
  local label = first == last and tostring(first) or string.format("%d-%d", first, last)
  local lines = { string.format("`%s:%s`", source.path, label), "" }
  vim.list_extend(lines, { "```" .. (vim.bo[source.buf].filetype or "") })
  vim.list_extend(lines, body)
  vim.list_extend(lines, { "```", "" })

  local row = vim.api.nvim_win_get_cursor(ui.composer_win)[1]
  vim.api.nvim_buf_set_lines(ui.composer_buf, row, row, false, lines)
  pcall(vim.api.nvim_win_set_cursor, ui.composer_win, { row + #lines, 0 })
end

-- The ```suggestion block in a draft, as its fence rows (0-based), or nil.
local function draft_suggestion_block(lines)
  for open, line in ipairs(lines) do
    if line:match("^```suggestion%s*$") then
      for close = open + 1, #lines do
        if lines[close]:match("^```%s*$") then
          return open - 1, close - 1
        end
      end
    end
  end
  return nil
end

--- Edit the suggestion as code, not as text in a markdown fence: its lines open
--- in a buffer of their own with the file's filetype, and :w or <C-s> writes
--- them back into the draft's ```suggestion block (adding one if there is
--- none). q goes back to the draft without changing it.
function M.composer_suggest()
  local source = ui.composer_source
  if not source or not vim.api.nvim_buf_is_valid(source.buf) or not composer_is_open() then
    return
  end

  vim.cmd("stopinsert")
  local draft_buf, draft_win = ui.composer_buf, ui.composer_win
  local draft = vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)
  local open_row, close_row = draft_suggestion_block(draft)
  local last = math.min(source.end_line or source.line, vim.api.nvim_buf_line_count(source.buf))
  local first = math.min(source.start_line or source.line, last)
  local code = open_row and vim.list_slice(draft, open_row + 2, close_row)
    or vim.api.nvim_buf_get_lines(source.buf, first - 1, last, false)
  local insert_row = vim.api.nvim_win_get_cursor(draft_win)[1]

  vim.api.nvim_set_current_win(draft_win)
  vim.cmd("aboveleft split")
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(bufnr, "review-mode://suggestion-code")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, code)
  vim.bo[bufnr].filetype = vim.bo[source.buf].filetype
  vim.bo[bufnr].modified = false
  vim.wo[win].winbar =
    string.format("Suggestion for %s:%d-%d  │  :w or C-s to the draft  q cancel", source.path, first, last)

  local function back(write)
    if write and vim.api.nvim_buf_is_valid(draft_buf) then
      local block = { "```suggestion" }
      vim.list_extend(block, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      block[#block + 1] = "```"
      local open, close = draft_suggestion_block(vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false))
      if open then
        vim.api.nvim_buf_set_lines(draft_buf, open, close + 1, false, block)
      else
        block[#block + 1] = ""
        vim.api.nvim_buf_set_lines(draft_buf, insert_row, insert_row, false, block)
      end
    end
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_win_is_valid(draft_win) then
      vim.api.nvim_set_current_win(draft_win)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
      back(true)
    end,
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    back(true)
  end, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "q", function()
    back(false)
  end, { buffer = bufnr, nowait = true, silent = true })
end

function M.composer_submit()
  local submit = ui.composer_submit
  local body = composer_body()
  if body == "" then
    vim.notify("Review Mode: nothing to post", vim.log.levels.WARN)
    return
  end

  local preview = body:match("([^\n]+)") or body
  if #preview > 60 then
    preview = preview:sub(1, 57) .. "..."
  end
  local extra = select(2, body:gsub("\n", ""))
  local prompt = string.format(
    "%s\n\n  %s%s\n",
    ui.composer_prompt or "Post this to GitHub?",
    preview,
    extra > 0 and string.format("\n  (+%d more lines)", extra) or ""
  )

  if vim.fn.confirm(prompt, "&Post\n&Keep editing", 2) ~= 1 then
    return
  end

  close_composer()
  if submit then
    submit(body)
  end
end

--- Queue the draft for the next review instead of posting it. Only offered for
--- new comments: the reviews endpoint cannot batch replies.
function M.composer_pend()
  local pend = ui.composer_pend
  local body = composer_body()
  if not pend or body == "" then
    return
  end
  close_composer()
  pend(body)
end

function M.composer_cancel()
  if composer_body() ~= "" and vim.fn.confirm("Discard this draft?", "&Discard\n&Keep editing", 2) ~= 1 then
    return
  end
  close_composer()
end

--- Open a multi-line draft buffer. Nothing is sent until |M.composer_submit|
--- has been confirmed, so a stray keystroke cannot post to the PR.
local function open_composer(opts)
  close_composer()

  if panel_is_open() then
    vim.api.nvim_set_current_win(ui.panel_win)
    vim.cmd("belowright split")
  else
    vim.cmd("botright split")
  end
  vim.api.nvim_win_set_height(0, math.max(8, math.floor(vim.o.lines * 0.25)))

  local bufnr = vim.api.nvim_create_buf(false, true)
  ui.composer_buf = bufnr
  ui.composer_win = vim.api.nvim_get_current_win()
  ui.composer_source = opts.source
  ui.composer_submit = opts.submit
  ui.composer_prompt = opts.prompt
  ui.composer_pend = opts.pend

  vim.api.nvim_win_set_buf(ui.composer_win, bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, "review-mode://" .. (opts.name or "draft"))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.default or { "" })
  vim.wo[ui.composer_win].winbar = opts.title
    .. "  │  C-s post  C-r quote  C-g suggest  q cancel"
    .. (opts.pend and "  C-p pending" or "")
  vim.wo[ui.composer_win].wrap = true

  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
  map({ "n", "i" }, "<C-s>", M.composer_submit)
  map("n", "q", M.composer_cancel)
  map({ "n", "i" }, "<C-r>", M.composer_reference)
  map({ "n", "i" }, "<C-g>", M.composer_suggest)
  if opts.pend then
    map({ "n", "i" }, "<C-p>", M.composer_pend)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
      M.composer_submit()
    end,
  })

  vim.cmd("startinsert")
end

-- Panel actions --------------------------------------------------------------

local function panel_source(thread, target)
  if not target then
    return nil
  end
  return {
    buf = target.buf,
    win = target.win,
    path = target.path,
    line = target.line,
    start_line = thread and (thread.start_line or thread.line) or target.line,
    end_line = thread and thread.line or target.line,
  }
end

local function reply_to_thread(thread, target)
  local comments = thread and thread.comments or {}
  local last_comment = comments[#comments]
  if not last_comment or not last_comment.id then
    vim.notify("Review Mode reply: no comment to reply to", vim.log.levels.WARN)
    return
  end

  open_composer({
    name = "reply",
    title = string.format("Reply to %s", comments[1].author or "thread"),
    prompt = string.format("Post this reply to %s?", thread.path or "the thread"),
    source = panel_source(thread, target),
    submit = function(body)
      api.reply({ thread_id = thread.id, comment_id = last_comment.id, body = body }, function(ok, err)
        if not ok then
          vim.notify("Review Mode reply failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
          return
        end
        vim.notify("Submitted PR thread reply")
      end)
    end,
  })
end

local function comment_on_target(source)
  if not source then
    vim.notify("Review Mode comment: no PR file in focus", vim.log.levels.WARN)
    return
  end

  local first = math.min(source.start_line or source.line, source.end_line or source.line)
  local last = math.max(source.start_line or source.line, source.end_line or source.line)
  open_composer({
    name = "comment",
    title = string.format("Comment on %s:%d-%d", source.path, first, last),
    prompt = string.format("Post this comment on %s:%d-%d?", source.path, first, last),
    source = source,
    submit = function(body)
      api.comment({ path = source.path, start_line = first, end_line = last, body = body })
    end,
    pend = function(body)
      local draft, err = api.add_pending({ path = source.path, start_line = first, end_line = last, body = body })
      if not draft then
        vim.notify("Review Mode pending: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("Added pending comment on %s:%d (%d pending)", source.path, last, #api.pending()))
    end,
  })
end

-- Applying goes through the trial machinery, so every application is marked and
-- revertible. The buffer write itself is the same one this used to do inline.
local function apply_thread_suggestion(thread, target)
  if not thread or not target then
    return
  end

  -- the apply key toggles: on a suggestion already applied, it reverts
  for _, live in ipairs(api.suggestion_trials()) do
    if live.thread_id == thread.id and live.buf == target.buf then
      local reverted, err = api.revert_suggestion(live.id)
      if not reverted then
        vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      vim.notify(string.format("Reverted the trial suggestion at %s:%d", reverted.path, reverted.line))
      return
    end
  end

  local trial, err = api.accept_suggestion(thread, { buf = target.buf })
  if not trial then
    vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
    return
  end

  vim.notify(
    string.format(
      "Applied suggestion to %s:%d as trial %d (unsaved; apply again to revert)",
      trial.path,
      trial.line,
      trial.id
    )
  )
end

local function jump_to_thread(thread, target)
  if not thread or not target or not thread.line then
    return
  end
  vim.api.nvim_set_current_win(target.win)
  pcall(vim.api.nvim_win_set_cursor, target.win, { util.clamp_line(thread.line), 0 })
end

local function panel_move(delta)
  local threads = ui.panel_threads or {}
  if #threads == 0 then
    return
  end

  local rows = {}
  for _, thread in ipairs(threads) do
    local row = (ui.panel_rows or {})[thread.id]
    if row then
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)

  local current = vim.api.nvim_win_get_cursor(ui.panel_win)[1] - 1
  local index = 1
  for position, row in ipairs(rows) do
    if row <= current then
      index = position
    end
  end
  index = math.min(#rows, math.max(1, index + delta))
  pcall(vim.api.nvim_win_set_cursor, ui.panel_win, { rows[index] + 1, 0 })
end

local function open_thread_url(thread)
  local comments = thread and thread.comments or {}
  local url = comments[#comments] and comments[#comments].url
  if not url then
    M.open_browser()
    return
  end

  util.open_url(url)
end

-- Edit and delete ------------------------------------------------------------

local function modifiable(comment)
  if not comment then
    vim.notify("Review Mode: no PR comment here", vim.log.levels.WARN)
    return false
  end
  local ok, err = api.can_modify_comment(comment.id)
  if not ok then
    vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
  end
  return ok
end

local function edit_comment(thread, comment, target)
  if not modifiable(comment) then
    return
  end

  open_composer({
    name = "edit",
    title = "Edit your comment",
    prompt = "Save this edit to GitHub?",
    source = panel_source(thread, target),
    default = vim.split(comment.body or "", "\n", { plain = true }),
    submit = function(body)
      api.edit_comment({ comment_id = comment.id, body = body }, function(ok, err)
        if not ok then
          vim.notify("Review Mode edit failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
          return
        end
        vim.notify("Edited PR comment")
      end)
    end,
  })
end

local function delete_comment(comment)
  if not modifiable(comment) then
    return
  end

  local first = vim.trim((comment.body or ""):match("([^\n]+)") or "")
  if vim.fn.confirm(string.format("Delete your comment?\n\n  %s\n", first), "&Delete\n&Keep", 2) ~= 1 then
    return
  end

  -- The reload that follows a delete is async, so between the request and the
  -- refresh the cached rows still point at a comment GitHub has dropped. Clear
  -- them now: a key pressed in that window finds nothing rather than acting on
  -- an id that no longer exists.
  ui.panel_comment_rows = nil

  api.delete_comment(comment.id, function(ok, err)
    if not ok then
      vim.notify("Review Mode delete failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    vim.notify("Deleted PR comment")
  end)
end

local function apply_panel_keys(bufnr)
  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end

  map("q", function()
    M.close_panel()
  end)
  map("<CR>", function()
    jump_to_thread(panel_thread_at_cursor(), ui.panel_target)
  end)
  -- r comments, as <leader>rr does: a reply here, a new thread on an empty panel
  map("r", function()
    local thread = panel_thread_at_cursor()
    if thread then
      reply_to_thread(thread, ui.panel_target)
    else
      comment_on_target(panel_source(nil, ui.panel_target))
    end
  end)
  map("R", function()
    comment_on_target(panel_source(nil, ui.panel_target))
  end)
  map("x", function()
    local thread = panel_thread_at_cursor()
    if thread then
      api.resolve(thread.id, not thread.is_resolved)
    end
  end)
  map("a", function()
    apply_thread_suggestion(panel_thread_at_cursor(), ui.panel_target)
  end)
  -- suggestions
  map("p", function()
    M.preview_suggestion("inline")
  end)
  map("A", function()
    M.accept_all_suggestions()
  end)
  map("o", function()
    open_thread_url(panel_thread_at_cursor())
  end)
  map("]r", function()
    panel_move(1)
  end)
  map("[r", function()
    panel_move(-1)
  end)
  map("<C-l>", function()
    api.reload_comments()
  end)
  -- Reactions --
  map("+", function()
    local _, comment = panel_comment_at_cursor()
    M.react_to(comment)
  end)
  -- edit and delete
  map("e", function()
    local thread, comment = panel_comment_at_cursor()
    edit_comment(thread, comment, ui.panel_target)
  end)
  map("dd", function()
    delete_comment(select(2, panel_comment_at_cursor()))
  end)
  -- the review buffer is a sibling UI module, loaded lazily
  map("s", function()
    require("review_mode.review_buffer").open()
  end)
end

local function forget_panel()
  ui.panel_win, ui.panel_buf = nil, nil
  ui.panel_threads, ui.panel_rows, ui.panel_target = nil, nil, nil
  ui.panel_comment_rows = nil
end

function M.close_panel()
  close_composer()
  local win, bufnr = ui.panel_win, ui.panel_buf
  forget_panel()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  elseif bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  hooks.emit("panel_close", {})
end

function M.open_panel()
  if panel_is_open() then
    render_panel()
    return
  end

  if not api.is_active() then
    vim.notify("Review Mode panel: start Review Mode first", vim.log.levels.WARN)
    return
  end

  api.ensure_highlights()
  local origin = vim.api.nvim_get_current_win()
  local config = api.config().panel
  local bufnr = vim.api.nvim_create_buf(false, true)

  -- hooks.open_panel_window gets the scratch buffer and the configured
  -- position/width and returns the window to use, so a float, a tab, or an
  -- existing split all work without the plugin knowing about them.
  local win = hooks.resolve("open_panel_window", {
    buf = bufnr,
    position = config.position,
    width = config.width,
    origin = origin,
  }, function(ctx)
    vim.cmd(ctx.position == "left" and "topleft vsplit" or "botright vsplit")
    vim.api.nvim_win_set_width(0, math.max(30, tonumber(ctx.width) or 60))
    return vim.api.nvim_get_current_win()
  end)

  if not win or not vim.api.nvim_win_is_valid(win) then
    vim.notify("Review Mode panel: open_panel_window did not return a window", vim.log.levels.ERROR)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  ui.panel_buf = bufnr
  ui.panel_win = win
  vim.api.nvim_win_set_buf(ui.panel_win, bufnr)
  vim.bo[bufnr].filetype = "review-thread"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  vim.wo[ui.panel_win].winbar = "PR threads"
  vim.wo[ui.panel_win].number = false
  vim.wo[ui.panel_win].relativenumber = false
  vim.wo[ui.panel_win].signcolumn = "no"
  vim.wo[ui.panel_win].wrap = false
  vim.wo[ui.panel_win].cursorline = true
  apply_panel_keys(bufnr)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(ui.panel_win),
    once = true,
    callback = function()
      -- The window is already gone; closing anything else from inside this
      -- event re-enters the teardown, so only drop state here.
      forget_panel()
      vim.schedule(close_composer)
    end,
  })

  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  api.ensure_comments()
  render_panel()
  hooks.emit("panel_open", { win = ui.panel_win, buf = ui.panel_buf })
end

-- Both entry points work from the panel and from an ordinary buffer, so
-- resolve "which thread, in which file" once for both.
local function focused_thread()
  if panel_is_open() and vim.api.nvim_get_current_win() == ui.panel_win then
    return panel_thread_at_cursor(), ui.panel_target
  end

  local path = current_relpath()
  if not path then
    return nil, nil
  end
  api.ensure_comments()

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local threads = api.threads({ path = path, line = line })
  return threads[#threads],
    {
      win = vim.api.nvim_get_current_win(),
      buf = vim.api.nvim_get_current_buf(),
      path = path,
      line = line,
    }
end

--- Reply to the thread on the current line, or to the one the panel is on.
function M.reply()
  local thread, target = focused_thread()
  if not thread then
    vim.notify("No PR comment thread on current line", vim.log.levels.WARN)
    return
  end
  reply_to_thread(thread, target)
end

--- Draft a suggestion from an edit you made in the file (see api.edits). The
--- suggestion block is filled in from the edit; write a message above it.
--- Posting or queueing it puts HEAD's lines back, since the change lives on as
--- the suggestion.
function M.suggest_edit(edit)
  local range = string.format("%s:%d-%d", edit.path, edit.start_line, edit.end_line)
  if not edit.in_diff then
    vim.notify(
      string.format("Review Mode: %s is outside the PR diff, so it cannot carry a suggestion", range),
      vim.log.levels.WARN
    )
    return
  end

  api.track_edit(edit)
  local default = { "" }
  vim.list_extend(default, vim.split(api.edit_suggestion_body(edit), "\n"))
  local where = { path = edit.path, start_line = edit.start_line, end_line = edit.end_line }
  open_composer({
    name = "suggestion",
    title = "Suggest your edit on " .. range,
    prompt = string.format("Post this suggestion on %s and undo your edit?", range),
    source = {
      buf = edit.buf,
      win = vim.fn.bufwinid(edit.buf),
      path = edit.path,
      line = edit.end_line,
      start_line = edit.start_line,
      end_line = edit.end_line,
    },
    default = default,
    submit = function(body)
      api.comment(vim.tbl_extend("force", where, { body = body }), function(ok, err)
        if not ok then
          vim.notify("Review Mode suggestion failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
          return
        end
        if api.undo_edit(edit) then
          vim.notify("Posted suggestion on " .. range .. " and undid your edit")
        else
          vim.notify("Posted suggestion on " .. range .. ", but could not undo your edit", vim.log.levels.WARN)
        end
      end)
    end,
    pend = function(body)
      local draft, err = api.add_pending(vim.tbl_extend("force", where, { body = body }))
      if not draft then
        vim.notify("Review Mode pending: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      if api.undo_edit(edit) then
        vim.notify(string.format("Queued suggestion on %s and undid your edit (%d pending)", range, #api.pending()))
      else
        vim.notify("Queued suggestion on " .. range .. ", but could not undo your edit", vim.log.levels.WARN)
      end
    end,
  })
end

--- Reply to a given thread, e.g. one picked from several on a line.
function M.reply_to(thread)
  reply_to_thread(thread, select(2, focused_thread()))
end

--- Replace the lines a suggestion is anchored to with the suggested lines.
function M.apply_suggestion()
  local thread, target = focused_thread()
  if not thread then
    vim.notify("No PR comment thread on current line", vim.log.levels.WARN)
    return
  end
  apply_thread_suggestion(thread, target)
end

-- Suggestions ----------------------------------------------------------------

-- "Which file, in which window" for the suggestion commands, which -- unlike
-- the thread ones -- also have something to do when no thread is on the line.
local function suggestion_target()
  if panel_is_open() and vim.api.nvim_get_current_win() == ui.panel_win then
    return ui.panel_target
  end

  local path = current_relpath()
  if not path then
    return nil
  end
  return {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    path = path,
    line = vim.api.nvim_win_get_cursor(0)[1],
  }
end

--- Toggle a preview of the suggestion under the cursor. layout is "inline"
--- (virtual lines in the file) or "split" (side by side).
function M.preview_suggestion(layout)
  layout = (layout == "" or layout == nil) and "inline" or layout
  local thread, target = focused_thread()
  if not thread or not target then
    vim.notify("No PR comment thread on current line", vim.log.levels.WARN)
    return
  end

  local shown, err = api.preview_suggestion(thread, { buf = target.buf, layout = layout })
  if shown == nil then
    vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Apply every suggestion in the current file, after a confirmation saying how
--- many and where.
function M.accept_all_suggestions()
  local target = suggestion_target()
  if not target then
    vim.notify("Review Mode: current buffer is not a PR file", vim.log.levels.WARN)
    return
  end

  local entries = api.suggestions(target.path)
  if #entries == 0 then
    vim.notify(string.format("No suggestions in %s", target.path), vim.log.levels.WARN)
    return
  end

  local prompt = string.format("Apply %d suggestion%s in %s?", #entries, #entries == 1 and "" or "s", target.path)
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end

  local applied, err = api.accept_all_suggestions(target.path, { buf = target.buf })
  if applied == 0 then
    vim.notify("Review Mode: " .. tostring(err or "nothing to apply"), vim.log.levels.WARN)
    return
  end
  vim.notify(
    string.format("Applied %d suggestion%s to %s (unsaved trials)", applied, applied == 1 and "" or "s", target.path)
  )
end

--- Revert a trial: the one under the cursor, or the one with this id.
function M.revert_suggestion(id)
  local trial, err = api.revert_suggestion(tonumber(id))
  if not trial then
    vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  vim.notify(string.format("Reverted trial %d in %s:%d", trial.id, trial.path, trial.line))
end

--- List the trials that are applied but not saved.
function M.list_trials()
  local trials = api.suggestion_trials()
  if #trials == 0 then
    vim.notify("No trial suggestions are live")
    return
  end

  local lines = { string.format("%d trial suggestion(s), applied but not saved:", #trials) }
  for _, trial in ipairs(trials) do
    lines[#lines + 1] = string.format(
      "  %d  %s:%d  +%d -%d  (:ReviewModeSuggestionRevert %d)",
      trial.id,
      trial.path,
      trial.line,
      trial.added,
      trial.removed,
      trial.id
    )
  end
  util.open_lines_preview(lines, "review-trials")
end

--- Commit every live trial, crediting the suggesters, after one confirmation
--- that can also resolve the suggestion threads.
function M.commit_suggestions()
  local plan, err = api.suggestion_commit_plan()
  if not plan then
    vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
    return
  end

  local count = #plan.trials
  local lines =
    { string.format("Commit %d trial suggestion%s (local only, nothing is pushed):", count, count == 1 and "" or "s") }
  for _, trial in ipairs(plan.trials) do
    local login = trial.suggester and trial.suggester.login or "unknown"
    lines[#lines + 1] = string.format("  %s:%d  from %s", trial.path, trial.line, tostring(login))
  end
  lines[#lines + 1] = ""
  for _, line in ipairs(vim.split(vim.trim(plan.message), "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. line
  end
  local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Commit\nCommit and &resolve threads\n&Cancel", 3)
  if choice ~= 1 and choice ~= 2 then
    return
  end

  local result, commit_err = api.commit_suggestions(plan)
  if not result then
    vim.notify("Review Mode: " .. tostring(commit_err), vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("Committed %d suggestion%s as %s", count, count == 1 and "" or "s", result.sha:sub(1, 7)))
  if #result.unwritten > 0 then
    vim.notify(
      "Review Mode: committed, but could not write " .. table.concat(result.unwritten, ", ") .. "; :write it",
      vim.log.levels.WARN
    )
  end

  if choice == 2 then
    local resolved = {}
    for _, trial in ipairs(plan.trials) do
      if not resolved[trial.thread_id] then
        resolved[trial.thread_id] = true
        api.resolve(trial.thread_id, true)
      end
    end
  end
end

--- Comment on the current line or visual range through the draft buffer.
function M.compose_comment(command)
  local path = current_relpath()
  if not path then
    vim.notify("Review Mode comment: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  local start_line, end_line = util.visual_range(command)
  comment_on_target({
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    path = path,
    line = start_line,
    start_line = start_line,
    end_line = end_line,
  })
end

-- Reactions ------------------------------------------------------------------

--- Toggle a reaction on `comment`. Without `content`, pick one; reactions you
--- already added are marked, and picking one removes it. No confirmation: a
--- reaction is cheap to undo.
function M.react_to(comment, content)
  if not comment then
    vim.notify("No PR comment to react to", vim.log.levels.WARN)
    return
  end
  -- a pending draft only exists locally, so it has no id to react to; refuse
  -- before the picker rather than after it
  if not comment.id then
    vim.notify("A pending review comment cannot be reacted to until it is submitted", vim.log.levels.WARN)
    return
  end
  if content and content ~= "" then
    api.react({ comment = comment, content = content:upper() })
    return
  end

  local own = {}
  for _, reaction in ipairs(comment.reactions or {}) do
    own[reaction.content] = reaction.viewer_has_reacted
  end
  vim.ui.select(api.reaction_contents, {
    prompt = "React to " .. (comment.author or "comment"),
    format_item = function(item)
      return string.format("%s %s%s", item.emoji, item.content, own[item.content] and "  (yours, remove)" or "")
    end,
  }, function(item)
    if item then
      api.react({ comment = comment, content = item.content })
    end
  end)
end

--- React to the latest comment on the current line, or the one under the panel
--- cursor.
function M.react(content)
  if panel_is_open() and vim.api.nvim_get_current_win() == ui.panel_win then
    local _, comment = panel_comment_at_cursor()
    return M.react_to(comment, content)
  end
  local thread = focused_thread()
  local comments = thread and thread.comments or {}
  M.react_to(comments[#comments], content)
end

-- Your most recent comment on the current line, or the one under the panel
-- cursor. With none of your own, the line's last comment, so the refusal can
-- say why (not yours, or authorship unknown).
local function focused_own_comment()
  if panel_is_open() and vim.api.nvim_get_current_win() == ui.panel_win then
    local thread, comment = panel_comment_at_cursor()
    return thread, comment, ui.panel_target
  end

  local thread, target = focused_thread()
  if not thread then
    return nil, nil, nil
  end

  local own_thread, own
  for _, candidate in ipairs(api.threads({ path = target.path, line = target.line })) do
    for _, comment in ipairs(candidate.comments) do
      if comment.viewer_did_author and (not own or (comment.created_at or "") >= (own.created_at or "")) then
        own_thread, own = candidate, comment
      end
    end
  end
  if own then
    return own_thread, own, target
  end
  return thread, thread.comments[#thread.comments], target
end

--- Edit your most recent comment on the current line through the draft buffer.
function M.edit_comment()
  edit_comment(focused_own_comment())
end

--- Delete your most recent comment on the current line, after confirming.
function M.delete_comment()
  delete_comment(select(2, focused_own_comment()))
end

function M.toggle_panel()
  if panel_is_open() then
    M.close_panel()
    return
  end
  M.open_panel()
end

function M.panel_is_open()
  return panel_is_open()
end

function M.panel_win()
  return ui.panel_win
end

return M
