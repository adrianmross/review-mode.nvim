-- fixture: gh REVIEW_MODE_PR_VIEW_LOG={tmp}/gh.log
-- Checkouts across forges and clones: a PR in another repo (or from a fork) is
-- fetched from that repo and checked against the head GitHub reports; GitHub
-- Enterprise URLs parse; two clones never share a tree; clean survives a tree
-- deleted by hand. Builds its own repos; gh is scripts/mock/gh.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local pr_view_log = assert(os.getenv("REVIEW_MODE_PR_VIEW_LOG"), "REVIEW_MODE_PR_VIEW_LOG is required")

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
local function notified(text)
  for _, n in ipairs(notifications) do
    if n.msg:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function init(dir)
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q" }, dir)
  git({ "config", "core.hooksPath", dir .. "/.nohooks" }, dir)
  git({ "checkout", "-q", "-B", "main" }, dir)
end

local top = vim.fn.tempname()
-- the base repo (other/repo on the forge): main, and a PR head under pull/
local base_repo = top .. "/base"
init(base_repo)
vim.fn.writefile({ "one", "two" }, base_repo .. "/file.txt")
git({ "add", "." }, base_repo)
git({ "commit", "-q", "-m", "base" }, base_repo)
git({ "checkout", "-q", "-b", "feature" }, base_repo)
vim.fn.writefile({ "one", "two", "three" }, base_repo .. "/file.txt")
git({ "commit", "-q", "-am", "feature" }, base_repo)
git({ "update-ref", "refs/pull/123/head", "feature" }, base_repo)
git({ "checkout", "-q", "main" }, base_repo)
local pr_head, base_main = git({ "rev-parse", "feature" }, base_repo), git({ "rev-parse", "main" }, base_repo)

-- the user's fork: origin is the fork, which has no pull refs and another main
local fork = top .. "/fork"
init(fork)
vim.fn.writefile({ "fork" }, fork .. "/fork.txt")
git({ "add", "." }, fork)
git({ "commit", "-q", "-m", "fork" }, fork)

-- two clones of it, with the same basename
local function clone(dir)
  git({ "clone", "-q", base_repo, dir })
  git({ "config", "core.hooksPath", dir .. "/.nohooks" }, dir)
  git({ "remote", "set-url", "origin", fork }, dir)
  git({ "fetch", "-q", "origin" }, dir)
  -- the forge's URLs, answered by the base repo
  git({ "config", "url." .. base_repo .. ".insteadOf", "https://github.com/other/repo" }, dir)
  git({ "config", "--add", "url." .. base_repo .. ".insteadOf", "https://ghe.example.com/owner/repo" }, dir)
  return dir
end
local clone_a = clone(top .. "/a/clone")
local clone_b = clone(top .. "/b/clone")

local pr = require("review_mode")
local api = require("review_mode.api")
local core = require("review_mode.state")
local checkout = require("review_mode.checkout")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = false },
  viewed = { enabled = false },
  follow_head = false,
})

local function review(target, root)
  local done, ok, result
  api.review_pr({ pr = target, root = root }, function(success, value)
    done, ok, result = true, success, value
  end)
  wait_for(function()
    return done
  end, "review_pr did not finish")
  return ok, result
end

vim.env.REVIEW_MODE_PR_REPO_DIR = base_repo

-- 1. a PR in another repo, with origin a fork: fetched from the PR's repo
vim.env.REVIEW_MODE_PR_URL = "https://github.com/other/repo/pull/123"
local ok, result = review("https://github.com/other/repo/pull/123", clone_a)
assert(ok, "cross-repo checkout failed: " .. vim.inspect(result))
assert(git({ "rev-parse", "HEAD" }, result.path) == pr_head, "tree is not at the PR head")
assert(api.session().repo == "other/repo", "session repo: " .. tostring(api.session().repo))
-- the base comes from the PR's repo too, into a ref of its own
assert(api.base_ref() == "refs/review-mode/base/123", "base ref: " .. api.base_ref())
assert(git({ "rev-parse", "refs/review-mode/base/123" }, clone_a) == base_main, "base was not fetched from the PR repo")
wait_for(function()
  return api.is_changed_file("file.txt")
end, "the cross-repo review did not load its changes")
local tree_a = result.path
pr.stop()

-- 2. a head that is not the one GitHub reports is refused
vim.env.REVIEW_MODE_HEAD_OID = string.rep("0", 40)
notifications = {}
ok, result = review("123", clone_a)
assert(not ok, "a checkout whose head does not match headRefOid was accepted")
assert(tostring(result):find("its head is " .. string.rep("0", 40), 1, true), "mismatch error: " .. tostring(result))
vim.env.REVIEW_MODE_HEAD_OID = nil

