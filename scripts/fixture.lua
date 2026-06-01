local repo_root = assert(os.getenv("PR_REVIEW_PLUGIN_ROOT"), "PR_REVIEW_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local pr = require("pr_review")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  auto_open_first_change = false,
})

pr.start()
assert(
  vim.wait(5000, function()
    return pr.is_changed_file("file.txt")
  end, 20),
  "changed file map did not load"
)

vim.cmd.edit("file.txt")
pr.next_change()
assert(
  vim.wait(5000, function()
    return vim.api.nvim_win_get_cursor(0)[1] == 2
  end, 20),
  "lazy hunk navigation failed"
)

local before = vim.o.diffopt
pr.old_toggle()
assert(
  vim.wait(5000, function()
    return #vim.api.nvim_list_wins() == 2
  end, 20),
  "old split did not open"
)
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
assert(
  vim.wait(5000, function()
    return #vim.api.nvim_list_wins() == 1
  end, 20),
  "old split did not close"
)
assert(vim.o.diffopt == before, "diffopt was not restored")

pr.stop()
