-- fixture: gh REVIEW_MODE_STARTUP_GH_DELAY=3
-- fixture: gh pr REVIEW_MODE_STARTUP_GH_DELAY=3
-- Time to first comment sign on a warm cache.
--
-- The first start fills the on-disk comment cache. The second one runs against
-- the same XDG_CACHE_HOME with every gh call made slow (REVIEW_MODE_GH_DELAY),
-- so a sign that shows up inside the budget can only have come from the cache:
-- waiting on gh would cost the whole delay. The budget is deliberately loose
-- (REVIEW_MODE_STARTUP_BUDGET_MS); it catches "waits on the network", not noise.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local delay = assert(tonumber(os.getenv("REVIEW_MODE_STARTUP_GH_DELAY")), "REVIEW_MODE_STARTUP_GH_DELAY is required")
local budget_ms = tonumber(os.getenv("REVIEW_MODE_STARTUP_BUDGET_MS") or "") or 500
assert(budget_ms < delay * 1000, "the budget must sit below the gh delay, or it cannot tell cache from network")

local pr = require("review_mode")
local api = require("review_mode.api")
local github = require("review_mode.github")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

vim.cmd.edit("file.txt")
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_create_namespace("review_mode_normal")

local function has_sign()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].sign_text then
      return true
    end
  end
  return false
end

-- The branch pointer is named by a hash, not by cache_path's lossy sanitizing.
assert(
  github.cache_path(github.branch_pointer("/a/b", "c")) ~= github.cache_path(github.branch_pointer("/a_b", "c")),
  "roots that sanitize alike must not share a branch pointer"
)
assert(
  #vim.fs.basename(github.cache_path(github.branch_pointer("/" .. string.rep("d", 300), "feature"))) < 255,
  "a deep root must not overflow the pointer's filename"
)

-- Cold: nothing cached, gh answers at full speed. Waits for the metadata too:
-- that is when the branch remembers its PR.
pr.start()
assert(
  vim.wait(5000, function()
    return api.comment_count("file.txt") > 0 and has_sign() and state.metadata_loaded
  end, 5),
  "cold start never placed a comment sign"
)
pr.stop()
assert(not has_sign(), "stop must clear the signs, or the warm run measures nothing")

-- Warm: same cache, slow gh.
vim.env.REVIEW_MODE_GH_DELAY = tostring(delay)

local function warm(label)
  local started = vim.uv.hrtime()
  pr.start()
  local placed = vim.wait(delay * 1000 + 5000, has_sign, 5)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  pr.stop()

  print(
    string.format(
      "startup budget: first comment sign on a warm cache (%s) in %.1f ms (budget %d ms, gh delay %ss)",
      label,
      elapsed_ms,
      budget_ms,
      delay
    )
  )
  assert(placed, "warm start never placed a comment sign")
  assert(
    elapsed_ms < budget_ms,
    string.format(
      "warm start (%s) took %.1f ms to its first comment sign, over the %d ms budget",
      label,
      elapsed_ms,
      budget_ms
    )
  )
end

if vim.env.GH_REVIEW_PR then
  warm("GH_REVIEW_*")
  -- A GH_REVIEW_* start must still teach the branch its PR, or a later plain
  -- start on the same branch waits on gh.
  for _, name in ipairs({ "GH_REVIEW_REPO", "GH_REVIEW_PR", "GH_REVIEW_BASE", "GH_REVIEW_HEAD" }) do
    vim.env[name] = nil
  end
  warm("discovery after a GH_REVIEW_* start")
else
  warm("discovery")
end
harness.done()
