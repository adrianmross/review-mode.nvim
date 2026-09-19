-- Which forge the review talks to.
--
-- GitHub is the default and its code stays where it always was. GitLab support
-- lives in review_mode.providers.gitlab, and the few places that reach a forge
-- (metadata, loading comments, posting, replying, resolving) branch to it when
-- state.provider is "gitlab".
--
-- "local" is the third: no forge at all, refs and comments both come off disk.
-- See review_mode.providers.local.
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
  if configured == "github" or configured == "gitlab" or configured == "local" then
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
  -- no remote, no forge to ask: review the local refs instead of failing on gh
  if not url then
    return "local"
  end
  return M.detect(url, state.config.gitlab_hosts)
end

-- What each forge's CLI says when there is nothing to review, matched narrowly
-- (see is_no_pr).
local no_pr_answers = {
  -- gh pr view on a branch without a PR
  "no pull requests found",
  -- glab mr view on a branch without an MR (glab's mrutils)
  "no open merge request available for",
  -- gh on a remote that is no GitHub host at all (Gitea, Bitbucket, Codeberg):
  -- there is no forge to ask, so the local refs are all there is
  "point to a known GitHub host",
}

--- True when a forge answered that the branch has no PR, as opposed to failing.
---
--- Both come back from `gh pr view` (or `glab mr view`) as exit 1, so the
--- wording is the only signal. That is the point of matching it narrowly: a
--- network error, an expired token or a rate limit must stay an error, because
--- falling back on one would quietly review a branch that does have a PR, minus
--- its comments.
function M.is_no_pr(err)
  if type(err) ~= "string" then
    return false
  end
  for _, answer in ipairs(no_pr_answers) do
    if err:find(answer, 1, true) then
      return true
    end
  end
  return false
end

function M.is_local()
  return state.provider == "local"
end

function M.is_gitlab()
  return state.provider == "gitlab"
end

-- how each non-GitHub provider finishes "X is not supported ..."
local unsupported_targets = { gitlab = "on GitLab yet", ["local"] = "in a local review" }

--- The error for a GitHub-only feature used against another provider. Notifies,
--- calls `callback(false, err)` when given, and returns the message.
function M.unsupported(feature, callback)
  local err = string.format("%s is not supported %s", feature, unsupported_targets[state.provider] or "here")
  vim.notify("Review Mode: " .. err, vim.log.levels.WARN)
  if callback then
    callback(false, err)
  end
  return err
end

return M
