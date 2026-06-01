local repo_root = assert(os.getenv("PR_REVIEW_PLUGIN_ROOT"), "PR_REVIEW_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function comment_marks()
  local ns = vim.api.nvim_get_namespaces().pr_review_normal
  if not ns then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
end

local function has_icon(icons, icon)
  for _, item in ipairs(icons or {}) do
    if item.str == icon then
      return true
    end
  end
  return false
end

local pr = require("pr_review")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true, sign_text = "◆" },
  processing = { enabled = true, sync = true },
  auto_open_first_change = false,
})

pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not load")
wait_for(function()
  return pr.is_processed_file("file.txt")
end, "GitHub processing state did not load")
wait_for(function()
  return pr.comment_count("file.txt") == 2
end, "PR comments did not load")

vim.cmd.edit("file.txt")
wait_for(function()
  local marks = comment_marks()
  return #marks == 2 and vim.trim(marks[1][4].sign_text or "") == "◆"
end, "comment sign was not placed")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_comment()
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "next comment did not jump to first comment")
pr.next_comment()
assert(vim.api.nvim_win_get_cursor(0)[1] == 4, "next comment did not jump to second comment")
pr.prev_comment()
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "previous comment did not jump back")

pr.toggle_processed()
assert(not pr.is_processed_file("file.txt"), "processing toggle did not mark file pending")

pr.list_processed("pending")
local pending_qf = vim.fn.getqflist({ items = 1, title = 1 })
assert(#pending_qf.items == 1, "pending processing list did not include file")
assert(pending_qf.items[1].text:find("%[pending%] file.txt"), "pending processing list label was wrong")
pr.list_processed("processed")
local processed_qf = vim.fn.getqflist({ items = 1, title = 1 })
assert(#processed_qf.items == 0, "processed processing list should be empty")
vim.cmd.cclose()

pr.config().processing.sync = false
pr.stop()
pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not reload")
assert(not pr.is_processed_file("file.txt"), "local pending processing state did not persist")

pr.config().processing.sync = true
pr.sync_processed()
wait_for(function()
  return pr.is_processed_file("file.txt")
end, "GitHub processing sync did not restore processed state")

package.preload["nvim-tree.renderer.decorator"] = function()
  return {
    extend = function()
      return {}
    end,
  }
end

local Decorator = require("pr_review.integrations.nvim_tree")
local decorator = setmetatable({}, { __index = Decorator })
decorator:new()
local tree_node = { absolute_path = vim.fs.joinpath(pr.root(), "file.txt") }
local icons = decorator:icons(tree_node)
assert(has_icon(icons, "◆"), "nvim-tree comment marker missing")
assert(has_icon(icons, "✓"), "nvim-tree processed marker missing")
assert(not has_icon(icons, "●"), "nvim-tree pending marker shown for processed file")

pr.config().nvim_tree.show_processing = false
icons = decorator:icons(tree_node)
assert(has_icon(icons, "◆"), "nvim-tree comment marker missing when processing disabled")
assert(has_icon(icons, "●"), "nvim-tree pending marker missing when processing disabled")
assert(not has_icon(icons, "✓"), "nvim-tree processed marker shown when processing disabled")
pr.config().nvim_tree.show_processing = true

pr.config().nvim_tree.show_comments = false
icons = decorator:icons(tree_node)
assert(not has_icon(icons, "◆"), "nvim-tree comment marker shown when comments disabled")
assert(has_icon(icons, "✓"), "nvim-tree processed marker missing when comments disabled")
pr.config().nvim_tree.show_comments = true

pr.toggle_comments()
wait_for(function()
  return pr.comment_count("file.txt") == 0 and #comment_marks() == 0
end, "comment toggle did not clear comment markers")
pr.toggle_comments()
wait_for(function()
  return pr.comment_count("file.txt") == 2 and #comment_marks() == 2
end, "comment toggle did not restore comment markers")

pr.toggle_processing()
assert(not pr.config().processing.enabled, "processing toggle did not disable processing")
assert(not pr.is_processed_file("file.txt"), "processing marker stayed active while processing disabled")
pr.toggle_processing()
assert(pr.config().processing.enabled, "processing toggle did not enable processing")
wait_for(function()
  return pr.is_processed_file("file.txt")
end, "processing toggle did not restore processing state")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
wait_for(function()
  return vim.api.nvim_win_get_cursor(0)[1] == 2
end, "lazy hunk navigation failed")

local before = vim.o.diffopt
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2
end, "old split did not open")
assert(vim.o.diffopt:find("linematch:0", 1, true), "fast diffopt not applied")

local found = false
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(buf)
  if name:find("pr%-base://", 1) then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(lines[1] == "one" and lines[2] == "" and lines[3] == "base", "base content not preserved")
    found = true
  end
end
assert(found, "base buffer not found")

pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1
end, "old split did not close")
assert(vim.o.diffopt == before, "diffopt was not restored")

pr.stop()
