-- fixture: gh pr REVIEW_MODE_THREADS_FILE={tmp}/threads.json
-- The panel's folds and its two motions: a suggestion renders as a closed fold
-- with a one-line summary, za opens it and the open state survives the
-- re-render the cursor triggers, ]r steps message by message across threads
-- while ]] steps thread by thread, and collapse_suggestions = false renders
-- the block out in full as it always did.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local threads_file = assert(os.getenv("REVIEW_MODE_THREADS_FILE"), "REVIEW_MODE_THREADS_FILE is required")

local wait_for = harness.wait_for

-- The payload -----------------------------------------------------------------

local function comment(id, author, body)
  return {
    id = "comment_" .. id,
    databaseId = id,
    body = body,
    author = { login = author },
    createdAt = "2024-01-02T03:04:05Z",
    url = "https://github.com/owner/repo/pull/123#discussion_r" .. id,
    state = "SUBMITTED",
    authorAssociation = "NONE",
    viewerDidAuthor = false,
    reactionGroups = {},
  }
end

local function thread(id, line, comments)
  return {
    id = id,
    path = "file.txt",
    line = line,
    originalLine = line,
    diffSide = "RIGHT",
    isResolved = false,
    isOutdated = false,
    comments = { pageInfo = { hasNextPage = false }, nodes = comments },
  }
end

-- Two conversations, two messages each, so ]r has four stops and ]] two. The
-- first message of each carries a suggestion, the fold's reason to exist.
vim.fn.writefile({
  vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          reviewThreads = {
            pageInfo = { hasNextPage = false },
            nodes = {
              thread("thread_f1", 2, {
                comment(301, "alice", "Two needs more\n\n```suggestion\ntwo improved\ntwo extra\n```"),
                comment(302, "adrian", "Will do"),
              }),
              thread("thread_f2", 4, {
                comment(303, "bob", "And this one\n\n```suggestion\nbase improved\n```"),
                comment(304, "adrian", "Pushed"),
              }),
            },
          },
        },
      },
    },
  }),
}, threads_file)

-- The session -----------------------------------------------------------------

local pr = require("review_mode")
local api = require("review_mode.api")
local panel = require("review_mode.panel")

local function setup(opts)
  pr.setup(vim.tbl_extend("force", {
    gitsigns = { enabled = false },
    nvim_tree = { enabled = false },
    viewed = { enabled = false },
    auto_open_first_change = false,
  }, opts or {}))
end

setup()
pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 4
end, "comments did not load")

vim.cmd.edit("file.txt")
local code_win = vim.api.nvim_get_current_win()
-- line 6 carries no thread, so the panel lists every thread in the file
vim.api.nvim_win_set_cursor(code_win, { 6, 0 })
panel.open_panel()
wait_for(function()
  return panel.panel_is_open()
end, "panel did not open")

local panel_win = panel.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)
vim.api.nvim_set_current_win(panel_win)

local function lines()
  return vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
end

local function row_of(pattern)
  for index, line in ipairs(lines()) do
    if line:match(pattern) then
      return index
    end
  end
  error("no panel line matches " .. pattern .. "\n" .. table.concat(lines(), "\n"))
end

local function press(key)
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(mapping and mapping.callback, "the panel has no " .. key .. " mapping")
  mapping.callback()
end

-- 'foldtext' is what a closed fold shows; call it with v:foldstart set the way
-- Vim would, by folding to the block and reading the fold Vim reports.
local function fold_state(row)
  return vim.api.nvim_win_call(panel_win, function()
    return vim.fn.foldclosed(row), vim.fn.foldclosedend(row)
  end)
end

local function fold_text_at(row)
  return vim.api.nvim_win_call(panel_win, function()
    vim.api.nvim_win_set_cursor(panel_win, { row, 0 })
    return vim.fn.foldtextresult(row)
  end)
end

-- Folded by default -----------------------------------------------------------

local suggestion_row = row_of("┌ suggestion")
assert(fold_state(suggestion_row) == suggestion_row, "the suggestion block did not render as a closed fold")
local summary = fold_text_at(suggestion_row)
assert(summary:match("▸ suggestion"), "the closed fold shows no summary: " .. summary)
assert(summary:match("%+2 −0"), "the summary should count the suggested lines: " .. summary)
assert(summary:match("file%.txt:2"), "the summary should name where the suggestion lands: " .. summary)
-- the suggested lines are in the buffer; the fold is what hides them
assert(row_of("two improved") == suggestion_row + 1, "the folded block should still hold its lines")

-- za opens it, and the open state survives a re-render ------------------------

vim.api.nvim_win_set_cursor(panel_win, { suggestion_row, 0 })
press("za")
assert(fold_state(suggestion_row) == -1, "za did not open the fold")

