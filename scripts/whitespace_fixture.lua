-- Hide whitespace: diff.ignore_whitespace and :ReviewModeDiffWhitespaceToggle.
--
-- Builds its own repo so the shared fixture repo keeps its files: ws.txt is a
-- reindent and nothing else, mixed.txt has a whitespace-only line 2 and a real
-- change on line 10.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, args))
  assert(vim.v.shell_error == 0, "git " .. table.concat(args, " ") .. ": " .. out)
end
local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end
local mixed = { "one", "x = 1", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven" }

git({ "init", "-q" })
git({ "config", "user.email", "test@example.com" })
git({ "config", "user.name", "Test" })
git({ "config", "core.hooksPath", dir .. "/nohooks" })
git({ "checkout", "-q", "-B", "main" })
write("ws.txt", { "a", "b", "c" })
write("mixed.txt", mixed)
git({ "add", "." })
git({ "commit", "-q", "-m", "base" })
git({ "checkout", "-q", "-b", "feature" })
write("ws.txt", { "  a", "  b", "  c" })
mixed[2] = "x  =  1"
mixed[10] = "ten changed"
write("mixed.txt", mixed)
git({ "add", "." })
git({ "commit", "-q", "-m", "feature" })
git({ "remote", "add", "origin", "." })
git({ "update-ref", "refs/remotes/origin/main", "refs/heads/main" })
vim.cmd.cd(dir)

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
assert(pr.config().diff.ignore_whitespace == false, "ignore_whitespace should default to false")

local function hunks(path)
  local result
  api.hunks(path, function(lines)
    result = lines
  end)
  wait_for(function()
    return result ~= nil
  end, "hunks did not load for " .. path)
  return result
end

-- The unified diff's git arguments, as the plugin sent them.
local unified_args
local original_system = vim.system
vim.system = function(cmd, ...)
  if cmd[1] == "git" and vim.tbl_contains(cmd, "--no-index") then
    unified_args = cmd
  end
  return original_system(cmd, ...)
end

local function lines_of(pattern)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):find(pattern) then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
end

pr.start()
wait_for(function()
  return #api.files() == 2
end, "changed files did not load")

-- Off: whitespace counts, as git diff does by default.
assert(vim.deep_equal(hunks("mixed.txt"), { 2, 10 }), "whitespace hunk missing with the setting off")
assert(vim.deep_equal(hunks("ws.txt"), { 1 }), "reindent hunk missing with the setting off")
assert(not api.file("ws.txt").whitespace_only, "whitespace_only reported with the setting off")

-- On, with no diff open: the toggle opens the side-by-side diff with iwhiteall,
-- added once even when the configured diffopt already has it.
local before = vim.o.diffopt
pr.config().diff.fast_diffopt = pr.config().diff.fast_diffopt .. ",iwhiteall"
vim.cmd.edit("mixed.txt")
vim.cmd("ReviewModeDiffWhitespaceToggle")
assert(pr.config().diff.ignore_whitespace, "toggle did not turn ignore_whitespace on")
wait_for(function()
  return lines_of("pr%-base://") ~= nil
end, "toggle did not show the diff")
local _, iwhiteall_count = vim.o.diffopt:gsub("iwhiteall", "")
assert(iwhiteall_count == 1, "iwhiteall not in the applied diffopt exactly once: " .. vim.o.diffopt)
assert(notifications[#notifications] == "Review Mode diff whitespace: hidden", "toggle did not notify the new state")

-- Vim's own ]c skips the whitespace-only line 2 in the split.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 10, "diff ]c stopped on a whitespace-only change")

-- Hunks recompute with -w: line 2 is gone, ws.txt has none but stays listed.
assert(vim.deep_equal(hunks("mixed.txt"), { 10 }), "whitespace-only hunk survived -w")
assert(vim.deep_equal(hunks("ws.txt"), {}), "reindent-only file still has hunks under -w")
assert(#api.files() == 2, "whitespace-only file dropped from the changed files")
assert(api.file("ws.txt").whitespace_only, "ws.txt not reported as whitespace-only")
assert(not api.file("mixed.txt").whitespace_only, "mixed.txt wrongly reported as whitespace-only")

-- Out of diff mode, review ]c walks the -w hunks too.
pr.old_toggle()
wait_for(function()
  return lines_of("pr%-base://") == nil
end, "side-by-side diff did not close")
assert(vim.o.diffopt == before, "diffopt was not restored")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 10, "review ]c stopped on a whitespace-only change")

-- Unified: git diff -w leaves the whitespace-only line as context.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.toggle_diff_layout()
wait_for(function()
  return lines_of("pr%-diff://") ~= nil
end, "unified diff did not open")
local unified = lines_of("pr%-diff://")
assert(vim.tbl_contains(unified, "+ten changed"), "unified diff lost the real change")
assert(vim.tbl_contains(unified_args, "-w"), "unified diff did not pass -w")
-- context may carry either side's spacing depending on git; only require that
-- the whitespace-only line is not shown as a change
for _, line in ipairs(unified) do
  local body = line:match("^[+-](.*)$")
  assert(not (body and body:gsub("%s", "") == "x=1"), "unified diff showed a whitespace-only change: " .. line)
end

-- Off again, while the unified diff is open: it re-renders with the change.
pr.toggle_diff_whitespace()
wait_for(function()
  local lines = lines_of("pr%-diff://")
  return lines and vim.tbl_contains(lines, "+x  =  1")
end, "toggling off did not re-render the open unified diff")
assert(notifications[#notifications] == "Review Mode diff whitespace: shown", "toggle off did not notify")
-- off means git's own defaults: no -w, and no flag standing in for it
local plain_args = require("review_mode.git").diff({ "--no-index", "--unified=1000000" })
assert(
  vim.deep_equal({ unpack(unified_args, 1, #plain_args) }, plain_args) and unified_args[#plain_args + 1] == "--",
  "unified diff with whitespace shown passed extra flags: " .. table.concat(unified_args, " ")
)
assert(vim.deep_equal(hunks("mixed.txt"), { 2, 10 }), "hunks did not recompute after toggling off")

pr.stop()
harness.done()
