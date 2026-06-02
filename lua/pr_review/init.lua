local M = {}

local ns = vim.api.nvim_create_namespace("pr_review_normal")
local diff_ns = vim.api.nvim_create_namespace("pr_review_diff")
local cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "pr-review-comments")
local defaults = {
  auto_open_first_change = true,
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
    sign_text = "◆",
    sign_hl_group = "DiagnosticInfo",
    virtual_text = true,
  },
  diff = {
    fast_diffopt = "internal,filler,closeoff,indent-heuristic,linematch:0",
    full_file = false,
    layout = "side_by_side",
    partial_line_highlights = true,
    unified_context = 3,
    use_fast_diffopt = true,
  },
  gitsigns = {
    enabled = true,
  },
  nvim_tree = {
    enabled = true,
    show_comments = true,
    show_viewed = true,
  },
  viewed = {
    enabled = true,
    sync = false,
    state_path = nil,
  },
  performance = {
    ui_refresh_debounce_ms = 50,
    hunk_prefetch = {
      enabled = true,
      count = 8,
      concurrency = 2,
      focused_delay_ms = 0,
      gitsigns_delay_ms = 5,
    },
    background_hunk_scan = {
      enabled = true,
      max_files = 5000,
      delay_ms = 250,
    },
  },
  commands = true,
}

local state = {
  active = false,
  config = vim.deepcopy(defaults),
  repo = nil,
  pr = nil,
  base = nil,
  head = nil,
  root = nil,
  files = {},
  file_order = {},
  file_index = {},
  dirs = {},
  hunks = {},
  hunks_loaded = {},
  hunks_loading = {},
  hunk_callbacks = {},
  prefetch_queue = {},
  prefetch_seen = {},
  prefetch_active = 0,
  background_hunk_scan_loading = false,
  comments = {},
  comment_threads = {},
  comments_loading = false,
  viewed = {},
  viewed_order = {},
  viewed_sync_queue = {},
  viewed_store = nil,
  viewed_loading = false,
  viewed_sync_loading = false,
  pr_node_id = nil,
  generation = 0,
  maps_loaded = false,
  maps_loading = false,
  metadata_loaded = false,
  ui_refresh_pending = false,
  old_win = nil,
  old_buf = nil,
  old_target_win = nil,
  old_target_buf = nil,
  old_loading = false,
  old_diffopt = nil,
  old_fold_options = nil,
  old_layout = nil,
  old_path = nil,
  old_closing = false,
}

local setup_done = false
local diff_text_hl = "PrReviewDiffText"

local function normalize_config(opts)
  opts = opts or {}
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if config.diff.layout ~= "side_by_side" and config.diff.layout ~= "unified" then
    config.diff.layout = defaults.diff.layout
  end
  config.diff.unified_context = math.max(0, tonumber(config.diff.unified_context) or defaults.diff.unified_context)

  return config
end

local function env_value(name)
  local value = vim.env[name]
  if value and value ~= "" then
    return value
  end
  return nil
end

local function trim(value)
  return vim.trim(value or "")
end

local function system(args, opts)
  opts = opts or {}
  local result = vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }):wait()
  if result.code ~= 0 then
    return nil, trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  if opts.raw then
    return result.stdout
  end
  return trim(result.stdout)
end

local function system_async(args, opts, callback)
  opts = opts or {}
  vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, trim(result.stderr ~= "" and result.stderr or result.stdout))
        return
      end
      if opts.raw then
        callback(result.stdout, nil)
        return
      end
      callback(trim(result.stdout), nil)
    end)
  end)
end

local function gh_json(args)
  local full = vim.list_extend({ "gh" }, args)
  local stdout, err = system(full)
  if not stdout then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, "Failed to decode gh JSON output"
  end
  return decoded
end

local function gh_json_async(args, callback)
  local full = vim.list_extend({ "gh" }, args)
  system_async(full, {}, function(stdout, err)
    if not stdout then
      callback(nil, err)
      return
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok then
      callback(nil, "Failed to decode gh JSON output")
      return
    end
    callback(decoded, nil)
  end)
end

local is_current

local function repo_slug_async(generation, callback)
  local repo = env_value("GH_REVIEW_REPO")
  if repo then
    callback(repo, nil)
    return
  end

  system_async({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }, {}, function(slug, err)
    if not is_current(generation) then
      return
    end
    callback(slug, err)
  end)
end

