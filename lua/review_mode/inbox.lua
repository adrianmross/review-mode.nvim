-- The review inbox: open PRs in this repo that are waiting on you, in the action
-- picker, each one reviewed in its own worktree when chosen. Needs no session.
--
-- One `gh pr list` call answers the lot, CI state included (statusCheckRollup),
-- so the inbox costs the same with one PR or thirty.
--
-- Built on review_mode.api like the rest of the bundled UI.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")
local picker = require("review_mode.picker")

M.scopes = {
  requested = "review-requested:@me",
  mine = "author:@me",
  all = false,
}

local FIELDS = "number,title,author,additions,deletions,updatedAt,isDraft,url,statusCheckRollup"

local failed = {
  FAILURE = true,
  ERROR = true,
  TIMED_OUT = true,
  CANCELLED = true,
  ACTION_REQUIRED = true,
  STARTUP_FAILURE = true,
}

--- "✗" if any check failed, "…" if any is still running, "✓" if all passed,
--- "" with no checks. Check runs carry status/conclusion, commit statuses state.
function M.ci_symbol(rollup)
  if type(rollup) ~= "table" or #rollup == 0 then
    return ""
  end
  local pending = false
  for _, check in ipairs(rollup) do
    local result = check.conclusion or check.state
    if failed[result] then
      return "✗"
    end
    if (check.status and check.status ~= "COMPLETED") or result == "PENDING" or result == "EXPECTED" then
      pending = true
    end
  end
  return pending and "…" or "✓"
end

--- "5m", "3h" or "2d" since an ISO-8601 UTC timestamp.
function M.age(iso, now)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  -- both sides read as local time, so the zone offset cancels
  local seconds = (now or os.time(os.date("!*t")))
    - os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
  if seconds < 3600 then
    return math.max(0, math.floor(seconds / 60)) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function item(pr)
  local author = type(pr.author) == "table" and pr.author.login or "?"
  local label = string.format(
    "%6s %6s %-1s %4s %s%s (@%s)",
    "+" .. (pr.additions or 0),
    "−" .. (pr.deletions or 0),
    M.ci_symbol(pr.statusCheckRollup),
    M.age(pr.updatedAt),
    pr.isDraft and "[draft] " or "",
    pr.title or "",
    author
  )
  return {
    category = "#" .. pr.number,
    label = label,
    pr = pr,
    run = function()
      -- the URL carries owner/repo, so the checkout needs no second lookup
      api.review_pr({ pr = pr.url or pr.number })
    end,
  }
end

--- The gh arguments for a scope ("requested", "mine" or "all").
function M.args(scope)
  local args = { "pr", "list", "--state", "open", "--json", FIELDS }
  local search = M.scopes[scope]
  if search then
    vim.list_extend(args, { "--search", search })
  end
  local session = api.session()
  local repo = (session and session.provider == "github" and session.repo) or util.env_value("GH_REVIEW_REPO")
  if repo then
    vim.list_extend(args, { "--repo", repo })
  end
  return args
end

--- Open the inbox. scope defaults to "requested".
function M.open(scope)
  scope = (scope == nil or scope == "") and "requested" or scope
  if M.scopes[scope] == nil then
    vim.notify("Review Mode inbox: unknown scope " .. tostring(scope), vim.log.levels.ERROR)
    return
  end
  local session = api.session()
  if session and session.provider == "gitlab" then
    vim.notify("Review Mode: the review inbox is GitHub-only; this review is on GitLab", vim.log.levels.WARN)
    return
  end
  util.gh_json_async(M.args(scope), function(prs, err)
    if type(prs) ~= "table" then
      vim.notify("Review Mode inbox: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if #prs == 0 then
      vim.notify(
        scope == "requested" and "Review Mode: no PRs waiting on your review"
          or ("Review Mode: no open PRs (" .. scope .. ")"),
        vim.log.levels.INFO
      )
      return
    end
    picker.actions(vim.tbl_map(item, prs), "Review Mode inbox [" .. scope .. "]")
  end)
end

return M
