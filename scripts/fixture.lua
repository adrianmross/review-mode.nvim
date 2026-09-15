local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local comment_sign = ""

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function comment_marks()
  local ns = vim.api.nvim_get_namespaces().review_mode_normal
  if not ns then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
end

local function diff_marks(bufnr)
  local ns = vim.api.nvim_get_namespaces().review_mode_diff
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

local function has_line_parts(lines, parts)
  for _, line in ipairs(lines or {}) do
    local matched = true
    for _, part in ipairs(parts or {}) do
      if not line:find(part, 1, true) then
        matched = false
        break
      end
    end
    if matched then
      return true
    end
  end
  return false
end

local function win_by_filetype(filetype)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].filetype == filetype then
      return winid
    end
  end
  return nil
end

local function lines_by_filetype(filetype)
  local winid = assert(win_by_filetype(filetype), filetype .. " window missing")
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), winid
end

local function close_win_by_filetype(filetype)
  local winid = win_by_filetype(filetype)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
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

-- The real vim.ui.select reads EOF under "nvim -l" and ends the script with
-- status 0, so an unstubbed call silently skips the rest of this suite instead
-- of failing it. Every intentional picker call installs its own stub.
vim.ui.select = function()
  error("unexpected vim.ui.select call")
end

local function notification_count(needle)
  local count = 0
  for _, message in ipairs(notifications) do
    if message:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function viewed_sync_queue_count()
  local path = vim.fs.joinpath(vim.fn.stdpath("state"), "review-mode-state.json")
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

local pr = require("review_mode")
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
assert(pr.config().picker.provider == "auto", "picker provider default was wrong")

local commands = vim.api.nvim_get_commands({})
assert(commands.ReviewMode, "ReviewMode command missing")
assert(not commands.ReviewModeStart, "old start command alias should be removed")
assert(commands.ReviewModeActions, "ReviewModeActions command missing")
assert(commands.ReviewModeBrowser, "ReviewModeBrowser command missing")
assert(commands.ReviewModeCopyUrl, "ReviewModeCopyUrl command missing")
assert(commands.ReviewModeChecks, "ReviewModeChecks command missing")
assert(commands.ReviewModeStatus, "ReviewModeStatus command missing")
assert(commands.ReviewModeResolveThread, "ReviewModeResolveThread command missing")
assert(commands.ReviewModeUnresolveThread, "ReviewModeUnresolveThread command missing")
assert(commands.ReviewModeSuggest, "ReviewModeSuggest command missing")
assert(commands.ReviewModeViewedToggle, "ReviewModeViewedToggle command missing")
assert(commands.ReviewModeViewedList, "ReviewModeViewedList command missing")
assert(commands.ReviewModeViewedFeatureToggle, "ReviewModeViewedFeatureToggle command missing")
assert(commands.ReviewModeDiffLayoutToggle, "ReviewModeDiffLayoutToggle command missing")
assert(commands.ReviewModeDiffFullToggle, "ReviewModeDiffFullToggle command missing")
assert(not commands.ReviewModeProcessedToggle, "old viewed toggle command alias should be removed")
assert(not commands.ReviewModeProcessedList, "old viewed list command alias should be removed")
assert(not commands.ReviewModeProcessedClear, "old viewed clear command alias should be removed")
assert(not commands.ReviewModeProcessedSync, "old viewed sync command alias should be removed")
assert(not commands.ReviewModeProcessedSyncToggle, "old viewed sync-toggle command alias should be removed")
assert(not commands.ReviewModeProcessingToggle, "old viewed feature-toggle command alias should be removed")
assert(has_value(vim.fn.getcompletion("ReviewModeViewedList ", "cmdline"), "viewed"), "viewed list completion missing")
assert(
  has_value(vim.fn.getcompletion("ReviewModeViewedList ", "cmdline"), "unviewed"),
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
  return pr.is_changed_file("nested/deeper/more.txt")
end, "deep changed file did not load")
wait_for(function()
  return pr.is_changed_file("new.txt")
end, "added file did not load")
wait_for(function()
  return pr.is_viewed_file("file.txt")
end, "GitHub viewed state did not load")
wait_for(function()
  return pr.comment_count("file.txt") == 2
end, "PR comments did not load")

