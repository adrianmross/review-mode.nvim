local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local function wait_for(predicate, message)
  assert(vim.wait(10000, predicate, 20), message)
end

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = cwd }):wait()
  assert(result.code == 0, "git " .. table.concat(args, " ") .. ": " .. result.stderr)
  return vim.trim(result.stdout)
end

local function real(path)
  return vim.uv.fs_realpath(path) or path
end

local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level }
end
local function notified(text, level)
  for _, n in ipairs(notifications) do
    if n.msg:find(text, 1, true) and (level == nil or n.level == level) then
      return true
    end
  end
  return false
end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = false },
  viewed = { enabled = false },
  follow_head = false,
})

local events = {}
api.on("checkout_ready", function(ctx)
  events[#events + 1] = { name = "ready", ctx = ctx }
end)
api.on("checkout_removed", function(ctx)
  events[#events + 1] = { name = "removed", ctx = ctx }
end)

local user_repo = vim.uv.cwd()
local user_branch = git({ "rev-parse", "--abbrev-ref", "HEAD" })
local user_status = git({ "status", "--porcelain" })
local origin_tab = vim.api.nvim_get_current_tabpage()
-- the fixture repo's origin is "." so the PR ref it fetches lives here too
git({ "update-ref", "refs/pull/123/head", "feature" })
local feature_sha = git({ "rev-parse", "feature" })
local tree = vim.fs.joinpath(vim.fn.stdpath("cache"), "review-mode", "worktrees", "owner_repo", "pr-123")

local function review(target)
  local done, ok, result
  api.review_pr({ pr = target }, function(success, value)
    done, ok, result = true, success, value
  end)
  wait_for(function()
    return done
  end, "review_pr did not finish")
  assert(ok, "review_pr failed: " .. vim.inspect(result))
  wait_for(function()
    return api.is_changed_file("file.txt")
  end, "checkout review did not load changed files")
  return result
end

-- 1. checkout: a detached worktree at the cache path, at the PR head
local first = review("https://github.com/owner/repo/pull/123")
assert(vim.uv.fs_stat(tree), "worktree was not created at " .. tree)
assert(real(first.path) == real(tree), "worktree path " .. first.path .. " is not the cache path")
assert(git({ "rev-parse", "HEAD" }, tree) == feature_sha, "worktree is not at the PR head")
assert(first.head == feature_sha, "result head is not the fetched PR head")
assert(events[1] and events[1].name == "ready" and events[1].ctx.pr == "123", "checkout_ready was not emitted")

-- the user's checkout, branch and cwd are untouched
assert(git({ "rev-parse", "--abbrev-ref", "HEAD" }, user_repo) == user_branch, "user branch changed")
assert(git({ "status", "--porcelain" }, user_repo) == user_status, "user working tree changed")
assert(real(vim.fn.getcwd(-1, -1)) == real(user_repo), "global cwd changed")
assert(
  real(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(origin_tab))) == real(user_repo),
  "origin tab cwd changed"
)

-- the session lives in its own tab, rooted in the worktree, with a tab-local cwd
local review_tab = vim.api.nvim_get_current_tabpage()
assert(review_tab ~= origin_tab, "checkout review did not open its own tabpage")
assert(vim.fn.haslocaldir(-1, 0) == 1, "review tab has no tab-local cwd")
assert(real(vim.fn.getcwd()) == real(tree), "review tab cwd is not the worktree")
assert(real(api.session().root) == real(tree), "session root is not the worktree")
assert(api.session().pr == "123" and api.session().repo == "owner/repo", "session context not passed in")
wait_for(function()
  return vim.startswith(real(vim.api.nvim_buf_get_name(0)), real(tree) .. "/")
end, "changed file did not open from under the worktree")

-- stepping out returns to the user's tab and keeps the review tab
pr.leave()
assert(vim.api.nvim_get_current_tabpage() == origin_tab, "leaving did not return to the origin tab")
pr.enter()
assert(vim.api.nvim_get_current_tabpage() == review_tab, "entering did not return to the review tab")

-- 2. a second call reuses the tree
local second = review("123")
assert(second.reused and not second.dirty, "second checkout did not reuse the clean tree")
assert(real(api.session().root) == real(tree), "reused session root moved")
local listed = git({ "worktree", "list", "--porcelain" }, user_repo)
local _, tree_count = listed:gsub("pr%-123", "")
assert(tree_count == 1, "second checkout created another worktree")
assert(#vim.api.nvim_list_tabpages() == 2, "restarting a checkout review leaked a tabpage")

-- 3. a dirty tree is neither updated nor removed
vim.fn.writefile({ "my local edit" }, vim.fs.joinpath(tree, "file.txt"))
git({ "update-ref", "refs/pull/123/head", "main" })
local third = review("123")
assert(third.dirty, "dirty tree was not reported dirty")
assert(git({ "rev-parse", "HEAD" }, tree) == feature_sha, "dirty tree was moved to the new PR head")
assert(vim.fn.readfile(vim.fs.joinpath(tree, "file.txt"))[1] == "my local edit", "dirty edit was lost")
assert(notified("uncommitted changes", vim.log.levels.WARN), "dirty reuse did not warn")

local confirms = {}
vim.fn.confirm = function(prompt)
  confirms[#confirms + 1] = prompt
  return 1
end

-- the active review's tree is refused even if clean-looking, and dirty trees are refused
pr.stop()
assert(vim.api.nvim_get_current_tabpage() == origin_tab, "stop did not return to the origin tab")
notifications = {}
pr.checkout_clean()
assert(vim.uv.fs_stat(tree), "CheckoutClean removed a dirty tree")
assert(#confirms == 0, "CheckoutClean asked to remove a dirty tree")
assert(notified("uncommitted changes", vim.log.levels.WARN), "CheckoutClean did not say why it refused")

-- 4. a clean tree is removed only after confirmation
git({ "checkout", "--", "file.txt" }, tree)
vim.fn.confirm = function(prompt)
  confirms[#confirms + 1] = prompt
  return 2
end
pr.checkout_clean("123")
assert(#confirms == 1 and vim.uv.fs_stat(tree), "declining the confirmation still removed the tree")
vim.fn.confirm = function(prompt)
  confirms[#confirms + 1] = prompt
  return 1
end
pr.checkout_clean("123")
assert(#confirms == 2, "CheckoutClean did not confirm")
assert(not vim.uv.fs_stat(tree), "CheckoutClean did not remove the clean tree")
assert(events[#events].name == "removed" and events[#events].ctx.pr == "123", "checkout_removed was not emitted")

-- 5. prepare_checkout overrides where the tree comes from
git({ "update-ref", "refs/pull/123/head", "feature" })
local alt = vim.fs.joinpath(vim.fn.tempname(), "my-tool-tree")
local seen
pr.config().hooks.prepare_checkout = function(ctx)
  seen = ctx
  git({ "worktree", "add", "--detach", alt, ctx.ref }, ctx.root)
  return alt
end
local hooked = review("123")
assert(hooked.path == alt, "prepare_checkout path was not used")
assert(real(api.session().root) == real(alt), "session is not rooted at the hook's path")
assert(not vim.uv.fs_stat(tree), "default worktree was created despite the hook")
assert(seen.pr == "123" and seen.repo == "owner/repo" and seen.base == "main", "hook ctx is missing PR context")
assert(seen.head == feature_sha and seen.ref == "refs/review-mode/pr/123", "hook ctx is missing head/ref")
assert(real(seen.default_path) == real(tree) or seen.default_path == tree, "hook ctx default_path is wrong")
assert(real(seen.root) == real(user_repo), "hook ctx root is wrong")
pr.stop()
pr.config().hooks.prepare_checkout = nil
git({ "worktree", "remove", alt }, user_repo)
harness.done()
