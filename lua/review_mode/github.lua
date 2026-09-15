-- Fetching PR review comments from GitHub and caching them on disk.
--
-- GraphQL is the real source (it carries thread ids, resolution state,
-- reactions); the REST list is the fallback when the GraphQL query fails. Both
-- end up in the one comment shape review_mode.comments defines.
--
-- Loading finishes with a "comments_loaded" event rather than a direct redraw,
-- so this module never has to know what is on screen.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")
local comments_ui = require("review_mode.comments")

local state = core.state
local gh_json_async = util.gh_json_async

local cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "review-mode-comments")

function M.cache_path(key)
  return vim.fs.joinpath(cache_dir, key:gsub("[^%w_.-]", "_") .. ".json")
end

function M.read_comment_cache(key)
  return util.read_json_file(M.cache_path(key))
end

-- one file per PR is written forever otherwise, and each one holds every review
-- comment body for that PR
local comment_cache_max_age_seconds = 30 * 24 * 60 * 60
local comment_cache_pruned = false

function M.prune_comment_cache()
  local cutoff = os.time() - comment_cache_max_age_seconds
  for name, kind in vim.fs.dir(cache_dir) do
    if kind == "file" and name:match("%.json$") then
      local path = vim.fs.joinpath(cache_dir, name)
      local stat = vim.uv.fs_stat(path)
      if stat and stat.mtime and stat.mtime.sec < cutoff then
        vim.uv.fs_unlink(path)
      end
    end
  end
end

function M.write_comment_cache_entry(key, grouped, threads)
  pcall(util.write_json_file, M.cache_path(key), { fetched_at = os.time(), grouped = grouped, threads = threads or {} })

  if comment_cache_pruned then
    return
  end

  -- one attempt per session either way: a scan that fails once will fail again,
  -- and it must not take the cache write down with it
  comment_cache_pruned = true
  pcall(M.prune_comment_cache)
end

function M.group_comments(comments)
  local grouped = {}
  for _, comment in ipairs(comments or {}) do
    if comment.path then
      grouped[comment.path] = grouped[comment.path] or {}
      table.insert(grouped[comment.path], comments_ui.normalize_rest(comment))
    end
  end
  return grouped
end

function M.normalize_thread_comment(thread, comment)
  local path = comment.path or thread.path
  if not path then
    return nil
  end

  local reactions = {}
  for _, group in ipairs(comment.reactionGroups or {}) do
    local count = group.reactors and tonumber(group.reactors.totalCount) or 0
    if count > 0 then
      reactions[#reactions + 1] = { content = group.content, count = count }
    end
  end

  return {
    id = comment.databaseId or comment.fullDatabaseId or comment.id,
    node_id = comment.id,
    thread_id = thread.id,
    path = path,
    line = comment.line or thread.line,
    original_line = comment.originalLine or thread.originalLine,
    start_line = comment.startLine or thread.startLine,
    body = comment.body,
    user = comment.author and { login = comment.author.login } or nil,
    created_at = comment.createdAt,
    url = comment.url,
    association = comment.authorAssociation,
    viewer_did_author = comment.viewerDidAuthor == true,
    is_pending = comment.state == "PENDING",
    reactions = #reactions > 0 and reactions or nil,
    is_resolved = thread.isResolved == true,
    is_outdated = thread.isOutdated == true,
  }
end

function M.group_review_threads(threads)
  local grouped = {}
  local by_path = {}
  for _, thread in ipairs(threads or {}) do
    if thread.path then
      by_path[thread.path] = by_path[thread.path] or {}
      by_path[thread.path][#by_path[thread.path] + 1] = thread
    end

    local comments = thread.comments and thread.comments.nodes or {}
    for _, comment in ipairs(comments) do
      local normalized = M.normalize_thread_comment(thread, comment)
      if normalized then
        grouped[normalized.path] = grouped[normalized.path] or {}
        grouped[normalized.path][#grouped[normalized.path] + 1] = normalized
      end
    end
  end

  return grouped, by_path
end

function M.hydrate_comments()
  local key = core.cache_key()
  if not key then
    return false
  end

  local cached = M.read_comment_cache(key)
  if not cached or type(cached.grouped) ~= "table" then
    return false
  end

  state.comments = cached.grouped
  state.comment_threads = cached.threads or {}
  return (os.time() - tonumber(cached.fetched_at or 0)) < state.config.comments.cache_ttl_seconds
end

function M.rest_comments_async(generation, page, comments, callback)
  if not state.repo or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  gh_json_async({
    "api",
    string.format("repos/%s/pulls/%s/comments?per_page=100&page=%d", state.repo, state.pr, page),
  }, function(result, err)
    if not core.is_current(generation) then
      return
    end

    if not result then
      callback(nil, err)
      return
    end

    vim.list_extend(comments, result)
    if #result == 100 then
      M.rest_comments_async(generation, page + 1, comments, callback)
      return
    end

    callback(comments, nil)
  end)
end

function M.review_threads_async(generation, after, threads, callback)
  local owner, name = core.repo_parts()
  if not owner or not name or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  local query = [[
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          path
          line
          originalLine
          startLine
          diffSide
          isResolved
          isOutdated
          comments(first: 100) {
            nodes {
              id
              databaseId
              body
              path
              line
              originalLine
              startLine
              createdAt
              url
              state
              authorAssociation
              viewerDidAuthor
              author {
                login
              }
              reactionGroups {
                content
                reactors {
                  totalCount
                }
              }
            }
          }
        }
      }
    }
  }
}
]]

  local args = {
    "api",
    "graphql",
    "-f",
    "query=" .. query,
    "-F",
    "owner=" .. owner,
    "-F",
    "name=" .. name,
    "-F",
    "number=" .. tostring(state.pr),
  }

  if after then
    vim.list_extend(args, { "-F", "after=" .. after })
  end

  gh_json_async(args, function(result, err)
    if not core.is_current(generation) then
      return
    end

    if not result then
      callback(nil, err)
      return
    end

    local pr = result.data and result.data.repository and result.data.repository.pullRequest
    local review_threads = pr and pr.reviewThreads
    if not review_threads then
      callback(nil, "GitHub review thread query returned no review threads")
      return
    end

    vim.list_extend(threads, review_threads.nodes or {})
    local page_info = review_threads.pageInfo or {}
    if page_info.hasNextPage and page_info.endCursor then
      M.review_threads_async(generation, page_info.endCursor, threads, callback)
      return
    end

    callback(threads, nil)
  end)
end

function M.load_comments_from_rest_async(generation)
  M.rest_comments_async(generation, 1, {}, function(comments, err)
    if not core.is_current(generation) then
      return
    end

    state.comments_loading = false
    if not comments then
      vim.notify("Failed to load PR comments: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.comments = M.group_comments(comments)
    state.comment_threads = {}
    local key = core.cache_key()
    if key then
      M.write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  end)
end

function M.load_comments_async(opts)
  opts = opts or {}
  if
    not state.config.comments.enabled
    or not state.active
    or state.comments_loading
    or not state.repo
    or not state.pr
  then
    return
  end

  local generation = state.generation
  -- after a write the cache is stale by definition, so never serve it back
  local fresh = not opts.force and M.hydrate_comments()
  hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  if fresh then
    return
  end

  state.comments_loading = true
  M.review_threads_async(generation, nil, {}, function(threads, err)
    if not core.is_current(generation) then
      return
    end

    if not threads then
      M.load_comments_from_rest_async(generation)
      return
    end

    state.comments, state.comment_threads = M.group_review_threads(threads)
    local key = core.cache_key()
    if key then
      M.write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    state.comments_loading = false
    hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  end)
end

return M
