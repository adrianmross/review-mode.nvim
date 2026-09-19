local M = {}

local health = vim.health or require("health")

local function call(name, ...)
  local fn = health[name] or health["report_" .. name]
  if fn then
    fn(...)
  end
end

local function command_exists(name)
  return vim.fn.exists(":" .. name) == 2
end

-- level: how bad a missing one is -- "error" when the review needs it
local function executable(name, level, why)
  if vim.fn.executable(name) == 1 then
    call("ok", name .. " executable found")
    return true
  end
  call(level or "error", name .. " executable not found" .. (why and (" (" .. why .. ")") or ""))
  return false
end

local function system_ok(args, ok_message, warn_message)
  local result = vim.system(args, { text = true }):wait()
  if result.code == 0 then
    call("ok", ok_message)
    return true
  end

  local detail = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
  if detail ~= "" then
    call("warn", warn_message .. ": " .. detail)
  else
    call("warn", warn_message)
  end
  return false
end

function M.check()
  call("start", "review-mode.nvim")

  -- vim.fs.relpath, which path handling throughout relies on, is 0.11
  if vim.fn.has("nvim-0.11") == 1 then
    call("ok", "Neovim 0.11+ detected")
  else
    call("error", "Neovim 0.11+ is required")
  end

  local has_git = executable("git")

  -- Only the forge this checkout reviews against needs its CLI: a missing gh
  -- is not an error for a GitLab or local review, nor glab for a GitHub one.
  -- Outside a checkout there is nothing to go by, so gh stays the one expected.
  -- pcall: vim.system throws on a missing cwd, and a health check must not
  local ok, probe = pcall(function()
    return vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
  end)
  local root = (has_git and ok and probe) or {}
  local provider = root.code == 0 and require("review_mode.providers").select(vim.trim(root.stdout)) or "github"
  for _, forge in ipairs({ { cli = "gh", provider = "github" }, { cli = "glab", provider = "gitlab" } }) do
    local needed = provider == forge.provider
    local why = needed and ("the " .. provider .. " provider uses it")
      or ("only the " .. forge.provider .. " provider uses it")
    if executable(forge.cli, needed and "error" or "warn", why) and needed then
      system_ok(
        { forge.cli, "auth", "status" },
        forge.cli .. " authentication available",
        forge.cli .. " authentication check failed"
      )
    end
  end

  if has_git then
    system_ok(
      { "git", "rev-parse", "--show-toplevel" },
      "current buffer is inside a git checkout",
      "not currently inside a git checkout"
    )
  end

  if pcall(require, "gitsigns") then
    call("ok", "optional gitsigns.nvim integration available")
  else
    call("warn", "optional gitsigns.nvim integration not found")
  end

  if pcall(require, "nvim-tree") then
    call("ok", "optional nvim-tree integration available")
  else
    call("warn", "optional nvim-tree integration not found")
  end

  if command_exists("ReviewMode") then
    call("ok", ":ReviewMode command registered")
  else
    call("warn", ":ReviewMode command not registered; call require('review_mode').setup()")
  end

  if command_exists("ReviewModeActions") then
    call("ok", ":ReviewModeActions command registered")
  else
    call("warn", ":ReviewModeActions command not registered; call require('review_mode').setup()")
  end
end

return M