-- 3. GitHub Enterprise: a URL on any host parses, gh is asked on that host,
-- and a bare number takes its repo from gh's URL, never a placeholder
vim.env.REVIEW_MODE_PR_URL = "https://ghe.example.com/owner/repo/pull/123"
assert(select(2, checkout.parse_target("https://ghe.example.com/owner/repo/pull/123")) == "owner/repo", "GHE parse")
ok, result = review("https://ghe.example.com/owner/repo/pull/123", clone_b)
assert(ok, "GHE checkout failed: " .. vim.inspect(result))
local view_args = table.concat(vim.fn.readfile(pr_view_log), "\n")
assert(view_args:find("--repo ghe.example.com/owner/repo", 1, true), "gh was not asked on the GHE host: " .. view_args)
assert(api.session().repo == "owner/repo", "GHE session repo: " .. tostring(api.session().repo))
pr.stop()
ok, result = review("123", clone_b)
assert(ok and result.repo == "owner/repo", "a bare number did not take gh's repo: " .. vim.inspect(result))
pr.stop()
-- a repo already given as host/owner/repo is not qualified twice
vim.fn.writefile({}, pr_view_log)
local qualified_done
api.review_pr(
  { pr = "https://ghe.example.com/owner/repo/pull/123", repo = "ghe.example.com/owner/repo", root = clone_b },
  function()
    qualified_done = true
  end
)
wait_for(function()
  return qualified_done
end, "review_pr with a qualified repo did not finish")
view_args = table.concat(vim.fn.readfile(pr_view_log), "\n")
assert(not view_args:find("ghe.example.com/ghe.example.com", 1, true), "gh --repo named the host twice: " .. view_args)
pr.stop()

-- cache keys: a host without a dot still scopes the key; a path remote names none
local function key_for(remote)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "remote", "add", "origin", remote })
  local s = core.state
  local saved = { s.root, s.provider, s.repo, s.pr }
  s.root, s.provider, s.repo, s.pr = dir, "github", "owner/repo", "7"
  local key = core.cache_key()
  s.root, s.provider, s.repo, s.pr = saved[1], saved[2], saved[3], saved[4]
  return key
end
local localhost_key, intranet_key = key_for("http://localhost/owner/repo"), key_for("git@intranet:owner/repo")
assert(localhost_key ~= intranet_key, "dotless hosts share a cache key: " .. localhost_key .. " / " .. intranet_key)
assert(localhost_key:find("localhost", 1, true), "a dotless host was dropped from the key: " .. localhost_key)
assert(key_for("../other-clone") == "owner/repo#7", "a path remote was read as a host: " .. key_for("../other-clone"))
assert(key_for("https://github.com/owner/repo") == "owner/repo#7", "github.com keys changed")

-- 4. two clones of one repo get their own trees, and never reuse another's
local path_a, path_b = checkout.default_path(clone_a, "owner/repo", "123"), result.path
assert(real(path_a) ~= real(path_b), "two clones share a tree: " .. path_a)
-- clone_b's tree registered at clone_a's path: not clone_a's to reuse
git({ "worktree", "add", "-q", "--detach", path_a, pr_head }, clone_b)
ok, result = review("123", clone_a)
assert(not ok and tostring(result):find("belongs to another clone", 1, true), "reused another clone's tree")
git({ "worktree", "remove", "--force", path_a }, clone_b)

-- 5. clean: "#123" is PR 123, and a tree deleted by hand is reported, not a crash
vim.cmd.cd(clone_b)
local prompts = {}
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return 2
end
pr.checkout_clean("#123")
assert(#prompts == 1 and prompts[1]:find("pr-123", 1, true), "clean did not read #123 as PR 123")
vim.fn.delete(path_b, "rf")
notifications = {}
pr.checkout_clean()
assert(notified("prunable"), "a tree deleted by hand was not reported as prunable")
pr.checkout_clean("nope")
assert(notified("expected a PR number or URL"), "a bad target cleaned every tree")
vim.fn.confirm = function()
  error("unexpected confirm")
end

-- 6. a GitLab repo refuses the checkout by its own remote, with no session
git({ "remote", "set-url", "origin", "https://gitlab.com/group/project.git" }, clone_a)
ok, result = review("1", clone_a)
assert(not ok and tostring(result):find("GitLab", 1, true), "checkout ran in a GitLab repo: " .. tostring(result))
git({ "remote", "set-url", "origin", fork }, clone_a)

-- 7. local reviews: a typo'd head is an error, and two clones of one branch
-- keep their viewed state apart
local local_provider = require("review_mode.providers.local")
local resolved, err = local_provider.resolve({ "main", "mian-typo" }, clone_a)
assert(not resolved and err:find("mian-typo", 1, true), "a typo'd head was accepted: " .. vim.inspect(resolved))
local keys = {}
for _, dir in ipairs({ clone_a, clone_b }) do
  pr.start({ provider = "local", local_args = { "main" }, root = dir })
  keys[#keys + 1] = core.cache_key()
  pr.stop()
end
assert(keys[1] and keys[1] ~= keys[2], "two clones share a local review key: " .. vim.inspect(keys))

-- 8. the base ref: a branch that starts with hex digits is still a branch
local saved = { base = core.state.base, base_ref = core.state.base_ref }
core.state.base_ref, core.state.base = nil, "20250101-release"
assert(core.base_ref() == "origin/20250101-release", "hex-led branch read as a SHA: " .. core.base_ref())
core.state.base = base_main
assert(core.base_ref() == base_main, "a full SHA is not a branch")
core.state.base, core.state.base_ref = saved.base, saved.base_ref

vim.fn.delete(tree_a, "rf")
harness.done()
