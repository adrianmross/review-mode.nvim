local repo_root = assert(os.getenv("PR_REVIEW_PLUGIN_ROOT"), "PR_REVIEW_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local comment_sign = ""

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

local function diff_marks(bufnr)
  local ns = vim.api.nvim_get_namespaces().pr_review_diff
  if not ns then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
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

local function line_number(lines, needle)
  for index, line in ipairs(lines or {}) do
    if line == needle then
      return index
    end
  end
  return nil
end

local function buffer_lines_matching(pattern)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:find(pattern, 1) then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
    end
  end
  return nil, nil
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
  nvim_tree = { enabled = false, show_viewed = true },
  comments = { enabled = true },
  viewed = { enabled = true, sync = true },
  auto_open_first_change = false,
})

assert(pr.config().viewed.enabled, "viewed config was not enabled")
assert(pr.config().viewed.sync, "viewed sync config was not enabled")
assert(pr.config().processing == nil, "old viewed config alias should not be exposed")
assert(pr.config().comments.sign_text == comment_sign, "comment sign default was wrong")
assert(pr.config().nvim_tree.show_viewed, "show_viewed config was not enabled")
assert(pr.config().nvim_tree.show_processing == nil, "old nvim-tree viewed option alias should not be exposed")

local commands = vim.api.nvim_get_commands({})
assert(commands.PrReviewViewedToggle, "PrReviewViewedToggle command missing")
assert(commands.PrReviewViewedList, "PrReviewViewedList command missing")
assert(commands.PrReviewViewedFeatureToggle, "PrReviewViewedFeatureToggle command missing")
assert(commands.PrReviewDiffLayoutToggle, "PrReviewDiffLayoutToggle command missing")
assert(commands.PrReviewDiffFullToggle, "PrReviewDiffFullToggle command missing")
assert(not commands.PrReviewProcessedToggle, "old viewed toggle command alias should be removed")
assert(not commands.PrReviewProcessedList, "old viewed list command alias should be removed")
assert(not commands.PrReviewProcessedClear, "old viewed clear command alias should be removed")
assert(not commands.PrReviewProcessedSync, "old viewed sync command alias should be removed")
assert(not commands.PrReviewProcessedSyncToggle, "old viewed sync-toggle command alias should be removed")
assert(not commands.PrReviewProcessingToggle, "old viewed feature-toggle command alias should be removed")
assert(has_value(vim.fn.getcompletion("PrReviewViewedList ", "cmdline"), "viewed"), "viewed list completion missing")
assert(
  has_value(vim.fn.getcompletion("PrReviewViewedList ", "cmdline"), "unviewed"),
  "unviewed list completion missing"
)

pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not load")
wait_for(function()
  return pr.is_changed_file("nested/other.txt")
end, "second changed file did not load")
wait_for(function()
  return pr.is_changed_file("new.txt")
end, "added file did not load")
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "GitHub viewed state did not load")
wait_for(function()
  return pr.comment_count("file.txt") == 2
end, "PR comments did not load")

pr.summary()
assert(last_notification():find("Files: 1 viewed, 2 unviewed, 3 total", 1, true), "summary file counts were wrong")
assert(last_notification():find("Comments: 3", 1, true), "summary comment count was wrong")
assert(last_notification():find("Threads: 3 total, 2 unresolved", 1, true), "summary thread counts were wrong")

