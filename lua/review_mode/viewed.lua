-- Viewed/unviewed state for the PR's changed files, and the optional two-way
-- sync with GitHub's own viewed marks.
--
-- Refreshing signs and the file tree is not this module's business: it emits
-- "viewed_changed" and whoever owns the UI reacts. That is also what keeps this
-- module from having to require init.lua back.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local state = core.state
local gh_json_async = util.gh_json_async

function M.viewed_state_path()
  return state.config.viewed.state_path or vim.fs.joinpath(vim.fn.stdpath("state"), "review-mode-state.json")
end

function M.load_viewed_store()
  if state.viewed_store then
    return state.viewed_store
  end

  state.viewed_store = util.read_json_file(M.viewed_state_path()) or {}
  return state.viewed_store
end

function M.viewed_state_entry()
  local key = core.cache_key()
  if not key then
    return nil
  end

  local store = M.load_viewed_store()
  store[key] = store[key] or { viewed = {}, order = {}, sync_queue = {} }
  store[key].viewed = store[key].viewed or {}
  store[key].order = store[key].order or {}
  store[key].sync_queue = store[key].sync_queue or {}
  return store[key]
end

function M.add_viewed_order(path)
  if vim.tbl_contains(state.viewed_order, path) then
    return
  end
  state.viewed_order[#state.viewed_order + 1] = path
end

function M.remove_viewed_order(path)
  for index, item in ipairs(state.viewed_order) do
    if item == path then
      table.remove(state.viewed_order, index)
      return
    end
  end
end

function M.persist_viewed_state()
  if not state.config.viewed.enabled then
    return
  end

  local entry = M.viewed_state_entry()
  if not entry then
    return
  end

  entry.viewed = state.viewed
  entry.order = state.viewed_order
  entry.sync_queue = state.viewed_sync_queue
  local ok, err = pcall(util.write_json_file, M.viewed_state_path(), M.load_viewed_store())
  if not ok then
    vim.notify("Review Mode viewed state: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.load_viewed_state()
  state.viewed = {}
  state.viewed_order = {}

  if not state.config.viewed.enabled then
    return
  end

  local entry = M.viewed_state_entry()
  if not entry then
    return
  end

  state.viewed = vim.deepcopy(entry.viewed or {})
  state.viewed_order = vim.deepcopy(entry.order or {})
  state.viewed_sync_queue = vim.deepcopy(entry.sync_queue or {})
end

function M.set_viewed_path(path, viewed)
  if not path or not state.config.viewed.enabled then
    return false
  end

  state.dir_totals = nil

  if viewed then
    state.viewed[path] = true
    M.add_viewed_order(path)
    return true
  end

  state.viewed[path] = nil
  M.remove_viewed_order(path)
  return false
end

function M.github_viewed_files_async(generation, after, viewed, callback)
  local owner, name = core.repo_parts()
  if not owner or not name or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  local query = [[
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      files(first: 100, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          path
          viewerViewedState
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
      callback(nil, err or "GitHub viewed state query failed")
      return
    end

    local pr = result.data and result.data.repository and result.data.repository.pullRequest
    local files = pr and pr.files
    if not pr or not files then
      callback(nil, "GitHub viewed state query returned no PR files")
      return
    end

    state.pr_node_id = pr.id
    for _, file in ipairs(files.nodes or {}) do
      if file.path and file.viewerViewedState == "VIEWED" then
        viewed[file.path] = true
      end
    end

    local page_info = files.pageInfo or {}
    if page_info.hasNextPage and page_info.endCursor then
      M.github_viewed_files_async(generation, page_info.endCursor, viewed, callback)
      return
    end

    callback(viewed, nil)
  end)
end

function M.refresh_viewed_order()
  local ordered = {}
  for _, path in ipairs(state.file_order) do
    if state.viewed[path] then
      ordered[#ordered + 1] = path
    end
  end
  state.viewed_order = ordered
end

function M.apply_queued_viewed_changes()
  for path, viewed in pairs(state.viewed_sync_queue or {}) do
    M.set_viewed_path(path, viewed == true)
  end
end

function M.sync_viewed_from_github_async(generation, force)
  if
    not state.config.viewed.enabled
    or (not force and not state.config.viewed.sync)
    or state.viewed_loading
    or not state.repo
    or not state.pr
  then
    return
  end

  state.viewed_loading = true
  M.github_viewed_files_async(generation, nil, {}, function(viewed, err)
    state.viewed_loading = false
    if not core.is_current(generation) then
      return
    end

    if not viewed then
      vim.notify("Review Mode viewed sync failed: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.viewed = viewed
    M.apply_queued_viewed_changes()
    M.refresh_viewed_order()
    M.persist_viewed_state()
    hooks.emit("viewed_changed", { path = nil, source = "github" })
    vim.schedule(function()
      M.flush_viewed_sync()
    end)
  end)
end

function M.github_pr_node_id_async(generation, callback)
  if state.pr_node_id then
    callback(state.pr_node_id, nil)
    return
  end

  local owner, name = core.repo_parts()
  if not owner or not name or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  local query = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
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
    "owner=" .. owner,
    "-F",
    "name=" .. name,
    "-F",
    "number=" .. tostring(state.pr),
  }, function(result, err)
    if not core.is_current(generation) then
      return
    end

    local pr_id = result
      and result.data
      and result.data.repository
      and result.data.repository.pullRequest
      and result.data.repository.pullRequest.id
    state.pr_node_id = pr_id
    callback(pr_id, pr_id and nil or err or "GitHub PR id query failed")
  end)
end

function M.queue_viewed_sync(path, viewed)
  if not path then
    return
  end

  state.viewed_sync_queue[path] = viewed == true
  M.persist_viewed_state()
end

function M.clear_queued_viewed_sync(path)
  if not path or state.viewed_sync_queue[path] == nil then
    return
  end

  state.viewed_sync_queue[path] = nil
  M.persist_viewed_state()
end

function M.sync_viewed_path_to_github_async(path, viewed, opts)
  opts = opts or {}
  local function done(ok)
    if opts.on_done then
      opts.on_done(ok)
    end
  end

  if not state.config.viewed.enabled or not state.config.viewed.sync or not path then
    done(false)
    return
  end

  local generation = state.generation
  M.github_pr_node_id_async(generation, function(pr_id, err)
    if not pr_id then
      M.queue_viewed_sync(path, viewed)
      vim.notify("Review Mode viewed sync queued: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      done(false)
      return
    end

    local field = viewed and "markFileAsViewed" or "unmarkFileAsViewed"
    local mutation = string.format(
      [[
mutation($pullRequestId: ID!, $path: String!) {
  %s(input: {pullRequestId: $pullRequestId, path: $path}) {
    clientMutationId
  }
}
]],
      field
    )

    gh_json_async({
      "api",
      "graphql",
      "-f",
      "query=" .. mutation,
      "-F",
      "pullRequestId=" .. pr_id,
      "-F",
      "path=" .. path,
    }, function(result, mutation_err)
      if not core.is_current(generation) then
        return
      end

      if not result then
        M.queue_viewed_sync(path, viewed)
        vim.notify("Review Mode viewed sync queued: " .. tostring(mutation_err or "unknown error"), vim.log.levels.WARN)
        done(false)
        return
      end

      M.clear_queued_viewed_sync(path)
      done(true)
    end)
  end)
end

-- The guard holds the generation that owns the in-flight write rather than a
-- bare flag. Stale callbacks bail on core.is_current() without reaching on_done, and
-- M.refresh() bumps the generation without resetting state, so a boolean would
-- stay set forever and wedge every later flush. Stamping it means a new
-- generation simply does not match, and a late callback cannot clear a guard
-- that a newer flush now owns.
function M.flush_viewed_sync()
  if
    not state.config.viewed.enabled
    or not state.config.viewed.sync
    or state.viewed_sync_loading == state.generation
    or vim.tbl_isempty(state.viewed_sync_queue)
  then
    return
  end

  local path, viewed = next(state.viewed_sync_queue)
  if not path then
    return
  end

  local generation = state.generation
  state.viewed_sync_loading = generation
  M.sync_viewed_path_to_github_async(path, viewed, {
    on_done = function(ok)
      if state.viewed_sync_loading ~= generation then
        return
      end

      state.viewed_sync_loading = nil
      -- a failed entry stays queued for the next sync rather than spinning here
      if ok and not vim.tbl_isempty(state.viewed_sync_queue) then
        M.flush_viewed_sync()
      end
    end,
  })
end

return M
