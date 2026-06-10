local plugin_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local target_file = assert(os.getenv("REVIEW_MODE_BENCH_FILE"), "REVIEW_MODE_BENCH_FILE is required")
local label = os.getenv("REVIEW_MODE_BENCH_LABEL") or "plugin"
local idle_ms = tonumber(os.getenv("REVIEW_MODE_BENCH_IDLE_MS") or "0") or 0
local post_edit_idle_ms = tonumber(os.getenv("REVIEW_MODE_BENCH_POST_EDIT_IDLE_MS") or "0") or 0
local wait_ms = tonumber(os.getenv("REVIEW_MODE_BENCH_WAIT_MS") or "20") or 20
local gitsigns_enabled = os.getenv("REVIEW_MODE_BENCH_GITSIGNS") == "1"
local gitsigns_root = os.getenv("REVIEW_MODE_GITSIGNS_ROOT")

vim.opt.runtimepath:prepend(plugin_root)
if gitsigns_enabled and gitsigns_root and gitsigns_root ~= "" then
  vim.opt.runtimepath:prepend(gitsigns_root)
end
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

if gitsigns_enabled then
  local ok, gitsigns = pcall(require, "gitsigns")
  assert(ok, "REVIEW_MODE_BENCH_GITSIGNS=1 requires gitsigns on runtimepath")
  gitsigns.setup({ update_debounce = 0 })
end

local ok, pr = pcall(require, "review_mode")
if not ok then
  ok, pr = pcall(require, "pr_review")
end
assert(ok, "review_mode or pr_review module is required")
pr.setup({
  gitsigns = { enabled = gitsigns_enabled },
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
end, wait_ms)
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
local first_nav_call_return_ms = nil
local nav_ready = vim.wait(60000, function()
  if vim.api.nvim_win_get_cursor(0)[1] > 1 then
    return true
  end

  local call_start = vim.uv.hrtime()
  pr.next_change()
  first_nav_call_return_ms = first_nav_call_return_ms or ((vim.uv.hrtime() - call_start) / 1000000)
  return vim.api.nvim_win_get_cursor(0)[1] > 1
end, wait_ms)
assert(nav_ready, "hunk navigation did not complete")
first_nav_call_return_ms = first_nav_call_return_ms or 0
local first_nav_ms = ms_since(nav_start)

local result = {
  label = label,
  start_return_ms = start_return_ms,
  map_ready_ms = map_ready_ms,
  first_nav_ms = first_nav_ms,
  first_nav_call_return_ms = first_nav_call_return_ms,
  wait_ms = wait_ms,
  gitsigns = gitsigns_enabled,
  idle_ms = idle_ms,
  post_edit_idle_ms = post_edit_idle_ms,
  cursor_line = vim.api.nvim_win_get_cursor(0)[1],
}

print(vim.json.encode(result))
pr.stop()
