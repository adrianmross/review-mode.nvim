-- Which forge the review talks to.
--
-- GitHub is the default and its code stays where it always was. GitLab support
-- lives in review_mode.providers.gitlab, and the few places that reach a forge
-- (metadata, loading comments, posting, replying, resolving) branch to it when
-- state.provider is "gitlab".
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")

local state = core.state

--- The host of a git remote URL: https://, ssh:// and scp-style git@host:path.
function M.remote_host(url)
  local rest = tostring(url or ""):gsub("^[%w+.-]+://", ""):gsub("^[^@/]*@", "")
  local host = rest:match("^([^/:]+)")
  return host and host:lower() or nil
end

--- "gitlab" when the remote is on gitlab.com, a host with gitlab in its name, or
--- one of `hosts` (self-hosted instances); "github" otherwise.
function M.detect(url, hosts)
  local host = M.remote_host(url)
  if not host then
    return "github"
  end
  if host:find("gitlab", 1, true) then
    return "gitlab"
  end
  for _, candidate in ipairs(hosts or {}) do
    if M.remote_host(candidate) == host or tostring(candidate):lower() == host then
      return "gitlab"
    end
  end
  return "github"
end

--- Pick the provider for a review starting in `root`.
function M.select(root)
  local configured = state.config.provider
  if configured == "github" or configured == "gitlab" then
    return configured
  end
  -- a launcher's handoff says which forge it came from
  if util.env_value("GL_REVIEW_MR") then
    return "gitlab"
  end
  if util.env_value("GH_REVIEW_PR") then
    return "github"
  end
  local url = util.system({ "git", "remote", "get-url", "origin" }, { cwd = root })
  return M.detect(url, state.config.gitlab_hosts)
end

function M.is_gitlab()
  return state.provider == "gitlab"
end

--- The error for a GitHub-only feature used against GitLab. Notifies, calls
--- `callback(false, err)` when given, and returns the message.
function M.unsupported(feature, callback)
  local err = string.format("%s is not supported on GitLab yet", feature)
  vim.notify("Review Mode: " .. err, vim.log.levels.WARN)
  if callback then
    callback(false, err)
  end
  return err
end

return M