local function fake_snacks_preview()
  local preview = { lines = {}, ft = nil }
  preview.reset = function() end
  preview.set_lines = function(_, lines)
    preview.lines = lines
  end
  preview.highlight = function(_, opts)
    preview.ft = opts and opts.ft
  end
  return preview
end

local original_snacks = rawget(_G, "Snacks")
local snacks_actions_opts = nil
local snacks_files_opts = nil
local snacks_files_preview = nil
_G.Snacks = {
  picker = {
    pick = function(opts)
      if opts.source == "review_mode_actions" then
        snacks_actions_opts = opts
        assert(opts.items[1].text:find("PR", 1, true), "snacks action category missing")
        assert(opts.items[1].preview.text:find("Open in browser", 1, true), "snacks action preview missing")
      elseif opts.source == "review_mode_files" then
        snacks_files_opts = opts
        if type(opts.preview) == "function" then
          local preview = fake_snacks_preview()
          opts.preview({ item = opts.items[1], preview = preview })
          snacks_files_preview = preview
        end
      else
        error("unexpected snacks picker source: " .. tostring(opts.source))
      end
    end,
  },
}
pr.config().picker.provider = "snacks"
pr.actions()
assert(snacks_actions_opts, "snacks action picker was not used")
pr.list_viewed("unviewed")
assert(snacks_files_opts, "snacks viewed picker was not used")
assert(snacks_files_opts.title:find("unviewed", 1, true), "snacks file title filter missing")
assert(snacks_files_opts.items[1].preview == nil, "snacks items should not carry eagerly built previews")
assert(type(snacks_files_opts.preview) == "function", "snacks file preview should be built per selection")
assert(snacks_files_preview, "snacks lazy preview was not invoked")
assert(snacks_files_preview.ft == "diff", "snacks file preview filetype was wrong")
assert(has_line(snacks_files_preview.lines, snacks_files_opts.items[1].item.path), "snacks file preview path missing")
assert(
  has_line(snacks_files_preview.lines, "+feature") or has_line(snacks_files_preview.lines, "+new"),
  "snacks file preview diff missing"
)
_G.Snacks = original_snacks

