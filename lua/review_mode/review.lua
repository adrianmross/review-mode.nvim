-- Pending review comments and review submission.
--
-- Drafts live on disk, one file per PR, so a half-written review survives
-- restarting Neovim. Nothing here touches GitHub until submit(), which sends
-- every draft plus the review body in one POST to the reviews endpoint and only
-- forgets the drafts once GitHub has accepted them.
--
-- Replies cannot be batched: the reviews endpoint only takes new comments, so
-- replies keep posting immediately. A pending review started in the GitHub web
-- UI is not merged with these drafts.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")
local github = require("review_mode.github")

local state = core.state

M.review_events = { COMMENT = true, APPROVE = true, REQUEST_CHANGES = true }

local function store_path()
  local owner, name = core.repo_parts()
  if not owner or not state.pr then
    return nil
  end
  local key = string.format("%s_%s_%s", owner, name, state.pr):gsub("[^%w_.-]", "_")
  return vim.fs.joinpath(vim.fn.stdpath("state"), "review-mode-reviews", key .. ".json")
end

M.store_path = store_path

--- Pending drafts for the current PR, oldest first.
-- ponytail: re-reads the file on every call (signs, panel renders); cache in
-- memory keyed by path if that ever shows up in a profile.
function M.list()
  local path = store_path()
  local data = path and util.read_json_file(path)
  return data and data.drafts or {}
end

local function save(drafts)
  local path = store_path()
  if not path then
    return false
  end
  if #drafts == 0 then
    vim.uv.fs_unlink(path)
  else
    util.write_json_file(path, { drafts = drafts })
  end
  hooks.emit("pending_changed", { count = #drafts })
  return true
end

--- Queue a comment for the next review. Returns the draft, or nil and an error.
function M.add(opts)
  if state.provider == "gitlab" then
    return nil, require("review_mode.providers").unsupported("Pending review comments")
  end
  opts = opts or {}
  local body = util.trim(opts.body)
  local first = tonumber(opts.start_line) or tonumber(opts.line)
  local last = tonumber(opts.end_line) or tonumber(opts.line) or first
  if not opts.path or body == "" or not first then
    return nil, "path, line and body are required"
  end
  if not store_path() then
    return nil, "no review session"
  end

  local drafts = M.list()
  local draft = {
    id = tostring(vim.uv.hrtime()),
    path = opts.path,
    start_line = math.min(first, last),
    end_line = math.max(first, last),
    side = "RIGHT",
    body = body,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  drafts[#drafts + 1] = draft
  save(drafts)
  return draft
end

function M.remove(id)
  local drafts = M.list()
  for index, draft in ipairs(drafts) do
    if draft.id == id then
      table.remove(drafts, index)
      return save(drafts)
    end
  end
  return false
end

function M.discard()
  return save({})
end

-- Comments posted but not yet answered by GitHub. Session-only: each one is
-- removed again when its request settles, success or failure.
local sending = {}

--- Show `comment` (the flat stored shape, with path) at once, marked sending,
--- until M.settle_sending(comment) removes it.
function M.add_sending(comment)
  comment.is_sending = true
  sending[#sending + 1] = comment
  return comment
end

function M.settle_sending(comment)
  for index, entry in ipairs(sending) do
    if entry == comment then
      table.remove(sending, index)
      return
    end
  end
end

--- `comments` (a path's loaded comments) with that path's drafts appended in
--- the same flat shape, so the thread renderer and signs show them as pending,
--- along with any comments still on their way to GitHub.
function M.with_pending(comments, path)
  local out = comments
  for _, comment in ipairs(sending) do
    if comment.path == path then
      out = out == comments and vim.list_extend({}, comments or {}) or out
      out[#out + 1] = comment
    end
  end
  for _, draft in ipairs(M.list()) do
    if draft.path == path then
      out = out == comments and vim.list_extend({}, comments or {}) or out
      out[#out + 1] = {
        thread_id = "pending:" .. draft.id,
        path = path,
        line = draft.end_line,
        start_line = draft.start_line ~= draft.end_line and draft.start_line or nil,
        body = draft.body,
        user = { login = "you" },
        created_at = draft.created_at,
        is_pending = true,
      }
    end
  end
  return out
end

local function payload(event, body, drafts, commit_id)
  local comments = {}
  for _, draft in ipairs(drafts) do
    local comment = { path = draft.path, line = draft.end_line, side = draft.side or "RIGHT", body = draft.body }
    if draft.start_line and draft.start_line < draft.end_line then
      comment.start_line = draft.start_line
      comment.start_side = comment.side
    end
    comments[#comments + 1] = comment
  end
  -- an empty Lua table encodes as {}, which GitHub rejects as `comments`
  local out = { commit_id = commit_id, event = event, comments = #comments > 0 and comments or nil }
  if body ~= "" then
    out.body = body
  end
  return out
end

local function post(event, body, drafts, commit_id, callback)
  local input = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(payload(event, body, drafts, commit_id)) }, input)
  util.gh_json_async({
    "api",
    string.format("repos/%s/pulls/%s/reviews", state.repo, state.pr),
    "--method",
    "POST",
    "--input",
    input,
  }, function(result, err)
    vim.uv.fs_unlink(input)
    if not result then
      callback(false, err or "review submission failed")
      return
    end
    -- keep anything drafted while the request was in flight
    local sent = {}
    for _, draft in ipairs(drafts) do
      sent[draft.id] = true
    end
    save(vim.tbl_filter(function(draft)
      return not sent[draft.id]
    end, M.list()))
    hooks.emit("review_submitted", { event = event, count = #drafts })
    github.load_comments_async({ force = true })
    callback(true, nil)
  end)
end

--- Submit every pending draft as one review. opts.event is COMMENT, APPROVE or
--- REQUEST_CHANGES (any case). Drafts are cleared only after GitHub accepts it.
function M.submit(opts, callback)
  if state.provider == "gitlab" then
    return (callback or function() end)(false, require("review_mode.providers").unsupported("Submitting a review"))
  end
  opts = opts or {}
  callback = callback or function() end
  local event = tostring(opts.event or "COMMENT"):upper()
  local body = util.trim(opts.body)

  if not state.active or not state.repo or not state.pr then
    return callback(false, "start Review Mode first")
  end
  if not M.review_events[event] then
    return callback(false, "unknown review event " .. event)
  end

  local drafts = M.list()
  -- GitHub wants a body for REQUEST_CHANGES, and for a COMMENT review that has
  -- no inline comments to carry it.
  if body == "" and (event == "REQUEST_CHANGES" or (event == "COMMENT" and #drafts == 0)) then
    return callback(false, event .. " needs a review body")
  end

  if state.head then
    return post(event, body, drafts, state.head, callback)
  end
  util.system_async(
    { "gh", "pr", "view", state.pr, "--json", "headRefOid", "-q", ".headRefOid" },
    {},
    function(sha, err)
      if not sha or sha == "" then
        return callback(false, err or "could not determine PR head SHA")
      end
      post(event, body, drafts, sha, callback)
    end
  )
end

return M
