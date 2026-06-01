local plugin_root = assert(os.getenv("PR_REVIEW_PLUGIN_ROOT"), "PR_REVIEW_PLUGIN_ROOT is required")
local target_file = assert(os.getenv("PR_REVIEW_BENCH_FILE"), "PR_REVIEW_BENCH_FILE is required")
local label = os.getenv("PR_REVIEW_BENCH_LABEL") or "plugin"
local idle_ms = tonumber(os.getenv("PR_REVIEW_BENCH_IDLE_MS") or "0") or 0
local post_edit_idle_ms = tonumber(os.getenv("PR_REVIEW_BENCH_POST_EDIT_IDLE_MS") or "0") or 0

vim.opt.runtimepath:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local pr = require("pr_review")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = false },
  auto_open_first_change = false,
})

local function ms_since(start)
  return (vim.uv.hrtime() - start) / 1000000
end

local start = vim.uv.hrtime()
pr.start()
local start_return_ms = ms_since(start)

local map_ready = vim.wait(60000, function()
  return pr.is_changed_file(target_file)
end, 20)
assert(map_ready, "changed file map did not load")
local map_ready_ms = ms_since(start)
if idle_ms > 0 then
  vim.wait(idle_ms, function()
    return false
  end, idle_ms)
end

vim.cmd.edit(target_file)
if post_edit_idle_ms > 0 then
  vim.wait(post_edit_idle_ms, function()
    return false
  end, post_edit_idle_ms)
end
local nav_start = vim.uv.hrtime()
pr.next_change()
local nav_ready = vim.wait(60000, function()
  return vim.api.nvim_win_get_cursor(0)[1] > 1
end, 20)
assert(nav_ready, "hunk navigation did not complete")
local first_nav_ms = ms_since(nav_start)

local result = {
  label = label,
  start_return_ms = start_return_ms,
  map_ready_ms = map_ready_ms,
  first_nav_ms = first_nav_ms,
  idle_ms = idle_ms,
  post_edit_idle_ms = post_edit_idle_ms,
  cursor_line = vim.api.nvim_win_get_cursor(0)[1],
}

print(vim.json.encode(result))
pr.stop()
