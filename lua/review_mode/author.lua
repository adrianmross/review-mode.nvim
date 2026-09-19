-- The author's side of a review: addressing the feedback you received.
--
-- Everything else in the plugin assumes you are reviewing someone else's PR.
-- When the PR is yours, two chores follow every round of feedback: marking the
-- threads your fix commit dealt with, and asking the reviewers to look again.
-- Both write to the PR as you, so both are always confirmed first.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")
local api = require("review_mode.api")

local state = core.state

-- ponytail: only the last 100 reviews are read, so a reviewer whose only review
-- is older than that is missed; paginate if a PR ever gets that long
local people_query = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      viewerDidAuthor
      author { login }
      reviews(last: 100) {
        nodes { author { __typename login } }
      }
    }
  }
}
]]

local function pr_people(callback)
  local owner, name = core.repo_parts()
  if not owner or not state.pr then
    callback(nil, "no GitHub PR in this session")
    return
  end
  util.gh_json_async({
    "api",
    "graphql",
    "-f",
    "query=" .. people_query,
    "-F",
    "owner=" .. owner,
    "-F",
    "name=" .. name,
    "-F",
    "number=" .. tostring(state.pr),
  }, function(result, err)
    local pr = result and result.data and result.data.repository and result.data.repository.pullRequest
    callback(pr, pr and nil or err or "PR query failed")
  end)
end

-- Authorship cannot change within a session, so it is asked once per session.
local authored = {}

local function viewer_is_author(callback)
  local generation = state.generation
  if authored[generation] ~= nil then
    callback(authored[generation])
    return
  end
  pr_people(function(pr)
    if pr then
      authored[generation] = pr.viewerDidAuthor == true
    end
    callback(authored[generation] == true)
  end)
end

--- Per path, the old-side line ranges `git diff --unified=0` reports as
--- changed. A pure insertion (count 0) sits after its line, so it counts as
--- touching that line.
function M.changed_ranges(patch)
  local ranges, path = {}, nil
  for line in (patch or ""):gmatch("[^\n]+") do
    local old_path = line:match("^%-%-%- a/(.+)$")
    if old_path then
      path = old_path
    elseif line:match("^%-%-%- /dev/null") then
      path = nil
    elseif path then
      local start, count = line:match("^@@ %-(%d+),?(%d*) ")
      if start then
        start, count = tonumber(start), tonumber(count ~= "" and count or "1")
        ranges[path] = ranges[path] or {}
        table.insert(ranges[path], { start, start + math.max(count, 1) - 1 })
      end
    end
  end
  return ranges
end

