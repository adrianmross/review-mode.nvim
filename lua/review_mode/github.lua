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

function M.write_comment_cache_entry(key, grouped, threads, rest_pages)
  pcall(
    util.write_json_file,
    M.cache_path(key),
    { fetched_at = os.time(), grouped = grouped, threads = threads or {}, rest_pages = rest_pages }
  )

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
      reactions[#reactions + 1] = {
        content = group.content,
        count = count,
        viewer_has_reacted = group.viewerHasReacted == true,
      }
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
    original_start_line = comment.originalStartLine or thread.originalStartLine,
    side = thread.diffSide,
    body = comment.body,
    -- id and name are for crediting a suggestion's author in a commit
    user = comment.author and {
      login = comment.author.login,
      id = comment.author.databaseId,
      name = comment.author.name,
    } or nil,
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

-- Cache-first start --------------------------------------------------------------
-- The comment cache is keyed by PR, and a plain :ReviewMode only learns its PR
-- once `gh pr view` answers, so a warm cache used to sit unread for that whole
-- round trip. Each branch remembers the PR it last resolved to, and start draws
-- that PR's cached comments while gh is still being asked; start reconciles
-- against gh's answer when it arrives.
--
-- The pointer's name is a hash: cache_path's sanitizing is lossy ("/a/b" and
-- "/a_b" come out the same) and a deep root would overflow a filename. "\n" is
-- the separator because a git branch name cannot hold one (and vim.fn cannot
-- take a NUL).
function M.branch_pointer(root, branch)
  return "branch-" .. vim.fn.sha256(root .. "\n" .. branch)
end

local function current_branch_pointer(root)
  local branch = util.system({ "git", "symbolic-ref", "--short", "-q", "HEAD" }, { cwd = root })
  return branch and branch ~= "" and M.branch_pointer(root, branch) or nil
end

function M.remember_branch(root)
  local pointer, key = current_branch_pointer(root), core.cache_key()
  if pointer and key then
    pcall(util.write_json_file, M.cache_path(pointer), { key = key })
  end
end

--- Draw the cached comments of the PR this branch last resolved to. Returns the
--- cache key it drew, or nil when there was nothing to draw.
function M.hydrate_for_branch(root)
  if not state.config.comments.enabled then
    return nil
  end
  local pointer = current_branch_pointer(root)
  local entry = pointer and M.read_comment_cache(pointer)
  local key = entry and entry.key
  local cached = type(key) == "string" and M.read_comment_cache(key) or nil
  if not cached or type(cached.grouped) ~= "table" then
    return nil
  end

  state.comments = cached.grouped
  state.comment_threads = cached.threads or {}
  local repo, pr = key:match("^(.*)#(.-)$")
  hooks.emit("comments_loaded", { repo = repo, pr = pr })
  return key
end
-- End cache-first start ----------------------------------------------------------

-- Conditional REST comment fetch -----------------------------------------------
-- GitHub's ETags are per page, never per collection: a 304 on page 1 says
-- nothing about pages 2..n, and each page's ETag changes only when that page's
-- payload does. So every page keeps its own ETag *and* its own payload on disk,
-- and revalidation is per page -- a page that answers 200 is replaced while its
-- neighbours keep serving from the cache. That is why the cached bodies have to
-- be stored: a 304 carries no body, so the only way to satisfy page 2 while
-- page 1 changed is to already hold page 2's comments.
--
-- Page count is still driven by the responses, not by the cache: paging stops at
-- the first page holding fewer than 100 comments, whether that page came back
-- 200 or 304, and the pages written back are only the ones walked this time. A
-- PR that lost a page therefore drops the stale tail instead of replaying it.
local function cached_rest_pages()
  local key = core.cache_key()
  local cached = key and M.read_comment_cache(key) or nil
  if not cached or type(cached.rest_pages) ~= "table" then
    return {}
  end
  return cached.rest_pages
end

function M.rest_comments_async(generation, page, comments, callback, pages)
  if not state.repo or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  pages = pages or { cached = cached_rest_pages(), fresh = {} }
  local cached_page = state.config.comments.conditional_requests and pages.cached[page] or nil

  local args = {
    "api",
    "--include",
    string.format("repos/%s/pulls/%s/comments?per_page=100&page=%d", state.repo, state.pr, page),
  }
  if cached_page and cached_page.etag then
    vim.list_extend(args, { "-H", "If-None-Match: " .. cached_page.etag })
  end

  util.gh_include_async(args, function(response, err)
    if not core.is_current(generation) then
      return
    end

    if not response then
      callback(nil, err)
      return
    end

    local etag, list
    if response.status == 304 then
      etag, list = cached_page.etag, cached_page.comments or {}
    elseif response.status >= 200 and response.status < 300 then
      local ok, decoded = pcall(vim.json.decode, response.body)
      if not ok or type(decoded) ~= "table" then
        callback(nil, "Failed to decode gh JSON output")
        return
      end
      etag, list = response.headers.etag, decoded
    else
      callback(nil, string.format("gh returned HTTP %d for the comment list", response.status))
      return
    end

    pages.fresh[page] = { etag = etag, comments = list }
    vim.list_extend(comments, list)
    if #list == 100 then
      M.rest_comments_async(generation, page + 1, comments, callback, pages)
      return
    end

    callback(comments, nil, pages.fresh)
  end)
