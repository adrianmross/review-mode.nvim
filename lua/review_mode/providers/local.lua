-- Reviewing local refs, with comments kept on disk instead of on a forge.
--
-- Two halves, and they are independent: `resolve` works out the base/head a
-- session should compare (no network, no PR), and the rest is a comment store
-- that writes the same normalized shape review_mode.comments defines, so signs,
-- the panel, diagnostics, quickfix and review_mode.api work unchanged.
--
-- The store lives under `git rev-parse --git-common-dir` (the main `.git`, for
-- a linked worktree too), so removing a worktree never takes its comments with
-- it, and git never tracks any of it. The filename is the branch the head
-- resolves to (percent-encoded), so switching branches switches comments.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local state = core.state

local store_version = 1

-- Percent-encoding, so no two keys share a file (feat/x is feat%2Fx, feat_x
-- stays feat_x).
local function encode_key(key)
  return (tostring(key):gsub("[^%w_.-]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

-- What stores were named before: every odd character became "_".
local function legacy_key(key)
  return (tostring(key):gsub("[^%w_.-]", "_"))
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Refs --------------------------------------------------------------------------

local function git(args, root)
  return util.system(vim.list_extend({ "git" }, args), { cwd = root })
end

--- The repo's default branch: what origin/HEAD points at, else main or master.
function M.default_branch(root)
  local origin_head = git({ "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" }, root)
  if origin_head then
    return (origin_head:gsub("^origin/", ""))
  end
  for _, candidate in ipairs({ "main", "master" }) do
    if git({ "rev-parse", "--verify", "--quiet", candidate .. "^{commit}" }, root) then
      return candidate
    end
  end
  return "HEAD"
end

local function git_path(root, flag)
  local dir = git({ "rev-parse", flag }, root)
  if not dir then
    return nil
  end
  -- git answers a relative ".git" in a plain checkout and an absolute path in a
  -- linked worktree, so only join when it is relative
  if not dir:match("^[/\\]") and not dir:match("^%a:[/\\]") then
    dir = vim.fs.joinpath(root, dir)
  end
  return vim.fs.normalize(dir)
end

--- Where a local review keeps its comments:
--- <git-common-dir>/review-mode/<percent-encoded key>.json.
function M.store_for(root, key)
  local dir = git_path(root, "--git-common-dir")
  return dir and vim.fs.joinpath(dir, "review-mode", encode_key(key) .. ".json")
end

-- Older releases kept the store under --git-dir (deleted with a linked worktree)
-- with "_" for every odd character. Copy it over once, so nothing is lost.
local function migrate(root, old_key, store)
  local dir = git_path(root, "--git-dir")
  local old = dir and vim.fs.joinpath(dir, "review-mode", legacy_key(old_key) .. ".json")
  if not old or old == store or vim.uv.fs_stat(store) or not vim.uv.fs_stat(old) then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(store), "p")
  if vim.uv.fs_copyfile(old, store) then
    vim.notify("Review Mode: local comments moved to " .. store)
  end
end

-- The branch a head names (HEAD included), else a ref's own name, else the
-- detached commit: never "HEAD", which every branch would share.
local function store_key(head_rev, root)
  local full = git({ "rev-parse", "--symbolic-full-name", head_rev }, root)
  local branch = full and full:match("^refs/heads/(.+)$")
  if branch then
    return branch
  end
  if full and full ~= "" and full ~= "HEAD" then
    return (full:gsub("^refs/", ""))
  end
  return "detached-" .. tostring(git({ "rev-parse", "--short", head_rev }, root) or "unknown")
end

--- Turn `:ReviewModeLocal [<base>] [<head>]` into opts for review_mode.start.
---
--- One argument may also be a range ("main..feature", "main...feature"). The
--- base is always resolved to the merge base with the head, so the session
--- compares what a PR would. An absent head means the working tree.
function M.resolve(args, root)
  local base_arg, head_arg = args[1], args[2]
  if base_arg and not head_arg then
    local left, right = base_arg:match("^(.-)%.%.%.?(.+)$")
    if left and left ~= "" then
      base_arg, head_arg = left, right
    end
  end
  base_arg = base_arg or M.default_branch(root)

  local head_rev = head_arg or "HEAD"
  -- a typo'd head would otherwise leave a session with no head at all
  if head_arg and not git({ "rev-parse", "--verify", "--quiet", head_arg .. "^{commit}" }, root) then
    return nil, string.format("could not resolve %s in this repo", head_arg)
  end
  local base = git({ "merge-base", base_arg, head_rev }, root)
    or git({ "rev-parse", "--verify", "--quiet", base_arg .. "^{commit}" }, root)
  if not base then
    return nil, string.format("could not resolve %s in this repo", base_arg)
  end

  local key = store_key(head_rev, root)
  local store = M.store_for(root, key)
  if not store then
    return nil, "not in a git repo"
  end
  -- what the store was keyed by before: the head as typed, else the branch
  local old_key = head_arg
  if not old_key then
    old_key = git({ "rev-parse", "--abbrev-ref", "HEAD" }, root)
    if not old_key or old_key == "HEAD" then
      old_key = "detached-" .. tostring(git({ "rev-parse", "--short", "HEAD" }, root) or "unknown")
    end
  end
  migrate(root, old_key, store)

  return {
    provider = "local",
    root = root,
    repo = vim.fs.basename(root),
    pr = key,
    base = base,
    head = git({ "rev-parse", head_rev }, root),
    -- "" is the working tree; a named head is diffed as a ref
    head_ref = head_arg or "",
    local_store = store,
  }
end

-- Store -------------------------------------------------------------------------

-- Stable key order and two-space indent: this file is meant to be read by a
-- human debugging a review and by an agent that did not write it.
local function encode(value, indent)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end

  local pad = indent .. "  "
  local parts = {}
  if vim.islist(value) then
    if #value == 0 then
      return "[]"
    end
    for _, item in ipairs(value) do
      parts[#parts + 1] = pad .. encode(item, pad)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = vim.tbl_keys(value)
  if #keys == 0 then
    return "{}"
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = pad .. vim.json.encode(tostring(key)) .. ": " .. encode(value[key], pad)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

M.encode = encode

local function read_doc()
  local doc = state.local_store and util.read_json_file(state.local_store) or nil
  if type(doc) ~= "table" then
    doc = {}
  end
  doc.version = store_version
  doc.threads = type(doc.threads) == "table" and doc.threads or {}
  doc.next_id = tonumber(doc.next_id) or 1
  return doc
end

local function write_doc(doc)
  local path = state.local_store
  if not path then
    return false, "no local review store: start a local review first"
  end
  local ok, err = pcall(util.write_file, path, vim.split(encode(doc, ""), "\n", { plain = true }))
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- The author a new local comment is attributed to: what the caller asked for,
--- else this repo's git user.name, else "agent".
function M.author(explicit)
  if type(explicit) == "string" and explicit ~= "" then
    return explicit
  end
  local name = util.system({ "git", "config", "user.name" })
  if name and name ~= "" then
    return name
  end
  return "agent"
end

--- Read the store into state.comments, in the normalized comment shape.
--- Synchronous on purpose: it is one small local file, not a forge.
function M.load_comments()
  local grouped = {}
  for _, thread in ipairs(read_doc().threads) do
    for _, comment in ipairs(thread.comments or {}) do
      if thread.path then
        grouped[thread.path] = grouped[thread.path] or {}
        table.insert(grouped[thread.path], {
          id = comment.id,
          thread_id = thread.id,
          path = thread.path,
          line = tonumber(thread.line),
          start_line = tonumber(thread.start_line),
          body = comment.body,
          user = { login = comment.author or "agent" },
          created_at = comment.created_at,
          -- it is your disk: every local comment is yours to edit and delete
          viewer_did_author = true,
          is_pending = false,
          is_resolved = thread.resolved == true,
          is_outdated = false,
        })
      end
    end
  end

  state.comments = grouped
  state.comment_threads = {}
  state.comments_loading = false
  hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  return grouped
end

local function refuse(err, callback)
  if callback then
    callback(false, err)
  end
  return false
end

local function commit(doc, event, payload, callback, result)
  local ok, err = write_doc(doc)
  if not ok then
    return refuse(err, callback)
  end
  M.load_comments()
  hooks.emit(event, payload)
  if callback then
    callback(true, result)
  end
  return true
end

local function find_thread(doc, thread_id, comment_id)
  for _, thread in ipairs(doc.threads) do
    if thread_id ~= nil and tostring(thread.id) == tostring(thread_id) then
      return thread
    end
    for _, comment in ipairs(thread.comments or {}) do
      if comment_id ~= nil and tostring(comment.id) == tostring(comment_id) then
        return thread, comment
      end
    end
  end
  return nil
end

--- Start a thread. opts: path, start_line, end_line (or line), body, author.
--- callback(true, thread) on success, callback(false, err) otherwise.
function M.add_comment(opts, callback)
  opts = opts or {}
  local path = opts.path
  local body = util.trim(opts.body or "")
  if not path or body == "" then
    return refuse("path and body are required", callback)
  end

  local first = tonumber(opts.start_line) or tonumber(opts.line) or 1
  local last = tonumber(opts.end_line) or tonumber(opts.line) or first
  if first > last then
    first, last = last, first
  end

  local doc = read_doc()
  local id = doc.next_id
  doc.next_id = id + 1
  local thread = {
    id = "t" .. id,
    path = path,
    start_line = first,
    line = last,
    resolved = false,
    comments = {
      { id = "c" .. id, author = M.author(opts.author), body = body, created_at = now_iso() },
    },
  }
  doc.threads[#doc.threads + 1] = thread

  return commit(doc, "comment_posted", { kind = "comment", path = path, line = last }, callback, thread)
end

--- Add to a thread. opts: thread_id or comment_id, body, author.
function M.submit_reply(opts, callback)
  opts = opts or {}
  local body = util.trim(opts.body or "")
  local doc = read_doc()
  local thread = find_thread(doc, opts.thread_id, opts.comment_id)
  if not thread or body == "" then
    return refuse("a thread with at least one comment, and a body, are required", callback)
  end

  local id = doc.next_id
  doc.next_id = id + 1
  thread.comments = thread.comments or {}
  thread.comments[#thread.comments + 1] =
    { id = "c" .. id, author = M.author(opts.author), body = body, created_at = now_iso() }

  return commit(doc, "comment_posted", { kind = "reply", thread_id = thread.id }, callback, thread)
end

function M.set_resolved(thread_id, resolved, callback)
  local doc = read_doc()
  local thread = find_thread(doc, thread_id, nil)
  if not thread then
    return refuse("no local thread with id " .. tostring(thread_id), callback)
  end

  thread.resolved = resolved == true
  return commit(doc, "thread_resolved", { thread_id = thread.id, resolved = thread.resolved }, callback, thread)
end

--- Replace a comment body. opts: comment_id, body.
function M.edit_comment(opts, callback)
  opts = opts or {}
  local body = util.trim(opts.body or "")
  if body == "" then
    return refuse("a body is required", callback)
  end

  local doc = read_doc()
  local thread, comment = find_thread(doc, nil, opts.comment_id)
  if not comment then
    return refuse("comment not found in this review", callback)
  end

  comment.body = body
  comment.edited_at = now_iso()
  return commit(
    doc,
    "comment_edited",
    { comment_id = comment.id, thread_id = thread.id, path = thread.path },
    callback,
    comment
  )
end

--- Delete a comment, and the thread with it when it was the last one.
function M.delete_comment(comment_id, callback)
  local doc = read_doc()
  local thread, comment = find_thread(doc, nil, comment_id)
  if not comment then
    return refuse("comment not found in this review", callback)
  end

  for index, candidate in ipairs(thread.comments) do
    if candidate == comment then
      table.remove(thread.comments, index)
      break
    end
  end
  if #thread.comments == 0 then
    for index, candidate in ipairs(doc.threads) do
      if candidate == thread then
        table.remove(doc.threads, index)
        break
      end
    end
  end

  return commit(
    doc,
    "comment_deleted",
    { comment_id = comment.id, thread_id = thread.id, path = thread.path },
    callback,
    comment
  )
end

return M
