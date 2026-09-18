-- Resolving a thread used to be silent: the comment simply stopped being drawn.
-- These checks pin the confirmation flash -- both directions, both entry points,
-- and the switch that turns it off.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

vim.notify = function() end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true, resolve_flash_ms = 150 },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

assert(api.config().comments.resolve_flash_ms == 150, "comments.resolve_flash_ms did not survive setup")
-- on by default: a confirmation nobody opted into is the whole point
assert(
  require("review_mode.state").defaults.comments.resolve_flash_ms == 1200,
  "comments.resolve_flash_ms is missing from the defaults"
)

-- The plugin subscribes at require time, so this listener runs after the flash
-- has been drawn (or deliberately not drawn): no sleeping on a timer.
local resolved_events = 0
api.on("thread_resolved", function()
  resolved_events = resolved_events + 1
end)

local flash_ns =
  assert(vim.api.nvim_get_namespaces()["review_mode_resolve_flash"], "the resolve-feedback namespace does not exist")

pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 3 and not api.unstable_state().comments_loading
end, "resolve feedback fixture comments did not load")

vim.cmd.edit("file.txt")
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 0 })

local function flash_marks()
  return vim.api.nvim_buf_get_extmarks(bufnr, flash_ns, 0, -1, { details = true })
end

--- The single flash mark, asserted to sit on `line` and read `label`.
local function assert_flash(line, label, hl, context)
  local marks = flash_marks()
  assert(#marks == 1, context .. ": expected one flash mark, got " .. #marks)
  local mark = marks[1]
  assert(mark[2] == line - 1, context .. ": flash landed on row " .. mark[2] .. ", wanted " .. (line - 1))
  local details = mark[4]
  assert(details.line_hl_group == hl, context .. ": flash highlight was " .. tostring(details.line_hl_group))
  local text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
  assert(text:find(label, 1, true), context .. ": flash text was " .. tostring(text) .. ", wanted " .. label)
  assert(details.priority and details.priority > 160, context .. ": flash must outrank the comment annotations")
end

local function after_resolve(fn)
  local before = resolved_events
  fn()
  wait_for(function()
    return resolved_events > before
  end, "thread_resolved never fired")
end

-- resolve: the line says so before the thread stops being drawn
assert(#flash_marks() == 0, "a flash mark existed before anything was resolved")
after_resolve(function()
  api.resolve("thread_1", true)
end)
assert_flash(2, "resolved", "ReviewModeResolved", "api.resolve(true)")

-- and it is brief: the mark clears itself
wait_for(function()
  return #flash_marks() == 0
end, "the resolve flash never cleared")

-- unresolve: the other direction is marked too, and differently
after_resolve(function()
  api.resolve("thread_1", false)
end)
assert_flash(2, "unresolved", "ReviewModeUnresolved", "api.resolve(false)")
wait_for(function()
  return #flash_marks() == 0
end, "the unresolve flash never cleared")

-- the flash is drawn even when resolved threads are hidden, which is the case
-- that needed it: the sign is about to vanish
api.unstable_state().config.comments.show_resolved = false
after_resolve(function()
  vim.cmd("ReviewModeResolveThread")
end)
assert_flash(2, "resolved", "ReviewModeResolved", ":ReviewModeResolveThread")
wait_for(function()
  return #flash_marks() == 0
end, "the command's flash never cleared")

-- panel R is the other entry point, and it goes through the same event. The
-- mock always answers the same payload, so the reloaded thread reads unresolved
-- and R resolves it again.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.open_panel()
local panel_win = pr.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)
local thread_row
wait_for(function()
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:find("Needs review", 1, true) then
      thread_row = index
      break
    end
  end
  return thread_row ~= nil
end, "the panel never rendered the thread")

after_resolve(function()
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { thread_row, 0 })
  vim.cmd("normal R")
end)
assert_flash(2, "resolved", "ReviewModeResolved", "panel R")
pr.close_panel()
vim.api.nvim_set_current_win(vim.fn.win_findbuf(bufnr)[1])
wait_for(function()
  return #flash_marks() == 0
end, "the panel's flash never cleared")

-- and it can be turned off
api.unstable_state().config.comments.resolve_flash_ms = 0
after_resolve(function()
  api.resolve("thread_1", true)
end)
assert(#flash_marks() == 0, "resolve_flash_ms = 0 still drew a flash")

pr.stop()