end

-- End conditional REST comment fetch -------------------------------------------

-- The fields of one review comment, shared by the thread query and the query
-- that pages a long thread's comments.
local comment_fields = [[
              id
              databaseId
              body
              path
              line
              originalLine
              startLine
              originalStartLine
              createdAt
              url
              state
              authorAssociation
              viewerDidAuthor
              author {
                login
                ... on User {
                  databaseId
                  name
                }
                ... on Bot {
                  databaseId
                }
              }
              reactionGroups {
                content
                viewerHasReacted
                reactors {
                  totalCount
                }
              }
]]

-- The thread query takes each thread's first 100 comments. Fetch the rest of
-- any thread that has more, one page at a time, then hand the list on.
function M.thread_comment_pages_async(generation, threads, index, callback)
  local thread = threads[index]
  if not thread then
    callback(threads, nil)
    return
  end
  local page = thread.comments and thread.comments.pageInfo or {}
  if not page.hasNextPage or not page.endCursor then
    M.thread_comment_pages_async(generation, threads, index + 1, callback)
    return
  end

  local query = [[
query($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
]] .. comment_fields .. [[
        }
      }
    }
  }
}
]]
  gh_json_async({
    "api",
    "graphql",
    "-f",
    "query=" .. query,
    "-F",
    "id=" .. thread.id,
    "-F",
    "after=" .. page.endCursor,
  }, function(result, err)
    if not core.is_current(generation) then
      return
    end
    local comments = result and result.data and result.data.node and result.data.node.comments
    if not comments then
      callback(nil, err or "GitHub returned no comments for a review thread page")
      return
    end
    vim.list_extend(thread.comments.nodes, comments.nodes or {})
    thread.comments.pageInfo = comments.pageInfo
    M.thread_comment_pages_async(generation, threads, index, callback)
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
          originalStartLine
          diffSide
          isResolved
          isOutdated
          comments(first: 100) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
]] .. comment_fields .. [[
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

    M.thread_comment_pages_async(generation, threads, 1, callback)
  end)
end

-- A forced load that arrived while another was running asked for data newer
-- than that run can hold (a comment just posted, a thread just resolved): drop
-- the run's result instead of showing or caching it, and fetch again. Returns
-- true when it did.
local function superseded()
  state.comments_loading = false
  if not state.comments_reload_queued then
    return false
  end
  state.comments_reload_queued = false
  M.load_comments_async({ force = true })
  return true
end

function M.load_comments_from_rest_async(generation)
  M.rest_comments_async(generation, 1, {}, function(comments, err, rest_pages)
    if not core.is_current(generation) then
      return
    end

    if superseded() then
      return
    end
    if not comments then
      vim.notify("Failed to load PR comments: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.comments = M.group_comments(comments)
    state.comment_threads = {}
    local key = core.cache_key()
    if key then
      -- rewriting the entry is also what refreshes fetched_at after an all-304
      -- revalidation, so the TTL restarts without anything being downloaded
      M.write_comment_cache_entry(key, state.comments, state.comment_threads, rest_pages)
    end
    hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  end)
end

function M.load_comments_async(opts)
  opts = opts or {}
  if not state.config.comments.enabled or not state.active then
    return
  end
  if state.comments_loading then
    -- the running load may predate the write that forced this one
    state.comments_reload_queued = state.comments_reload_queued or opts.force == true
    return
  end

  -- Local reviews: the store is a file next to the repo, read synchronously.
  if state.provider == "local" then
    return require("review_mode.providers.local").load_comments()
  end

  if not state.repo or not state.pr then
    return
  end

  local generation = state.generation
  -- after a write the cache is stale by definition, so never serve it back
  local fresh = not opts.force and M.hydrate_comments()
  hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  if fresh then
    return
  end

  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").fetch_comments_async(generation)
  end

  state.comments_loading = true
  state.comments_reload_queued = false
  M.review_threads_async(generation, nil, {}, function(threads, err)
    if not core.is_current(generation) then
      return
    end

    if not threads then
      M.load_comments_from_rest_async(generation)
      return
    end

    if superseded() then
      return
    end
    state.comments, state.comment_threads = M.group_review_threads(threads)
    local key = core.cache_key()
    if key then
      M.write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    hooks.emit("comments_loaded", { repo = state.repo, pr = state.pr })
  end)
end

-- Reactions ------------------------------------------------------------------

--- Toggle one reaction on a review comment: remove it when the viewer already
--- reacted with it, add it otherwise, then reload. `comment` is a stored or
--- thread comment. callback(ok, err).
---
--- GraphQL needs the comment's node id. Comments without one (the REST
--- fallback) can only gain a reaction through REST: removing one there needs
--- the reaction's own id, which the REST comment list does not carry.
function M.toggle_reaction(comment, content, callback)
  local function done(ok, err)
    if not ok then
      vim.notify("Review Mode reaction: " .. tostring(err), vim.log.levels.WARN)
    end
    if callback then
      callback(ok, err)
    end
  end

  if state.provider == "gitlab" then
    require("review_mode.providers").unsupported("Reactions", callback)
    return
  end

  local rest_key = comments_ui.rest_reaction_key(content)
  if not state.repo or not state.pr then
    return done(false, "start Review Mode first")
  end
  if not comment or not comment.id or not rest_key then
    return done(false, "a comment and a valid reaction content are required")
  end

  local added = true
  for _, reaction in ipairs(comment.reactions or {}) do
    if reaction.content == content and reaction.viewer_has_reacted then
      added = false
    end
  end

  local args
  if comment.node_id then
    local field = added and "addReaction" or "removeReaction"
    args = {
      "api",
      "graphql",
      "-f",
      string.format(
        "query=mutation($subjectId: ID!, $content: ReactionContent!) { %s(input: {subjectId: $subjectId, content: $content}) { reaction { content } } }",
        field
      ),
      "-F",
      "subjectId=" .. comment.node_id,
      "-F",
      "content=" .. content,
    }
  elseif added then
    args = {
      "api",
      string.format("repos/%s/pulls/comments/%s/reactions", state.repo, comment.id),
      "--method",
      "POST",
      "-f",
      "content=" .. rest_key,
    }
  else
    return done(false, "this comment was loaded without a GraphQL id, so its reactions cannot be removed here")
  end

  gh_json_async(args, function(result, err)
    if not result then
      return done(false, err or "unknown error")
    end
    M.load_comments_async({ force = true })
    hooks.emit("reaction_changed", { comment_id = comment.id, content = content, added = added })
    done(true, nil)
  end)
end

-- Editing and deleting your own comments ----------------------------------------

--- The loaded comment with this id, when the viewer wrote it; otherwise nil and
--- why not. Only the GraphQL path says who wrote a comment: one loaded through
--- the REST fallback has no viewer_did_author at all, and guessing from the
--- login would be wrong for anyone reviewing under a different account.
function M.own_comment(comment_id)
  for _, list in pairs(state.comments) do
    for _, comment in ipairs(list) do
      if comment_id ~= nil and tostring(comment.id) == tostring(comment_id) then
        if comment.viewer_did_author == nil then
          return nil, "authorship is unknown for comments loaded through the REST fallback"
        end
        if comment.viewer_did_author ~= true then
          return nil, "you can only edit or delete your own comments"
        end
        return comment, nil
      end
    end
  end
  return nil, "comment not found in this review"
end

local function refuse(err, callback)
  if callback then
    callback(false, err)
  end
  return false
end

local function finish_comment_write(event, comment, callback)
  return function(output, err)
    if not output then
      refuse(err or "unknown error", callback)
      return
    end
    M.load_comments_async({ force = true })
    hooks.emit(event, { comment_id = comment.id, thread_id = comment.thread_id, path = comment.path })
    if callback then
      callback(true, nil)
    end
  end
end

function M.edit_comment(opts, callback)
  if state.provider == "gitlab" then
    require("review_mode.providers").unsupported("Editing a comment", callback)
    return false
  end
  opts = opts or {}
  local body = util.trim(opts.body or "")
  if body == "" then
    return refuse("a body is required", callback)
  end
  local comment, err = M.own_comment(opts.comment_id)
  if not comment then
    return refuse(err, callback)
  end

  gh_json_async({
    "api",
    "--method",
    "PATCH",
    string.format("repos/%s/pulls/comments/%s", state.repo, comment.id),
    "-f",
    "body=" .. body,
  }, finish_comment_write("comment_edited", comment, callback))
  return true
end

function M.delete_comment(comment_id, callback)
  if state.provider == "gitlab" then
    require("review_mode.providers").unsupported("Deleting a comment", callback)
    return false
  end
  local comment, err = M.own_comment(comment_id)
  if not comment then
    return refuse(err, callback)
  end

  -- DELETE answers 204 with an empty body, which gh_json_async cannot decode;
  -- success here is the exit code alone.
  util.system_async({
    "gh",
    "api",
    "--method",
    "DELETE",
    string.format("repos/%s/pulls/comments/%s", state.repo, comment.id),
  }, {}, finish_comment_write("comment_deleted", comment, callback))
  return true
end

return M