--- The unresolved threads whose lines fall in `ranges`. Outdated threads are
--- left out: their line belongs to an older commit, not the one the diff starts
--- from. Synthetic ids ("comment:", "rest:", "pending:", "sending:") are
--- threads GitHub has not issued an id for, so there is nothing to resolve.
function M.touched_threads(ranges)
  local touched = {}
  for _, thread in ipairs(api.threads({ include_resolved = true })) do
    local last = thread.line
    local resolvable = not thread.is_resolved and not thread.is_outdated and not thread.id:find(":", 1, true)
    for _, range in ipairs(resolvable and last and ranges[thread.path] or {}) do
      if range[1] <= last and range[2] >= (thread.start_line or last) then
        touched[#touched + 1] = thread
        break
      end
    end
  end
  return touched
end

local function summary(thread)
  local first = thread.comments[1] or {}
  return string.format(
    "  %s:%d  %s: %s",
    thread.path,
    thread.line,
    first.author or "?",
    (first.body or ""):match("[^\n]*")
  )
end

local function reply_and_resolve(threads, body)
  local pending, failed = #threads, 0
  for _, thread in ipairs(threads) do
    api.reply({ thread_id = thread.id, path = thread.path, body = body }, function(ok)
      local function done(resolved)
        failed = failed + (resolved and 0 or 1)
        pending = pending - 1
        if pending == 0 then
          vim.notify(
            string.format("Review Mode: resolved %d of %d threads", #threads - failed, #threads),
            failed > 0 and vim.log.levels.WARN or nil
          )
        end
      end
      if not ok then
        -- never resolve a thread whose "fixed in" note did not land
        done(false)
        return
      end
      api.resolve(thread.id, true, done)
    end)
  end
end

--- HEAD moved from `from` to `to` during the review. When the PR is yours and
--- the move only added commits, offer to reply and resolve every unresolved
--- thread those commits changed a line of.
function M.offer_resolve(from, to)
  if not (state.config.author or {}).offer_resolve or state.provider ~= "github" then
    return
  end
  local generation = state.generation
  viewer_is_author(function(is_author)
    if not is_author or not core.is_current(generation) then
      return
    end
    -- a checkout, reset or rebase is not "fixed in" anything
    util.system_async({ "git", "merge-base", "--is-ancestor", from, to }, { cwd = state.root }, function(ancestor)
      if not ancestor or not core.is_current(generation) then
        return
      end
      util.system_async({
        "git",
        "-c",
        "core.quotepath=off",
        "diff",
        "--unified=0",
        "--no-renames",
        "--no-ext-diff",
        "--no-color",
        from,
        to,
      }, { cwd = state.root }, function(patch)
        if not patch or not core.is_current(generation) then
          return
        end
        local threads = M.touched_threads(M.changed_ranges(patch))
        if #threads == 0 then
          return
        end
        local body = string.format("Fixed in `%s`", to:sub(1, 7))
        local lines = {}
        for _, thread in ipairs(threads) do
          lines[#lines + 1] = summary(thread)
        end
        local prompt = string.format(
          'Reply "%s" and resolve %d thread%s?\n\n%s\n',
          body,
          #threads,
          #threads == 1 and "" or "s",
          table.concat(lines, "\n")
        )
        if vim.fn.confirm(prompt, "&Resolve\n&Skip", 2) == 1 then
          reply_and_resolve(threads, body)
        end
      end)
    end)
  end)
end

--- Everyone who has reviewed the PR, minus its author and bots, who cannot be
--- asked. Returns logins in first-review order.
function M.reviewers(pr)
  local author = pr.author and pr.author.login
  local seen, logins = {}, {}
  for _, review in ipairs(pr.reviews and pr.reviews.nodes or {}) do
    local who = review.author
    if who and who.__typename == "User" and who.login ~= author and not seen[who.login] then
      seen[who.login] = true
      logins[#logins + 1] = who.login
    end
  end
  return logins
end

--- Ask everyone who has reviewed the PR to review it again, after a
--- confirmation naming them. callback(ok, err) is optional.
function M.rerequest(callback)
  callback = callback or function() end
  if state.provider ~= "github" then
    vim.notify("Review Mode: re-requesting review needs a GitHub PR", vim.log.levels.WARN)
    callback(false, "not a GitHub PR")
    return
  end
  pr_people(function(pr, err)
    if not pr then
      vim.notify("Review Mode: " .. tostring(err), vim.log.levels.ERROR)
      callback(false, err)
      return
    end
    local logins = M.reviewers(pr)
    if #logins == 0 then
      vim.notify("Review Mode: nobody has reviewed this PR yet")
      callback(false, "no reviewers")
      return
    end
    if vim.fn.confirm("Re-request review from " .. table.concat(logins, ", ") .. "?", "&Request\n&Cancel", 2) ~= 1 then
      callback(false, "cancelled")
      return
    end
    local args =
      { "api", "--method", "POST", string.format("repos/%s/pulls/%s/requested_reviewers", state.repo, state.pr) }
    for _, login in ipairs(logins) do
      vim.list_extend(args, { "-f", "reviewers[]=" .. login })
    end
    util.gh_json_async(args, function(result, post_err)
      if not result then
        vim.notify("Review Mode: re-request failed: " .. tostring(post_err), vim.log.levels.ERROR)
        callback(false, post_err)
        return
      end
      vim.notify("Review Mode: re-requested review from " .. table.concat(logins, ", "))
      callback(true, nil)
    end)
  end)
end

hooks.on("head_moved", function(ctx)
  M.offer_resolve(ctx.from, ctx.to)
end)

return M
