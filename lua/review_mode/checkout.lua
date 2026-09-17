-- Review a PR without checking it out.
--
-- The PR head is fetched into a private ref and given a detached worktree of
-- its own under stdpath("cache"). The files are real files on disk, so LSP and
-- the rest of the ordinary-buffers model keep working, while the user's own
-- checkout, branch and working tree are never touched.
--
-- Safety rule for everything below: a worktree with uncommitted changes is
-- never updated and never removed. It is somebody's work.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

--- Accepts 123, "#123", or a https://github.com/owner/repo/pull/123 URL.
--- Returns pr, repo (repo from the URL unless one was given).
function M.parse_target(target, repo)
  target = vim.trim(tostring(target or ""))
  local url_repo, number = target:match("github%.com/([^/]+/[^/]+)/pull/(%d+)")
  if number then
    return number, repo or url_repo
  end
  return target:match("^#?(%d+)$"), repo
end

function M.base_dir()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "review-mode", "worktrees")
end

function M.ref(pr)
  return "refs/review-mode/pr/" .. pr
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

-- sync status check; "" means clean, nil means git failed
local function dirty_status(path)
  return util.system({ "git", "status", "--porcelain" }, { cwd = path })
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
    local status = dirty_status(path)
    if status == nil then
      return nil, "could not read status of " .. path
    end
    if status ~= "" then
      vim.notify(
        "Review Mode: " .. path .. " has uncommitted changes; reviewing it as-is, not updated to the PR head",
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
--- { path, repo, pr, base, head, ref, reused, dirty }.
---
--- opts.pr    number or URL
--- opts.repo  "owner/repo" (optional; defaults to the repo `gh` sees from root)
--- opts.root  the local clone to fetch into (defaults to the cwd's repo)
function M.prepare(opts, callback)
  if core.state.provider == "gitlab" then
    return callback(nil, require("review_mode.providers").unsupported("Reviewing in a separate checkout"))
  end
  opts = opts or {}
  coroutine.wrap(function()
    local pr, repo = M.parse_target(opts.pr, opts.repo)
    if not pr then
      return callback(nil, "expected a PR number or URL, got " .. tostring(opts.pr))
    end

    local root = opts.root or util.repo_root()
    if not root then
      return callback(nil, "not in a git repository")
    end

    local view = { "gh", "pr", "view", pr, "--json", "number,headRefOid,baseRefName,url" }
    if repo then
      vim.list_extend(view, { "--repo", repo })
    end
    local out, err = await(view, root)
    local ok, meta = pcall(vim.json.decode, out or "")
    if not ok or type(meta) ~= "table" then
      return callback(nil, err or "could not decode gh pr view output")
    end
    repo = repo or tostring(meta.url or ""):match("github%.com/([^/]+/[^/]+)/pull/") or "repo"
    local base = meta.baseRefName or "main"
    local ref = M.ref(pr)

    -- pull/<n>/head exists on the base repo for fork PRs too; "+" follows force-pushes
    err = select(2, await({ "git", "fetch", "--quiet", "origin", "+pull/" .. pr .. "/head:" .. ref }, root))
    if err then
      return callback(nil, err)
    end
    err = select(2, await({ "git", "fetch", "--quiet", "origin", base }, root))
    if err then
      return callback(nil, err)
    end
    local head = await({ "git", "rev-parse", ref }, root)

    local ctx = {
      repo = repo,
      pr = pr,
      head = head,
      base = base,
      ref = ref,
      root = root,
      default_path = vim.fs.joinpath(M.base_dir(), (repo:gsub("/", "_")), "pr-" .. pr),
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

    result = vim.tbl_extend("keep", result, { repo = repo, pr = pr, base = base, head = head, ref = ref })
    hooks.emit("checkout_ready", { path = result.path, pr = pr, head = head, repo = repo })
    callback(result, nil)
  end)()
end

--- Remove review worktrees under base_dir() (optionally only one PR's), after
--- a confirmation. Dirty trees and the tree the current review is rooted in
--- are refused and listed. Worktrees made by a prepare_checkout hook live
--- elsewhere and belong to whatever made them.
function M.clean(pr)
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
    local real = realpath(path)
    local name = vim.fs.basename(real)
    if vim.startswith(real, base) and (not pr or name == "pr-" .. pr) then
      local status = dirty_status(real)
      if real == session_root then
        refused[#refused + 1] = real .. ": the current review is using it (:ReviewModeStop first)"
      elseif status ~= "" then
        refused[#refused + 1] = real .. ": uncommitted changes\n" .. (status or "status unavailable")
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
      end
      hooks.emit("checkout_removed", { path = path, pr = number })
    end
  end
end

return M
