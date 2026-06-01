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

local function has_icon_hl(icons, icon, hl)
  for _, item in ipairs(icons or {}) do
    if item.str == icon and vim.tbl_contains(item.hl or {}, hl) then
      return true
    end
  end
  return false
end

local function has_value(values, value)
  for _, item in ipairs(values or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function has_line(lines, needle)
  for _, line in ipairs(lines or {}) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = tostring(message)
  return original_notify(message, level, opts)
end

local function last_notification()
  return notifications[#notifications] or ""
end

local function viewed_sync_queue_count()
  local path = vim.fs.joinpath(vim.fn.stdpath("state"), "pr-review-state.json")
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return 0
  end

  local decoded = vim.json.decode(table.concat(lines, "\n"))
  local count = 0
  for _, entry in pairs(decoded or {}) do
    for _ in pairs(entry.sync_queue or {}) do
      count = count + 1
    end
  end
  return count
end

local pr = require("pr_review")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false, show_processing = false, show_viewed = true },
  comments = { enabled = true, sign_text = "◆" },
  processing = { enabled = false, sync = false },
  viewed = { enabled = true, sync = true },
  auto_open_first_change = false,
})

assert(pr.config().viewed.enabled, "viewed config did not override processing compatibility config")
assert(pr.config().viewed.sync, "viewed sync config did not override processing compatibility config")
assert(pr.config().processing == pr.config().viewed, "processing compatibility alias did not point to viewed config")
assert(pr.config().nvim_tree.show_viewed, "show_viewed config did not override show_processing compatibility config")
assert(
  pr.config().nvim_tree.show_processing == pr.config().nvim_tree.show_viewed,
  "show_processing compatibility alias did not mirror show_viewed"
)

local commands = vim.api.nvim_get_commands({})
assert(commands.PrReviewViewedToggle, "PrReviewViewedToggle command missing")
assert(commands.PrReviewViewedList, "PrReviewViewedList command missing")
assert(commands.PrReviewViewedFeatureToggle, "PrReviewViewedFeatureToggle command missing")
assert(commands.PrReviewProcessedToggle, "PrReviewProcessedToggle compatibility command missing")
assert(commands.PrReviewProcessingToggle, "PrReviewProcessingToggle compatibility command missing")
assert(not commands.PrReviewProcessedNext, "unexpected new PrReviewProcessedNext compatibility command")
assert(has_value(vim.fn.getcompletion("PrReviewViewedList ", "cmdline"), "viewed"), "viewed list completion missing")
assert(
  has_value(vim.fn.getcompletion("PrReviewViewedList ", "cmdline"), "unviewed"),
  "unviewed list completion missing"
)
assert(
  has_value(vim.fn.getcompletion("PrReviewProcessedList ", "cmdline"), "processed"),
  "processed alias completion missing"
)
assert(
  has_value(vim.fn.getcompletion("PrReviewProcessedList ", "cmdline"), "pending"),
  "pending alias completion missing"
)

pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not load")
wait_for(function()
  return pr.is_changed_file("nested/other.txt")
end, "second changed file did not load")
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "GitHub viewed state did not load")
wait_for(function()
  return pr.comment_count("file.txt") == 2
end, "PR comments did not load")

pr.summary()
assert(last_notification():find("Files: 1 viewed, 1 unviewed, 2 total", 1, true), "summary file counts were wrong")
assert(last_notification():find("Comments: 3", 1, true), "summary comment count was wrong")
assert(last_notification():find("Threads: 3 total, 2 unresolved", 1, true), "summary thread counts were wrong")

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

pr.toggle_viewed()
assert(not pr.is_viewed_file("file.txt"), "viewed toggle did not mark file unviewed")

pr.list_viewed("unviewed")
local unviewed_menu = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(has_line(unviewed_menu, "PR review files [unviewed]"), "unviewed picker title was wrong")
assert(has_line(unviewed_menu, "☐ 1 ◆ 1 file.txt"), "unviewed picker file label was wrong")
assert(has_line(unviewed_menu, "☐ 1 ◆ 1 nested/other.txt"), "unviewed picker nested file label was wrong")
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.api.nvim_feedkeys("t", "x", false)
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "viewed picker toggle did not mark selected file viewed")
pr.toggle_viewed("file.txt")
assert(not pr.is_viewed_file("file.txt"), "viewed picker toggle restore failed")
pr.list_viewed("viewed")
local viewed_menu = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(has_line(viewed_menu, "PR review files [viewed]"), "viewed picker title was wrong")
assert(has_line(viewed_menu, "No matching PR files"), "viewed picker should be empty")
vim.api.nvim_win_close(0, true)

pr.config().viewed.sync = false
pr.stop()
pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not reload")
assert(not pr.is_viewed_file("file.txt"), "local unviewed state did not persist")

pr.config().viewed.sync = true
pr.sync_viewed()
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "GitHub viewed sync did not restore viewed state")

vim.env.PR_REVIEW_FAIL_MUTATION = "1"
pr.toggle_viewed()
wait_for(function()
  return viewed_sync_queue_count() == 1
end, "failed viewed sync mutation was not queued")
vim.env.PR_REVIEW_FAIL_MUTATION = nil
pr.flush_viewed_sync()
wait_for(function()
  return viewed_sync_queue_count() == 0
end, "queued viewed sync mutation was not flushed")

