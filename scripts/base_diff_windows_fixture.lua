-- The base diff hands the user's window back as it found it: window options
-- restored on close, :close of the file window in side by side, the unified
-- view after ]f, and ]c / ]f pressed inside the base pane or unified buffer.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

vim.notify = function() end

local pr = require("review_mode")
local api = require("review_mode.api")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
  comments = { enabled = false },
})
pr.start()
wait_for(function()
  return api.is_active() and state.maps_loaded and api.is_changed_file("file.txt")
end, "the review did not load")

local paths = vim.tbl_map(function(file)
  return file.path
end, api.files())
local index = assert(api.file("file.txt") and vim.fn.index(paths, "file.txt") + 1)
local next_path = paths[index % #paths + 1]
-- a ]f that lost track of the file would land on the first one instead
assert(next_path ~= paths[1], "fixture needs file.txt not to be the last file: " .. vim.inspect(paths))

local function relpath()
  local name = vim.api.nvim_buf_get_name(0)
  return vim.fs.relpath(vim.uv.cwd(), vim.uv.fs_realpath(name) or name) or name
end
local options = { "wrap", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "foldlevel", "foldenable", "diff" }
local function snapshot(win)
  local values = {}
  for _, name in ipairs(options) do
    values[name] = vim.wo[win][name]
  end
  return values
end
local function open_side_by_side()
  pr.old_toggle()
  wait_for(function()
    return state.old_win and vim.api.nvim_win_is_valid(state.old_win) and vim.wo[state.old_win].diff
  end, "the side-by-side base diff did not open")
end

local diffopt = vim.o.diffopt

-- Closing the split restores the window ----------------------------------------------
vim.cmd.edit("file.txt")
local win = vim.api.nvim_get_current_win()
vim.wo[win].wrap = false
vim.wo[win].foldcolumn = "0"
vim.wo[win].foldmethod = "indent"
vim.wo[win].foldlevel = 3
vim.wo[win].foldenable = false
local before = snapshot(win)
open_side_by_side()
pr.old_toggle()
assert(state.old_layout == nil, "the base diff did not close")
assert(
  vim.deep_equal(snapshot(win), before),
  "closing the base diff left diff-mode options behind: " .. vim.inspect(snapshot(win)) .. " vs " .. vim.inspect(before)
)
assert(vim.o.diffopt == diffopt, "diffopt was not restored")

-- In the base pane, ]c is Vim's own diff jump and ]f knows the file --------------------
open_side_by_side()
local base_win = state.old_win
vim.api.nvim_set_current_win(base_win)
vim.api.nvim_win_set_cursor(base_win, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_get_current_win() == base_win, "]c in the base pane left it")
assert(vim.api.nvim_win_get_cursor(base_win)[1] > 1, "]c in the base pane did not move to a change")
pr.next_file()
wait_for(function()
  return relpath() == next_path
end, "]f in the base pane should reach " .. next_path .. ", at " .. relpath())
wait_for(function()
  return state.old_layout == nil
end, "]f did not close the side-by-side diff")

-- :close of the file window in side by side --------------------------------------------
vim.cmd("silent! only")
vim.cmd.edit("file.txt")
open_side_by_side()
vim.api.nvim_set_current_win(state.old_target_win)
local ok, err = pcall(vim.cmd.close)
assert(ok, ":close of the file window failed: " .. tostring(err))
wait_for(function()
  return state.old_layout == nil and not state.old_closing
end, "closing the file window left the base diff half torn down")
assert(vim.o.diffopt == diffopt, "diffopt was not restored after :close")
-- and a later base diff opens as one split, not on top of the last one
vim.cmd("silent! only")
vim.cmd.edit("file.txt")
open_side_by_side()
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "base diffs piled up: " .. #vim.api.nvim_tabpage_list_wins(0))
pr.old_toggle()

-- Unified ------------------------------------------------------------------------------
vim.cmd("silent! only")
api.config().diff.layout = "unified"
vim.cmd.edit("file.txt")
win = vim.api.nvim_get_current_win()
vim.wo[win].foldmethod = "indent"
pr.old_toggle()
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find("pr-diff://", 1, true) ~= nil
end, "the unified diff did not open")
local diff_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)
for _, line in ipairs(lines) do
  assert(
    not line:find("No newline at end of file", 1, true),
    "file.txt ends in a newline: " .. table.concat(lines, "\n")
  )
end

-- ]c moves between the changes of the diff buffer itself
vim.api.nvim_win_set_cursor(win, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_get_current_buf() == diff_buf, "]c in the unified diff left it")
local row = vim.api.nvim_win_get_cursor(win)[1]
assert(lines[row]:find("^[-+]") and row > 1, "]c in the unified diff did not stop at a change, at " .. row)

-- ]f from the unified buffer goes to the next file, and the diff is gone with it
pr.next_file()
wait_for(function()
  return relpath() == next_path
end, "]f in the unified diff should reach " .. next_path .. ", at " .. relpath())
vim.wait(50)
assert(vim.wo[win].foldmethod == "indent", "the unified diff's manual folds leaked: " .. vim.wo[win].foldmethod)
-- <leader>rd now opens this file's diff; it does not "close" the old one by
-- putting file.txt back
pr.old_toggle()
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find("pr-diff://", 1, true) ~= nil
end, "<leader>rd after ]f did not open the new file's diff, at " .. vim.api.nvim_buf_get_name(0))
assert(vim.api.nvim_buf_get_name(0):find(next_path, 1, true), "the diff is not of " .. next_path)
pr.old_toggle()
assert(relpath() == next_path, "closing the diff did not put " .. next_path .. " back, at " .. relpath())

pr.stop()
print("base diff windows fixture passed")
harness.done()
