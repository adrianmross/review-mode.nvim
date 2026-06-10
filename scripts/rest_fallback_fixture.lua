local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local pr = require("review_mode")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

pr.start()
wait_for(function()
  return pr.is_changed_file("file.txt")
end, "changed file map did not load for REST fallback")
wait_for(function()
  return pr.comment_count("file.txt") == 2
end, "REST comment fallback did not load PR comments")

pr.stop()