local function pr_view_args()
  local args = {
    "pr",
    "view",
  }

  local pr = env_value("GH_REVIEW_PR")
  if pr then
    args[#args + 1] = pr
  end

  vim.list_extend(args, {
    "--json",
    "baseRefName,headRefOid,number",
  })
  return args
end

local function pr_meta_async(generation, callback)
  gh_json_async(pr_view_args(), function(meta, err)
    if not is_current(generation) then
      return
    end
    callback(meta, err)
  end)
end

local function repo_root()
  local cwd = vim.uv.cwd()
  if vim.fs.root then
    local root = vim.fs.root(cwd, ".git")
    if root then
      return root
    end
  end
  return system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
end

local function base_ref()
  local base = state.base or "main"
  if base:match("^origin/") or base:match("^refs/") or base:match("^%x%x%x%x%x%x%x+") then
    return base
  end
  return "origin/" .. base
end

local function cache_key()
  if not state.repo or not state.pr then
    return nil
  end
  return string.format("%s#%s", state.repo, state.pr)
end

local function next_generation()
  state.generation = state.generation + 1
  return state.generation
end

is_current = function(generation)
  return state.active and state.generation == generation
end

local function reset_changed_data()
  state.files = {}
  state.file_order = {}
  state.file_index = {}
  state.dirs = {}
  state.hunks = {}
  state.hunks_loaded = {}
  state.hunks_loading = {}
  state.hunk_callbacks = {}
  state.prefetch_queue = {}
  state.prefetch_seen = {}
  state.prefetch_active = 0
  state.background_hunk_scan_loading = false
  state.maps_loaded = false
  state.maps_loading = false
end

local function reset_review_data()
  reset_changed_data()
  state.comments = {}
  state.comment_threads = {}
  state.comments_loading = false
  state.viewed = {}
  state.viewed_order = {}
  state.viewed_sync_queue = {}
  state.viewed_loading = false
  state.viewed_sync_loading = false
  state.pr_node_id = nil
end

local function split_blob_lines(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function read_json_file(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local stat = vim.uv.fs_fstat(fd)
  local content = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)

  if not content or content == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  return decoded
end

local function write_json_file(path, value)
  local dir = vim.fs.dirname(path)
  if dir then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

local function cache_path(key)
  return vim.fs.joinpath(cache_dir, key:gsub("[^%w_.-]", "_") .. ".json")
end

local function read_comment_cache(key)
  return read_json_file(cache_path(key))
end

local function write_comment_cache_entry(key, grouped, threads)
  pcall(function()
    write_json_file(cache_path(key), { fetched_at = os.time(), grouped = grouped, threads = threads or {} })
  end)
end

local function group_comments(comments)
  local grouped = {}
  for _, comment in ipairs(comments or {}) do
    if comment.path then
      grouped[comment.path] = grouped[comment.path] or {}
      table.insert(grouped[comment.path], comment)
    end
  end
  return grouped
end

local function normalize_thread_comment(thread, comment)
  local path = comment.path or thread.path
  if not path then
    return nil
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
    is_resolved = thread.isResolved == true,
    is_outdated = thread.isOutdated == true,
  }
end

local function group_review_threads(threads)
  local grouped = {}
  local by_path = {}
  for _, thread in ipairs(threads or {}) do
    if thread.path then
      by_path[thread.path] = by_path[thread.path] or {}
      by_path[thread.path][#by_path[thread.path] + 1] = thread
    end

    local comments = thread.comments and thread.comments.nodes or {}
    for _, comment in ipairs(comments) do
      local normalized = normalize_thread_comment(thread, comment)
      if normalized then
        grouped[normalized.path] = grouped[normalized.path] or {}
        grouped[normalized.path][#grouped[normalized.path] + 1] = normalized
      end
    end
  end

  return grouped, by_path
end

local function hydrate_comments()
  local key = cache_key()
  if not key then
    return false
  end

  local cached = read_comment_cache(key)
  if not cached or type(cached.grouped) ~= "table" then
    return false
  end

  state.comments = cached.grouped
  state.comment_threads = cached.threads or {}
  return (os.time() - tonumber(cached.fetched_at or 0)) < state.config.comments.cache_ttl_seconds
end

local function viewed_state_path()
  return state.config.viewed.state_path or vim.fs.joinpath(vim.fn.stdpath("state"), "pr-review-state.json")
end

local function load_viewed_store()
  if state.viewed_store then
    return state.viewed_store
  end

  state.viewed_store = read_json_file(viewed_state_path()) or {}
  return state.viewed_store
end

local function viewed_state_entry()
  local key = cache_key()
  if not key then
    return nil
  end

  local store = load_viewed_store()
  store[key] = store[key] or { viewed = {}, order = {}, sync_queue = {} }
  store[key].viewed = store[key].viewed or {}
  store[key].order = store[key].order or {}
  store[key].sync_queue = store[key].sync_queue or {}
  return store[key]
end

local function add_viewed_order(path)
  if vim.tbl_contains(state.viewed_order, path) then
    return
  end
  state.viewed_order[#state.viewed_order + 1] = path
end

local function remove_viewed_order(path)
  for index, item in ipairs(state.viewed_order) do
    if item == path then
      table.remove(state.viewed_order, index)
      return
    end
  end
end

local function persist_viewed_state()
  if not state.config.viewed.enabled then
    return
  end

  local entry = viewed_state_entry()
  if not entry then
    return
  end

  entry.viewed = state.viewed
  entry.order = state.viewed_order
  entry.sync_queue = state.viewed_sync_queue
  local ok, err = pcall(write_json_file, viewed_state_path(), load_viewed_store())
  if not ok then
    vim.notify("PR review viewed state: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function load_viewed_state()
  state.viewed = {}
  state.viewed_order = {}

  if not state.config.viewed.enabled then
    return
  end

  local entry = viewed_state_entry()
  if not entry then
    return
  end

  state.viewed = vim.deepcopy(entry.viewed or {})
  state.viewed_order = vim.deepcopy(entry.order or {})
  state.viewed_sync_queue = vim.deepcopy(entry.sync_queue or {})
end

local function set_viewed_path(path, viewed)
  if not path or not state.config.viewed.enabled then
    return false
  end

  if viewed then
    state.viewed[path] = true
    add_viewed_order(path)
    return true
  end

  state.viewed[path] = nil
  remove_viewed_order(path)
  return false
end

local function buf_relpath(bufnr)
  bufnr = bufnr or 0
  if bufnr ~= 0 and not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" or not state.root then
    return nil
  end
  return vim.fs.relpath(state.root, name)
end

local function current_relpath()
  return buf_relpath(0)
end

local function current_file_index(path)
  path = path or current_relpath()
  if not path then
    return nil
  end
  return state.file_index[path]
end

local function clamp_line(line)
  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  return math.max(1, math.min(line or 1, max_line))
end

local function jump_to_path(path, line)
  if not path then
    return false
  end

  local full_path = vim.fs.joinpath(state.root, path)
  if vim.uv.fs_stat(full_path) then
    vim.cmd.edit(vim.fn.fnameescape(full_path))
  else
    vim.cmd.edit(vim.fn.fnameescape(path))
  end

  vim.api.nvim_win_set_cursor(0, { clamp_line(line), 0 })
  vim.cmd("normal! zz")
  return true
end

local function comments_for_line(path, line)
  local results = {}
  for _, comment in ipairs(state.comments[path] or {}) do
    local comment_line = tonumber(comment.line) or tonumber(comment.original_line)
    local start_line = tonumber(comment.start_line) or comment_line
    if comment_line and line >= start_line and line <= comment_line then
      table.insert(results, comment)
    end
  end
  return results
end

local function comment_line(comment)
  return tonumber(comment.line) or tonumber(comment.original_line) or tonumber(comment.start_line)
end

local function comment_positions()
  local positions = {}
  for _, path in ipairs(state.file_order) do
    for _, comment in ipairs(state.comments[path] or {}) do
      local line = comment_line(comment)
      if line then
        positions[#positions + 1] = {
          path = path,
          line = line,
        }
      end
    end
  end

  table.sort(positions, function(left, right)
    local left_index = state.file_index[left.path] or math.huge
    local right_index = state.file_index[right.path] or math.huge
    if left_index == right_index then
      return left.line < right.line
    end
    return left_index < right_index
  end)

  return positions
end

local function comment_summary(comment)
  local body = trim((comment.body or ""):match("([^\n\r]+)") or "")
  if body == "" then
    body = "comment"
  elseif #body > 80 then
    body = body:sub(1, 77) .. "..."
  end
  local author = comment.user and comment.user.login or "reviewer"
  return string.format("%s: %s", author, body)
end

local function clear_buffer_marks(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function annotate_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear_buffer_marks(bufnr)

  if not state.active or not state.root then
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end

  local path = vim.fs.relpath(state.root, name)
  local comments = path and state.comments[path] or nil
  if not comments then
    return
  end

  local grouped = {}
  for _, comment in ipairs(comments) do
    local line = tonumber(comment.line) or tonumber(comment.original_line)
    if line then
      grouped[line] = grouped[line] or {}
      table.insert(grouped[line], comment)
    end
  end

  for line, line_comments in pairs(grouped) do
    local sign_hl = state.config.comments.sign_hl_group or "DiagnosticInfo"
    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      sign_text = state.config.comments.sign_text or "◆",
      sign_hl_group = sign_hl,
      number_hl_group = sign_hl,
      virt_text = state.config.comments.virtual_text and {
        { " " .. comment_summary(line_comments[#line_comments]), "DiagnosticVirtualTextInfo" },
      } or nil,
      virt_text_pos = "eol",
      priority = 160,
    })
  end
end

local function annotate_open_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      annotate_buffer(bufnr)
    end
  end
end

local function refresh_tree()
  if not state.config.nvim_tree.enabled then
    return
  end

  pcall(function()
    require("nvim-tree.api").tree.reload()
  end)
end

local function refresh_comments_ui()
  annotate_open_buffers()
  refresh_tree()
end

local function schedule_comments_ui_refresh()
  if state.ui_refresh_pending then
    return
  end

  state.ui_refresh_pending = true
  vim.defer_fn(function()
    state.ui_refresh_pending = false
    refresh_comments_ui()
  end, state.config.performance.ui_refresh_debounce_ms)
end

local function repo_parts()
  local owner, name = tostring(state.repo or ""):match("^([^/]+)/(.+)$")
  return owner, name
end

local function rest_comments_async(generation, page, comments, callback)
  if not state.repo or not state.pr then
    callback(nil, "could not determine GitHub repository or PR")
    return
  end

  gh_json_async({
    "api",
    string.format("repos/%s/pulls/%s/comments?per_page=100&page=%d", state.repo, state.pr, page),
  }, function(result, err)
    if not is_current(generation) then
      return
    end

    if not result then
      callback(nil, err)
      return
    end

    vim.list_extend(comments, result)
    if #result == 100 then
      rest_comments_async(generation, page + 1, comments, callback)
      return
    end

    callback(comments, nil)
  end)
end

local function review_threads_async(generation, after, threads, callback)
  local owner, name = repo_parts()
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
              author {
                login
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
    if not is_current(generation) then
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
      review_threads_async(generation, page_info.endCursor, threads, callback)
      return
    end

    callback(threads, nil)
  end)
end

local function load_comments_from_rest_async(generation)
  rest_comments_async(generation, 1, {}, function(comments, err)
    if not is_current(generation) then
      return
    end

    state.comments_loading = false
    if not comments then
      vim.notify("Failed to load PR comments: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.comments = group_comments(comments)
    state.comment_threads = {}
    local key = cache_key()
    if key then
      write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    schedule_comments_ui_refresh()
  end)
end

local function load_comments_async()
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
  local fresh = hydrate_comments()
  schedule_comments_ui_refresh()
  if fresh then
    return
  end

  state.comments_loading = true
  review_threads_async(generation, nil, {}, function(threads, err)
    if not is_current(generation) then
      return
    end

    if not threads then
      load_comments_from_rest_async(generation)
      return
    end

    state.comments, state.comment_threads = group_review_threads(threads)
    local key = cache_key()
    if key then
      write_comment_cache_entry(key, state.comments, state.comment_threads)
    end
    state.comments_loading = false
    schedule_comments_ui_refresh()
  end)
end

local function github_viewed_files_async(generation, after, viewed, callback)
  local owner, name = repo_parts()
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
    if not is_current(generation) then
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
      github_viewed_files_async(generation, page_info.endCursor, viewed, callback)
      return
    end

    callback(viewed, nil)
  end)
end

local function refresh_viewed_order()
  local ordered = {}
  for _, path in ipairs(state.file_order) do
    if state.viewed[path] then
      ordered[#ordered + 1] = path
    end
  end
  state.viewed_order = ordered
end

local function apply_queued_viewed_changes()
  for path, viewed in pairs(state.viewed_sync_queue or {}) do
    set_viewed_path(path, viewed == true)
  end
end

local function sync_viewed_from_github_async(generation, force)
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
  github_viewed_files_async(generation, nil, {}, function(viewed, err)
    state.viewed_loading = false
    if not is_current(generation) then
      return
    end

    if not viewed then
      vim.notify("PR review viewed sync failed: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.viewed = viewed
    apply_queued_viewed_changes()
    refresh_viewed_order()
    persist_viewed_state()
    schedule_comments_ui_refresh()
    vim.schedule(function()
      M.flush_viewed_sync()
    end)
  end)
end

local function github_pr_node_id_async(generation, callback)
  if state.pr_node_id then
    callback(state.pr_node_id, nil)
    return
  end

  local owner, name = repo_parts()
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
    if not is_current(generation) then
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

local function queue_viewed_sync(path, viewed)
  if not path then
    return
  end

  state.viewed_sync_queue[path] = viewed == true
  persist_viewed_state()
end

local function clear_queued_viewed_sync(path)
  if not path or state.viewed_sync_queue[path] == nil then
    return
  end

  state.viewed_sync_queue[path] = nil
  persist_viewed_state()
end

local function sync_viewed_path_to_github_async(path, viewed, opts)
  opts = opts or {}
  if not state.config.viewed.enabled or not state.config.viewed.sync or not path then
    return
  end

  local generation = state.generation
  github_pr_node_id_async(generation, function(pr_id, err)
    if not pr_id then
      queue_viewed_sync(path, viewed)
      vim.notify("PR review viewed sync queued: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
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
      if not is_current(generation) then
        return
      end

      if not result then
        queue_viewed_sync(path, viewed)
        vim.notify("PR review viewed sync queued: " .. tostring(mutation_err or "unknown error"), vim.log.levels.WARN)
        return
      end

      clear_queued_viewed_sync(path)
      if opts.on_success then
        opts.on_success()
      end
    end)
  end)
end

function M.flush_viewed_sync()
  if
    not state.config.viewed.enabled
    or not state.config.viewed.sync
    or state.viewed_sync_loading
    or vim.tbl_isempty(state.viewed_sync_queue)
  then
    return
  end

  local path, viewed = next(state.viewed_sync_queue)
  if not path then
    return
  end

  state.viewed_sync_loading = true
  sync_viewed_path_to_github_async(path, viewed, {
    on_success = function()
      state.viewed_sync_loading = false
      if not vim.tbl_isempty(state.viewed_sync_queue) then
        M.flush_viewed_sync()
      end
    end,
  })
  vim.defer_fn(function()
    state.viewed_sync_loading = false
  end, 1000)
end

local function parse_changed_files(output)
  state.files = {}
  state.file_order = {}
  state.file_index = {}
  state.dirs = {}
  state.hunks = {}
  state.hunks_loaded = {}
  state.hunks_loading = {}
  state.hunk_callbacks = {}

  for line in (output or ""):gmatch("[^\n]+") do
    local status, rest = line:match("^(%S+)%s+(.+)$")
    if status and rest then
      local path = rest:match("[^\t]+$") or rest
      state.files[path] = status
      if not status:match("^D") then
        state.file_order[#state.file_order + 1] = path
        state.file_index[path] = #state.file_order
      end

      local dir = vim.fs.dirname(path)
      while dir and dir ~= "." and dir ~= "" do
        state.dirs[dir] = true
        dir = vim.fs.dirname(dir)
      end
    end
  end
end

local function parse_hunks_by_path(patch)
  local by_path = {}
  local current_path = nil
  for line in (patch or ""):gmatch("[^\n]+") do
    local path = line:match("^%+%+%+ b/(.+)$")
    if path then
      current_path = path
      by_path[current_path] = by_path[current_path] or {}
    elseif line:match("^%+%+%+ /dev/null$") then
      current_path = nil
    elseif current_path then
      local new_start = line:match("^@@ %-%d+,?%d* %+(%d+),?%d* @@")
      if new_start then
        by_path[current_path][#by_path[current_path] + 1] = math.max(1, tonumber(new_start) or 1)
      end
    end
  end
  return by_path
end

local function parse_hunks(patch, path)
  return parse_hunks_by_path(patch)[path] or {}
end

local function build_changed_maps_async(generation, callback)
  reset_changed_data()
  state.maps_loading = true
  system_async(
    { "git", "diff", "--name-status", "--find-renames", "--no-ext-diff", "--no-color", base_ref() .. "...HEAD" },
    { cwd = state.root },
    function(output, err)
      if not is_current(generation) then
        return
      end

      state.maps_loading = false
      if not output then
        state.maps_loaded = true
        callback(err or "failed to load changed files")
        return
      end

      parse_changed_files(output)
      state.maps_loaded = true
      callback(nil)
    end
  )
end

local function finish_hunks_for_path(path, hunks)
  state.hunks[path] = hunks or {}
  state.hunks_loaded[path] = true
  state.hunks_loading[path] = false
  state.prefetch_seen[path] = nil

  local callbacks = state.hunk_callbacks[path] or {}
  state.hunk_callbacks[path] = nil
  for _, queued_callback in ipairs(callbacks) do
    queued_callback(state.hunks[path])
  end
end

local function gitsigns_hunk_lines(bufnr)
  if not state.config.gitsigns.enabled or not package.loaded["gitsigns"] then
    return nil
  end

  bufnr = bufnr or 0
  if bufnr ~= 0 and not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  if vim.bo[bufnr].modified then
    return nil
  end

  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok or type(gitsigns.get_hunks) ~= "function" then
    return nil
  end

  local hunks_ok, hunks = pcall(gitsigns.get_hunks, bufnr)
  if not hunks_ok or type(hunks) ~= "table" then
    return nil
  end

  local lines = {}
  for _, hunk in ipairs(hunks) do
    local added = type(hunk) == "table" and hunk.added or nil
    local line = type(added) == "table" and tonumber(added.start) or nil
    if line then
      lines[#lines + 1] = math.max(1, line)
    end
  end

  if #lines == 0 then
    return nil
  end

  table.sort(lines)
  return lines
end

local function should_delay_for_gitsigns(bufnr)
  bufnr = bufnr or 0
  if bufnr ~= 0 and not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  return state.config.gitsigns.enabled and package.loaded["gitsigns"] and not vim.bo[bufnr].modified
end

local function finish_hunks_from_gitsigns(path, bufnr)
  if not path or state.hunks_loaded[path] then
    return state.hunks_loaded[path] == true
  end

  if buf_relpath(bufnr or 0) ~= path then
    return false
  end

  local lines = gitsigns_hunk_lines(bufnr)
  if not lines then
    return false
  end

  finish_hunks_for_path(path, lines)
  return true
end

local function load_hunks_for_paths(paths, on_done)
  local pending_paths = {}
  local needs_rename_detection = false
  for _, path in ipairs(paths) do
    if path and state.files[path] and not state.hunks_loaded[path] and not state.hunks_loading[path] then
      state.hunks_loading[path] = true
      pending_paths[#pending_paths + 1] = path
      if tostring(state.files[path]):match("^R") then
        needs_rename_detection = true
      end
    end
  end

  if #pending_paths == 0 then
    if on_done then
      on_done()
    end
    return
  end

  local generation = state.generation
  local args = {
    "git",
    "diff",
    "--unified=0",
    "--diff-filter=ACMRT",
    "--no-ext-diff",
    "--no-color",
    base_ref() .. "...HEAD",
    "--",
  }
  if needs_rename_detection then
    table.insert(args, 5, "--find-renames")
  else
    table.insert(args, 5, "--no-renames")
  end
  vim.list_extend(args, pending_paths)

  system_async(args, { cwd = state.root }, function(patch)
    if not is_current(generation) then
      return
    end

    local by_path = parse_hunks_by_path(patch or "")
    for _, path in ipairs(pending_paths) do
      finish_hunks_for_path(path, by_path[path] or {})
    end

    if on_done then
      on_done()
    end
  end)
end

local function load_hunks_for_path(path, callback)
  if state.hunks_loaded[path] then
    callback(state.hunks[path] or {})
    return
  end

  if finish_hunks_from_gitsigns(path, 0) then
    callback(state.hunks[path] or {})
    return
  end

  state.hunk_callbacks[path] = state.hunk_callbacks[path] or {}
  state.hunk_callbacks[path][#state.hunk_callbacks[path] + 1] = callback
  if state.hunks_loading[path] then
    return
  end

  load_hunks_for_paths({ path })
end

local function maybe_with_hunks(path, callback)
  if not path then
    return
  end

  load_hunks_for_path(path, callback)
end

local function pump_hunk_prefetch()
  local config = state.config.performance.hunk_prefetch
  if not config.enabled then
    return
  end

  while state.prefetch_active < config.concurrency and #state.prefetch_queue > 0 do
    local batch = {}
    while #batch < config.count and #state.prefetch_queue > 0 do
      local path = table.remove(state.prefetch_queue, 1)
      if path and state.files[path] and not state.hunks_loaded[path] and not state.hunks_loading[path] then
        batch[#batch + 1] = path
      end
    end

    if #batch == 0 then
      return
    end

    state.prefetch_active = state.prefetch_active + 1
    load_hunks_for_paths(batch, function()
      state.prefetch_active = math.max(0, state.prefetch_active - 1)
      pump_hunk_prefetch()
    end)
  end
end

local function enqueue_hunk_prefetch(paths)
  local config = state.config.performance.hunk_prefetch
  if not config.enabled or not state.maps_loaded then
    return
  end

  for _, path in ipairs(paths or {}) do
    if
      path
      and state.files[path]
      and not state.hunks_loaded[path]
      and not state.hunks_loading[path]
      and not state.prefetch_seen[path]
    then
      state.prefetch_seen[path] = true
      state.prefetch_queue[#state.prefetch_queue + 1] = path
    end
  end

  pump_hunk_prefetch()
end

local function nearby_paths(path)
  local results = {}
  local count = state.config.performance.hunk_prefetch.count
  local index = path and state.file_index[path] or 1
  if not index then
    index = 1
  end

  for offset = 0, count - 1 do
    local next_path = state.file_order[index + offset]
    if next_path then
      results[#results + 1] = next_path
    end
  end

  if path and state.file_index[path] then
    for offset = 1, math.floor(count / 2) do
      local prev_path = state.file_order[state.file_index[path] - offset]
      if prev_path then
        results[#results + 1] = prev_path
      end
    end
  end

  return results
end

local function prefetch_near_path(path)
  enqueue_hunk_prefetch(nearby_paths(path))
end

local function prefetch_focused_path(path, bufnr)
  if
    not state.config.performance.hunk_prefetch.enabled
    or not state.maps_loaded
    or not path
    or not state.files[path]
  then
    return
  end

  if finish_hunks_from_gitsigns(path, bufnr or 0) then
    prefetch_near_path(path)
    return
  end

  if should_delay_for_gitsigns(bufnr or 0) then
    local generation = state.generation
    local delay = tonumber(state.config.performance.hunk_prefetch.gitsigns_delay_ms or 0) or 0
    vim.defer_fn(function()
      if not is_current(generation) then
        return
      end

      if finish_hunks_from_gitsigns(path, bufnr or 0) then
        prefetch_near_path(path)
        return
      end

      if not state.hunks_loaded[path] and not state.hunks_loading[path] then
        load_hunks_for_paths({ path }, function()
          prefetch_near_path(path)
        end)
      end
    end, delay)
    return
  end

  if state.hunks_loaded[path] then
    prefetch_near_path(path)
    return
  end

  if state.hunks_loading[path] then
    return
  end

  load_hunks_for_paths({ path }, function()
    prefetch_near_path(path)
  end)
end

local function prefetch_current_buffer(bufnr)
  if not state.active or not state.maps_loaded then
    return
  end

  local path = buf_relpath(bufnr or 0)
  if path and state.files[path] then
    prefetch_focused_path(path, bufnr or 0)
  end
end

local function start_background_hunk_scan()
  local config = state.config.performance.background_hunk_scan
  if
    not config.enabled
    or state.background_hunk_scan_loading
    or #state.file_order == 0
    or #state.file_order > config.max_files
  then
    return
  end

  state.background_hunk_scan_loading = true
  local generation = state.generation
  vim.defer_fn(function()
    if not is_current(generation) or not state.maps_loaded then
      state.background_hunk_scan_loading = false
      return
    end

    system_async({
      "git",
      "diff",
      "--unified=0",
      "--find-renames",
      "--diff-filter=ACMRT",
      "--no-ext-diff",
      "--no-color",
      base_ref() .. "...HEAD",
    }, { cwd = state.root }, function(patch)
      if not is_current(generation) then
        state.background_hunk_scan_loading = false
        return
      end

      local by_path = parse_hunks_by_path(patch or "")
      for _, path in ipairs(state.file_order) do
        if not state.hunks_loaded[path] then
          finish_hunks_for_path(path, by_path[path] or {})
        end
      end
      state.background_hunk_scan_loading = false
    end)
  end, config.delay_ms)
end

local function first_hunk_line(path)
  local hunks = state.hunks[path]
  return hunks and hunks[1] or 1
end

local function open_initial_change()
  if current_file_index() then
    return
  end

  local first_path = state.file_order[1]
  if first_path then
    jump_to_path(first_path, first_hunk_line(first_path))
    maybe_with_hunks(first_path, function(hunks)
      if current_relpath() == first_path then
        jump_to_path(first_path, hunks[1] or 1)
      end
    end)
  end
end

local function ensure_active()
  if state.active then
    return true
  end

  vim.notify("PR review mode is not active", vim.log.levels.WARN)
  return false
end

local function jump_changed_file(delta)
  if not ensure_active() then
    return
  end

  if not state.maps_loaded then
    vim.notify("PR review mode: changed files are still loading", vim.log.levels.INFO)
    return
  end

  if #state.file_order == 0 then
    return
  end

  local index = current_file_index() or (delta > 0 and 0 or 1)
  local next_index = ((index - 1 + delta) % #state.file_order) + 1
  local path = state.file_order[next_index]
  jump_to_path(path, first_hunk_line(path))
  prefetch_focused_path(path)
  maybe_with_hunks(path, function(hunks)
    if current_relpath() == path then
      jump_to_path(path, hunks[1] or 1)
    end
  end)
end

local function jump_hunk(delta)
  if not ensure_active() then
    return
  end

  if not state.maps_loaded then
    vim.notify("PR review mode: changed files are still loading", vim.log.levels.INFO)
    return
  end

  local path = current_relpath()
  local hunks = path and state.hunks[path] or nil
  if path and not state.hunks_loaded[path] then
    prefetch_focused_path(path)
    maybe_with_hunks(path, function()
      if current_relpath() == path then
        jump_hunk(delta)
      end
    end)
    return
  end

  if not hunks or #hunks == 0 then
    jump_changed_file(delta)
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  if delta > 0 then
    for _, hunk_line in ipairs(hunks) do
      if hunk_line > current_line then
        jump_to_path(path, hunk_line)
        return
      end
    end
  else
    for index = #hunks, 1, -1 do
      local hunk_line = hunks[index]
      if hunk_line < current_line then
        jump_to_path(path, hunk_line)
        return
      end
    end
  end

  jump_changed_file(delta)
end

local function jump_comment(delta)
  if not ensure_active() then
    return
  end

  if not state.config.comments.enabled then
    vim.notify("PR review comments are disabled", vim.log.levels.WARN)
    return
  end

  if vim.tbl_isempty(state.comments) then
    hydrate_comments()
    load_comments_async()
  end

  local positions = comment_positions()
  if #positions == 0 then
    vim.notify(
      state.comments_loading and "PR review comments are still loading" or "No PR comments loaded",
      vim.log.levels.INFO
    )
    return
  end

  local path = current_relpath()
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local current_index = current_file_index(path) or (delta > 0 and 0 or math.huge)
  local target = nil

  if delta > 0 then
    for _, position in ipairs(positions) do
      local index = state.file_index[position.path] or math.huge
      if index > current_index or (index == current_index and position.line > current_line) then
        target = position
        break
      end
    end
    target = target or positions[1]
  else
    for index = #positions, 1, -1 do
      local position = positions[index]
      local file_index = state.file_index[position.path] or 0
      if file_index < current_index or (file_index == current_index and position.line < current_line) then
        target = position
        break
      end
    end
    target = target or positions[#positions]
  end

  jump_to_path(target.path, target.line)
end

local function set_gitsigns_base()
  if not state.config.gitsigns.enabled then
    return
  end

  vim.schedule(function()
    local ok, gitsigns = pcall(require, "gitsigns")
    if ok and gitsigns.change_base then
      gitsigns.change_base(base_ref(), true, function()
        if state.active then
          prefetch_current_buffer(0)
        end
      end)
      return
    end
    pcall(vim.cmd, "Gitsigns change_base " .. base_ref() .. " --global")
  end)
end

local function restore_old_diffopt()
  if state.old_diffopt then
    vim.o.diffopt = state.old_diffopt
    state.old_diffopt = nil
  end
end

local function apply_old_diffopt()
  if not state.config.diff.use_fast_diffopt then
    return
  end

  state.old_diffopt = vim.o.diffopt
  local ok = pcall(function()
    vim.o.diffopt = state.config.diff.fast_diffopt
  end)
  if ok then
    return
  end

  vim.o.diffopt = state.old_diffopt
  state.old_diffopt = nil
end

local function disable_diff_for_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].diff = false
    end)
  end
end

local function capture_fold_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  state.old_fold_options = state.old_fold_options or {}
  if state.old_fold_options[win] then
    return
  end

  state.old_fold_options[win] = {
    foldenable = vim.wo[win].foldenable,
    foldlevel = vim.wo[win].foldlevel,
    foldmethod = vim.wo[win].foldmethod,
  }
end

local function restore_fold_options()
  for win, options in pairs(state.old_fold_options or {}) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function()
        vim.wo[win].foldmethod = options.foldmethod
        vim.wo[win].foldlevel = options.foldlevel
        vim.wo[win].foldenable = options.foldenable
      end)
    end
  end
  state.old_fold_options = nil
end

local function clear_old_diff_highlights()
  for _, bufnr in ipairs({ state.old_buf, state.old_target_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    end
  end
end

local function apply_side_by_side_context()
  local condensed = not state.config.diff.full_file
  local previous_win = vim.api.nvim_get_current_win()
  for _, win in ipairs({ state.old_target_win, state.old_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      capture_fold_options(win)
      pcall(function()
        vim.wo[win].foldmethod = "diff"
        vim.wo[win].foldenable = condensed
        if condensed then
          vim.api.nvim_set_current_win(win)
          vim.cmd("silent! normal! zM")
        else
          vim.wo[win].foldlevel = 99
          vim.api.nvim_set_current_win(win)
          vim.cmd("silent! normal! zR")
        end
      end)
    end
  end
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

local function close_old_view()
  if state.old_closing then
    return
  end

  state.old_closing = true
  disable_diff_for_window(state.old_target_win)
  disable_diff_for_window(state.old_win)
  restore_fold_options()
  clear_old_diff_highlights()

  if
    state.old_layout == "unified"
    and state.old_target_win
    and vim.api.nvim_win_is_valid(state.old_target_win)
    and state.old_target_buf
    and vim.api.nvim_buf_is_valid(state.old_target_buf)
  then
    pcall(vim.api.nvim_win_set_buf, state.old_target_win, state.old_target_buf)
  elseif state.old_win and vim.api.nvim_win_is_valid(state.old_win) then
    vim.api.nvim_win_close(state.old_win, true)
  end

  if state.old_buf and vim.api.nvim_buf_is_valid(state.old_buf) then
    pcall(vim.api.nvim_buf_delete, state.old_buf, { force = true })
  end

  state.old_win = nil
  state.old_buf = nil
  state.old_target_win = nil
  state.old_target_buf = nil
  state.old_loading = false
  state.old_layout = nil
  state.old_path = nil
  state.old_closing = false
  restore_old_diffopt()
end

local function load_review_async(generation, opts)
  opts = opts or {}
  build_changed_maps_async(generation, function(err)
    if not is_current(generation) then
      return
    end

    if err then
      vim.notify("PR review mode: " .. tostring(err), vim.log.levels.ERROR)
      return
    end

    load_viewed_state()
    refresh_tree()
    annotate_open_buffers()
    sync_viewed_from_github_async(generation)
    prefetch_current_buffer()
    prefetch_near_path(state.file_order[1])
    start_background_hunk_scan()
    if opts.open_initial and state.config.auto_open_first_change then
      open_initial_change()
    end

    vim.notify(
      string.format(
        "PR review mode: %s#%s against %s (%d files)",
        state.repo or "repo",
        state.pr or "?",
        state.base or "?",
        #state.file_order
      )
    )
  end)
end

local function load_metadata_async(generation, callback)
  local pending = 2
  local slug_result = nil
  local meta_result = nil
  local first_err = nil

  local function done()
    pending = pending - 1
    if pending > 0 or not is_current(generation) then
      return
    end

    if first_err then
      callback(nil, first_err)
      return
    end

    callback({ repo = slug_result, meta = meta_result }, nil)
  end

  repo_slug_async(generation, function(slug, err)
    if not slug and not first_err then
      first_err = err or "could not determine repository"
    end
    slug_result = slug
    done()
  end)

  pr_meta_async(generation, function(meta, err)
    if not meta and not first_err then
      first_err = err or "could not load PR metadata"
    end
    meta_result = meta
    done()
  end)
end

function M.start()
  local root, root_err = repo_root()
  if not root then
    vim.notify("PR review mode: " .. tostring(root_err or "not in a git repo"), vim.log.levels.ERROR)
    return
  end

  state.root = root
  state.active = true
  state.metadata_loaded = false
  state.repo = env_value("GH_REVIEW_REPO")
  state.pr = env_value("GH_REVIEW_PR")
  state.base = env_value("GH_REVIEW_BASE")
  state.head = env_value("GH_REVIEW_HEAD")
  local generation = next_generation()
  reset_review_data()
  close_old_view()

  local review_loading_started = false
  if state.base then
    review_loading_started = true
    set_gitsigns_base()
    load_comments_async()
    load_review_async(generation, { open_initial = true })
  else
    vim.notify("PR review mode: loading PR metadata")
  end

  load_metadata_async(generation, function(result, err)
    if not is_current(generation) then
      return
    end

    if not result then
      if review_loading_started then
        state.metadata_loaded = true
        vim.notify(
          "PR review mode metadata refresh failed: " .. tostring(err or "could not load PR metadata"),
          vim.log.levels.WARN
        )
        return
      end
      state.active = false
      vim.notify("PR review mode: " .. tostring(err or "could not load PR metadata"), vim.log.levels.ERROR)
      return
    end

    local meta = result.meta or {}
    state.repo = state.repo or result.repo
    state.pr = state.pr or tostring(meta.number or env_value("GH_REVIEW_PR") or "")
    state.base = state.base or meta.baseRefName or "main"
    state.head = state.head or meta.headRefOid
    state.metadata_loaded = true

    load_viewed_state()
    schedule_comments_ui_refresh()
    sync_viewed_from_github_async(generation)
    load_comments_async()
    if not review_loading_started then
      set_gitsigns_base()
      load_review_async(generation, { open_initial = true })
    end
  end)
end

function M.stop()
  next_generation()
  state.active = false
  state.metadata_loaded = false
  state.repo = nil
  state.pr = nil
  state.base = nil
  state.head = nil
  reset_review_data()
  close_old_view()
  annotate_open_buffers()
  refresh_tree()
  vim.notify("PR review mode stopped")
end

function M.refresh()
  if not state.active then
    M.start()
    return
  end

  if not state.metadata_loaded then
    vim.notify("PR review mode: metadata is still loading", vim.log.levels.INFO)
    return
  end

  local generation = next_generation()
  state.comments = {}
  state.comment_threads = {}
  state.comments_loading = false
  close_old_view()
  load_comments_async()
  load_review_async(generation, { open_initial = false })
end

local function diff_context_lines()
  if state.config.diff.full_file then
    return 1000000
  end
  return state.config.diff.unified_context
end

local function write_temp_diff_file(tmpdir, side, path, lines)
  local rel = vim.fs.joinpath(side, path)
  local file = vim.fs.joinpath(tmpdir, rel)
  local dir = vim.fs.dirname(file)
  if dir then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile(lines, file, "b")
  return rel
end

local function unified_diff_lines(diff, path)
  local lines = split_blob_lines(diff)
  if #lines == 0 then
    return { "No differences: " .. path }
  end

  for index, line in ipairs(lines) do
    if line:find("^diff %-%-git ") then
      lines[index] = "diff --git base/" .. path .. " head/" .. path
    elseif line:find("^%-%-%- ") and line ~= "--- /dev/null" then
      lines[index] = "--- base/" .. path
    elseif line:find("^%+%+%+ ") and line ~= "+++ /dev/null" then
      lines[index] = "+++ head/" .. path
    end
  end

  return lines
end

local function ensure_diff_highlights()
  pcall(vim.api.nvim_set_hl, 0, diff_text_hl, { default = true, link = "DiffText" })
end

local function is_deleted_diff_line(line)
  return line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---"
end

local function is_added_diff_line(line)
  return line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++"
end

local function changed_line_ranges(old_text, new_text)
  local old_len = #old_text
  local new_len = #new_text
  local prefix = 0
  local min_len = math.min(old_len, new_len)

  while prefix < min_len and old_text:byte(prefix + 1) == new_text:byte(prefix + 1) do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < min_len - prefix and old_text:byte(old_len - suffix) == new_text:byte(new_len - suffix) do
    suffix = suffix + 1
  end

  return prefix, old_len - suffix, new_len - suffix
end

local function highlight_changed_range(bufnr, row, start_col, end_col)
  if start_col >= end_col then
    return
  end

  vim.api.nvim_buf_set_extmark(bufnr, diff_ns, row, start_col, {
    end_col = end_col,
    hl_group = diff_text_hl,
    hl_mode = "replace",
  })
end

local function highlight_partial_line_pair(old_buf, old_row, old_line, new_buf, new_row, new_line, col_offset)
  local prefix, old_end, new_end = changed_line_ranges(old_line, new_line)
  highlight_changed_range(old_buf, old_row, prefix + col_offset, old_end + col_offset)
  highlight_changed_range(new_buf, new_row, prefix + col_offset, new_end + col_offset)
end

local function highlight_partial_diff_pair(bufnr, old_row, old_line, new_row, new_line)
  highlight_partial_line_pair(bufnr, old_row, old_line:sub(2), bufnr, new_row, new_line:sub(2), 1)
end

local function apply_partial_diff_highlights(bufnr)
  if not state.config.diff.partial_line_highlights then
    return
  end

  ensure_diff_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local index = 1
  while index <= #lines do
    if is_deleted_diff_line(lines[index]) then
      local deleted = {}
      while index <= #lines and is_deleted_diff_line(lines[index]) do
        deleted[#deleted + 1] = { row = index - 1, line = lines[index] }
        index = index + 1
      end

      local added = {}
      while index <= #lines and is_added_diff_line(lines[index]) do
        added[#added + 1] = { row = index - 1, line = lines[index] }
        index = index + 1
      end

      for pair_index = 1, math.min(#deleted, #added) do
        highlight_partial_diff_pair(
          bufnr,
          deleted[pair_index].row,
          deleted[pair_index].line,
          added[pair_index].row,
          added[pair_index].line
        )
      end
    else
      index = index + 1
    end
  end
end

local function parse_diff_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end

  return tonumber(old_start),
    tonumber(old_count ~= "" and old_count or "1"),
    tonumber(new_start),
    tonumber(new_count ~= "" and new_count or "1")
end

local function apply_side_by_side_partial_diff_highlights(old_buf, new_buf, diff)
  if not state.config.diff.partial_line_highlights then
    return
  end

  ensure_diff_highlights()
  vim.api.nvim_buf_clear_namespace(old_buf, diff_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(new_buf, diff_ns, 0, -1)

  local old_line = nil
  local new_line = nil
  local deleted = {}
  local added = {}

  local function flush_pairs()
    for index = 1, math.min(#deleted, #added) do
      highlight_partial_line_pair(
        old_buf,
        deleted[index].row,
        deleted[index].line,
        new_buf,
        added[index].row,
        added[index].line,
        0
      )
    end
    deleted = {}
    added = {}
  end

  for _, line in ipairs(split_blob_lines(diff)) do
    local hunk_old_start, _, hunk_new_start = parse_diff_hunk_header(line)
    if hunk_old_start then
      flush_pairs()
      old_line = hunk_old_start
      new_line = hunk_new_start
    elseif old_line and is_deleted_diff_line(line) then
      deleted[#deleted + 1] = { row = old_line - 1, line = line:sub(2) }
      old_line = old_line + 1
    elseif old_line and is_added_diff_line(line) then
      added[#added + 1] = { row = new_line - 1, line = line:sub(2) }
      new_line = new_line + 1
    elseif old_line then
      flush_pairs()
      if line:sub(1, 1) == " " then
        old_line = old_line + 1
        new_line = new_line + 1
      end
    end
  end

  flush_pairs()
end

local function diff_for_partial_highlights(path, base_content, head_lines, base_missing)
  local tmpdir = vim.fn.tempname()
  local head_rel = write_temp_diff_file(tmpdir, "head", path, head_lines)
  local base_rel = base_missing and "/dev/null"
    or write_temp_diff_file(tmpdir, "base", path, split_blob_lines(base_content))
  local result = vim
    .system(
      { "git", "diff", "--no-index", "--no-color", "--unified=0", "--", base_rel, head_rel },
      { text = true, cwd = tmpdir }
    )
    :wait()
  pcall(vim.fn.delete, tmpdir, "rf")

  if result.code ~= 0 and result.code ~= 1 then
    return nil
  end
  return result.stdout or ""
end

local function open_old_side_by_side(path, current_win, current_buf, current_filetype, base_content, base_missing)
  close_old_view()

  vim.api.nvim_set_current_win(current_win)
  vim.cmd("vsplit")
  state.old_win = vim.api.nvim_get_current_win()
  state.old_target_win = current_win
  state.old_target_buf = current_buf
  state.old_buf = vim.api.nvim_create_buf(false, true)
  state.old_layout = "side_by_side"
  state.old_path = path
  vim.api.nvim_win_set_buf(state.old_win, state.old_buf)
  vim.api.nvim_buf_set_name(state.old_buf, "pr-base://" .. base_ref() .. "/" .. path)
  vim.api.nvim_buf_set_lines(state.old_buf, 0, -1, false, split_blob_lines(base_content))
  vim.bo[state.old_buf].buftype = "nofile"
  vim.bo[state.old_buf].bufhidden = "wipe"
  vim.bo[state.old_buf].modifiable = false
  vim.bo[state.old_buf].readonly = true
  vim.bo[state.old_buf].filetype = current_filetype

  local side_by_side_diff =
    diff_for_partial_highlights(path, base_content, vim.api.nvim_buf_get_lines(current_buf, 0, -1, false), base_missing)
  if side_by_side_diff then
    apply_side_by_side_partial_diff_highlights(state.old_buf, current_buf, side_by_side_diff)
  end

  apply_old_diffopt()

  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(current_win)
  vim.cmd("diffthis")
  apply_side_by_side_context()
  vim.api.nvim_set_current_win(current_win)
end

local function is_added_file(path)
  return (state.files[path] or ""):match("^A") ~= nil
end

local function open_old_unified(path, current_win, current_buf, base_content, generation, base_missing)
  local tmpdir = vim.fn.tempname()
  local head_rel = write_temp_diff_file(tmpdir, "head", path, vim.api.nvim_buf_get_lines(current_buf, 0, -1, false))
  local base_rel = base_missing and "/dev/null"
    or write_temp_diff_file(tmpdir, "base", path, split_blob_lines(base_content))
  local context = diff_context_lines()

  vim.system(
    { "git", "diff", "--no-index", "--no-color", "--unified=" .. tostring(context), "--", base_rel, head_rel },
    { text = true, cwd = tmpdir },
    function(result)
      vim.schedule(function()
        pcall(vim.fn.delete, tmpdir, "rf")
        if not is_current(generation) then
          return
        end

        state.old_loading = false
        if result.code ~= 0 and result.code ~= 1 then
          vim.notify(
            "PR review unified diff: " .. trim(result.stderr ~= "" and result.stderr or result.stdout),
            vim.log.levels.WARN
          )
          return
        end

        if not vim.api.nvim_win_is_valid(current_win) or not vim.api.nvim_buf_is_valid(current_buf) then
          vim.notify("PR review unified diff: target window is no longer valid", vim.log.levels.WARN)
          return
        end

        close_old_view()

        vim.api.nvim_set_current_win(current_win)
        state.old_target_win = current_win
        state.old_target_buf = current_buf
        state.old_buf = vim.api.nvim_create_buf(false, true)
        state.old_layout = "unified"
        state.old_path = path
        vim.api.nvim_win_set_buf(current_win, state.old_buf)
        vim.api.nvim_buf_set_name(state.old_buf, "pr-diff://" .. base_ref() .. "/" .. path)
        vim.api.nvim_buf_set_lines(state.old_buf, 0, -1, false, unified_diff_lines(result.stdout or "", path))
        apply_partial_diff_highlights(state.old_buf)
        vim.bo[state.old_buf].buftype = "nofile"
        vim.bo[state.old_buf].bufhidden = "wipe"
        vim.bo[state.old_buf].modifiable = false
        vim.bo[state.old_buf].readonly = true
        vim.bo[state.old_buf].filetype = "diff"
        vim.api.nvim_set_current_win(current_win)
      end)
    end
  )
end

local function open_old_view(path, current_win, current_buf)
  local current_filetype = vim.bo[current_buf].filetype
  local generation = state.generation
  state.old_loading = true

  system_async({ "git", "show", base_ref() .. ":" .. path }, { cwd = state.root, raw = true }, function(content, err)
    if not is_current(generation) then
      return
    end

    local base_missing = false
    if content == nil then
      if is_added_file(path) then
        content = ""
        base_missing = true
      else
        state.old_loading = false
        vim.notify("PR review old version: " .. tostring(err or "file not present at base"), vim.log.levels.WARN)
        return
      end
    end

    if not vim.api.nvim_win_is_valid(current_win) or not vim.api.nvim_buf_is_valid(current_buf) then
      state.old_loading = false
      vim.notify("PR review old version: target window is no longer valid", vim.log.levels.WARN)
      return
    end

    if state.config.diff.layout == "unified" then
      open_old_unified(path, current_win, current_buf, content, generation, base_missing)
      return
    end

    state.old_loading = false
    open_old_side_by_side(path, current_win, current_buf, current_filetype, content, base_missing)
  end)
end

local function refresh_old_view()
  if state.old_layout == "side_by_side" and not (state.old_win and vim.api.nvim_win_is_valid(state.old_win)) then
    return false
  end
  if
    state.old_layout == "unified" and not (state.old_target_win and vim.api.nvim_win_is_valid(state.old_target_win))
  then
    return false
  end

  local path = state.old_path
  local target_win = state.old_target_win
  if not path or not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return false
  end

  local target_buf = state.old_target_buf
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = vim.api.nvim_win_get_buf(target_win)
  end
  close_old_view()
  open_old_view(path, target_win, target_buf)
  return true
end

local function old_view_is_open()
  if state.old_layout == "side_by_side" then
    return state.old_win and vim.api.nvim_win_is_valid(state.old_win)
  end
  if state.old_layout == "unified" then
    return state.old_target_win and vim.api.nvim_win_is_valid(state.old_target_win)
  end
  return false
end

local function close_side_by_side_pair_for_buffer(bufnr)
  if state.old_closing or state.old_layout ~= "side_by_side" then
    return
  end

  if bufnr ~= state.old_buf and bufnr ~= state.old_target_buf then
    return
  end

  vim.schedule(function()
    if state.old_closing or state.old_layout ~= "side_by_side" then
      return
    end
    if bufnr == state.old_buf or bufnr == state.old_target_buf then
      close_old_view()
    end
  end)
end

function M.old_toggle()
  if not ensure_active() then
    return
  end

  if old_view_is_open() then
    close_old_view()
    return
  end

  local path = current_relpath()
  if not path then
    vim.notify("PR review old version: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  if state.old_loading then
    vim.notify("PR review old version: base file is still loading", vim.log.levels.INFO)
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  open_old_view(path, current_win, current_buf)
end

function M.toggle_diff_layout()
  state.config.diff.layout = state.config.diff.layout == "side_by_side" and "unified" or "side_by_side"
  vim.notify("PR review diff layout: " .. (state.config.diff.layout == "unified" and "unified" or "side-by-side"))
  refresh_old_view()
  vim.cmd("redrawtabline")
end

function M.toggle_diff_full_file()
  state.config.diff.full_file = not state.config.diff.full_file
  vim.notify("PR review diff context: " .. (state.config.diff.full_file and "full file" or "condensed"))
  if state.old_layout == "side_by_side" and old_view_is_open() then
    apply_side_by_side_context()
    vim.cmd("redrawtabline")
    return
  end
  refresh_old_view()
  vim.cmd("redrawtabline")
end

function M.next_hunk()
  jump_hunk(1)
end

function M.prev_hunk()
  jump_hunk(-1)
end

M.next_change = M.next_hunk
M.prev_change = M.prev_hunk

function M.next_comment()
  jump_comment(1)
end

function M.prev_comment()
  jump_comment(-1)
end

function M.next_file()
  jump_changed_file(1)
end

function M.prev_file()
  jump_changed_file(-1)
end

function M.toggle_viewed(path)
  if not ensure_active() then
    return
  end

  if not state.config.viewed.enabled then
    vim.notify("PR review viewed state is disabled", vim.log.levels.WARN)
    return
  end

  path = path or current_relpath()
  if not path or not state.files[path] then
    vim.notify("PR review viewed state: current buffer is not a changed PR file", vim.log.levels.WARN)
    return
  end

  local viewed = not state.viewed[path]
  set_viewed_path(path, viewed)
  persist_viewed_state()
  sync_viewed_path_to_github_async(path, viewed)
  schedule_comments_ui_refresh()
  vim.notify((viewed and "Marked viewed: " or "Marked unviewed: ") .. path, vim.log.levels.INFO)
end

function M.mark_viewed(path, opts)
  opts = opts or {}
  if not ensure_active() then
    return false
  end

  if not state.config.viewed.enabled then
    vim.notify("PR review viewed state is disabled", vim.log.levels.WARN)
    return false
  end

  path = path or current_relpath()
  if not path or not state.files[path] then
    vim.notify("PR review viewed state: current buffer is not a changed PR file", vim.log.levels.WARN)
    return false
  end

  set_viewed_path(path, true)
  persist_viewed_state()
  sync_viewed_path_to_github_async(path, true)
  schedule_comments_ui_refresh()
  if not opts.silent then
    vim.notify("Marked viewed: " .. path, vim.log.levels.INFO)
  end
  return true
end

local function jump_next_unviewed_file()
  if #state.file_order == 0 then
    return
  end

  local start_index = current_file_index() or 0
  for offset = 1, #state.file_order do
    local index = ((start_index - 1 + offset) % #state.file_order) + 1
    local path = state.file_order[index]
    if not state.viewed[path] then
      jump_to_path(path, first_hunk_line(path))
      prefetch_focused_path(path)
      maybe_with_hunks(path, function(hunks)
        if current_relpath() == path then
          jump_to_path(path, hunks[1] or 1)
        end
      end)
      return
    end
  end

  vim.notify("No unviewed PR files remaining", vim.log.levels.INFO)
end

function M.mark_viewed_next()
  if M.mark_viewed(nil, { silent = true }) then
    jump_next_unviewed_file()
  end
end

function M.clear_viewed()
  if not ensure_active() then
    return
  end

  state.viewed = {}
  state.viewed_order = {}
  state.viewed_sync_queue = {}
  persist_viewed_state()
  schedule_comments_ui_refresh()
  vim.notify("Cleared PR viewed state")
end

function M.sync_viewed()
  if not ensure_active() then
    return
  end

  if not state.config.viewed.enabled then
    vim.notify("PR review viewed state is disabled", vim.log.levels.WARN)
    return
  end

  sync_viewed_from_github_async(state.generation, true)
  M.flush_viewed_sync()
end

function M.toggle_viewed_sync()
  state.config.viewed.sync = not state.config.viewed.sync
  vim.notify("PR review GitHub viewed sync " .. (state.config.viewed.sync and "enabled" or "disabled"))
  if state.config.viewed.sync and state.active then
    sync_viewed_from_github_async(state.generation)
  end
end

function M.toggle_viewed_feature()
  state.config.viewed.enabled = not state.config.viewed.enabled
  if state.config.viewed.enabled then
    if state.active then
      load_viewed_state()
      sync_viewed_from_github_async(state.generation)
    end
  else
    state.viewed = {}
    state.viewed_order = {}
  end

  schedule_comments_ui_refresh()
  vim.notify("PR review viewed state " .. (state.config.viewed.enabled and "enabled" or "disabled"))
end

function M.toggle_comments()
  state.config.comments.enabled = not state.config.comments.enabled
  state.comments = {}

  if state.config.comments.enabled then
    load_comments_async()
  end

  schedule_comments_ui_refresh()
  vim.notify("PR review comments " .. (state.config.comments.enabled and "enabled" or "disabled"))
end

local viewed_picker = nil
local viewed_picker_header_lines = 4

local function normalize_viewed_filter(filter)
  filter = filter or "all"
  if filter == "viewed" or filter == "unviewed" then
    return filter
  end
  return "all"
end

local function fuzzy_match(value, query)
  query = vim.trim(query or ""):lower()
  if query == "" then
    return true
  end

  value = tostring(value or ""):lower()
  local index = 1
  for char in query:gmatch(".") do
    index = value:find(char, index, true)
    if not index then
      return false
    end
    index = index + 1
  end

  return true
end

local function viewed_picker_item(path)
  local viewed = state.viewed[path] == true
  local unviewed = M.unviewed_count(path)
  local comments = M.unresolved_comment_count(path)
  local review_icon = viewed and "✓" or string.format("☐ %d", unviewed)
  local comment_icon = comments > 0 and string.format("◆ %d", comments) or "   "

  return {
    path = path,
    viewed = viewed,
    label = string.format("%-4s %-4s %s", review_icon, comment_icon, path),
    search = table.concat({
      path,
      viewed and "viewed" or "unviewed",
      comments > 0 and "comments unresolved" or "",
    }, " "),
  }
end

local function viewed_picker_items(filter, query)
  local items = {}
  for _, path in ipairs(state.file_order) do
    local viewed = state.viewed[path] == true
    if filter == "all" or (filter == "viewed" and viewed) or (filter == "unviewed" and not viewed) then
      local item = viewed_picker_item(path)
      if fuzzy_match(item.search, query) then
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function close_viewed_picker()
  if viewed_picker and viewed_picker.winid and vim.api.nvim_win_is_valid(viewed_picker.winid) then
    pcall(vim.api.nvim_win_close, viewed_picker.winid, true)
  end
  viewed_picker = nil
end

local function selected_viewed_picker_item()
  if not viewed_picker or not viewed_picker.winid or not vim.api.nvim_win_is_valid(viewed_picker.winid) then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(viewed_picker.winid)[1]
  local index = line - viewed_picker_header_lines
  if index < 1 then
    index = 1
    pcall(vim.api.nvim_win_set_cursor, viewed_picker.winid, { viewed_picker_header_lines + 1, 0 })
  end

  return viewed_picker.items[index]
end

local function render_viewed_picker()
  if not viewed_picker or not vim.api.nvim_buf_is_valid(viewed_picker.bufnr) then
    return
  end

  viewed_picker.items = viewed_picker_items(viewed_picker.filter, viewed_picker.query)

  local lines = {
    string.format("PR review files [%s]", viewed_picker.filter),
    string.format("Search: %s", viewed_picker.query ~= "" and viewed_picker.query or "<empty>"),
    "Enter/o open  Space/t toggle  / search  a all  v viewed  u unviewed  q close",
    "",
  }

  if #viewed_picker.items == 0 then
    lines[#lines + 1] = "No matching PR files"
  else
    for _, item in ipairs(viewed_picker.items) do
      lines[#lines + 1] = item.label
    end
  end

  vim.bo[viewed_picker.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(viewed_picker.bufnr, 0, -1, false, lines)
  vim.bo[viewed_picker.bufnr].modifiable = false

  if viewed_picker.winid and vim.api.nvim_win_is_valid(viewed_picker.winid) then
    local line =
      math.min(math.max(viewed_picker_header_lines + 1, vim.api.nvim_win_get_cursor(viewed_picker.winid)[1]), #lines)
    pcall(vim.api.nvim_win_set_cursor, viewed_picker.winid, { line, 0 })
  end
end

local function prompt_viewed_picker_search()
  if not viewed_picker then
    return
  end

  local query = vim.fn.input("PR file search: ", viewed_picker.query)
  viewed_picker.query = query or ""
  render_viewed_picker()
end

local function set_viewed_picker_filter(filter)
  if not viewed_picker then
    return
  end

  viewed_picker.filter = normalize_viewed_filter(filter)
  render_viewed_picker()
end

local function toggle_viewed_picker_item()
  local item = selected_viewed_picker_item()
  if not item then
    return
  end

  M.toggle_viewed(item.path)
  render_viewed_picker()
end

local function open_viewed_picker_item()
  local item = selected_viewed_picker_item()
  if not item then
    return
  end

  close_viewed_picker()
  jump_to_path(item.path, 1)
end

local function open_viewed_picker(filter)
  filter = normalize_viewed_filter(filter)

  if viewed_picker and viewed_picker.winid and vim.api.nvim_win_is_valid(viewed_picker.winid) then
    viewed_picker.filter = filter
    render_viewed_picker()
    vim.api.nvim_set_current_win(viewed_picker.winid)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "pr-review-menu"
  vim.bo[bufnr].swapfile = false

  local width = math.min(math.max(64, math.floor(vim.o.columns * 0.72)), math.max(32, vim.o.columns - 4))
  local height = math.min(math.max(10, #state.file_order + viewed_picker_header_lines), math.max(8, vim.o.lines - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  viewed_picker = {
    bufnr = bufnr,
    winid = winid,
    filter = filter,
    query = "",
    items = {},
  }

  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = false

  local function map(lhs, callback)
    vim.keymap.set("n", lhs, callback, { buffer = bufnr, nowait = true, silent = true })
  end

  map("q", close_viewed_picker)
  map("<Esc>", close_viewed_picker)
  map("<CR>", open_viewed_picker_item)
  map("o", open_viewed_picker_item)
  map("<Space>", toggle_viewed_picker_item)
  map("t", toggle_viewed_picker_item)
  map("/", prompt_viewed_picker_search)
  map("a", function()
    set_viewed_picker_filter("all")
  end)
  map("v", function()
    set_viewed_picker_filter("viewed")
  end)
  map("u", function()
    set_viewed_picker_filter("unviewed")
  end)

  render_viewed_picker()
end

function M.list_viewed(filter)
  if not ensure_active() then
    return
  end

  open_viewed_picker(filter)
end

function M.summary()
  if not ensure_active() then
    return
  end

  local viewed_count = 0
  for _, path in ipairs(state.file_order) do
    if state.viewed[path] then
      viewed_count = viewed_count + 1
    end
  end

  local comment_count = 0
  for _, comments in pairs(state.comments) do
    comment_count = comment_count + #comments
  end

  local thread_count = 0
  local unresolved_count = 0
  for _, threads in pairs(state.comment_threads) do
    for _, thread in ipairs(threads) do
      thread_count = thread_count + 1
      if not thread.isResolved then
        unresolved_count = unresolved_count + 1
      end
    end
  end

  local queued_sync = 0
  for _ in pairs(state.viewed_sync_queue) do
    queued_sync = queued_sync + 1
  end

  local lines = {
    string.format(
      "Files: %d viewed, %d unviewed, %d total",
      viewed_count,
      #state.file_order - viewed_count,
      #state.file_order
    ),
    string.format("Comments: %d", comment_count),
    string.format("Threads: %d total, %d unresolved", thread_count, unresolved_count),
    string.format("Viewed sync: %s, %d queued", state.config.viewed.sync and "enabled" or "disabled", queued_sync),
  }

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.show_thread()
  local path = current_relpath()
  if not path then
    return
  end

  if vim.tbl_isempty(state.comments) then
    hydrate_comments()
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comments = comments_for_line(path, line)
  local lines = {}

  if #comments == 0 then
    lines = { string.format("No PR comments on %s:%d", path, line) }
  else
    for _, comment in ipairs(comments) do
      local author = comment.user and comment.user.login or "reviewer"
      lines[#lines + 1] = string.format("%s:", author)
      for body_line in (comment.body or ""):gmatch("[^\n]+") do
        lines[#lines + 1] = "  " .. body_line
      end
      lines[#lines + 1] = ""
    end
  end

  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focusable = true,
    max_width = math.floor(vim.o.columns * 0.6),
    max_height = math.floor(vim.o.lines * 0.5),
  })
end

function M.reply()
  local path = current_relpath()
  if not path then
    return
  end

  if vim.tbl_isempty(state.comments) then
    hydrate_comments()
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comments = comments_for_line(path, line)
  if #comments == 0 then
    vim.notify("No PR comment thread on current line", vim.log.levels.WARN)
    return
  end

  local target = comments[#comments]
  vim.ui.input({ prompt = "PR thread reply: " }, function(input)
    local body = trim(input or "")
    if body == "" then
      return
    end

    local created, err = gh_json({
      "api",
      string.format("repos/%s/pulls/%s/comments/%s/replies", state.repo, state.pr, target.id),
      "--method",
      "POST",
      "-f",
      "body=" .. body,
    })
    if not created then
      vim.notify("PR review reply failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    state.comments = {}
    load_comments_async()
    vim.notify("Submitted PR thread reply")
  end)
end

local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return line, line
  end

  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_line = math.min(start_pos[2], end_pos[2])
  local end_line = math.max(start_pos[2], end_pos[2])
  vim.cmd("normal! \27")
  return start_line, end_line
end

function M.comment()
  local path = current_relpath()
  if not path then
    vim.notify("PR review comment: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  if not state.repo or not state.pr then
    vim.notify("PR review comment: start review mode first", vim.log.levels.WARN)
    return
  end

  local start_line, end_line = visual_range()
  vim.ui.input({ prompt = string.format("PR comment %s:%d-%d: ", path, start_line, end_line) }, function(input)
    local body = trim(input or "")
    if body == "" then
      return
    end

    local commit_id = state.head
      or system({ "gh", "pr", "view", state.pr, "--json", "headRefOid", "-q", ".headRefOid" })
    if not commit_id then
      vim.notify("PR review comment: could not determine PR head SHA", vim.log.levels.ERROR)
      return
    end

    local args = {
      "api",
      string.format("repos/%s/pulls/%s/comments", state.repo, state.pr),
      "--method",
      "POST",
      "-f",
      "body=" .. body,
      "-f",
      "commit_id=" .. commit_id,
      "-f",
      "path=" .. path,
      "-F",
      "line=" .. tostring(end_line),
      "-F",
      "side=RIGHT",
    }

    if start_line ~= end_line then
      vim.list_extend(args, {
        "-F",
        "start_line=" .. tostring(start_line),
        "-F",
        "start_side=RIGHT",
      })
    end

    local created, err = gh_json(args)
    if not created then
      vim.notify("PR review comment failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    state.comments = {}
    load_comments_async()
    vim.notify(string.format("Submitted PR comment on %s:%d", path, end_line))
  end)
end

function M.is_active()
  return state.active
end

function M.root()
  return state.root
end

function M.is_changed_file(path)
  return state.files[path] ~= nil
end

function M.is_changed_dir(path)
  return state.dirs[path] == true
end

function M.is_viewed_file(path)
  return state.config.viewed.enabled and state.viewed[path] == true
end

function M.unviewed_count(path)
  if not state.config.viewed.enabled or not path then
    return 0
  end

  if state.files[path] then
    return state.viewed[path] and 0 or 1
  end

  if not state.dirs[path] then
    return 0
  end

  local count = 0
  local prefix = path .. "/"
  for _, file in ipairs(state.file_order) do
    if vim.startswith(file, prefix) and not state.viewed[file] then
      count = count + 1
    end
  end

  return count
end

function M.is_viewed_dir(path)
  if not state.config.viewed.enabled or not state.dirs[path] or M.unviewed_count(path) > 0 then
    return false
  end

  local prefix = path .. "/"
  local has_changed_child = false
  for _, file in ipairs(state.file_order) do
    if vim.startswith(file, prefix) then
      has_changed_child = true
      if not state.viewed[file] then
        return false
      end
    end
  end

  return has_changed_child
end

function M.comment_count(path)
  return #(state.comments[path] or {})
end

function M.unresolved_comment_count(path)
  if not state.config.comments.enabled or not path then
    return 0
  end

  if state.files[path] then
    local count = 0
    for _, comment in ipairs(state.comments[path] or {}) do
      if comment.is_resolved ~= true then
        count = count + 1
      end
    end
    return count
  end

  if not state.dirs[path] then
    return 0
  end

  local count = 0
  local prefix = path .. "/"
  for _, file in ipairs(state.file_order) do
    if vim.startswith(file, prefix) then
      count = count + M.unresolved_comment_count(file)
    end
  end

  return count
end

function M.config()
  return state.config
end

function M.setup(opts)
  state.config = normalize_config(opts)

  if state.config.commands then
    vim.api.nvim_create_user_command("PrReviewStart", M.start, { desc = "Start normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewStop", M.stop, { desc = "Stop normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewRefresh", M.refresh, { desc = "Refresh normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewNextChange", M.next_change, { desc = "Alias for PrReviewNextHunk" })
    vim.api.nvim_create_user_command("PrReviewPrevChange", M.prev_change, { desc = "Alias for PrReviewPrevHunk" })
    vim.api.nvim_create_user_command(
      "PrReviewNextHunk",
      M.next_hunk,
      { desc = "Jump to next PR hunk in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewPrevHunk",
      M.prev_hunk,
      { desc = "Jump to previous PR hunk in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewNextComment",
      M.next_comment,
      { desc = "Jump to next PR comment in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewPrevComment",
      M.prev_comment,
      { desc = "Jump to previous PR comment in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewNextFile",
      M.next_file,
      { desc = "Jump to next changed PR file in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewPrevFile",
      M.prev_file,
      { desc = "Jump to previous changed PR file in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewOldToggle",
      M.old_toggle,
      { desc = "Toggle old PR base version beside current file" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewDiffLayoutToggle",
      M.toggle_diff_layout,
      { desc = "Toggle PR diff layout between side-by-side and unified" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewDiffFullToggle",
      M.toggle_diff_full_file,
      { desc = "Toggle PR diff context between condensed and full file" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewThread",
      M.show_thread,
      { desc = "Show PR comments for the current line" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewReply",
      M.reply,
      { desc = "Reply to PR comment thread on the current line" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewComment",
      M.comment,
      { range = true, desc = "Create PR review comment for current line or visual range" }
    )
    vim.api.nvim_create_user_command("PrReviewViewedToggle", function()
      M.toggle_viewed()
    end, { desc = "Toggle viewed state for the current PR file" })
    vim.api.nvim_create_user_command("PrReviewViewedList", function(command)
      M.list_viewed(command.args ~= "" and command.args or "all")
    end, {
      nargs = "?",
      complete = function()
        return { "all", "viewed", "unviewed" }
      end,
      desc = "Open PR file picker by viewed state",
    })
    vim.api.nvim_create_user_command(
      "PrReviewViewedNext",
      M.mark_viewed_next,
      { desc = "Mark current PR file viewed and jump to next unviewed file" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewViewedFeatureToggle",
      M.toggle_viewed_feature,
      { desc = "Toggle PR viewed state" }
    )
    vim.api.nvim_create_user_command("PrReviewCommentsToggle", M.toggle_comments, { desc = "Toggle PR comments" })
    vim.api.nvim_create_user_command(
      "PrReviewViewedClear",
      M.clear_viewed,
      { desc = "Clear viewed state for the current PR" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewViewedSync",
      M.sync_viewed,
      { desc = "Pull viewed state from GitHub for the current PR" }
    )
    vim.api.nvim_create_user_command(
      "PrReviewViewedSyncToggle",
      M.toggle_viewed_sync,
      { desc = "Toggle GitHub viewed-state sync" }
    )
    vim.api.nvim_create_user_command("PrViewedToggle", function()
      M.toggle_viewed()
    end, { desc = "Alias for PrReviewViewedToggle" })
    vim.api.nvim_create_user_command("PrViewedList", function(command)
      M.list_viewed(command.args ~= "" and command.args or "all")
    end, {
      nargs = "?",
      complete = function()
        return { "all", "viewed", "unviewed" }
      end,
      desc = "Alias for PrReviewViewedList",
    })
    vim.api.nvim_create_user_command("PrReviewSummary", M.summary, { desc = "Show PR review summary" })
  end

  if setup_done then
    return
  end

  setup_done = true

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("normal_pr_review", { clear = true }),
    callback = function(args)
      annotate_buffer(args.buf)
      local delay = tonumber(state.config.performance.hunk_prefetch.focused_delay_ms or 0) or 0
      if delay > 0 then
        vim.defer_fn(function()
          prefetch_current_buffer(args.buf)
        end, delay)
      else
        prefetch_current_buffer(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("normal_pr_review_old_view", { clear = true }),
    callback = function(args)
      close_side_by_side_pair_for_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "GitSignsUpdate",
    group = vim.api.nvim_create_augroup("normal_pr_review_gitsigns", { clear = true }),
    callback = function(args)
      local bufnr = args.data and args.data.buffer
      local path = bufnr and buf_relpath(bufnr)
      if state.active and state.maps_loaded and path and state.files[path] then
        finish_hunks_from_gitsigns(path, bufnr)
      end
    end,
  })
end

return M
