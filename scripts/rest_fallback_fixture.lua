local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

pr.start()
wait_for(function()
  return api.is_changed_file("file.txt")
end, "changed file map did not load for REST fallback")
wait_for(function()
  return api.comment_count("file.txt") == 2
end, "REST comment fallback did not load PR comments")

pr.stop()
harness.done()
