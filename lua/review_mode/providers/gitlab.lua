-- GitLab merge request review through `glab`.
--
-- Covers the core loop: MR metadata, loading diff discussions, starting a
-- thread on a line, replying, and resolving. Discussions are normalized into the
-- same comment shape review_mode.comments defines, so signs, the panel, the tree
-- and review_mode.api work unchanged.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")
local github = require("review_mode.github")

local state = core.state

local function glab_json_async(args, callback)
  util.system_async(vim.list_extend({ "glab" }, args), {}, function(stdout, err)
    if not stdout then
      callback(nil, err)
      return
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok then
      -- older glab releases print one array per page back to back
      ok, decoded = pcall(vim.json.decode, (stdout:gsub("%]%s*%[", ",")))
    end
    if not ok then
      callback(nil, "Failed to decode glab JSON output")
      return
    end
    callback(decoded, nil)
  end)
end

local function project_path(suffix)
  local encoded = tostring(state.repo or ""):gsub("[^%w_.~-]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  return string.format("projects/%s/merge_requests/%s%s", encoded, state.pr, suffix or "")
end

local function reload_comments()
  github.load_comments_async({ force = true })
end

--- Read the GL_REVIEW_* launcher handoff, in place of GH_REVIEW_*.
function M.apply_env()
  state.repo = util.env_value("GL_REVIEW_REPO")
  state.pr = util.env_value("GL_REVIEW_MR")
  state.base = util.env_value("GL_REVIEW_BASE")
  state.head = util.env_value("GL_REVIEW_HEAD")
  state.gitlab = {}
end

--- `glab mr view` as the GitHub metadata shape ({ number, baseRefName,
--- headRefOid }) so init.lua's start-up code consumes it unchanged. Also keeps
--- the MR's diff_refs and web url, which posting and links need.
function M.mr_meta_async(generation, callback)
  local args = { "mr", "view" }
  local mr = state.pr or util.env_value("GL_REVIEW_MR")
  if mr and mr ~= "" then
    args[#args + 1] = tostring(mr)
  end
  local repo = state.repo or util.env_value("GL_REVIEW_REPO")
  if repo then
    vim.list_extend(args, { "--repo", repo })
  end
  vim.list_extend(args, { "--output", "json" })

  glab_json_async(args, function(mr_json, err)
    if generation and not core.is_current(generation) then
      return
    end
    if type(mr_json) ~= "table" then
      callback(nil, err or "could not load merge request metadata")
      return
    end

    state.gitlab = state.gitlab or {}
    state.gitlab.diff_refs = mr_json.diff_refs or state.gitlab.diff_refs
    state.gitlab.web_url = mr_json.web_url or state.gitlab.web_url

    local full = mr_json.references and mr_json.references.full
    local slug = full and full:gsub("!%d+$", "")
      or tostring(mr_json.web_url or ""):match("^%a+://[^/]+/(.-)/%-/merge_requests/")
    callback({
      repo = slug,
      number = mr_json.iid,
      baseRefName = mr_json.target_branch,
      headRefOid = mr_json.diff_refs and mr_json.diff_refs.head_sha or mr_json.sha,
    }, nil)
  end)
end

--- Stand-in for init.lua's load_metadata_async: one glab call gives both the
--- project and the MR.
function M.load_metadata_async(generation, callback)
  M.mr_meta_async(generation, function(meta, err)
    if not meta then
      callback(nil, err)
      return
    end
    callback({ repo = meta.repo, meta = meta }, nil)
  end)
end

function M.web_url()
  return state.gitlab and state.gitlab.web_url or nil
end

-- Loading ---------------------------------------------------------------------

local function discussion_resolved(discussion)
  if discussion.resolved ~= nil then
    return discussion.resolved == true
  end
  local resolvable = false
  for _, note in ipairs(discussion.notes or {}) do
    if note.resolvable then
      resolvable = true
      if not note.resolved then
        return false
      end
    end
  end
  return resolvable
end

--- Discussions from the MR API, grouped by path in the normalized comment shape.
--- Only diff discussions are kept: a note with no position has no line to sit on.
function M.group_discussions(discussions, web_url)
  local grouped = {}
  for _, discussion in ipairs(discussions or {}) do
    local notes = discussion.notes or {}
    local anchor = notes[1] and notes[1].position
    local resolved = discussion_resolved(discussion)
    for _, note in ipairs(notes) do
      local position = note.position or anchor
      local path = position and (position.new_path or position.old_path)
      if path and not note.system then
        grouped[path] = grouped[path] or {}
        table.insert(grouped[path], {
          id = note.id,
          thread_id = discussion.id,
          path = path,
          line = position.new_line,
          original_line = position.old_line,
          body = note.body,
          user = note.author and { login = note.author.username } or nil,
          created_at = note.created_at,
          url = web_url and note.id and string.format("%s#note_%s", web_url, note.id) or nil,
          viewer_did_author = false,
          is_pending = false,
          is_resolved = resolved,
          is_outdated = false,
        })
      end
    end
  end
  return grouped
end

--- Fetch discussions. github.load_comments_async hands over here after its
--- guards and cache check, so both forges share those.
function M.fetch_comments_async(generation)
  state.comments_loading = true
  glab_json_async({ "api", "--paginate", project_path("/discussions?per_page=100") }, function(discussions, err)
    if not core.is_current(generation) then
      return
    end

    state.comments_loading = false
    if type(discussions) ~= "table" then
      vim.notify("Failed to load MR discussions: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.comments = M.group_discussions(discussions, M.web_url())
    state.comment_threads = {}
    local key = core.cache_key()
    if key then
      github.write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  end)
end

-- Writes ----------------------------------------------------------------------

--- Where `line` (new side) sits in a `git diff -U0` patch for one file.
--- Returns old_path, old_line; old_line is nil for an added line, which GitLab
--- wants with new_line only. Unchanged lines need both.
function M.line_position(patch, line)
  local file = require("review_mode.git").parse_patch(patch)[1] or { hunks = {} }
  local offset = 0
  for _, hunk in ipairs(file.hunks) do
    local b, c, d = hunk.old_count, hunk.new_start, hunk.new_count
    if d > 0 and line >= c and line < c + d then
      return file.old_path, nil
    end
    if (d > 0 and c + d <= line) or (d == 0 and c < line) then
      offset = offset + b - d
    else
      break
    end
  end
  return file.old_path, line + offset
end

local function with_diff_refs(callback)
  local refs = state.gitlab and state.gitlab.diff_refs
  if refs and refs.head_sha then
    callback(refs, nil)
    return
  end
  M.mr_meta_async(nil, function(meta, err)
    refs = state.gitlab and state.gitlab.diff_refs
    if not meta or not refs then
      callback(nil, err or "merge request has no diff_refs")
      return
    end
    callback(refs, nil)
  end)
end

local function write_input(value)
  local path = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(value) }, path)
  return path
end

--- Start a discussion on a line. A range anchors to its last line, as GitHub's
--- `line` does.
function M.submit_comment(path, start_line, end_line, body, callback)
  local function fail(err)
    vim.notify("Review Mode comment failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
    if callback then
      callback(false, err)
    end
  end

  with_diff_refs(function(refs, refs_err)
    if not refs then
      fail(refs_err)
      return
    end

    local git = require("review_mode.git")
    local args = git.diff({ "-U0", "--find-renames", core.diff_range(), "--" })
    util.system_async(vim.list_extend(args, git.pathspec({ path }, state.renames)), {
      cwd = state.root,
      raw = true,
    }, function(patch)
      local old_path, old_line = M.line_position(patch, end_line)
      local input = write_input({
        body = body,
        position = {
          position_type = "text",
          base_sha = refs.base_sha,
          start_sha = refs.start_sha,
          head_sha = refs.head_sha,
          new_path = path,
          new_line = end_line,
          old_path = old_path or path,
          old_line = old_line,
        },
      })

      glab_json_async(
        { "api", "--method", "POST", project_path("/discussions"), "--input", input },
        function(created, err)
          vim.fn.delete(input)
          if not created then
            fail(err)
            return
          end
          reload_comments()
          hooks.emit("comment_posted", { kind = "comment", path = path, line = end_line })
          vim.notify(string.format("Submitted MR comment on %s:%d", path, end_line))
          if callback then
            callback(true, nil)
          end
        end
      )
    end)
  end)
end

--- Reply to a discussion. opts.thread_id is the discussion id; opts.comment_id
--- (a note id) is looked up to its discussion.
function M.submit_reply(opts, callback)
  opts = opts or {}
  local body = util.trim(opts.body or "")
  local discussion_id = opts.thread_id
  if not discussion_id and opts.comment_id then
    for _, list in pairs(state.comments) do
      for _, comment in ipairs(list) do
        if tostring(comment.id) == tostring(opts.comment_id) then
          discussion_id = comment.thread_id
        end
      end
    end
  end

  if not discussion_id or body == "" then
    if callback then
      callback(false, "a thread with at least one comment, and a body, are required")
    end
    return false
  end

  glab_json_async({
    "api",
    "--method",
    "POST",
    project_path("/discussions/" .. discussion_id .. "/notes"),
    "--raw-field",
    "body=" .. body,
  }, function(created, err)
    if not created then
      if callback then
        callback(false, err)
      end
      return
    end
    reload_comments()
    hooks.emit("comment_posted", { kind = "reply", thread_id = discussion_id })
    if callback then
      callback(true, nil)
    end
  end)
  return true
end

function M.set_resolved(discussion_id, resolved, callback)
  glab_json_async({
    "api",
    "--method",
    "PUT",
    project_path("/discussions/" .. discussion_id),
    "--field",
    "resolved=" .. tostring(resolved),
  }, function(result, err)
    if not result then
      vim.notify("Review Mode thread update failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      if callback then
        callback(false, err)
      end
      return
    end
    reload_comments()
    hooks.emit("thread_resolved", { thread_id = discussion_id, resolved = resolved })
    vim.notify(resolved and "Resolved MR thread" or "Unresolved MR thread")
    if callback then
      callback(true, nil)
    end
  end)
end

return M
