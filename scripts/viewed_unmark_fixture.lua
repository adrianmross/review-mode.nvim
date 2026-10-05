-- fixture: gh pr REVIEW_MODE_GH_LOG={tmp}/gh.log
-- Marking and unmarking a file viewed each send their own GitHub mutation. The
-- gh mock logs which one it answered: "markFileAsViewed" is a substring of
-- "unmarkFileAsViewed", and a mock that matched the shorter name first answered
-- every unmark as a mark.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local gh_log = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

local wait_for = harness.wait_for

vim.notify = function() end

local function mutations()
  local found = {}
  for _, line in ipairs(vim.fn.filereadable(gh_log) == 1 and vim.fn.readfile(gh_log) or {}) do
    local field = line:match("^graphql (%a+FileAsViewed)$")
    if field then
      found[#found + 1] = field
    end
  end
  return found
end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = true, sync = true },
  auto_open_first_change = false,
})

pr.start()
-- maps_loaded: the stored viewed state is read after the name list lands
wait_for(function()
  return api.is_changed_file("new.txt") and require("review_mode.state").state.maps_loaded
end, "changed file map did not load")

api.set_viewed("new.txt", true)
wait_for(function()
  return #mutations() == 1
end, "marking viewed sent no mutation")
api.set_viewed("new.txt", false)
wait_for(function()
  return #mutations() == 2
end, "unmarking viewed sent no mutation")
assert(
  vim.deep_equal(mutations(), { "markFileAsViewed", "unmarkFileAsViewed" }),
  "the mock answered the wrong mutations: " .. vim.inspect(mutations())
)

pr.stop()
harness.done()