vim.cmd.edit("file.txt")
wait_for(function()
  local marks = comment_marks()
  local details = marks[1] and marks[1][4] or {}
  local virt_text = details.virt_text or {}
  return #marks == 2
    and vim.trim(details.sign_text or "") == comment_sign
    and details.number_hl_group == nil
    and virt_text[1]
    and virt_text[1][1] == "\t"
    and virt_text[2]
    and virt_text[2][1] == "■"
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
assert(has_line(unviewed_menu, "☐ 1 " .. comment_sign .. " 1 file.txt"), "unviewed picker file label was wrong")
assert(
  has_line(unviewed_menu, "☐ 1 " .. comment_sign .. " 1 nested/other.txt"),
  "unviewed picker nested file label was wrong"
)
assert(has_line(unviewed_menu, "☐ 1      new.txt"), "unviewed picker added file label was wrong")
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
assert(has_icon(icons, comment_sign .. " 1"), "nvim-tree comment marker missing")
assert(has_icon(icons, "✓"), "nvim-tree viewed marker missing")
assert(has_icon_hl(icons, "✓", "PrReviewTreeViewed"), "nvim-tree viewed marker highlight was wrong")
assert(not has_icon(icons, "☐"), "nvim-tree changed marker shown for viewed file")
assert(decorator:highlight_group(tree_node) == "PrReviewTreeViewed", "nvim-tree viewed file highlight was wrong")

local unviewed_tree_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested/other.txt") }
icons = decorator:icons(unviewed_tree_node)
assert(pr.unresolved_comment_count("nested/other.txt") == 1, "unresolved nested file comment count was wrong")
assert(has_icon(icons, comment_sign .. " 1"), "nvim-tree nested comment marker missing")
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
assert(has_icon(dir_icons, comment_sign .. " 1"), "nvim-tree folder comment marker missing")
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
assert(has_icon(dir_icons, comment_sign .. " 1"), "nvim-tree viewed folder comment marker missing")
assert(has_icon(dir_icons, "✓"), "nvim-tree viewed folder marker missing")
assert(has_icon_hl(dir_icons, "✓", "PrReviewTreeViewed"), "nvim-tree viewed folder marker highlight was wrong")
assert(decorator:highlight_group(dir_node) == "PrReviewTreeViewed", "nvim-tree viewed folder highlight was wrong")

pr.config().nvim_tree.show_viewed = false
icons = decorator:icons(tree_node)
assert(has_icon(icons, comment_sign .. " 1"), "nvim-tree comment marker missing when viewed marker disabled")
assert(has_icon(icons, "☐"), "nvim-tree changed marker missing when viewed marker disabled")
assert(not has_icon(icons, "✓"), "nvim-tree viewed marker shown when disabled")
dir_icons = decorator:icons(dir_node)
assert(has_icon(dir_icons, comment_sign .. " 1"), "nvim-tree folder comment marker missing when viewed marker disabled")
assert(has_icon(dir_icons, "☐"), "nvim-tree changed folder marker missing when viewed marker disabled")
assert(not has_icon(dir_icons, "✓"), "nvim-tree viewed folder marker shown when disabled")
pr.config().nvim_tree.show_viewed = true

pr.config().nvim_tree.show_comments = false
icons = decorator:icons(tree_node)
assert(not has_icon(icons, comment_sign .. " 1"), "nvim-tree comment marker shown when comments disabled")
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
local base_lines, base_buf = buffer_lines_matching("pr%-base://")
if base_lines then
  assert(base_lines[1] == "one" and base_lines[2] == "" and base_lines[3] == "base", "base content not preserved")
  found = true
end
assert(found, "base buffer not found")
local side_by_side_span_found = false
for _, mark in ipairs(diff_marks(vim.api.nvim_get_current_buf())) do
  local _, row, col, details = unpack(mark)
  if row == 3 and col == 4 and details.end_col == #"base changed" and details.priority >= 1000 then
    side_by_side_span_found = true
  end
end
assert(side_by_side_span_found, "side-by-side partial changed span missing")

vim.cmd.edit("nested/other.txt")
wait_for(function()
  return #vim.api.nvim_list_wins() == 1 and buffer_lines_matching("pr%-base://") == nil
end, "manual target buffer switch did not close side-by-side pair")

vim.cmd.edit("file.txt")
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2 and buffer_lines_matching("pr%-base://") ~= nil
end, "side-by-side diff did not reopen after manual target switch")
pr.next_file()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1
    and buffer_lines_matching("pr%-base://") == nil
    and vim.api.nvim_buf_get_name(0):find("nested/other%.txt$", 1) ~= nil
end, "next file navigation did not close side-by-side pair")

