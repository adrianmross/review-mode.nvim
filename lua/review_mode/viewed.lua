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
  entry.hunks = state.hunk_viewed
  -- One file holds every PR, and another Neovim may have written its own PRs
  -- since this one read it: merge this PR's entry into what is on disk now,
  -- rather than writing back a stale copy of everyone else's.
  local path = M.viewed_state_path()
  local ok, err = pcall(function()
    local store = util.read_json_file(path) or {}
    store[core.cache_key()] = entry
    state.viewed_store = store
    util.write_json_file(path, store)
  end)
  if not ok then
    vim.notify("Review Mode viewed state: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.load_viewed_state()
  state.viewed = {}
  state.viewed_order = {}
  state.hunk_viewed = {}

  if not state.config.viewed.enabled then
    return
  end

  local entry = M.viewed_state_entry()
  if not entry then
    return
  end

  state.hunk_viewed = vim.deepcopy(entry.hunks or {})
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

-- Hunk-level viewed ------------------------------------------------------------
-- GitHub only knows whole files. A hunk is remembered by a hash of its +/- lines
-- rather than its line number, so it stays viewed when an unrelated push shifts
-- it, and comes back unviewed exactly when its own content changes.

--- One key per hunk, from each hunk's +/- lines only, so context or "\ No
--- newline" lines (gitsigns may include them, git -U0 does not) never change it.
--- Identical hunks in one file get an occurrence suffix, so marking one does
--- not mark its twin.
function M.hunk_keys(bodies)
  local keys, seen = {}, {}
  for index, body in ipairs(bodies or {}) do
    local changed = vim.tbl_filter(function(line)
      return line:match("^[-+]") ~= nil
    end, body)
    local hash = vim.fn.sha256(table.concat(changed, "\n"))
    seen[hash] = (seen[hash] or 0) + 1
    keys[index] = seen[hash] > 1 and (hash .. "#" .. seen[hash]) or hash
  end
  return keys
end

function M.is_hunk_viewed(path, key)
  return key ~= nil and state.config.viewed.enabled and (state.hunk_viewed[path] or {})[key] == true
end

function M.set_hunk_viewed(path, key, viewed)
  if not path or not key or not state.config.viewed.enabled then
    return
  end
  state.hunk_viewed[path] = state.hunk_viewed[path] or {}
  state.hunk_viewed[path][key] = viewed and true or nil
  if vim.tbl_isempty(state.hunk_viewed[path]) then
    state.hunk_viewed[path] = nil
  end
  M.persist_viewed_state()
  hooks.emit("viewed_changed", { path = path, source = "hunk" })
end

--- viewed, total for a file's hunks; nil when its hunks are not loaded, viewed
--- tracking is off, or there is no path.
function M.hunk_progress(path)
  local keys = state.config.viewed.enabled and path and state.hunk_hashes[path]
  if not keys then
    return nil
  end
  local viewed = 0
  for _, key in ipairs(keys) do
    if M.is_hunk_viewed(path, key) then
      viewed = viewed + 1
    end
  end
  return viewed, #keys
end
-- End hunk-level viewed --------------------------------------------------------

function M.github_viewed_files_async(generation, after, viewed, callback)
  if state.provider == "gitlab" then
    callback(nil, "GitHub viewed-state sync is not supported on GitLab yet")
    return
  end
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

--- Pull GitHub's viewed marks. merge_local (turning sync on, a forced sync):
--- marks made here that GitHub does not have are queued for it rather than
--- replaced by GitHub's set, so they are pushed instead of lost.
function M.sync_viewed_from_github_async(generation, force, merge_local)
  if
    not state.config.viewed.enabled
    or (not force and not state.config.viewed.sync)
    -- stamped like viewed_sync_loading: a query outlived by :ReviewModeRefresh
    -- never calls back, so a bare flag would stay set and block every sync
    or state.viewed_loading == generation
    or not state.repo
    or not state.pr
  then
    return
  end

  state.viewed_loading = generation
  M.github_viewed_files_async(generation, nil, {}, function(viewed, err)
    if state.viewed_loading == generation then
      state.viewed_loading = false
    end
    if not core.is_current(generation) then
      return
    end

    if not viewed then
      vim.notify("Review Mode viewed sync failed: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    if merge_local then
      for path in pairs(state.viewed) do
        if not viewed[path] and state.viewed_sync_queue[path] == nil then
          state.viewed_sync_queue[path] = true
        end
      end
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
  if state.provider == "gitlab" then
    callback(nil, "GitHub viewed-state sync is not supported on GitLab yet")
    return
  end
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

  -- gh's own response cache. A PR's node id never changes, so this one is safe
  -- to serve stale and is the only repeating gh read here that is: the viewed
  -- state itself must not be, or a mark made on github.com would not show up.
  -- (`--cache` is a flag of `gh api` alone -- `gh pr view` and `gh repo view`
  -- reject it, verified against gh 2.72.0.)
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

  gh_json_async(vim.list_extend(args, util.gh_cache_args()), function(result, err)
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

--- Drop path from the queue once `viewed` reached GitHub -- only if that is
--- still what is queued: a toggle made while the mutation was in flight queued
--- the opposite, and that one has not been sent.
function M.clear_queued_viewed_sync(path, viewed)
  if not path or state.viewed_sync_queue[path] == nil or state.viewed_sync_queue[path] ~= (viewed == true) then
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

      M.clear_queued_viewed_sync(path, viewed)
      done(true)
    end)
  end)
end

-- The guard holds the generation that owns the in-flight write rather than a
-- bare flag. Stale callbacks bail on core.is_current() without reaching on_done, and
-- M.refresh() bumps the generation without resetting state, so a boolean would
-- stay set forever and wedge every later flush. Stamping it means a new
-- generation simply does not match, and a late callback cannot clear a guard
-- that a newer flush now owns. A flush asked for while one is in flight is
-- remembered in viewed_sync_pending and run once the in-flight one settles.
function M.flush_viewed_sync()
  if not state.config.viewed.enabled or not state.config.viewed.sync then
    return
  end
  if state.viewed_sync_loading == state.generation then
    state.viewed_sync_pending = true
    return
  end
  state.viewed_sync_pending = false
  if vim.tbl_isempty(state.viewed_sync_queue) then
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
      -- a failed entry stays queued for the next sync rather than spinning
      -- here, unless another flush was asked for while this one was in flight
      if state.viewed_sync_pending or (ok and not vim.tbl_isempty(state.viewed_sync_queue)) then
        M.flush_viewed_sync()
      end
    end,
  })
end

return M
