-- fixture: gh pr
-- How a session begins and ends: setup against the plugin file, the key layers
-- handing back the user's own mappings, one teardown for stop, restart and a
-- failed start, a missing gh, signs_when_out, the statusline and :checkhealth.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for
local root = os.getenv("REVIEW_MODE_PLUGIN_ROOT")

local notifications = {}
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = tostring(message), level = level }
end
local function notified(fragment, level)
  for _, note in ipairs(notifications) do
    if note.message:find(fragment, 1, true) and (not level or note.level == level) then
      return true
    end
  end
  return false
end

-- A PATH with git on it and nothing else: no gh, no glab.
local git_only = vim.fn.tempname()
vim.fn.mkdir(git_only, "p")
vim.uv.fs_symlink(vim.fn.exepath("git"), git_only .. "/git")
local real_path = vim.env.PATH

local pr = require("review_mode")
local api = require("review_mode.api")

-- setup, then the plugin file ---------------------------------------------------
-- A native pack/*/start install sources plugin/ after init.lua has called
-- setup({ ... }); the file's own setup() must not put the defaults back.
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
  mode = { signs_when_out = false },
})
dofile(root .. "/plugin/review-mode.lua")
assert(api.config().mode.signs_when_out == false, "plugin/review-mode.lua reset the user's setup() to the defaults")

-- :checkhealth ---------------------------------------------------------------------
local reports = {}
for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
  vim.health[level] = function(message)
    reports[#reports + 1] = { level = level, message = message }
  end
end
local function reported(level, fragment)
  for _, report in ipairs(reports) do
    if report.level == level and report.message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

vim.env.PATH = git_only
api.config().provider = "local"
require("review_mode.health").check()
assert(reported("ok", "Neovim 0.11+"), "health did not check for Neovim 0.11")
assert(not reported("error", "gh executable"), "health called a missing gh an error for a local review")
assert(reported("warn", "gh executable not found"), "health did not mention the missing gh")
assert(reported("warn", "glab executable not found"), "health never checked for glab")

reports = {}
api.config().provider = "github"
require("review_mode.health").check()
assert(reported("error", "gh executable not found"), "a GitHub review without gh is an error")
assert(reported("warn", "glab executable not found"), "glab is only a warning for a GitHub review")
assert(not reported("error", "glab"), "a GitHub review does not need glab")
api.config().provider = "auto"
vim.env.PATH = real_path

-- Key layers give back the user's own mappings ----------------------------------------
-- gitsigns maps ]c per buffer; the global ]c is the user's. Leaving must put the
-- global one back, and never copy the buffer's mapping into another buffer.
vim.keymap.set("n", "]c", "<Nop>", { desc = "user ]c" })
vim.keymap.set("n", "<leader>rt", "<Nop>", { desc = "user <leader>rt" })
-- named, or :edit would reuse the empty startup buffer and drop its mappings
vim.bo.buftype = "nofile"
vim.api.nvim_buf_set_name(0, "gitsigns-buffer")
local gitsigns_buf = vim.api.nvim_get_current_buf()
vim.keymap.set("n", "]c", "<Nop>", { buffer = gitsigns_buf, desc = "gitsigns ]c" })
vim.keymap.set("n", "<leader>rt", "<Nop>", { buffer = gitsigns_buf, desc = "buffer <leader>rt" })

local function global_desc(lhs)
  local raw = vim.fn.maparg(lhs, "n", false, true).lhsraw
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.lhsraw == raw then
      return map.desc
    end
  end
  return nil
end
local function buffer_desc(bufnr, lhs)
  local raw = vim.fn.maparg(lhs, "n", false, true).lhsraw
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if map.lhsraw == raw then
      return map.desc
    end
  end
  return nil
end

local stops = 0
api.on("stop", function()
  stops = stops + 1
end)

pr.start()
wait_for(function()
  return api.is_active() and api.is_changed_file("file.txt") and api.comment_count("file.txt") > 0
end, "the review did not load")
assert(global_desc("]c") ~= "user ]c", "the mode layer did not take ]c")

-- signs_when_out = false: stepping out hides the signs, and entering a buffer
-- afterwards must not draw them back
local ns = vim.api.nvim_create_namespace("review_mode_normal")
vim.cmd.edit("file.txt")
local file_buf = vim.api.nvim_get_current_buf()
local function marks()
  return #vim.api.nvim_buf_get_extmarks(file_buf, ns, 0, -1, {})
end
wait_for(function()
  return marks() > 0
end, "no comment signs in file.txt")
pr.leave()
assert(marks() == 0, "leave() did not clear the signs")
vim.cmd.edit("nested/other.txt")
vim.cmd.edit("file.txt")
vim.wait(100)
assert(marks() == 0, "signs came back on BufEnter with mode.signs_when_out = false")
pr.enter()
wait_for(function()
  return marks() > 0
end, "entering the mode did not bring the signs back")

-- the statusline's percent reads the stats, never the comment lists
local counted = 0
local unresolved_count = api.unresolved_count
api.unresolved_count = function(...)
  counted = counted + 1
  return unresolved_count(...)
end
local line = pr.statusline()
api.unresolved_count = unresolved_count
assert(counted == 0, "the statusline counted comments " .. counted .. " times")
local weight, done = 0, 0
for _, file in ipairs(api.files()) do
  local lines = math.max(file.added + file.removed, 1)
  weight, done = weight + lines, done + lines * api.review_fraction(file.path)
end
local expected = math.floor(done / weight * 100)
assert(api.review_percent() == expected, "review_percent changed: " .. api.review_percent() .. " vs " .. expected)
assert(line:find(" " .. expected .. "%%"), "statusline percent wrong: " .. line)

-- a restart ends the running session the way :ReviewModeStop does
stops = 0
pr.start()
assert(stops == 1, "restarting while active skipped the stop teardown")
wait_for(function()
  return api.is_active() and api.is_changed_file("file.txt")
end, "the restarted review did not load")

-- end the review from a buffer that never had a ]c of its own
vim.cmd.enew()
local other_buf = vim.api.nvim_get_current_buf()
notifications = {}
pr.stop()
assert(global_desc("]c") == "user ]c", "stop lost the user's global ]c: " .. tostring(global_desc("]c")))
assert(global_desc("<leader>rt") == "user <leader>rt", "stop lost the user's global <leader>rt")
assert(buffer_desc(other_buf, "]c") == nil, "stop copied gitsigns' buffer ]c into another buffer")
assert(buffer_desc(other_buf, "<leader>rt") == nil, "stop copied a buffer <leader>rt into another buffer")
assert(buffer_desc(gitsigns_buf, "]c") == "gitsigns ]c", "gitsigns' own buffer ]c was lost")
assert(vim.g.review_mode == nil, "stop left vim.g.review_mode set")

-- stopping with nothing running is quiet
stops = 0
notifications = {}
pr.stop()
assert(stops == 0, "stop with no session emitted ReviewModeStop")
assert(not notified("stopped"), "stop with no session said it stopped")

-- A start that fails ------------------------------------------------------------------
-- No base in the env, so the session waits on gh for it, and gh fails auth.
local saved_env = { base = vim.env.GH_REVIEW_BASE, head = vim.env.GH_REVIEW_HEAD }
vim.env.GH_REVIEW_BASE, vim.env.GH_REVIEW_HEAD = nil, nil
vim.env.REVIEW_MODE_FIXTURE = "gh_auth_fail"
notifications = {}
pr.start()
wait_for(function()
  return not api.is_active() and notified("Bad credentials", vim.log.levels.ERROR)
end, "the failed start did not report")
assert(vim.g.review_mode == nil, "a failed start left vim.g.review_mode = " .. tostring(vim.g.review_mode))
assert(stops == 1, "a failed start announced ReviewModeStart with no ReviewModeStop")
assert(global_desc("]c") == "user ]c", "a failed start left its ]c behind")
vim.env.REVIEW_MODE_FIXTURE = nil

-- No gh at all: a clean error, not a Lua error halfway through start
vim.env.PATH = git_only
notifications = {}
local ok, err = pcall(pr.start)
assert(ok, "start threw without gh on PATH: " .. tostring(err))
wait_for(function()
  return not api.is_active() and notified("Review Mode:", vim.log.levels.ERROR)
end, "a start without gh did not report")
assert(vim.g.review_mode == nil, "a start without gh left vim.g.review_mode set")
assert(global_desc("]c") == "user ]c", "a start without gh left its ]c behind")
vim.env.PATH = real_path
vim.env.GH_REVIEW_BASE, vim.env.GH_REVIEW_HEAD = saved_env.base, saved_env.head

vim.fn.delete(git_only, "rf")
print("session lifecycle fixture passed")
harness.done()
