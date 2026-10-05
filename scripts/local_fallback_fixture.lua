-- fixture: gh GLAB_LOG={tmp}/glab.log
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

-- record every notification with its level, so an INFO fallback notice and an
-- ERROR can be told apart
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end

local function notified(needle, level)
  for _, note in ipairs(notes) do
    if note.msg:find(needle, 1, true) and (level == nil or note.level == level) then
      return true
    end
  end
  return false
end

local function reset()
  notes = {}
end

vim.fn.system({ "git", "checkout", "-q", "feature" })
assert(vim.v.shell_error == 0, "could not check out the feature branch for this fixture")

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

-- 1. no PR for the branch: an answer, so review locally and say so
vim.env.GH_REVIEW_PR = nil
vim.env.REVIEW_MODE_FIXTURE = "no_pr"
reset()
pr.start()
wait_for(function()
  return api.is_active() and api.session() and api.session().provider == "local"
end, "a branch with no PR did not fall back to a local review")
assert(notified('no PR for "feature"', vim.log.levels.INFO), "the fallback did not say why it went local")
assert(not notified("no pull requests found", vim.log.levels.ERROR), "the no-PR answer was reported as an error")
assert(pr.statusline():find(" local ", 1, true), "a local review's statusline reads like a PR: " .. pr.statusline())
assert(not pr.statusline():find("#", 1, true), "a local review's statusline still uses repo#ref: " .. pr.statusline())
pr.stop()

-- 2. a real failure must stay a failure. Falling back here would review a
--    branch that may well have a PR, minus its comments, and look like success.
vim.env.REVIEW_MODE_FIXTURE = "gh_auth_fail"
reset()
pr.start()
wait_for(function()
  return notified("Bad credentials", vim.log.levels.ERROR)
end, "an auth failure was not reported as an error")
vim.wait(300)
assert(not api.is_active(), "an auth failure left a session running")
assert(not notified("reviewing it locally"), "an auth failure fell back to a local review")
-- start installed its keys before it knew it would fail
assert(vim.fn.maparg("<leader>rt", "n") == "", "a failed start left the session keys installed")
assert(vim.fn.maparg("]c", "n", false, true).desc ~= "review-mode ]c", "a failed start left the mode keys installed")

-- 3. no_pr = "error" opts out: report there is no PR instead
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  no_pr = "error",
})
vim.env.REVIEW_MODE_FIXTURE = "no_pr"
reset()
pr.start()
wait_for(function()
  return notified("no pull requests found", vim.log.levels.ERROR)
end, 'no_pr = "error" did not report the missing PR')
vim.wait(300)
assert(not api.is_active(), 'no_pr = "error" still started a session')
assert(not notified("reviewing it locally"), 'no_pr = "error" still fell back')

-- 4. a named PR is a request for that PR, never a fallback candidate
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
vim.env.GH_REVIEW_PR = "123"
vim.env.REVIEW_MODE_FIXTURE = "no_pr"
reset()
pr.start()
wait_for(function()
  return notified("no pull requests found", vim.log.levels.ERROR)
end, "a named PR that failed was not reported")
vim.wait(300)
assert(not notified("reviewing it locally"), "a named PR fell back to a local review")
vim.env.GH_REVIEW_PR = nil
if api.is_active() then
  pr.stop()
end

-- 5. GitLab: glab's no-MR answer falls back the same way
local origin_url = vim.trim(vim.fn.system({ "git", "remote", "get-url", "origin" }))
vim.fn.system({ "git", "remote", "set-url", "origin", "https://gitlab.com/group/project.git" })
vim.env.REVIEW_MODE_FIXTURE = "no_mr"
reset()
pr.start()
wait_for(function()
  return api.is_active() and api.session() and api.session().provider == "local"
end, "a GitLab branch with no MR did not fall back to a local review: " .. vim.inspect(notes))
assert(not notified("no open merge request", vim.log.levels.ERROR), "the no-MR answer was reported as an error")
pr.stop()

-- 6. a remote on no GitHub host (Codeberg, Gitea, ...): no forge, so local
vim.fn.system({ "git", "remote", "set-url", "origin", "https://codeberg.org/someone/project.git" })
vim.env.REVIEW_MODE_FIXTURE = "unknown_host"
reset()
pr.start()
wait_for(function()
  return api.is_active() and api.session() and api.session().provider == "local"
end, "a non-GitHub remote did not fall back to a local review: " .. vim.inspect(notes))
assert(not notified("known GitHub host", vim.log.levels.ERROR), "gh's unknown-host answer was reported as an error")
pr.stop()
vim.fn.system({ "git", "remote", "set-url", "origin", origin_url })

vim.env.REVIEW_MODE_FIXTURE = nil
harness.done()