vim.cmd.edit("file.txt")
pr.mark_viewed_next()
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find("nested/other%.txt$", 1) ~= nil
end, "mark viewed next did not jump to next unviewed file")

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
assert(pr.unresolved_comment_count("file.txt") == 1, "unresolved file comment count was wrong")
assert(has_icon(icons, "◆ 1"), "nvim-tree comment marker missing")
assert(has_icon(icons, "✓"), "nvim-tree viewed marker missing")
assert(has_icon_hl(icons, "✓", "PrReviewTreeViewed"), "nvim-tree viewed marker highlight was wrong")
assert(not has_icon(icons, "☐"), "nvim-tree changed marker shown for viewed file")
assert(decorator:highlight_group(tree_node) == "PrReviewTreeViewed", "nvim-tree viewed file highlight was wrong")

local unviewed_tree_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested/other.txt") }
icons = decorator:icons(unviewed_tree_node)
assert(pr.unresolved_comment_count("nested/other.txt") == 1, "unresolved nested file comment count was wrong")
assert(has_icon(icons, "◆ 1"), "nvim-tree nested comment marker missing")
assert(pr.unviewed_count("nested/other.txt") == 1, "unviewed file count was wrong")
assert(has_icon(icons, "☐ 1"), "nvim-tree changed marker missing for unviewed file")
assert(has_icon_hl(icons, "☐ 1", "PrReviewTreeChanged"), "nvim-tree changed marker highlight was wrong")
assert(not has_icon(icons, "✓"), "nvim-tree viewed marker shown for unviewed file")
assert(
  decorator:highlight_group(unviewed_tree_node) == "PrReviewTreeChanged",
  "nvim-tree changed file highlight was wrong"
)

local dir_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested") }
local dir_icons = decorator:icons(dir_node)
assert(pr.unresolved_comment_count("nested") == 1, "unresolved folder comment count was wrong")
assert(has_icon(dir_icons, "◆ 1"), "nvim-tree folder comment marker missing")
assert(pr.unviewed_count("nested") == 1, "unviewed folder count was wrong")
assert(has_icon(dir_icons, "☐ 1"), "nvim-tree changed folder marker missing")
assert(has_icon_hl(dir_icons, "☐ 1", "PrReviewTreeChanged"), "nvim-tree changed folder marker highlight was wrong")
assert(not pr.is_viewed_dir("nested"), "viewed dir state was true before all children were viewed")
assert(decorator:highlight_group(dir_node) == "PrReviewTreeChanged", "nvim-tree changed folder highlight was wrong")

pr.mark_viewed("nested/other.txt", { silent = true })
wait_for(function()
  return pr.is_viewed_dir("nested")
end, "viewed dir state did not cascade after all children were viewed")
assert(pr.unviewed_count("nested") == 0, "unviewed folder count did not clear after children were viewed")
dir_icons = decorator:icons(dir_node)
assert(has_icon(dir_icons, "◆ 1"), "nvim-tree viewed folder comment marker missing")
assert(has_icon(dir_icons, "✓"), "nvim-tree viewed folder marker missing")
assert(has_icon_hl(dir_icons, "✓", "PrReviewTreeViewed"), "nvim-tree viewed folder marker highlight was wrong")
assert(decorator:highlight_group(dir_node) == "PrReviewTreeViewed", "nvim-tree viewed folder highlight was wrong")

pr.config().nvim_tree.show_viewed = false
icons = decorator:icons(tree_node)
assert(has_icon(icons, "◆ 1"), "nvim-tree comment marker missing when viewed marker disabled")
assert(has_icon(icons, "☐"), "nvim-tree changed marker missing when viewed marker disabled")
assert(not has_icon(icons, "✓"), "nvim-tree viewed marker shown when disabled")
dir_icons = decorator:icons(dir_node)
assert(has_icon(dir_icons, "◆ 1"), "nvim-tree folder comment marker missing when viewed marker disabled")
assert(has_icon(dir_icons, "☐"), "nvim-tree changed folder marker missing when viewed marker disabled")
assert(not has_icon(dir_icons, "✓"), "nvim-tree viewed folder marker shown when disabled")
pr.config().nvim_tree.show_viewed = true

pr.config().nvim_tree.show_comments = false
icons = decorator:icons(tree_node)
assert(not has_icon(icons, "◆ 1"), "nvim-tree comment marker shown when comments disabled")
assert(has_icon(icons, "✓"), "nvim-tree viewed marker missing when comments disabled")
pr.config().nvim_tree.show_comments = true

vim.cmd.edit("file.txt")
pr.toggle_comments()
wait_for(function()
  return pr.comment_count("file.txt") == 0 and #comment_marks() == 0
end, "comment toggle did not clear comment markers")
pr.toggle_comments()
wait_for(function()
  return pr.comment_count("file.txt") == 2 and #comment_marks() == 2
end, "comment toggle did not restore comment markers")

pr.toggle_viewed_feature()
assert(not pr.config().viewed.enabled, "viewed feature toggle did not disable viewed tracking")
assert(not pr.is_viewed_file("file.txt"), "viewed marker stayed active while viewed tracking disabled")
pr.toggle_viewed_feature()
assert(pr.config().viewed.enabled, "viewed feature toggle did not enable viewed tracking")
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "viewed feature toggle did not restore viewed state")

pr.config().processing.enabled = false
assert(not pr.config().viewed.enabled, "processing compatibility alias did not update viewed config")
pr.config().processing.enabled = true

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