local telescope_state = { maps = {} }
package.preload["telescope.finders"] = function()
  return {
    new_table = function(opts)
      local entries = {}
      for _, item in ipairs(opts.results or {}) do
        entries[#entries + 1] = opts.entry_maker(item)
      end
      return { entries = entries }
    end,
  }
end
package.preload["telescope.config"] = function()
  return { values = {
    generic_sorter = function()
      return function() end
    end,
  } }
end
package.preload["telescope.actions.state"] = function()
  return {
    get_selected_entry = function()
      return telescope_state.selected
    end,
  }
end
package.preload["telescope.actions"] = function()
  return {
    close = function()
      telescope_state.closed = true
    end,
    select_default = {
      replace = function(_, fn)
        telescope_state.select_default = fn
      end,
    },
  }
end
package.preload["telescope.previewers"] = function()
  return {
    new_buffer_previewer = function(opts)
      telescope_state.previewer = opts
      return opts
    end,
  }
end
package.preload["telescope.pickers"] = function()
  return {
    new = function(_, opts)
      telescope_state.opts = opts
      return {
        find = function()
          if opts.prompt_title == "Review Mode actions" then
            telescope_state.selected = opts.finder.entries[#opts.finder.entries]
            opts.attach_mappings(17, function() end)
            telescope_state.select_default(17)
          else
            telescope_state.selected = opts.finder.entries[1]
            if opts.previewer and opts.previewer.define_preview then
              local preview_buf = vim.api.nvim_create_buf(false, true)
              opts.previewer.define_preview({ state = { bufnr = preview_buf } }, telescope_state.selected)
              local preview_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
              assert(
                has_line(preview_lines, "+feature") or has_line(preview_lines, "+new"),
                "telescope file preview diff missing"
              )
              vim.api.nvim_buf_delete(preview_buf, { force = true })
            end
          end
        end,
      }
    end,
  }
end
pr.config().picker.provider = "telescope"
pr.actions()
assert(last_notification():find("Files:", 1, true), "telescope action picker did not run selected action")
pr.list_viewed("unviewed")
assert(telescope_state.opts.prompt_title:find("unviewed", 1, true), "telescope viewed picker title missing")
for _, module in ipairs({
  "telescope.finders",
  "telescope.config",
  "telescope.actions.state",
  "telescope.actions",
  "telescope.previewers",
  "telescope.pickers",
}) do
  package.loaded[module] = nil
  package.preload[module] = nil
end
pr.config().picker.provider = "native"

pr.copy_url()
wait_for(function()
  return last_notification():find("Copied PR URL: https://github.com/owner/repo/pull/123", 1, true) ~= nil
end, "copy URL command did not copy PR URL")
assert(vim.fn.getreg('"') == "https://github.com/owner/repo/pull/123", "copy URL register was wrong")

pr.status()
wait_for(function()
  return win_by_filetype("markdown") ~= nil
end, "status preview did not open")
local status_lines = lines_by_filetype("markdown")
assert(has_line(status_lines, "# Improve review tools"), "status title missing")
assert(has_line(status_lines, "Review: REVIEW_REQUIRED"), "status review decision missing")
close_win_by_filetype("markdown")

pr.checks()
wait_for(function()
  return win_by_filetype("text") ~= nil
end, "checks preview did not open")
local check_lines = lines_by_filetype("text")
assert(has_line(check_lines, "validate"), "checks output missing")
close_win_by_filetype("text")

vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.resolve_thread()
wait_for(function()
  return last_notification():find("Resolved PR review thread", 1, true) ~= nil
end, "resolve thread command did not report success")
pr.unresolve_thread()
wait_for(function()
  return last_notification():find("Unresolved PR review thread", 1, true) ~= nil
end, "unresolve thread command did not report success")

local original_reply_input = vim.ui.input
vim.ui.input = function(_, callback)
  callback("looks good to me")
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.reply()
vim.ui.input = original_reply_input
wait_for(function()
  return last_notification():find("Submitted PR thread reply", 1, true) ~= nil
end, "reply command did not post a thread reply")

local original_input = vim.ui.input
vim.ui.input = function(opts, callback)
  assert(opts.default and opts.default:find("two", 1, true), "suggestion default text missing")
  callback("two improved")
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.suggest()
vim.ui.input = original_input
wait_for(function()
  return last_notification():find("Submitted PR comment on file.txt:2", 1, true) ~= nil
end, "suggest command did not create a PR comment")

pr.summary()
assert(last_notification():find("Files: 1 viewed, 3 unviewed, 4 total", 1, true), "summary file counts were wrong")
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

pr.show_thread()
wait_for(function()
  return win_by_filetype("markdown") ~= nil
end, "thread preview did not open")
local thread_lines = lines_by_filetype("markdown")
assert(has_line(thread_lines, "reviewer:"), "thread preview author missing")
assert(has_line(thread_lines, "Needs review"), "thread preview body missing")
close_win_by_filetype("markdown")

pr.toggle_viewed()
assert(not pr.is_viewed_file("file.txt"), "viewed toggle did not mark file unviewed")

local native_select = nil
local original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  native_select = { items = items, opts = opts, callback = callback }
end
pr.list_viewed("unviewed")
vim.ui.select = original_select
assert(native_select, "native viewed picker did not use vim.ui.select")
assert(native_select.opts.prompt:find("unviewed", 1, true), "native picker prompt filter missing")
local native_labels = vim.tbl_map(function(item)
  return native_select.opts.format_item(item)
end, native_select.items)
assert(
  has_line_parts(native_labels, { "☐ 1", "+2", "-1", comment_sign .. " 1", "file.txt" }),
  "native picker file label was wrong"
)
assert(
  has_line_parts(native_labels, { "☐ 1", "+1", "-1", comment_sign .. " 1", "nested/other.txt" }),
  "native picker nested file label was wrong"
)
assert(
  has_line_parts(native_labels, { "☐ 1", "+1", "-1", "nested/deeper/more.txt" }),
  "native picker deep file label was wrong"
)
assert(has_line_parts(native_labels, { "☐ 1", "+2", "-0", "new.txt" }), "native picker added file label was wrong")

local selected_native_item = native_select.items[1]
native_select.callback(selected_native_item)
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find(selected_native_item.path, 1, true) ~= nil
end, "native picker selection did not open the file")

native_select = nil
vim.ui.select = function(items, opts, callback)
  native_select = { items = items, opts = opts, callback = callback }
end
pr.list_viewed("viewed")
vim.ui.select = original_select
assert(not native_select, "native picker should not open without matching files")
assert(last_notification():find("no viewed PR files", 1, true), "empty native picker notification missing")

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

vim.env.REVIEW_MODE_FAIL_MUTATION = "1"
pr.toggle_viewed()
wait_for(function()
  return viewed_sync_queue_count() == 1
end, "failed viewed sync mutation was not queued")

-- a failed flush must release the in-flight guard instead of waiting out a timer
local queued_notifications = notification_count("Review Mode viewed sync queued")
pr.flush_viewed_sync()
wait_for(function()
  return notification_count("Review Mode viewed sync queued") == queued_notifications + 1
end, "failed viewed sync flush was not reported")
pr.flush_viewed_sync()
wait_for(function()
  return notification_count("Review Mode viewed sync queued") == queued_notifications + 2
end, "failed viewed sync flush left the in-flight guard stuck")
vim.env.REVIEW_MODE_FAIL_MUTATION = nil
pr.flush_viewed_sync()
wait_for(function()
  return viewed_sync_queue_count() == 0
end, "queued viewed sync mutation was not flushed")

-- a generation bump mid-flush must not wedge every later flush
vim.env.REVIEW_MODE_FAIL_MUTATION = "1"
pr.toggle_viewed()
wait_for(function()
  return viewed_sync_queue_count() == 1
end, "second failed viewed sync mutation was not queued")
local wedged_notifications = notification_count("Review Mode viewed sync queued")
pr.flush_viewed_sync()
pr.refresh()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "refresh did not reload the changed file map")
pr.flush_viewed_sync()
wait_for(function()
  return notification_count("Review Mode viewed sync queued") > wedged_notifications
end, "a refresh during a flush wedged the viewed sync queue")
vim.env.REVIEW_MODE_FAIL_MUTATION = nil
pr.flush_viewed_sync()
wait_for(function()
  return viewed_sync_queue_count() == 0
end, "queued viewed sync mutation was not flushed after a refresh")

