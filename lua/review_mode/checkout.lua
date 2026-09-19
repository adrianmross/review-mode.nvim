-- Review a PR without checking it out.
--
-- The PR head is fetched into a private ref and given a detached worktree of
-- its own under stdpath("cache"). The files are real files on disk, so LSP and
-- the rest of the ordinary-buffers model keep working, while the user's own
-- checkout, branch and working tree are never touched.
--
-- Safety rule for everything below: a worktree with uncommitted changes, or
-- with commits that are on neither the PR nor any remote (a trial suggestion
-- committed there, say), is never updated and never removed. It is somebody's
-- work, and moving HEAD off those commits would orphan them.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

--- Accepts 123, "#123", or a PR URL on any host (github.com or GitHub
--- Enterprise). Returns pr, repo (repo from the URL unless one was given) and
--- the URL's host.
function M.parse_target(target, repo)
  target = vim.trim(tostring(target or ""))
  local host, url_repo, number = target:match("^https?://([^/]+)/([^/]+/[^/]+)/pull/(%d+)")
  if number then
    return number, repo or url_repo, host
  end
  return target:match("^#?(%d+)$"), repo
end

function M.base_dir()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "review-mode", "worktrees")
end

function M.ref(pr)
  return "refs/review-mode/pr/" .. pr
end

--- Where the PR's base branch is fetched to: next to the head, and never a
--- remote-tracking branch, since the base repo need not be any remote.
function M.base_ref(pr)
  return "refs/review-mode/base/" .. pr
end