vim.cmd.edit("file.txt")
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2 and buffer_lines_matching("pr%-base://") ~= nil
end, "side-by-side diff did not reopen after next-file navigation")

pr.toggle_diff_full_file()
wait_for(function()
  local windows = vim.api.nvim_list_wins()
  return #windows == 2 and not vim.wo[windows[1]].foldenable and not vim.wo[windows[2]].foldenable
end, "full side-by-side diff did not open folds in both windows")
pr.toggle_diff_full_file()
wait_for(function()
  local windows = vim.api.nvim_list_wins()
  return #windows == 2 and vim.wo[windows[1]].foldenable and vim.wo[windows[2]].foldenable
end, "condensed side-by-side diff did not fold both windows")

pr.toggle_diff_layout()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1 and buffer_lines_matching("pr%-diff://") ~= nil
end, "unified diff did not open")
assert(buffer_lines_matching("pr%-base://") == nil, "base split buffer stayed open after switching to unified diff")
local condensed_lines, diff_buf = buffer_lines_matching("pr%-diff://")
assert(diff_buf and vim.bo[diff_buf].filetype == "diff", "unified diff buffer filetype was wrong")
assert(has_line(condensed_lines, "diff --git base/file.txt head/file.txt"), "unified diff header was wrong")
assert(has_line(condensed_lines, "-base"), "unified diff old line missing")
assert(has_line(condensed_lines, "+base changed"), "unified diff new line missing")
assert(not has_line(condensed_lines, "same5"), "condensed unified diff included distant common line")
local changed_row = line_number(condensed_lines, "+base changed")
assert(changed_row, "unified diff changed line row missing")
local changed_span_found = false
for _, mark in ipairs(diff_marks(diff_buf)) do
  local _, row, col, details = unpack(mark)
  if row == changed_row - 1 and col == 5 and details.end_col == #"+base changed" then
    changed_span_found = true
  end
end
assert(changed_span_found, "unified diff partial changed span missing")

pr.toggle_diff_full_file()
wait_for(function()
  local full_lines = buffer_lines_matching("pr%-diff://")
  return full_lines and #full_lines > #condensed_lines and has_line(full_lines, "same5")
end, "full unified diff did not include distant common line")
assert(pr.config().diff.full_file, "diff full-file toggle did not update config")

pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1 and vim.api.nvim_buf_get_name(0):find("file%.txt$", 1) ~= nil
end, "old split did not close")
assert(vim.o.diffopt == before, "diffopt was not restored")

vim.cmd.edit("new.txt")
pr.old_toggle()
wait_for(function()
  return buffer_lines_matching("pr%-diff://") ~= nil
end, "unified diff did not open for added file")
local added_lines = buffer_lines_matching("pr%-diff://")
assert(has_line(added_lines, "diff --git base/new.txt head/new.txt"), "added unified diff header was wrong")
assert(has_line(added_lines, "new file mode"), "added unified diff did not show new-file mode")
assert(has_line(added_lines, "--- /dev/null"), "added unified diff did not show missing base file")
assert(has_line(added_lines, "+++ head/new.txt"), "added unified diff head header was wrong")
assert(has_line(added_lines, "+new one"), "added unified diff first line missing")
assert(has_line(added_lines, "+new two"), "added unified diff second line missing")
pr.old_toggle()
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find("new%.txt$", 1) ~= nil
end, "added unified diff did not close")

pr.toggle_diff_layout()
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2
end, "added file side-by-side diff did not open")
local added_base_lines = buffer_lines_matching("pr%-base://")
assert(
  added_base_lines and #added_base_lines == 1 and added_base_lines[1] == "",
  "added file base buffer was not empty"
)
local _, added_base_buf = buffer_lines_matching("pr%-base://")
assert(added_base_buf, "added file base buffer handle missing")
vim.api.nvim_buf_delete(added_base_buf, { force = true })
wait_for(function()
  return #vim.api.nvim_list_wins() == 1 and buffer_lines_matching("pr%-base://") == nil
end, "closing added file base buffer did not close side-by-side pair")

pr.stop()