vim.cmd.edit("file.txt")
pr.mark_viewed_next()
wait_for(function()
  return vim.api.nvim_buf_get_name(0):find("nested/deeper/more%.txt$", 1) ~= nil
end, "mark viewed next did not jump to next unviewed file")

package.preload["nvim-tree.renderer.decorator"] = function()
  return {
    extend = function()
      return {}
    end,
  }
end

local Decorator = require("review_mode.integrations.nvim_tree")
local decorator = setmetatable({}, { __index = Decorator })
decorator:new()
local tree_node = { absolute_path = vim.fs.joinpath(pr.root(), "file.txt") }
local icons = decorator:icons(tree_node)
assert(pr.unresolved_comment_count("file.txt") == 1, "unresolved file comment count was wrong")
assert(has_icon(icons, comment_sign .. " 1"), "nvim-tree comment marker missing")
assert(has_icon(icons, "✓"), "nvim-tree viewed marker missing")
assert(has_icon_hl(icons, "✓", "ReviewModeTreeViewed"), "nvim-tree viewed marker highlight was wrong")
assert(not has_icon(icons, "☐"), "nvim-tree changed marker shown for viewed file")
assert(decorator:highlight_group(tree_node) == "ReviewModeTreeViewed", "nvim-tree viewed file highlight was wrong")

local unviewed_tree_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested/other.txt") }
icons = decorator:icons(unviewed_tree_node)
assert(pr.unresolved_comment_count("nested/other.txt") == 1, "unresolved nested file comment count was wrong")
assert(has_icon(icons, comment_sign .. " 1"), "nvim-tree nested comment marker missing")
assert(pr.unviewed_count("nested/other.txt") == 1, "unviewed file count was wrong")
assert(has_icon(icons, "☐ 1"), "nvim-tree changed marker missing for unviewed file")
assert(has_icon_hl(icons, "☐ 1", "ReviewModeTreeChanged"), "nvim-tree changed marker highlight was wrong")
assert(not has_icon(icons, "✓"), "nvim-tree viewed marker shown for unviewed file")
assert(
  decorator:highlight_group(unviewed_tree_node) == "ReviewModeTreeChanged",
  "nvim-tree changed file highlight was wrong"
)

