local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  comments = { diagnostics = { enabled = true } },
})

local ns = vim.api.nvim_get_namespaces().review_mode_diagnostics
assert(ns, "diagnostics namespace was not created")

local function diags(bufnr)
  local list = vim.diagnostic.get(bufnr, { namespace = ns })
  table.sort(list, function(left, right)
    return left.lnum < right.lnum
  end)
  return list
end

pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 3 and api.comment_count("nested/other.txt") == 1
end, "comments did not load")

vim.cmd("edit file.txt")
local buf = vim.api.nvim_get_current_buf()
wait_for(function()
  return #diags(buf) == 1
end, "expected one unresolved diagnostic on file.txt")

local first = diags(buf)[1]
assert(first.lnum == 1 and first.end_lnum == 1, "diagnostic lnum should be the thread line - 1")
assert(first.severity == vim.diagnostic.severity.INFO, "unresolved thread should default to INFO")
assert(first.message == "reviewer: Needs review", "unexpected message: " .. first.message)
assert(first.source == "review-mode", "unexpected source")
assert(first.user_data.thread_id == "thread_1", "user_data.thread_id missing")
assert(first.user_data.url == "https://github.com/owner/repo/pull/123#discussion_r1", "user_data.url missing")

-- The plugin draws its own signs and virtual text; the namespace must not.
local display = vim.diagnostic.config(nil, ns)
assert(display.signs == false, "namespace signs should be off")
assert(display.virtual_text == false, "namespace virtual_text should be off")
assert(display.underline == false, "namespace underline should be off")

-- show_resolved brings in the resolved thread, as a HINT with its reply count.
api.config().comments.show_resolved = true
require("review_mode.diagnostics").refresh()
local all = diags(buf)
assert(#all == 2, "show_resolved should include the resolved thread")
assert(all[2].lnum == 3 and all[2].severity == vim.diagnostic.severity.HINT, "resolved thread should be a HINT")
assert(
  all[2].message == "maintainer: Fixed in the follow-up commit. (1 reply)",
  "unexpected resolved message: " .. all[2].message
)
api.config().comments.show_resolved = false
require("review_mode.diagnostics").refresh()
assert(#diags(buf) == 1, "hiding resolved threads should drop the resolved diagnostic")

-- Toggling at runtime clears and restores.
vim.cmd("ReviewModeDiagnosticsToggle")
assert(#diags(buf) == 0, "disabled diagnostics should set none")
vim.cmd("ReviewModeDiagnosticsToggle")
assert(#diags(buf) == 1, "re-enabled diagnostics should come back")

-- Quickfix walks the changed-file list, which loads separately from comments.
wait_for(function()
  return api.is_changed_file("nested/other.txt")
end, "changed file map did not load")
local unresolved = api.quickfix_items()
assert(#unresolved == 2, "default quickfix items should be the two unresolved threads")
local items = api.quickfix_items({ filter = "all" })
assert(#items == 3, "all quickfix items should cover every thread")
assert(vim.endswith(items[1].filename, "/file.txt") and items[1].lnum == 2 and items[1].type == "I", "bad item 1")
assert(items[2].lnum == 4 and items[2].type == "N" and vim.endswith(items[2].text, "[resolved]"), "bad item 2")
assert(vim.endswith(items[3].filename, "/nested/other.txt") and items[3].lnum == 2, "bad item 3")

vim.cmd("ReviewModeQuickfix all")
local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(qf.title == "Review Mode: owner/repo#123 threads", "unexpected quickfix title: " .. qf.title)
assert(#qf.items == 3, "quickfix list should hold every thread")
assert(vim.endswith(vim.api.nvim_buf_get_name(qf.items[3].bufnr), "nested/other.txt"), "quickfix filename")
vim.cmd("cclose")

pr.stop()
assert(#vim.diagnostic.get(nil, { namespace = ns }) == 0, "stop should clear every diagnostic")

-- enabled = false (the default) sets nothing.
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 3
end, "comments did not reload")
vim.cmd("edit file.txt")
vim.wait(200)
assert(#vim.diagnostic.get(nil, { namespace = ns }) == 0, "diagnostics are off by default")
pr.stop()
harness.done()
