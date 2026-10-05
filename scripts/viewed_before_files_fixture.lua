-- fixture: gh pr
-- A file stored as viewed must never show as changed-but-unviewed while the
-- review loads: is_changed_file turns true with the name list, so the stored
-- viewed state has to be in place by then, not only after the numstat call.
-- Slowing numstat (and gh, whose metadata reply would also load it) holds that
-- window open for a second.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

vim.notify = function() end

local pr = require("review_mode")
local api = require("review_mode.api")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
})

local path = "new.txt"

-- a first session marks the file viewed
pr.start()
wait_for(function()
  return state.maps_loaded and api.is_changed_file(path)
end, "changed file map did not load")
pr.toggle_viewed(path)
assert(api.is_viewed_file(path), "toggle_viewed did not mark the file")
pr.stop()
state.viewed_store = nil

-- wrappers ahead of the real git and gh: numstat and every gh call sleep
local bin = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
local function wrap(name, body)
  local real = vim.fn.exepath(name)
  assert(real ~= "", name .. " not on PATH")
  vim.fn.writefile({ "#!/bin/sh", (body:gsub("REAL", real)) }, bin .. "/" .. name)
  vim.fn.setfperm(bin .. "/" .. name, "rwxr-xr-x")
end
wrap("git", 'case "$*" in *--numstat*) sleep 1 ;; esac; exec "REAL" "$@"')
wrap("gh", 'sleep 1; exec "REAL" "$@"')
vim.env.PATH = bin .. ":" .. vim.env.PATH

pr.start()
local seen_changed, stale = false, false
wait_for(function()
  if api.is_changed_file(path) then
    seen_changed = true
    stale = stale or not api.is_viewed_file(path)
  end
  return state.maps_loaded
end, "changed file map did not load")
assert(seen_changed, "the file never showed as changed")
assert(not stale, "the file showed as changed but not viewed before the viewed state loaded")
assert(api.is_viewed_file(path), "the viewed mark did not survive the new session")

pr.stop()
harness.done()
vim.cmd("qa!")