-- the shared .git of a clone (the main one, for a linked worktree too)
local function common_dir(path)
  local dir = util.system({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, { cwd = path })
  return dir and (vim.uv.fs_realpath(dir) or dir)
end

--- The default tree for a PR: per repo, and per local clone, so two clones of
--- one repo never share (or reuse) each other's tree.
function M.default_path(root, repo, pr)
  local clone = vim.fn.sha256(common_dir(root) or root):sub(1, 8)
  return vim.fs.joinpath(M.base_dir(), (repo:gsub("[/:]", "_")) .. "-" .. clone, "pr-" .. pr)
end

-- owner/repo of a remote URL (https, ssh:// or scp-style), lowercased
local function remote_slug(url)
  local path = url:match("^[%w+.-]+://[^/]+/(.+)$") or url:match("^[^/]+:(.+)$")
  return path and path:gsub("/$", ""):gsub("%.git$", ""):lower()
end

-- The base repo to fetch from: a remote that already points at it (so its
-- auth, ssh or not, keeps working), else its web URL.
local function fetch_source(root, host, repo)
  local remotes = util.system({ "git", "config", "--get-regexp", "^remote\\..*\\.url$" }, { cwd = root }) or ""
  local providers = require("review_mode.providers")
  for url in remotes:gmatch("%.url ([^\n]+)") do
    if providers.remote_host(url) == host:lower() and remote_slug(url) == repo:lower() then
      return url
    end
  end
  return string.format("https://%s/%s", host, repo)
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

-- sync status check; "" means clean, nil means git failed, otherwise what is
-- there: uncommitted changes, or commits reachable from HEAD but from none of
-- `refs` and no branch, tag or remote.
local function dirty_status(path, refs)
  local status = util.system({ "git", "status", "--porcelain" }, { cwd = path })
  if status ~= "" then
    return status and ("uncommitted changes\n" .. status)
  end
  -- on a branch, a tag or a remote, a commit outlives the tree; only commits on
  -- nothing but this detached HEAD would be orphaned
  local args = { "git", "log", "--oneline", "HEAD", "--not", "--branches", "--tags", "--remotes" }
  local commits = util.system(vim.list_extend(args, refs), { cwd = path })
  if commits == nil then
    return nil
  end
  return commits ~= "" and ("commits that are on no branch or remote and not in the PR\n" .. commits) or ""
end

-- run one command inside the coroutine, resuming when it finishes
local function await(args, cwd)
  local co = coroutine.running()
  util.system_async(args, { cwd = cwd }, function(out, err)
    local ok, failure = coroutine.resume(co, out, err)
    if not ok then
      error(failure)
    end
  end)
  return coroutine.yield()
end

local function default_worktree(ctx)
  local path = ctx.default_path
  if vim.uv.fs_stat(path) then
    -- only ever reuse a tree of this clone: another's has other refs and work
    local owner = common_dir(path)
    if owner ~= common_dir(ctx.root) then
      return nil, string.format("%s belongs to another clone (%s), not reusing it", path, owner or "not a git worktree")
    end
    -- the PR head it was last checked out at (ctx.prior) counts as the PR's own
    -- history, so a force-push alone does not make it look like local work
    local status = dirty_status(path, { ctx.ref, ctx.prior })
    if status == nil then
      return nil, "could not read status of " .. path
    end
    if status ~= "" then
      vim.notify(
        "Review Mode: " .. path .. " has " .. status .. "\nreviewing it as-is, not updated to the PR head",
        vim.log.levels.WARN
      )
      return { path = path, reused = true, dirty = true }
    end
    local _, err = await({ "git", "checkout", "--quiet", "--detach", ctx.ref }, path)
    if err then
      return nil, err
    end
    return { path = path, reused = true }
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- a tree deleted by hand leaves its registration behind and blocks the add
  await({ "git", "worktree", "prune" }, ctx.root)
  local _, err = await({ "git", "worktree", "add", "--detach", path, ctx.ref }, ctx.root)
  if err then
    return nil, err
  end
  return { path = path }
end

--- Fetch a PR and get a worktree for it. callback(result, err) where result is
--- { path, repo, pr, base, base_ref, head, ref, reused, dirty }.
---
--- opts.pr    number or URL (any GitHub host)
--- opts.repo  "owner/repo" or "host/owner/repo" (optional; defaults to the
---            repo `gh` sees from root)
--- opts.root  the local clone to fetch into (defaults to the cwd's repo)
function M.prepare(opts, callback)
  opts = opts or {}
  local root = opts.root or util.repo_root()
  if not root then
    return callback(nil, "not in a git repository")
  end
  if require("review_mode.providers").select(root) == "gitlab" then
    return callback(nil, "Reviewing in a separate checkout is not supported on GitLab yet")
  end
  coroutine.wrap(function()
    local pr, repo, host = M.parse_target(opts.pr, opts.repo)
    if not pr then
      return callback(nil, "expected a PR number or URL, got " .. tostring(opts.pr))
    end

    local view = { "gh", "pr", "view", pr, "--json", "number,headRefOid,baseRefName,url" }
    if repo then
      -- gh reads HOST/OWNER/REPO, so an Enterprise URL asks its own host
      vim.list_extend(view, { "--repo", host and (host .. "/" .. repo) or repo })
    end
    local out, err = await(view, root)
    local ok, meta = pcall(vim.json.decode, out or "")
    if not ok or type(meta) ~= "table" then
      return callback(nil, err or "could not decode gh pr view output")
    end
    -- the PR's own URL names the repo it lives in, which is where to fetch from
    host, repo = tostring(meta.url or ""):match("^https?://([^/]+)/([^/]+/[^/]+)/pull/%d+")
    if not repo or type(meta.headRefOid) ~= "string" then
      return callback(nil, "gh pr view did not return the PR's url and head")
    end
    local base = meta.baseRefName or "main"
    local ref, base_ref = M.ref(pr), M.base_ref(pr)

    -- where the PR head was before this fetch moves it (see default_worktree)
    local prior = util.system({ "git", "rev-parse", "--verify", "--quiet", ref }, { cwd = root })

    -- pull/<n>/head exists on the base repo for fork PRs too; "+" follows
    -- force-pushes. The base repo, not origin: origin may be a fork, or another
    -- repo altogether when the PR came from the inbox or a URL.
    err = select(
      2,
      await({
        "git",
        "fetch",
        "--quiet",
        fetch_source(root, host, repo),
        "+refs/pull/" .. pr .. "/head:" .. ref,
        "+refs/heads/" .. base .. ":" .. base_ref,
      }, root)
    )
    if err then
      return callback(nil, err)
    end
    local head = await({ "git", "rev-parse", ref }, root)
    if head ~= meta.headRefOid then
      return callback(
        nil,
        string.format("fetched %s for %s#%s, but its head is %s: not reviewing it", head, repo, pr, meta.headRefOid)
      )
    end

    local ctx = {
      repo = repo,
      pr = pr,
      head = head,
      base = base,
      ref = ref,
      root = root,
      prior = prior,
      default_path = M.default_path(root, repo, pr),
    }

    local result
    local path = hooks.resolve("prepare_checkout", ctx, nil)
    if path ~= nil then
      result = { path = path }
    else
      result, err = default_worktree(ctx)
      if not result then
        return callback(nil, err)
      end
    end

    result =
      vim.tbl_extend("keep", result, { repo = repo, pr = pr, base = base, base_ref = base_ref, head = head, ref = ref })
    hooks.emit("checkout_ready", { path = result.path, pr = pr, head = head, repo = repo })
    callback(result, nil)
  end)()
end

--- Remove review worktrees under base_dir() (optionally only one PR's), after
--- a confirmation. Dirty trees and the tree the current review is rooted in
--- are refused and listed. Worktrees made by a prepare_checkout hook live
--- elsewhere and belong to whatever made them.
function M.clean(pr)
  if pr ~= nil then
    local number = M.parse_target(pr)
    if not number then
      vim.notify("Review Mode: expected a PR number or URL, got " .. tostring(pr), vim.log.levels.ERROR)
      return
    end
    pr = number
  end
  local root = util.repo_root()
  local list = root and util.system({ "git", "worktree", "list", "--porcelain" }, { cwd = root })
  if not list then
    vim.notify("Review Mode: not in a git repository", vim.log.levels.ERROR)
    return
  end

  local base = realpath(M.base_dir()) .. "/"
  local session_root = core.state.active and core.state.root and realpath(core.state.root)
  local removable, refused = {}, {}
  for path in list:gmatch("worktree ([^\n]+)") do
    local gone = not vim.uv.fs_stat(path)
    -- a gone tree has no realpath of its own, but its parent usually still does
    local real = gone and vim.fs.joinpath(realpath(vim.fs.dirname(path)), vim.fs.basename(path)) or realpath(path)
    local name = vim.fs.basename(real)
    local ours = vim.startswith(real, base) and (not pr or name == "pr-" .. pr)
    if ours and gone then
      -- deleted by hand: no status to read, and git keeps only its registration
      refused[#refused + 1] = real .. ": prunable, the directory is gone (`git worktree prune` clears it)"
    elseif ours then
      local number = name:match("^pr%-(%d+)$")
      -- a tree whose name does not say which PR it holds excludes no PR ref, so
      -- any commit on nothing but its HEAD still counts (excluding "HEAD" here
      -- would exclude the very commits at risk)
      local status = dirty_status(real, number and { M.ref(number) } or {})
      if real == session_root then
        refused[#refused + 1] = real .. ": the current review is using it (:ReviewModeStop first)"
      elseif status ~= "" then
        refused[#refused + 1] = real .. ": " .. (status or "status unavailable")
      else
        removable[#removable + 1] = real
      end
    end
  end

  if #refused > 0 then
    vim.notify("Review Mode: not removing\n" .. table.concat(refused, "\n"), vim.log.levels.WARN)
  end
  if #removable == 0 then
    vim.notify("Review Mode: no clean review worktrees to remove")
    return
  end

  local prompt = "Remove review worktrees?\n" .. table.concat(removable, "\n")
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end

  for _, path in ipairs(removable) do
    -- no --force: git refuses a tree that became dirty since the check
    local _, err = util.system({ "git", "worktree", "remove", path }, { cwd = root })
    if err then
      vim.notify("Review Mode: " .. err, vim.log.levels.ERROR)
    else
      local number = vim.fs.basename(path):match("^pr%-(%d+)$")
      if number then
        util.system({ "git", "update-ref", "-d", M.ref(number) }, { cwd = root })
        util.system({ "git", "update-ref", "-d", M.base_ref(number) }, { cwd = root })
      end
      hooks.emit("checkout_removed", { path = path, pr = number })
    end
  end
end

return M