-- The panel follows the cursor: moving in the code window redraws it. The
-- opened block must still be open afterwards.
vim.api.nvim_set_current_win(code_win)
vim.api.nvim_win_set_cursor(code_win, { 7, 0 })
panel.schedule_refresh()
wait_for(function()
  return vim.api.nvim_win_call(panel_win, function()
    return vim.fn.foldclosed(row_of("┌ suggestion")) == -1
  end)
end, "the re-render snapped the opened suggestion shut")
vim.api.nvim_set_current_win(panel_win)

-- the second thread's suggestion was never opened, so it is still folded
local second = nil
for index, line in ipairs(lines()) do
  if line:match("┌ suggestion") and index ~= suggestion_row then
    second = index
  end
end
assert(second, "the second thread's suggestion is missing from the panel")
assert(fold_state(second) == second, "opening one block must not open the others")

-- zM closes everything again, zR opens it, and both are remembered
press("zM")
assert(fold_state(row_of("┌ suggestion")) ~= -1, "zM did not close the folds")
press("zR")
assert(fold_state(row_of("┌ suggestion")) == -1, "zR did not open the folds")
assert(fold_state(second) == -1, "zR should open every block")
panel.schedule_refresh()
wait_for(function()
  return vim.api.nvim_win_call(panel_win, function()
    return vim.fn.foldclosed(second) == -1
  end)
end, "zR did not survive the re-render")

-- Motions ---------------------------------------------------------------------

local function cursor_row()
  return vim.api.nvim_win_get_cursor(panel_win)[1]
end

local headers = {
  row_of("^ alice"),
  row_of("^ ↳ adrian"),
  row_of("^ bob"),
}
-- the second thread's reply: the last "↳ adrian" in the buffer
local last_reply
for index, line in ipairs(lines()) do
  if line:match("^ ↳ adrian") then
    last_reply = index
  end
end
headers[#headers + 1] = last_reply
assert(
  headers[1] < headers[2] and headers[2] < headers[3] and headers[3] < headers[4],
  "expected four message headers in order, got " .. vim.inspect(headers)
)

vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })
for index = 1, 4 do
  press("]r")
  assert(
    cursor_row() == headers[index],
    string.format("]r stop %d landed on line %d, wanted %d", index, cursor_row(), headers[index])
  )
end
press("]r")
assert(cursor_row() == headers[4], "]r past the last message should stay on it")
for index = 3, 1, -1 do
  press("[r")
  assert(
    cursor_row() == headers[index],
    string.format("[r stop %d landed on line %d, wanted %d", index, cursor_row(), headers[index])
  )
end

-- ]] is the coarser motion: thread headers, which is where ]r used to land
local thread_rows = {}
for index, line in ipairs(lines()) do
  if line:match("^── file%.txt:") then
    thread_rows[#thread_rows + 1] = index
  end
end
assert(#thread_rows == 2, "expected two thread headers, got " .. #thread_rows)
-- from inside the first thread, ]] skips the rest of its messages
vim.api.nvim_win_set_cursor(panel_win, { headers[2], 0 })
press("]]")
assert(cursor_row() == thread_rows[2], "]] did not step to the second thread, it landed on " .. cursor_row())
press("[[")
assert(cursor_row() == thread_rows[1], "[[ did not step back a thread, it landed on " .. cursor_row())

-- collapse_suggestions = false -------------------------------------------------

panel.close_panel()
pr.stop()
setup({ panel = { collapse_suggestions = false } })
assert(api.config().panel.collapse_suggestions == false, "the config did not take")
pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 4
end, "comments did not reload")

vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 6, 0 })
panel.open_panel()
wait_for(function()
  return panel.panel_is_open()
end, "panel did not reopen")
panel_win = panel.panel_win()
panel_buf = vim.api.nvim_win_get_buf(panel_win)

local plain_row = row_of("┌ suggestion")
assert(fold_state(plain_row) == -1, "collapse_suggestions = false should leave no folds")
assert(row_of("two improved") == plain_row + 1, "the block should render in full")

-- A non-table panel value is not a crash ---------------------------------------

panel.close_panel()
pr.stop()
setup({ panel = false })
assert(type(api.config().panel) == "table", "panel = false should fall back to the defaults")
assert(api.config().panel.collapse_suggestions == true, "the fallback should carry the defaults")
pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 4
end, "comments did not reload")
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 6, 0 })
panel.open_panel()
wait_for(function()
  return panel.panel_is_open()
end, "the panel did not open with panel = false")
panel_win = panel.panel_win()
panel_buf = vim.api.nvim_win_get_buf(panel_win)
assert(fold_state(row_of("┌ suggestion")) ~= -1, "the fallback defaults should still collapse")

harness.done()
vim.cmd("qa!")
