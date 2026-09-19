-- Following HEAD in a local review: a commit reloads the changed files without
-- asking a forge, and a hunk load started against the old HEAD cannot land its
-- stale hunks in the new maps. Builds its own repo, since it commits.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

-- Wrapped before the plugin loads: init.lua keeps its own reference. Forge
-- calls are recorded and refused; hunk loads can be held after git answered.
local util = require("review_mode.util")
local forge_calls, holding, held = {}, false, {}
local function is_forge(args)
  return type(args) == "table" and (args[1] == "gh" or args[1] == "glab")
end
local system, system_async = util.system, util.system_async
util.system = function(args, ...)
  if is_forge(args) then
    forge_calls[#forge_calls + 1] = table.concat(args, " ")
    return nil, "no forge in this fixture"
  end
  return system(args, ...)
end
util.system_async = function(args, opts, callback)
  if is_forge(args) then
    forge_calls[#forge_calls + 1] = table.concat(args, " ")
    vim.schedule(function()
      callback(nil, "no forge in this fixture")
    end)
    return
  end
  if holding and vim.tbl_contains(args, "--unified=0") then
    return system_async(args, opts, function(output, err)
      held[#held + 1] = function()
        callback(output, err)
      end
    end)
  end
  return system_async(args, opts, callback)
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, args))
  assert(vim.v.shell_error == 0, "git " .. table.concat(args, " ") .. ": " .. out)
end
local function write(lines)
  vim.fn.writefile(lines, dir .. "/a.txt")
end
local base = { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10" }
git({ "init", "-q" })
git({ "config", "core.hooksPath", dir .. "/.nohooks" })
git({ "checkout", "-q", "-B", "main" })
write(base)
git({ "add", "a.txt" })
git({ "commit", "-q", "-m", "base" })
git({ "checkout", "-q", "-b", "feature" })
local head = vim.deepcopy(base)
head[2] = "L2"
write(head)
git({ "commit", "-q", "-am", "feature" })
vim.fn.chdir(dir)

local pr = require("review_mode")
local api = require("review_mode.api")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
  performance = { hunk_prefetch = { enabled = false }, background_hunk_scan = { enabled = false } },
})

pr.review_local({ "main" })
wait_for(function()
  return api.is_active() and state.maps_loaded and api.is_changed_file("a.txt") and state.head_log_stamp ~= nil
end, "the local review did not load")

-- a hunk load against the current HEAD: git has answered, the answer is held
holding = true
api.hunks("a.txt", function() end)
wait_for(function()
  return #held == 1
end, "the hunk load did not run")

-- a commit lands, and the review follows it
head[8] = "L8"
write(head)
git({ "commit", "-q", "-am", "second" })
vim.api.nvim_exec_autocmds("FocusGained", {})
wait_for(function()
  return state.maps_loaded and vim.tbl_contains(notifications, "Review Mode: HEAD moved, 1 changed files")
end, "the review did not follow HEAD")

-- the old HEAD's hunks arrive now, after the maps were rebuilt
holding = false
held[1]()

local hunks
api.hunks("a.txt", function(lines)
  hunks = lines
end)
wait_for(function()
  return hunks ~= nil
end, "hunks did not load after the reload")
assert(vim.deep_equal(hunks, { 2, 8 }), "stale pre-commit hunks landed after the reload: " .. vim.inspect(hunks))

assert(#forge_calls == 0, "a local review asked a forge: " .. table.concat(forge_calls, "; "))

pr.stop()
vim.fn.chdir("/")
vim.fn.delete(dir, "rf")
print("follow HEAD local fixture passed")
harness.done()
