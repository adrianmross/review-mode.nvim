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

local function executable(name)
  if vim.fn.executable(name) == 1 then
    call("ok", name .. " executable found")
    return true
  end
  call("error", name .. " executable not found")
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

  if vim.fn.has("nvim-0.10") == 1 then
    call("ok", "Neovim 0.10+ detected")
  else
    call("error", "Neovim 0.10+ is required")
  end

  local has_git = executable("git")
  local has_gh = executable("gh")

  if has_gh then
    system_ok({ "gh", "auth", "status" }, "gh authentication available", "gh authentication check failed")
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
