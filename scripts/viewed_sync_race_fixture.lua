-- fixture: gh pr
-- GitHub viewed sync around refreshes and in-flight writes: a refresh mid-query
-- does not wedge the next sync, a queued change survives an older write
-- settling, turning sync on keeps local marks, and clearing tells GitHub.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

vim.notify = function() end

-- gh, answered here, before the plugin loads (viewed.lua keeps its own
-- reference). GitHub's viewed set is `remote`; a call matching `hold` waits in
-- `held` until the fixture lets it answer.
local util = require("review_mode.util")
local remote, queries, mutations, held = {}, 0, {}, {}
local hold, fail_mutations = nil, false
local function answer(text)
  if text:find("pr view", 1, true) then
    return { number = 123, headRefOid = "abc123", baseRefName = "main" }
  elseif text:find("viewerViewedState", 1, true) then
    queries = queries + 1
    local nodes = {}
    for path in pairs(remote) do
      nodes[#nodes + 1] = { path = path, viewerViewedState = "VIEWED" }
    end
    local files = { pageInfo = { hasNextPage = false }, nodes = nodes }
    return { data = { repository = { pullRequest = { id = "PR_node", files = files } } } }
  elseif text:find("FileAsViewed", 1, true) then
    local mark = not text:find("unmarkFileAsViewed", 1, true)
    local path = text:match("path=(%S+)")
    if fail_mutations then
      return nil, "forced mutation failure"
    end
    mutations[#mutations + 1] = (mark and "mark " or "unmark ") .. path
    remote[path] = mark or nil
    return { data = {} }
  elseif text:find("pullRequest(number", 1, true) then
    return { data = { repository = { pullRequest = { id = "PR_node" } } } }
  end
  return nil, "unexpected gh call: " .. text
end
util.gh_json_async = function(args, callback)
  local text = table.concat(args, " ")
  local function reply()
    callback(answer(text))
  end
  if hold and text:find(hold, 1, true) then
    hold = nil
    held[#held + 1] = reply
    return
  end
  vim.schedule(reply)
end

local pr = require("review_mode")
local api = require("review_mode.api")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
  comments = { enabled = false },
  ci = { diagnostics = false },
  viewed = { enabled = true, sync = true, state_path = vim.fn.tempname() .. ".json" },
})

-- A refresh while the viewed query is out ------------------------------------------------
hold = "viewerViewedState"
pr.start()
wait_for(function()
  return api.is_active() and state.maps_loaded and #held == 1
end, "the viewed query did not go out")
pr.refresh()
-- the old query never answers for this generation; the next sync must still run
wait_for(function()
  return queries >= 1 and state.maps_loaded
end, "the refreshed review did not query GitHub's viewed state: stuck behind the old query")
held[1]()
held = {}
local function settle()
  vim.wait(100)
end
settle()
pr.sync_viewed()
local before = queries
wait_for(function()
  return queries > before
end, ":ReviewModeViewedSync did nothing after a refresh")
settle()

-- A write settling after a newer change was queued ---------------------------------------
-- file.txt=true is queued (its write failed). A flush sends it and it is held;
-- meanwhile the user unmarks the file and that write fails too, queuing false.
-- The old write succeeding must not clear the false it never sent.
fail_mutations = true
pr.set_viewed("file.txt", true)
wait_for(function()
  return state.viewed_sync_queue["file.txt"] == true
end, "the failed mark was not queued")
fail_mutations = false
hold = "FileAsViewed"
pr.flush_viewed_sync()
wait_for(function()
  return #held == 1
end, "the flush did not send the queued mark")
fail_mutations = true
pr.set_viewed("file.txt", false)
wait_for(function()
  return state.viewed_sync_queue["file.txt"] == false
end, "the failed unmark was not queued")
fail_mutations = false
held[1]()
held = {}
settle()
assert(
  state.viewed_sync_queue["file.txt"] == false or vim.tbl_contains(mutations, "unmark file.txt"),
  "the settled mark cleared the queued unmark it never sent"
)
pr.flush_viewed_sync()
wait_for(function()
  return remote["file.txt"] == nil and next(state.viewed_sync_queue) == nil
end, "the queued unmark never reached GitHub")

-- Turning sync on keeps the marks made while it was off ------------------------------------
pr.toggle_viewed_sync()
assert(not api.config().viewed.sync, "sync did not turn off")
pr.set_viewed("nested/other.txt", true)
remote = { ["file.txt"] = true }
mutations = {}
before = queries
pr.toggle_viewed_sync()
wait_for(function()
  return queries > before
end, "turning sync on did not pull")
settle()
assert(api.is_viewed_file("file.txt"), "GitHub's mark did not arrive")
assert(api.is_viewed_file("nested/other.txt"), "turning sync on threw away a mark made while it was off")
wait_for(function()
  return remote["nested/other.txt"] == true
end, "the local mark was not pushed to GitHub: " .. vim.inspect(mutations))

-- Clearing with sync on tells GitHub, or the next pull brings it all back ----------------------
mutations = {}
pr.clear_viewed()
wait_for(function()
  return next(remote) == nil
end, "clearing viewed state left GitHub's marks: " .. vim.inspect(remote))
before = queries
pr.sync_viewed()
wait_for(function()
  return queries > before
end, "sync did not pull")
settle()
assert(not api.is_viewed_file("file.txt"), "a cleared mark came back from GitHub")

pr.stop()
print("viewed sync race fixture passed")
harness.done()
