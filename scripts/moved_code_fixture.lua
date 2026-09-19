-- Moved code: a block deleted in one file and added, unchanged, in another is
-- marked as moved, and ]c / [c pass over hunks that only move code.
--
-- Builds its own small repo, so the shared fixture repo's files stay as the
-- other fixtures expect them. A local review: no forge involved.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

vim.notify = function() end

-- Detection on its own ---------------------------------------------------------

local moved = require("review_mode.moved")
local found = moved.detect(table.concat({
  "diff --git a/x.lua b/x.lua",
  "--- a/x.lua",
  "+++ b/x.lua",
  "@@ -1,4 +0,0 @@",
  -- a deleted "-- a/b ..." comment reads "--- a/b ..." in the patch
  "--- a/b is the ratio",
  "-local value = compute()",
  "-print(value)",
  "-end",
  "diff --git a/y.lua b/y.lua",
  "--- a/y.lua",
  "+++ b/y.lua",
  "@@ -0,0 +5,5 @@",
  "+    -- a/b is the ratio",
  "+    local value = compute()",
  "+    print(value)",
  "+    end",
  "+new_line_here()",
  "@@ -9,3 +11,3 @@",
  "-end",
  "-end",
  "-}",
  "+end",
  "+end",
  "+}",
  "diff --git a/w.lua b/w.lua",
  "--- a/w.lua",
  "+++ b/w.lua",
  "@@ -1,3 +0,0 @@",
  "-function helper_one(argument)",
  "-  return argument * 2",
  "-end",
  "diff --git a/z.lua b/z.lua",
  "--- a/z.lua",
  "+++ b/z.lua",
  "@@ -0,0 +3,5 @@",
  "+",
  "+function helper_one(argument)",
  "+  return argument * 2",
  "+end",
  "+",
}, "\n"))

local y = found.added["y.lua"] or {}
assert(y[5] and y[5].path == "x.lua" and y[5].line == 1 and y[5].first, "re-indented block not matched to x.lua:1")
assert(y[8] and y[8].line == 4 and not y[8].first, "block did not run to its last line")
assert(not y[9], "a new line after the block was marked moved")
assert(not y[11] and not y[13], "a three-line run of end/} (under 20 alnum chars) was marked moved")
assert(found.skip["x.lua"][1] == true, "a hunk that only deletes moved code is not skippable")
assert(found.skip["y.lua"][5] == false, "a hunk with a real new line was skippable")
assert(found.skip["y.lua"][11] == false, "a hunk of noise lines was skippable")
assert(found.skip["z.lua"][3] == true, "blank lines around a moved block made its hunk a real change")
assert(not found.added["z.lua"][3], "a blank separator line was marked moved")

-- Thousands of identical lines on both sides must not stall the main thread:
-- trying every copy as a block start is quadratic.
local noise = { "diff --git a/p.c b/p.c", "--- a/p.c", "+++ b/p.c", "@@ -1,5000 +1,5000 @@" }
for _ = 1, 5000 do
  noise[#noise + 1] = "-}"
end
for _ = 1, 5000 do
  noise[#noise + 1] = "+}"
end
local started = vim.uv.hrtime()
moved.detect(table.concat(noise, "\n"))
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
assert(elapsed_ms < 2000, string.format("detect() took %.0f ms on 5000 identical lines", elapsed_ms))

-- In a review ------------------------------------------------------------------

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, args))
  assert(vim.v.shell_error == 0, "git " .. table.concat(args, " ") .. ": " .. out)
end
local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end

local block = {
  "local function total(items)",
  "  local sum = 0",
  "  for _, item in ipairs(items) do",
  "    sum = sum + item.price",
  "  end",
  "  return sum",
  "end",
  "",
}

git({ "init", "-q" })
git({ "config", "core.hooksPath", dir .. "/nohooks" })
git({ "config", "user.email", "test@example.com" })
git({ "config", "user.name", "Test" })
git({ "checkout", "-q", "-B", "main" })
write("a.lua", vim.list_extend(vim.list_extend({ "local A = {}", "" }, block), { "return A" }))
write("b.lua", { "local M = {}", "", "function M.keep()", "  return 1", "end", "", "return M" })
git({ "add", "." })
git({ "commit", "-q", "-m", "base" })
git({ "checkout", "-q", "-b", "feature" })
write("a.lua", { "local A = {}", "", "return A" })
write(
  "b.lua",
  vim.list_extend(
    vim.list_extend({ "local M = {}", "" }, block),
    { "function M.keep()", "  return 2", "end", "", "return M" }
  )
)
git({ "commit", "-q", "-am", "move total into b" })
vim.fn.chdir(dir)

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
pr.review_local({ "main..feature" })
wait_for(function()
  return api.is_active() and api.is_changed_file("b.lua")
end, "local review did not load")

vim.cmd.edit(dir .. "/b.lua")
local bufnr = vim.api.nvim_get_current_buf()
local marks
wait_for(function()
  marks = vim.api.nvim_buf_get_extmarks(bufnr, moved.namespace, 0, -1, { details = true })
  return #marks > 0
end, "no moved-code marks in b.lua")

local rows, label = {}, nil
for _, mark in ipairs(marks) do
  rows[mark[2] + 1] = true
  if mark[4].virt_text then
    label = mark[4].virt_text[1][1]
  end
end
for line = 3, 9 do
  assert(rows[line], "moved line " .. line .. " has no mark")
end
assert(not rows[12], "the real change on line 12 was marked moved")
assert(label == "moved from a.lua:3", "wrong moved label: " .. tostring(label))

-- ]c passes over the moved hunk and stops at the real change
local hunks
api.hunks("b.lua", function(list)
  hunks = list
end)
wait_for(function()
  return hunks ~= nil
end, "hunks did not load")
assert(#hunks == 2 and hunks[2] == 12, "unexpected hunks: " .. vim.inspect(hunks))

vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 12, "]c did not skip the moved hunk")

vim.api.nvim_win_set_cursor(0, { 15, 0 })
pr.prev_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 12, "[c did not stop at the real change")

-- nothing real before line 12 in b.lua, so [c leaves for the previous file
pr.prev_hunk()
assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "a.lua", "[c stopped at the moved hunk above")
vim.cmd.edit(dir .. "/b.lua")

-- with skipping off, the moved hunk is an ordinary stop again
pr.toggle_skip_moved()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == hunks[1], "]c skipped a moved hunk with skip_moved off")

-- ending the review takes the marks with it
pr.stop()
assert(#vim.api.nvim_buf_get_extmarks(bufnr, moved.namespace, 0, -1, {}) == 0, "moved-code marks outlived the review")

print("moved code fixture passed")
