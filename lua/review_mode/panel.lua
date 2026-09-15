-- The thread panel and its draft buffer.
--
-- This module talks to review_mode.api and nothing else from the plugin, which
-- is the rule that keeps the API honest: everything the built-in panel does,
-- your own UI can do too. Its window state is local here rather than in the
-- shared session table, because it belongs to this UI and not to the review.
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

local panel_hint = "r reply · c comment · R resolve · a apply · o open · <CR> jump · q close"

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

  local lines, marks, rows = api.render_threads(threads, {
    width = width,
    empty = empty,
    hint = panel_hint,
  })

  write_render(ui.panel_buf, lines, marks)
  ui.panel_threads = threads
  ui.panel_rows = rows
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

-- Composer -------------------------------------------------------------------

-- Both scratch buffers are bufhidden = "wipe", so closing the window is what
-- reclaims them. Deleting the buffer as well tears down a buffer that is
-- already being wiped, which crashes Neovim.
local function close_composer()
  local win, bufnr = ui.composer_win, ui.composer_buf
  ui.composer_win, ui.composer_buf, ui.composer_source = nil, nil, nil
  ui.composer_submit, ui.composer_prompt = nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  elseif bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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

--- Seed a GitHub suggestion block from the lines the draft is aimed at.
function M.composer_suggest()
  local source = ui.composer_source
  if not source or not vim.api.nvim_buf_is_valid(source.buf) or not composer_is_open() then
    return
  end

  local last = math.min(source.end_line or source.line, vim.api.nvim_buf_line_count(source.buf))
  local first = math.min(source.start_line or source.line, last)
  local lines = { "```suggestion" }
  vim.list_extend(lines, vim.api.nvim_buf_get_lines(source.buf, first - 1, last, false))
  vim.list_extend(lines, { "```", "" })

  local row = vim.api.nvim_win_get_cursor(ui.composer_win)[1]
  vim.api.nvim_buf_set_lines(ui.composer_buf, row, row, false, lines)
  pcall(vim.api.nvim_win_set_cursor, ui.composer_win, { row + #lines, 0 })
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

  vim.api.nvim_win_set_buf(ui.composer_win, bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, "review-mode://" .. (opts.name or "draft"))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.default or { "" })
  vim.wo[ui.composer_win].winbar = opts.title .. "  │  C-s post  C-r quote  C-g suggest  q cancel"
  vim.wo[ui.composer_win].wrap = true

  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
  map({ "n", "i" }, "<C-s>", M.composer_submit)
  map("n", "q", M.composer_cancel)
  map({ "n", "i" }, "<C-r>", M.composer_reference)
  map({ "n", "i" }, "<C-g>", M.composer_suggest)

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
  })
end

local function apply_thread_suggestion(thread, target)
  if not thread or not target then
    return
  end

  local suggestion
  for _, comment in ipairs(thread.comments or {}) do
    suggestion = api.suggestion(comment) or suggestion
  end
  if not suggestion then
    vim.notify("Review Mode: no suggestion in this thread", vim.log.levels.WARN)
    return
  end

  local last = math.min(thread.line or 0, vim.api.nvim_buf_line_count(target.buf))
  local first = math.max(1, thread.start_line or last)
  if last < 1 then
    vim.notify("Review Mode: suggestion is not anchored to a line here", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_buf_set_lines(target.buf, first - 1, last, false, suggestion)
  vim.notify(string.format("Applied suggestion to %s:%d-%d (unsaved)", target.path, first, first + #suggestion - 1))
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
  map("r", function()
    reply_to_thread(panel_thread_at_cursor(), ui.panel_target)
  end)
  map("c", function()
    comment_on_target(panel_source(nil, ui.panel_target))
  end)
  map("R", function()
    local thread = panel_thread_at_cursor()
    if thread then
      api.resolve(thread.id, not thread.is_resolved)
    end
  end)
  map("a", function()
    apply_thread_suggestion(panel_thread_at_cursor(), ui.panel_target)
  end)
  map("o", function()
    open_thread_url(panel_thread_at_cursor())
  end)
  map("]c", function()
    panel_move(1)
  end)
  map("[c", function()
    panel_move(-1)
  end)
  map("gr", function()
    api.reload_comments()
  end)
end

local function forget_panel()
  ui.panel_win, ui.panel_buf = nil, nil
  ui.panel_threads, ui.panel_rows, ui.panel_target = nil, nil, nil
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

--- Replace the lines a suggestion is anchored to with the suggested lines.
function M.apply_suggestion()
  local thread, target = focused_thread()
  if not thread then
    vim.notify("No PR comment thread on current line", vim.log.levels.WARN)
    return
  end
  apply_thread_suggestion(thread, target)
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
