-- fixture: gh pr
-- The viewed-file picker preview must not block on git diff (issue #58).
--
-- Driven through the snacks provider, because that is the shortest real path to
-- the shared preview helper: a fake _G.Snacks captures the pick options, and
-- fake preview objects record every set_lines call so the placeholder and the
-- late update can be told apart.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local function has_line(lines, needle)
  for _, line in ipairs(lines or {}) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Instrument vim.system so the test can tell a spawn from a blocking wait, and
-- know when git has actually finished rather than guessing at a sleep.
local blocking_waits = 0
local diff_spawns = 0
local diff_exits = 0
local real_system = vim.system
vim.system = function(cmd, opts, on_exit)
  -- git.diff puts "-c core.quotePath=false" before the subcommand
  local is_diff = cmd[1] == "git" and vim.list_contains(cmd, "diff")
  local wrapped = on_exit
  if is_diff then
    diff_spawns = diff_spawns + 1
    if on_exit then
      wrapped = function(...)
        diff_exits = diff_exits + 1
        return on_exit(...)
      end
    end
  end

  local handle = real_system(cmd, opts, wrapped)
  local real_wait = handle.wait
  handle.wait = function(self, ...)
    blocking_waits = blocking_waits + 1
    return real_wait(self, ...)
  end
  return handle
end

local function fake_preview()
  local preview = { renders = {} }
  preview.reset = function() end
  preview.set_lines = function(_, lines)
    preview.renders[#preview.renders + 1] = lines
  end
  preview.highlight = function() end
  return preview
end

local pick_opts = nil
_G.Snacks = {
  picker = {
    pick = function(opts)
      pick_opts = opts
    end,
  },
}

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

pr.start()
wait_for(function()
  return api.is_changed_file("file.txt")
end, "changed file map did not load for the async preview fixture")
pr.config().picker.provider = "snacks"

-- First visit: placeholder now, diff later, and nothing blocks in between.
pr.list_viewed("all")
assert(pick_opts, "snacks viewed picker was not used")
assert(#pick_opts.items >= 2, "async preview fixture needs at least two changed files")

local first = pick_opts.items[1]
local first_preview = fake_preview()
local waits_before = blocking_waits
pick_opts.preview({ item = first, preview = first_preview })
assert(blocking_waits == waits_before, "the preview callback blocked on git")
assert(#first_preview.renders == 1, "the preview callback should paint exactly once before git returns")
assert(has_line(first_preview.renders[1], "Loading diff"), "the preview callback did not paint a placeholder")
assert(not has_line(first_preview.renders[1], "@@"), "the placeholder already carried the diff")

wait_for(function()
  return #first_preview.renders == 2
end, "the async diff never reached the preview buffer")
assert(has_line(first_preview.renders[2], "@@"), "the async preview update carried no diff hunk")
assert(has_line(first_preview.renders[2], first.item.path), "the async preview update lost its header")

-- Second visit to the same file: served from the cache, synchronously, so
-- revisiting a file does not flicker back through the placeholder.
local spawns_before = diff_spawns
local repeat_preview = fake_preview()
pick_opts.preview({ item = first, preview = repeat_preview })
assert(diff_spawns == spawns_before, "a cached preview spawned git again")
assert(#repeat_preview.renders == 1, "a cached preview should paint once")
assert(not has_line(repeat_preview.renders[1], "Loading diff"), "a cached preview fell back to the placeholder")
assert(has_line(repeat_preview.renders[1], "@@"), "a cached preview did not serve the diff")

-- Staleness: the selection moves from A to B before A's diff returns. A's late
-- result must not land on the preview, which is now showing B.
pick_opts = nil
pr.list_viewed("all")
assert(pick_opts, "snacks viewed picker was not used for the staleness case")

local stale = pick_opts.items[1]
local current = pick_opts.items[2]
local stale_preview = fake_preview()
local current_preview = fake_preview()
local exits_before = diff_exits
pick_opts.preview({ item = stale, preview = stale_preview })
pick_opts.preview({ item = current, preview = current_preview })
assert(has_line(stale_preview.renders[1], "Loading diff"), "the stale item did not paint a placeholder")
assert(has_line(current_preview.renders[1], "Loading diff"), "the current item did not paint a placeholder")

wait_for(function()
  return #current_preview.renders == 2
end, "the diff for the current selection never arrived")
wait_for(function()
  return diff_exits >= exits_before + 2
end, "the stale diff never finished")
vim.wait(200)
assert(#stale_preview.renders == 1, "a late diff overwrote a preview whose selection had moved on")
assert(has_line(current_preview.renders[2], current.item.path), "the current preview lost its own file")

vim.system = real_system
pr.stop()
harness.done()