local dir_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested") }
local dir_icons = decorator:icons(dir_node)
assert(pr.unresolved_comment_count("nested") == 1, "unresolved folder comment count was wrong")
assert(has_icon(dir_icons, comment_sign .. " 1"), "nvim-tree folder comment marker missing")
assert(pr.unviewed_count("nested") == 2, "unviewed folder count was wrong")
assert(has_icon(dir_icons, "☐ 2"), "nvim-tree changed folder marker missing")
assert(has_icon_hl(dir_icons, "☐ 2", "ReviewModeTreeChanged"), "nvim-tree changed folder marker highlight was wrong")
assert(not pr.is_viewed_dir("nested"), "viewed dir state was true before all children were viewed")
assert(decorator:highlight_group(dir_node) == "ReviewModeTreeChanged", "nvim-tree changed folder highlight was wrong")

dir_node.open = true
assert(decorator:icons(dir_node) == nil, "nvim-tree open folder markers should be hidden")
dir_node.open = false

local deep_dir_node = { absolute_path = vim.fs.joinpath(pr.root(), "nested/deeper") }
local deep_dir_icons = decorator:icons(deep_dir_node)
assert(pr.unviewed_count("nested/deeper") == 1, "unviewed deep folder count was wrong")
assert(has_icon(deep_dir_icons, "☐ 1"), "nvim-tree deep folder marker missing")

pr.mark_viewed("nested/deeper/more.txt", { silent = true })
wait_for(function()
  return pr.is_viewed_dir("nested/deeper")
end, "viewed deep dir state did not cascade after child was viewed")
assert(pr.unviewed_count("nested/deeper") == 0, "unviewed deep folder count did not clear after child was viewed")
assert(pr.unviewed_count("nested") == 1, "unviewed parent folder count did not update after deep child was viewed")
deep_dir_icons = decorator:icons(deep_dir_node)
assert(has_icon(deep_dir_icons, "✓"), "nvim-tree viewed deep folder marker missing")
assert(
  has_icon_hl(deep_dir_icons, "✓", "ReviewModeTreeViewed"),
  "nvim-tree viewed deep folder marker highlight was wrong"
)

pr.mark_viewed("nested/other.txt", { silent = true })
wait_for(function()
  return pr.is_viewed_dir("nested")
end, "viewed dir state did not cascade after all children were viewed")
assert(pr.unviewed_count("nested") == 0, "unviewed folder count did not clear after children were viewed")
dir_icons = decorator:icons(dir_node)
assert(has_icon(dir_icons, comment_sign .. " 1"), "nvim-tree viewed folder comment marker missing")
assert(has_icon(dir_icons, "✓"), "nvim-tree viewed folder marker missing")
assert(has_icon_hl(dir_icons, "✓", "ReviewModeTreeViewed"), "nvim-tree viewed folder marker highlight was wrong")
assert(decorator:highlight_group(dir_node) == "ReviewModeTreeViewed", "nvim-tree viewed folder highlight was wrong")

-- a toggle must invalidate the rolled-up directory totals within the same turn
local nested_unviewed = pr.unviewed_count("nested")
pr.toggle_viewed("nested/other.txt")
assert(pr.unviewed_count("nested") == nested_unviewed + 1, "directory unviewed count was stale after toggle")
pr.toggle_viewed("nested/other.txt")
assert(pr.unviewed_count("nested") == nested_unviewed, "directory unviewed count was stale after restoring toggle")

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

-- a removed line whose content starts with "--" must not be read as a diff header
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1
end, "side-by-side pair did not close before comment-line diff check")
vim.cmd.edit("nested/other.txt")
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2 and buffer_lines_matching("pr%-base://") ~= nil
end, "side-by-side diff did not open for comment-line change")
local comment_span_found = false
for _, mark in ipairs(diff_marks(vim.api.nvim_get_current_buf())) do
  local _, row, col, details = unpack(mark)
  if row == 1 and col == #"-- " and details.end_col == #"-- new" then
    comment_span_found = true
  end
end
assert(comment_span_found, "partial span missing for changed line starting with --")
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 1
end, "comment-line side-by-side pair did not close")
vim.cmd.edit("file.txt")
pr.old_toggle()
wait_for(function()
  return #vim.api.nvim_list_wins() == 2 and buffer_lines_matching("pr%-base://") ~= nil
end, "side-by-side diff did not reopen after comment-line diff check")

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
    and vim.api.nvim_buf_get_name(0):find("nested/deeper/more%.txt$", 1) ~= nil
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
