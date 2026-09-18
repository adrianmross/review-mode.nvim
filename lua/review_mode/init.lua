local M = {}

local comments_ui = require("review_mode.comments")
local core = require("review_mode.state")
local util = require("review_mode.util")
local diff = require("review_mode.diff")
local hooks = require("review_mode.hooks")
local api = require("review_mode.api")
local picker = require("review_mode.picker")
local panel = require("review_mode.panel")

-- panel entry points stay on the module root so keymaps and commands keep working
M.list_viewed = picker.list_viewed
M.actions = function()
  return picker.actions(M.action_items())
end
M.open_panel = panel.open_panel
M.close_panel = panel.close_panel
M.toggle_panel = panel.toggle_panel
M.panel_is_open = panel.panel_is_open
M.panel_win = panel.panel_win
M.show_thread = panel.show_thread
M.reply = panel.reply
M.compose_comment = panel.compose_comment
M.apply_suggestion = panel.apply_suggestion
M.composer_submit = panel.composer_submit
M.composer_cancel = panel.composer_cancel
M.composer_reference = panel.composer_reference
M.composer_suggest = panel.composer_suggest
local viewed_state = require("review_mode.viewed")
local github = require("review_mode.github")
local checkout = require("review_mode.checkout")

M.flush_viewed_sync = viewed_state.flush_viewed_sync

local state = core.state
local trim = util.trim
local system_async = util.system_async
local gh_json_async = util.gh_json_async
local ensure_active = util.ensure_active
local current_relpath = util.current_relpath
local buf_relpath = util.buf_relpath
local defaults = core.defaults

local ns = vim.api.nvim_create_namespace("review_mode_normal")
local picker_ns = vim.api.nvim_create_namespace("review_mode_picker")
local panel_ns = vim.api.nvim_create_namespace("review_mode_panel")

local setup_done = false

local function active_pr_arg()
  if state.pr and state.pr ~= "" then
    return tostring(state.pr)
  end
  return util.env_value("GH_REVIEW_PR")
end

local function pr_url_async(callback)
  if state.provider == "gitlab" then
    local url = require("review_mode.providers.gitlab").web_url()
    callback(url, not url and "merge request metadata is still loading" or nil)
    return
  end
  if state.provider == "local" then
    callback(nil, "a local review has no PR to open")
    return
  end
  local args = { "pr", "view" }
  local pr = active_pr_arg()
  if pr then
    args[#args + 1] = pr
  end
  vim.list_extend(args, { "--json", "url", "-q", ".url" })
  system_async(vim.list_extend({ "gh" }, args), {}, callback)
end

local function repo_slug_async(generation, callback)
  local repo = state.repo or util.env_value("GH_REVIEW_REPO")
  if repo then
    callback(repo, nil)
    return
  end

  system_async({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }, {}, function(slug, err)
    if not core.is_current(generation) then
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

  local pr = active_pr_arg()
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
  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").mr_meta_async(generation, callback)
  end
  gh_json_async(pr_view_args(), function(meta, err)
    if not core.is_current(generation) then
      return
    end
    callback(meta, err)
  end)
end

local function current_file_index(path)
  path = path or current_relpath()
  if not path then
    return nil
  end
  return state.file_index[path]
end

local function jump_to_path(path, line)
  if not path then
    return false
  end

  if state.old_layout == "side_by_side" then
    local target_win = state.old_target_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    diff.close_old_view()
  end

  local full_path = vim.fs.joinpath(state.root, path)
  if vim.uv.fs_stat(full_path) then
    vim.cmd.edit(vim.fn.fnameescape(full_path))
  else
    vim.cmd.edit(vim.fn.fnameescape(path))
  end

  vim.api.nvim_win_set_cursor(0, { util.clamp_line(line), 0 })
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
  local comments = path and require("review_mode.review").with_pending(state.comments[path], path) or nil
  if not comments then
    return
  end

  api.ensure_highlights()

  local grouped = {}
  for _, thread in ipairs(comments_ui.threads(comments, path)) do
    local line = thread.line
    if line then
      grouped[line] = grouped[line] or {}
      table.insert(grouped[line], thread)
    end
  end

  local default_sign_hl = state.config.comments.sign_hl_group or "DiagnosticInfo"
  for line, line_threads in pairs(grouped) do
    local thread = line_threads[#line_threads]
    local sign_hl = default_sign_hl
    if thread.is_resolved then
      sign_hl = "ReviewModeResolved"
    elseif thread.is_outdated then
      sign_hl = "ReviewModeOutdated"
    elseif thread.comments[1].is_pending then
      sign_hl = "ReviewModePending"
    end

    local virt_text
    if state.config.comments.virtual_text then
      local summary, badges = comments_ui.virtual_text(thread, { max_width = 72 })
      virt_text = {
        { "\t", "NonText" },
        { "■", sign_hl },
        { " " .. summary, "DiagnosticVirtualTextInfo" },
      }
      if badges then
        virt_text[#virt_text + 1] = { badges, "ReviewModeReaction" }
      end
    end

    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      sign_text = api.comment_sign(),
      sign_hl_group = sign_hl,
      virt_text = virt_text,
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

-- Resolve feedback -------------------------------------------------------------
-- Resolving a thread otherwise just makes it disappear: the sign is gone on the
-- next reload and nothing says why. Flash the line the thread sat on, in the
-- colour of its new state, so the action is confirmed where it happened. Its own
-- namespace on purpose -- the reload that follows clears `ns`, and this mark has
-- to outlive it without touching the real signs or virtual text.
local flash_ns = vim.api.nvim_create_namespace("review_mode_resolve_flash")
local flash_generation = 0

local function clear_resolve_flash()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, 0, -1)
    end
  end
end

--- The path and line a thread sits on, searched across the changed files.
local function thread_location(thread_id)
  for _, path in ipairs(state.file_order or {}) do
    for _, thread in ipairs(comments_ui.threads(state.comments[path], path)) do
      if thread.id == thread_id then
        return path, thread.line
      end
    end
  end
  return nil, nil
end

--- Mark a thread's line as just resolved or just unresolved, briefly.
--- comments.resolve_flash_ms = 0 turns it off.
local function flash_thread_resolved(thread_id, resolved)
  local ms = (state.config.comments or {}).resolve_flash_ms
  if type(ms) ~= "number" or ms <= 0 or not state.active or not state.root then
    return
  end

  local path, line = thread_location(thread_id)
  if not path or not line then
    return
  end

  api.ensure_highlights()
  local hl = resolved and "ReviewModeResolved" or "ReviewModeUnresolved"
  local label = resolved and "resolved" or "unresolved"

  clear_resolve_flash()
  local marked = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fs.relpath(state.root, name) == path then
        -- line-1 can be past the end of a buffer showing an older revision
        if line <= vim.api.nvim_buf_line_count(bufnr) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, flash_ns, line - 1, 0, {
            line_hl_group = hl,
            virt_text = { { "  " .. label, hl } },
            virt_text_pos = "eol",
            -- above the annotation layer (160) so the confirmation reads first
            priority = 200,
          })
          marked = true
        end
      end
    end
  end

  if not marked then
    return
  end

  flash_generation = flash_generation + 1
  local generation = flash_generation
  vim.defer_fn(function()
    -- a newer flash owns the marks now; let its own timer clear them
    if generation == flash_generation then
      clear_resolve_flash()
    end
  end, ms)
end
-- End resolve feedback ---------------------------------------------------------

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
  panel.schedule_refresh()
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

-- The feature modules announce changes instead of reaching into the UI, so the
-- redraw is wired up here, once. Registered after the function it calls, or the
-- closure would capture a global instead of the local.
hooks.on("viewed_changed", function()
  schedule_comments_ui_refresh()
end)

hooks.on("comments_loaded", function()
  schedule_comments_ui_refresh()
end)

hooks.on("pending_changed", function()
  schedule_comments_ui_refresh()
end)

-- Resolve feedback: the flash rides the event, not the network call, so the
-- GitLab provider's own resolve and any future one get it for free.
hooks.on("thread_resolved", function(data)
  flash_thread_resolved(data.thread_id, data.resolved)
end)
-- End resolve feedback

local function parse_changed_files(output)
  state.files = {}
  state.file_stats = {}
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

local function parse_numstat_count(value)
  if value == "-" then
    return nil
  end
  return tonumber(value) or 0
end

local function numstat_path(path)
  path = path or ""
  local renamed = path:match("{.-=>%s*(.-)}")
  if renamed then
    return (path:gsub("{.-=>%s*.-}", renamed))
  end
  return path:match("[^\t]+$") or path
end

local function parse_changed_file_stats(output)
  state.file_stats = {}

  for line in (output or ""):gmatch("[^\n]+") do
    local additions, deletions, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if additions and deletions and path then
      state.file_stats[numstat_path(path)] = {
        additions = parse_numstat_count(additions),
        deletions = parse_numstat_count(deletions),
      }
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

local function build_changed_maps_async(generation, callback)
  core.reset_changed_data()
  state.maps_loading = true
  system_async(
    { "git", "diff", "--name-status", "--find-renames", "--no-ext-diff", "--no-color", core.diff_range() },
    { cwd = state.root },
    function(output, err)
      if not core.is_current(generation) then
        return
      end

      state.maps_loading = false
      if not output then
        state.maps_loaded = true
        callback(err or "failed to load changed files")
        return
      end

      parse_changed_files(output)
      system_async(
        { "git", "diff", "--numstat", "--find-renames", "--no-ext-diff", "--no-color", core.diff_range() },
        { cwd = state.root },
        function(numstat)
          if not core.is_current(generation) then
            return
          end

          if numstat then
            parse_changed_file_stats(numstat)
          end
          state.maps_loaded = true
          callback(nil)
        end
      )
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
    core.diff_range(),
    "--",
  }
  if needs_rename_detection then
    table.insert(args, 5, "--find-renames")
  else
    table.insert(args, 5, "--no-renames")
  end
  vim.list_extend(args, pending_paths)

  system_async(args, { cwd = state.root }, function(patch)
    if not core.is_current(generation) then
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
      if not core.is_current(generation) then
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
    if not core.is_current(generation) or not state.maps_loaded then
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
      core.diff_range(),
    }, { cwd = state.root }, function(patch)
      if not core.is_current(generation) then
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

-- the reflog is appended on every commit, amend, rebase and checkout, so its
-- size+mtime is a cheap stand-in for "HEAD moved" with no subprocess per event
local head_watch = {}

function head_watch.stamp()
  if not state.head_log_path then
    return nil
  end

  local stat = vim.uv.fs_stat(state.head_log_path)
  if not stat then
    return nil
  end

  local mtime = stat.mtime or {}
  return string.format("%d:%d:%d", stat.size or 0, mtime.sec or 0, mtime.nsec or 0)
end

-- ponytail: the baseline is stamped when rev-parse returns, not when the changed
-- maps were built, so a commit landing in that window is baked into the baseline
-- and not followed until HEAD next moves. Closing it without blocking start
-- means also returning HEAD's sha here and reloading if it differs from the sha
-- the maps were built from; not worth it unless someone actually hits it.
function head_watch.start(generation)
  state.head_log_path = nil
  state.head_log_stamp = nil
  system_async({ "git", "rev-parse", "--git-path", "logs/HEAD" }, { cwd = state.root }, function(path)
    if not core.is_current(generation) or not path or path == "" then
      return
    end

    if not vim.startswith(path, "/") then
      path = vim.fs.joinpath(state.root, path)
    end
    state.head_log_path = path
    state.head_log_stamp = head_watch.stamp()
  end)
end

function head_watch.reload()
  local generation = state.generation
  build_changed_maps_async(generation, function(err)
    if not core.is_current(generation) then
      return
    end

    if err then
      vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
      return
    end

    viewed_state.refresh_viewed_order()
    annotate_open_buffers()
    refresh_tree()
    prefetch_current_buffer()
    start_background_hunk_scan()
    vim.notify(string.format("Review Mode: HEAD moved, %d changed files", #state.file_order))
  end)

  -- new comments must anchor to a commit GitHub knows about, not the SHA we
  -- captured when the review started
  pr_meta_async(generation, function(meta)
    if not core.is_current(generation) or not meta then
      return
    end
    state.head = meta.headRefOid or state.head
  end)
end

function head_watch.check()
  if not state.config.follow_head or not state.active or not state.head_log_path or state.maps_loading then
    return
  end

  local stamp = head_watch.stamp()
  if not stamp or stamp == state.head_log_stamp then
    return
  end

  state.head_log_stamp = stamp
  head_watch.reload()
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

-- event is the bare name ("start", "enter"); hooks.emit turns it into the
-- ReviewModeStart / ReviewModeEnter autocommand pattern callers already use.
local function announce(event)
  vim.g.review_mode = state.in_mode and "mode" or (state.active and "session" or nil)
  hooks.emit(event, {
    repo = state.repo,
    pr = state.pr,
    base = state.base,
    root = state.root,
    in_mode = state.in_mode,
    active = state.active,
  })
  util.redraw_status()
end

local function mode_action(action)
  if type(action) == "function" then
    return action
  end
  return function()
    local fn = M[action]
    if type(fn) == "function" then
      fn()
    end
  end
end

local function apply_mode_keys()
  state.saved_keys = {}
  for lhs, action in pairs(state.config.mode.keys or {}) do
    -- keep whatever the user had, so leaving the mode is invisible to them
    state.saved_keys[lhs] = vim.fn.maparg(lhs, "n", false, true)
    vim.keymap.set("n", lhs, mode_action(action), {
      desc = "review-mode " .. lhs,
      silent = true,
    })
  end
end

local function clear_mode_keys()
  for lhs, saved in pairs(state.saved_keys or {}) do
    pcall(vim.keymap.del, "n", lhs)
    if saved and not vim.tbl_isempty(saved) then
      pcall(vim.fn.mapset, saved)
    end
  end
  state.saved_keys = {}
end

-- a session started with opts.workspace (a checkout review) overrides the config
local function workspace_kind()
  return state.workspace or state.config.mode.workspace
end

local function close_workspace()
  local tab = state.workspace_tab
  state.workspace_tab = nil
  if tab and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
  end

  local return_tab = state.return_tab
  state.return_tab = nil
  if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
    pcall(vim.api.nvim_set_current_tabpage, return_tab)
  end
end

-- the review keeps its own tabpage, so stepping out is a tab switch and the
-- review layout survives it
local function focus_workspace()
  if workspace_kind() ~= "tab" then
    return
  end

  if not state.workspace_tab or not vim.api.nvim_tabpage_is_valid(state.workspace_tab) then
    state.return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    state.workspace_tab = vim.api.nvim_get_current_tabpage()
    return
  end

  state.return_tab = vim.api.nvim_get_current_tabpage()
  pcall(vim.api.nvim_set_current_tabpage, state.workspace_tab)
end

local function leave_workspace()
  if workspace_kind() ~= "tab" then
    return
  end

  if state.return_tab and vim.api.nvim_tabpage_is_valid(state.return_tab) then
    pcall(vim.api.nvim_set_current_tabpage, state.return_tab)
  end
end

local function jump_changed_file(delta)
  if not ensure_active() then
    return
  end

  if not state.maps_loaded then
    vim.notify("Review Mode: changed files are still loading", vim.log.levels.INFO)
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
    vim.notify("Review Mode: changed files are still loading", vim.log.levels.INFO)
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
    vim.notify("Review Mode comments are disabled", vim.log.levels.WARN)
    return
  end

  if vim.tbl_isempty(state.comments) then
    github.hydrate_comments()
    github.load_comments_async()
  end

  local positions = comment_positions()
  if #positions == 0 then
    vim.notify(
      state.comments_loading and "Review Mode comments are still loading" or "No PR comments loaded",
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

  state.gitsigns_base_applied = true
  vim.schedule(function()
    local ok, gitsigns = pcall(require, "gitsigns")
    if ok and gitsigns.change_base then
      gitsigns.change_base(core.base_ref(), true, function()
        if state.active then
          prefetch_current_buffer(0)
        end
      end)
      return
    end
    pcall(vim.cmd, "Gitsigns change_base " .. core.base_ref() .. " --global")
  end)
end

local function reset_gitsigns_base()
  if not state.gitsigns_base_applied then
    return
  end

  state.gitsigns_base_applied = false
  vim.schedule(function()
    local ok, gitsigns = pcall(require, "gitsigns")
    if ok and gitsigns.change_base then
      gitsigns.change_base(nil, true)
      return
    end
    pcall(vim.cmd, "Gitsigns change_base --global")
  end)
end

local function load_review_async(generation, opts)
  opts = opts or {}
  build_changed_maps_async(generation, function(err)
    if not core.is_current(generation) then
      return
    end

    if err then
      vim.notify("Review Mode: " .. tostring(err), vim.log.levels.ERROR)
      return
    end

    viewed_state.load_viewed_state()
    refresh_tree()
    annotate_open_buffers()
    viewed_state.sync_viewed_from_github_async(generation)
    prefetch_current_buffer()
    prefetch_near_path(state.file_order[1])
    start_background_hunk_scan()
    if opts.open_initial and state.config.auto_open_first_change then
      open_initial_change()
    end

    vim.notify(
      string.format(
        "Review Mode: %s#%s against %s (%d files)",
        state.repo or "repo",
        state.pr or "?",
        state.base or "?",
        #state.file_order
      )
    )
  end)
end

local function load_metadata_async(generation, callback)
  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").load_metadata_async(generation, callback)
  end
  local pending = 2
  local slug_result = nil
  local meta_result = nil
  local first_err = nil

  local function done()
    pending = pending - 1
    if pending > 0 or not core.is_current(generation) then
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

--- opts (all optional; no opts keeps the env/`gh` discovery):
---   root, repo, pr, base, head  the session's context, instead of env/`gh`
---   workspace                   "tab" | "inplace", overriding mode.workspace
---   provider                    "github" | "gitlab" | "local", instead of auto
---   local_args                  `:ReviewModeLocal` arguments, for provider "local"
function M.start(opts)
  opts = opts or {}
  local root, root_err = opts.root, nil
  if not root then
    root, root_err = util.repo_root()
  end
  if not root then
    vim.notify("Review Mode: " .. tostring(root_err or "not in a git repo"), vim.log.levels.ERROR)
    return
  end

  -- Local reviews ---------------------------------------------------------------
  -- A local review has no forge to ask, so its refs and its comment store are
  -- worked out here, up front, and the rest of start-up runs unchanged.
  local provider = opts.provider or require("review_mode.providers").select(root)
  if provider == "local" and not opts.local_store then
    local resolved, resolve_err = require("review_mode.providers.local").resolve(opts.local_args or {}, root)
    if not resolved then
      vim.notify("Review Mode: " .. tostring(resolve_err), vim.log.levels.ERROR)
      return
    end
    opts = vim.tbl_extend("force", resolved, { workspace = opts.workspace })
  end
  -- End local reviews -----------------------------------------------------------

  state.root = root
  state.active = true
  -- restarting while already in the mode must not capture our own mappings
  clear_mode_keys()
  state.in_mode = state.config.mode.enabled
  state.metadata_loaded = false
  state.repo = opts.repo or util.env_value("GH_REVIEW_REPO")
  state.pr = opts.pr and tostring(opts.pr) or util.env_value("GH_REVIEW_PR")
  state.base = opts.base or util.env_value("GH_REVIEW_BASE")
  state.head = opts.head or util.env_value("GH_REVIEW_HEAD")
  state.workspace = opts.workspace
  state.head_ref = opts.head_ref
  state.local_store = opts.local_store
  state.provider = provider
  if state.provider == "gitlab" then
    require("review_mode.providers.gitlab").apply_env()
  end
  local generation = core.next_generation()
  core.reset_review_data()
  diff.close_old_view()
  if state.in_mode then
    apply_mode_keys()
  end
  focus_workspace()
  if opts.root and state.workspace_tab == vim.api.nvim_get_current_tabpage() then
    -- tab-local, so the rest of the editor keeps its own cwd
    vim.cmd.tcd(vim.fn.fnameescape(root))
  end
  head_watch.start(generation)
  announce("start")

  local review_loading_started = false
  if state.base then
    review_loading_started = true
    set_gitsigns_base()
    github.load_comments_async()
    load_review_async(generation, { open_initial = true })
  else
    vim.notify("Review Mode: loading PR metadata")
  end

  -- Local reviews: the refs are already resolved and there is nothing to ask.
  if state.provider == "local" then
    state.metadata_loaded = true
    return
  end

  load_metadata_async(generation, function(result, err)
    if not core.is_current(generation) then
      return
    end

    if not result then
      if review_loading_started then
        state.metadata_loaded = true
        vim.notify(
          "Review Mode metadata refresh failed: " .. tostring(err or "could not load PR metadata"),
          vim.log.levels.WARN
        )
        return
      end
      state.active = false

      -- No PR for this branch is an answer, not a failure, so review it
      -- locally. Only that answer: anything else (auth, network, a named PR
      -- that does not exist) still reports, since falling back then would
      -- review a branch that has a PR without its comments.
      local providers = require("review_mode.providers")
      if
        state.config.no_pr == "local"
        and state.provider ~= "gitlab"
        and not util.env_value("GH_REVIEW_PR")
        and providers.is_no_pr(err)
      then
        local branch = util.system({ "git", "branch", "--show-current" }, { cwd = state.root }) or "this branch"
        vim.notify(string.format('Review Mode: no PR for "%s", reviewing it locally', branch))
        -- deferred: restarting from inside start's own callback re-enters it
        vim.schedule(function()
          M.review_local({})
        end)
        return
      end

      vim.notify("Review Mode: " .. tostring(err or "could not load PR metadata"), vim.log.levels.ERROR)
      return
    end

    local meta = result.meta or {}
    state.repo = state.repo or result.repo
    state.pr = state.pr or tostring(meta.number or util.env_value("GH_REVIEW_PR") or "")
    state.base = state.base or meta.baseRefName or "main"
    state.head = state.head or meta.headRefOid
    state.metadata_loaded = true

    viewed_state.load_viewed_state()
    schedule_comments_ui_refresh()
    viewed_state.sync_viewed_from_github_async(generation)
    github.load_comments_async()
    if not review_loading_started then
      set_gitsigns_base()
      load_review_async(generation, { open_initial = true })
    end
  end)
end

function M.enter()
  if not state.active then
    M.start()
    return
  end

  if state.in_mode then
    return
  end

  state.in_mode = true
  if state.config.mode.enabled then
    apply_mode_keys()
  end
  focus_workspace()
  if state.config.mode.gitsigns_follows then
    set_gitsigns_base()
  end
  if not state.config.mode.signs_when_out then
    annotate_open_buffers()
  end
  if state.config.panel.auto_open then
    panel.open_panel()
  end
  announce("enter")
end

function M.leave()
  if not state.in_mode then
    return
  end

  state.in_mode = false
  clear_mode_keys()
  leave_workspace()
  if state.config.mode.gitsigns_follows then
    reset_gitsigns_base()
  end
  if not state.config.mode.signs_when_out then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      clear_buffer_marks(bufnr)
    end
    refresh_tree()
  end
  announce("leave")
end

function M.toggle()
  if not state.active then
    M.start()
    return
  end

  if state.in_mode then
    M.leave()
    return
  end

  M.enter()
end

function M.is_in_mode()
  return state.in_mode
end

function M.statusline()
  if not state.active then
    return ""
  end

  local viewed = 0
  for _, path in ipairs(state.file_order) do
    if state.viewed[path] then
      viewed = viewed + 1
    end
  end

  -- a local review's pr is a ref key, so "repo#feat-x" would read as a PR
  if state.provider == "local" then
    return string.format(
      "%s local %s@%s %d/%d",
      state.in_mode and "REVIEW" or "review",
      state.repo or "?",
      state.pr or "?",
      viewed,
      #state.file_order
    )
  end

  return string.format(
    "%s %s#%s %d/%d",
    state.in_mode and "REVIEW" or "review",
    state.repo or "?",
    state.pr or "?",
    viewed,
    #state.file_order
  )
end

local mode_names = {
  n = "NORMAL",
  no = "O-PENDING",
  v = "VISUAL",
  V = "V-LINE",
  ["\22"] = "V-BLOCK",
  s = "SELECT",
  S = "S-LINE",
  ["\19"] = "S-BLOCK",
  i = "INSERT",
  R = "REPLACE",
  c = "COMMAND",
  r = "PROMPT",
  ["!"] = "SHELL",
  t = "TERMINAL",
}

--- Text for a statusline mode slot.
---
--- The review layer sits on top of normal mode rather than replacing it, so
--- this reads "REVIEW" while the layer is live and you are in normal mode, and
--- "REVIEW INSERT" once you step into another mode, keeping both contexts
--- visible. Outside the mode it is just the usual mode name, so it can stand in
--- for a statusline's own mode component.
function M.mode_text(opts)
  opts = opts or {}
  local mode = vim.fn.mode()
  local name = mode_names[mode] or mode_names[mode:sub(1, 1)] or mode:upper()
  if vim.g.review_mode ~= "mode" then
    return name
  end

  local label = opts.label or "REVIEW"
  if mode == "n" then
    return label
  end
  return label .. (opts.separator or " ") .. name
end

function M.stop()
  M.leave()
  close_workspace()
  state.workspace = nil
  core.next_generation()
  reset_gitsigns_base()
  state.active = false
  state.metadata_loaded = false
  state.repo = nil
  state.pr = nil
  state.base = nil
  state.head = nil
  state.head_ref = nil
  state.local_store = nil
  state.head_log_path = nil
  state.head_log_stamp = nil
  core.reset_review_data()
  diff.close_old_view()
  panel.close_panel()
  annotate_open_buffers()
  refresh_tree()
  announce("stop")
  vim.notify("Review Mode stopped")
end

function M.refresh()
  if not state.active then
    M.start()
    return
  end

  if not state.metadata_loaded then
    vim.notify("Review Mode: metadata is still loading", vim.log.levels.INFO)
    return
  end

  local generation = core.next_generation()
  state.comments = {}
  state.comment_threads = {}
  state.comments_loading = false
  diff.close_old_view()
  github.load_comments_async()
  load_review_async(generation, { open_initial = false })
end

M.old_toggle = diff.old_toggle
M.toggle_diff_layout = diff.toggle_diff_layout
M.toggle_diff_full_file = diff.toggle_diff_full_file

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

function M.set_viewed(path, viewed)
  if not ensure_active() or not state.config.viewed.enabled then
    return false
  end

  path = path or current_relpath()
  if not path or not state.files[path] then
    return false
  end

  viewed = viewed ~= false
  viewed_state.set_viewed_path(path, viewed)
  viewed_state.persist_viewed_state()
  viewed_state.sync_viewed_path_to_github_async(path, viewed)
  schedule_comments_ui_refresh()
  return true
end

function M.toggle_viewed(path)
  if not ensure_active() then
    return
  end

  if not state.config.viewed.enabled then
    vim.notify("Review Mode viewed state is disabled", vim.log.levels.WARN)
    return
  end

  path = path or current_relpath()
  if not path or not state.files[path] then
    vim.notify("Review Mode viewed state: current buffer is not a changed PR file", vim.log.levels.WARN)
    return
  end

  local viewed = not state.viewed[path]
  viewed_state.set_viewed_path(path, viewed)
  viewed_state.persist_viewed_state()
  viewed_state.sync_viewed_path_to_github_async(path, viewed)
  schedule_comments_ui_refresh()
  vim.notify((viewed and "Marked viewed: " or "Marked unviewed: ") .. path, vim.log.levels.INFO)
end

function M.mark_viewed(path, opts)
  opts = opts or {}
  if not ensure_active() then
    return false
  end

  if not state.config.viewed.enabled then
    vim.notify("Review Mode viewed state is disabled", vim.log.levels.WARN)
    return false
  end

  path = path or current_relpath()
  if not path or not state.files[path] then
    vim.notify("Review Mode viewed state: current buffer is not a changed PR file", vim.log.levels.WARN)
    return false
  end

  viewed_state.set_viewed_path(path, true)
  viewed_state.persist_viewed_state()
  viewed_state.sync_viewed_path_to_github_async(path, true)
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
  viewed_state.persist_viewed_state()
  schedule_comments_ui_refresh()
  vim.notify("Cleared PR viewed state")
end

function M.sync_viewed()
  if not ensure_active() then
    return
  end

  if not state.config.viewed.enabled then
    vim.notify("Review Mode viewed state is disabled", vim.log.levels.WARN)
    return
  end

  viewed_state.sync_viewed_from_github_async(state.generation, true)
  viewed_state.flush_viewed_sync()
end

function M.toggle_viewed_sync()
  state.config.viewed.sync = not state.config.viewed.sync
  vim.notify("Review Mode GitHub viewed sync " .. (state.config.viewed.sync and "enabled" or "disabled"))
  if state.config.viewed.sync and state.active then
    viewed_state.sync_viewed_from_github_async(state.generation)
  end
end

function M.toggle_viewed_feature()
  state.config.viewed.enabled = not state.config.viewed.enabled
  if state.config.viewed.enabled then
    if state.active then
      viewed_state.load_viewed_state()
      viewed_state.sync_viewed_from_github_async(state.generation)
    end
  else
    state.viewed = {}
    state.viewed_order = {}
  end

  schedule_comments_ui_refresh()
  vim.notify("Review Mode viewed state " .. (state.config.viewed.enabled and "enabled" or "disabled"))
end

function M.toggle_comments()
  state.config.comments.enabled = not state.config.comments.enabled
  state.comments = {}

  if state.config.comments.enabled then
    github.load_comments_async()
  end

  schedule_comments_ui_refresh()
  vim.notify("Review Mode comments " .. (state.config.comments.enabled and "enabled" or "disabled"))
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

  -- API calls ----------------------------------------------------------------
  -- This line is a rate-limit report. A local review has no rate limit and never
  -- spawns a forge CLI, so the honest thing is to have nothing to say rather
  -- than print zero against a tool the session never intended to use.
  -- api.request_stats() still answers, correctly, zero.
  if state.provider ~= "local" then
    local stats = util.request_stats()
    lines[#lines + 1] =
      string.format("API calls: %d gh invocations, %d answered 304 Not Modified", stats.calls, stats.not_modified)
  end
  -- End API calls --------------------------------------------------------------

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function thread_comment_on_current_line()
  local path = current_relpath()
  if not path then
    return nil, "current buffer is not under repo root"
  end

  if vim.tbl_isempty(state.comments) then
    github.hydrate_comments()
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comments = comments_for_line(path, line)
  if #comments == 0 then
    return nil, "no PR comment thread on current line"
  end

  local target = comments[#comments]
  if not target.thread_id then
    return nil, "current comment was loaded without a review thread id"
  end
  return target, nil
end

local function set_thread_resolved(resolved, thread_id, callback)
  if not state.repo or not state.pr then
    vim.notify("Review Mode thread: start Review Mode first", vim.log.levels.WARN)
    return
  end

  if not thread_id then
    local target, err = thread_comment_on_current_line()
    if not target then
      vim.notify("Review Mode thread: " .. tostring(err), vim.log.levels.WARN)
      return
    end
    thread_id = target.thread_id
  end

  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").set_resolved(thread_id, resolved, callback)
  end
  if state.provider == "local" then
    return require("review_mode.providers.local").set_resolved(thread_id, resolved, callback)
  end

  -- REST-loaded and cache-derived threads have a synthetic id; GitHub only
  -- resolves threads it issued an id for.
  if thread_id:match("^comment:") or thread_id:match("^rest:") then
    vim.notify("Review Mode thread: this comment was loaded without a review thread id", vim.log.levels.WARN)
    return
  end

  local field = resolved and "resolveReviewThread" or "unresolveReviewThread"
  local mutation = string.format(
    [[
mutation($threadId: ID!) {
  %s(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
    }
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
    "threadId=" .. thread_id,
  }, function(result, mutation_err)
    if not result then
      vim.notify(
        "Review Mode thread update failed: " .. tostring(mutation_err or "unknown error"),
        vim.log.levels.ERROR
      )
      if callback then
        callback(false, mutation_err)
      end
      return
    end

    api.reload_comments()
    hooks.emit("thread_resolved", { thread_id = thread_id, resolved = resolved })
    vim.notify(resolved and "Resolved PR review thread" or "Unresolved PR review thread")
    if callback then
      callback(true, nil)
    end
  end)
end

function M.resolve_thread(thread_id)
  set_thread_resolved(true, thread_id)
end

function M.unresolve_thread(thread_id)
  set_thread_resolved(false, thread_id)
end

local function post_review_comment(path, start_line, end_line, body, commit_id, callback)
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

  gh_json_async(args, function(created, err)
    if not created then
      vim.notify("Review Mode comment failed: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      if callback then
        callback(false, err)
      end
      return
    end

    api.reload_comments()
    hooks.emit("comment_posted", { kind = "comment", path = path, line = end_line })
    vim.notify(string.format("Submitted PR comment on %s:%d", path, end_line))
    if callback then
      callback(true, nil)
    end
  end)
end

local function submit_review_comment(path, start_line, end_line, body, callback)
  if not state.repo or not state.pr then
    vim.notify("Review Mode comment: start Review Mode first", vim.log.levels.WARN)
    return
  end

  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").submit_comment(path, start_line, end_line, body, callback)
  end
  if state.provider == "local" then
    return require("review_mode.providers.local").add_comment(
      { path = path, start_line = start_line, end_line = end_line, body = body },
      callback
    )
  end

  if state.head then
    post_review_comment(path, start_line, end_line, body, state.head, callback)
    return
  end

  system_async(
    { "gh", "pr", "view", state.pr, "--json", "headRefOid", "-q", ".headRefOid" },
    {},
    function(commit_id, err)
      if not commit_id then
        vim.notify("Review Mode comment: " .. tostring(err or "could not determine PR head SHA"), vim.log.levels.ERROR)
        return
      end

      post_review_comment(path, start_line, end_line, body, commit_id, callback)
    end
  )
end

--- Backing calls for review_mode.api. They take tables and callbacks rather
--- than reading the cursor, so a caller that is not a keymap can use them.
function M.submit_comment(opts, callback)
  opts = opts or {}
  local path = opts.path or current_relpath()
  local body = util.trim(opts.body or "")
  if not path or body == "" then
    if callback then
      callback(false, "path and body are required")
    end
    return false
  end

  local first = tonumber(opts.start_line) or tonumber(opts.line) or 1
  local last = tonumber(opts.end_line) or tonumber(opts.line) or first
  submit_review_comment(path, math.min(first, last), math.max(first, last), body, callback)
  return true
end

function M.submit_reply(opts, callback)
  if state.provider == "gitlab" then
    return require("review_mode.providers.gitlab").submit_reply(opts, callback)
  end
  if state.provider == "local" then
    return require("review_mode.providers.local").submit_reply(opts, callback)
  end
  opts = opts or {}
  local body = util.trim(opts.body or "")
  -- A reply needs the id of the comment it answers. Callers may pass it
  -- directly, or a thread id: search the file they named, and every changed
  -- file when they did not, so opts.path stays optional.
  local comment_id = opts.comment_id
  if not comment_id and opts.thread_id then
    local paths = opts.path and { opts.path } or state.file_order
    for _, path in ipairs(paths) do
      for _, thread in ipairs(comments_ui.threads(state.comments[path], path)) do
        if thread.id == opts.thread_id then
          comment_id = thread.comments[#thread.comments].id
          break
        end
      end
      if comment_id then
        break
      end
    end
  end

  if not comment_id or body == "" then
    if callback then
      callback(false, "a thread with at least one comment, and a body, are required")
    end
    return false
  end

  gh_json_async({
    "api",
    string.format("repos/%s/pulls/%s/comments/%s/replies", state.repo, state.pr, comment_id),
    "--method",
    "POST",
    "-f",
    "body=" .. body,
  }, function(created, err)
    if not created then
      if callback then
        callback(false, err)
      end
      return
    end
    api.reload_comments()
    hooks.emit("comment_posted", { kind = "reply", thread_id = opts.thread_id })
    if callback then
      callback(true, nil)
    end
  end)
  return true
end

function M.set_thread_resolved_by_id(thread_id, resolved, callback)
  return set_thread_resolved(resolved, thread_id, callback)
end

function M.with_hunks(path, callback)
  return maybe_with_hunks(path, callback)
end

function M.comment(command)
  local path = current_relpath()
  if not path then
    vim.notify("Review Mode comment: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  -- read the range first: opening the panel leaves visual mode
  local start_line, end_line = util.visual_range(command)

  if state.config.comments.compose == "panel" then
    -- draft in the thread panel, so the comment is written beside the threads
    -- it joins; open_panel hands focus back to this window
    if not panel.panel_is_open() then
      panel.open_panel()
    end
    panel.compose_comment({ range = 2, line1 = start_line, line2 = end_line })
    return
  end

  vim.ui.input({ prompt = string.format("PR comment %s:%d-%d: ", path, start_line, end_line) }, function(input)
    local body = trim(input or "")
    if body == "" then
      return
    end
    submit_review_comment(path, start_line, end_line, body)
  end)
end

function M.suggest(command)
  local path = current_relpath()
  if not path then
    vim.notify("Review Mode suggestion: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  local start_line, end_line = util.visual_range(command)
  vim.ui.input({
    prompt = string.format("PR suggestion %s:%d-%d: ", path, start_line, end_line),
    default = util.selected_text(start_line, end_line),
  }, function(input)
    local suggestion = input or ""
    if suggestion == "" then
      return
    end
    submit_review_comment(path, start_line, end_line, "```suggestion\n" .. suggestion .. "\n```")
  end)
end

-- The panel and its draft buffer own a lot of small helpers, and this file is
-- already near Lua's 200-locals-per-chunk limit. Scoping them to a block keeps
-- them out of the file-level slot budget; the M.* entry points below are still
-- module functions.

function M.open_browser()
  pr_url_async(function(url, err)
    if not url then
      vim.notify("Review Mode browser: " .. tostring(err or "could not determine PR URL"), vim.log.levels.ERROR)
      return
    end

    util.open_url(url)
  end)
end

function M.copy_url()
  pr_url_async(function(url, err)
    if not url then
      vim.notify("Review Mode URL: " .. tostring(err or "could not determine PR URL"), vim.log.levels.ERROR)
      return
    end

    vim.fn.setreg('"', url)
    pcall(vim.fn.setreg, "+", url)
    vim.notify("Copied PR URL: " .. url)
  end)
end

function M.checks()
  if state.provider == "gitlab" or state.provider == "local" then
    return require("review_mode.providers").unsupported("PR checks")
  end
  local args = { "gh", "pr", "checks" }
  local pr = active_pr_arg()
  if pr then
    args[#args + 1] = pr
  end
  system_async(args, { raw = true }, function(stdout, err)
    if not stdout then
      vim.notify("Review Mode checks: " .. tostring(err or "could not load checks"), vim.log.levels.ERROR)
      return
    end

    local lines = vim.split(vim.trim(stdout), "\n", { plain = true })
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
      lines = { "No PR checks found" }
    end
    util.open_lines_preview(lines, "text")
  end)
end

function M.status()
  if state.provider == "gitlab" or state.provider == "local" then
    return require("review_mode.providers").unsupported("PR status")
  end
  local args = { "pr", "view" }
  local pr = active_pr_arg()
  if pr then
    args[#args + 1] = pr
  end
  vim.list_extend(args, { "--json", "title,state,isDraft,mergeable,reviewDecision,headRefName,baseRefName,url" })

  gh_json_async(args, function(result, err)
    if not result then
      vim.notify("Review Mode status: " .. tostring(err or "could not load PR status"), vim.log.levels.ERROR)
      return
    end

    local lines = {
      string.format("# %s", result.title or "Pull request"),
      "",
      string.format("State: %s%s", result.state or "unknown", result.isDraft and " draft" or ""),
      string.format("Branch: %s -> %s", result.headRefName or "?", result.baseRefName or "?"),
      string.format("Mergeable: %s", result.mergeable or "unknown"),
      string.format("Review: %s", result.reviewDecision or "none"),
      string.format("URL: %s", result.url or ""),
    }
    util.open_lines_preview(lines, "markdown")
  end)
end

--- Open a changed file at a line. Backing call for review_mode.api.
function M.goto_file(path, line)
  return jump_to_path(path, line)
end

function M.action_items()
  return {
    { category = "PR", label = "Open in browser", run = M.open_browser },
    { category = "PR", label = "Copy PR URL", run = M.copy_url },
    { category = "PR", label = "Show PR status", run = M.status },
    { category = "PR", label = "Show PR checks", run = M.checks },
    { category = "Thread", label = "Toggle thread panel", run = panel.toggle_panel },
    { category = "Thread", label = "Show current thread", run = panel.show_thread },
    { category = "Thread", label = "Reply to current thread", run = panel.reply },
    { category = "Thread", label = "Resolve current thread", run = M.resolve_thread },
    { category = "Thread", label = "Unresolve current thread", run = M.unresolve_thread },
    -- Reactions --
    {
      category = "Thread",
      label = "React to current comment",
      run = function()
        panel.react()
      end,
    },
    -- edit and delete
    { category = "Thread", label = "Edit my comment on line", run = panel.edit_comment },
    { category = "Thread", label = "Delete my comment on line", run = panel.delete_comment },
    { category = "Review", label = "Comment on line/range", run = M.comment },
    { category = "Review", label = "Draft comment on line/range", run = panel.compose_comment },
    { category = "Review", label = "Apply suggestion on line", run = panel.apply_suggestion },
    { category = "Review", label = "Suggest change for line/range", run = M.suggest },
    { category = "Files", label = "Toggle viewed", run = M.toggle_viewed },
    {
      category = "Files",
      label = "Viewed file list",
      run = function()
        M.list_viewed("all")
      end,
    },
    {
      category = "PR",
      label = "Review a PR without checking it out",
      run = function()
        vim.ui.input({ prompt = "PR number or URL: " }, function(target)
          if target and target ~= "" then
            M.review_pr({ pr = target })
          end
        end)
      end,
    },
    -- Diagnostics and quickfix
    {
      category = "Thread",
      label = "Threads to quickfix",
      run = function()
        require("review_mode.diagnostics").set_quickfix()
      end,
    },
    {
      category = "Thread",
      label = "Toggle thread diagnostics",
      run = function()
        require("review_mode.diagnostics").toggle()
      end,
    },
    -- pending review (Summary stays last: scripts/fixture.lua selects the last action)
    {
      category = "Review",
      label = "Pending review",
      run = function()
        require("review_mode.review_buffer").open()
      end,
    },
    {
      category = "Review",
      label = "Submit review",
      run = function()
        vim.ui.select({ "comment", "approve", "request_changes" }, { prompt = "Submit review as" }, function(kind)
          if kind then
            require("review_mode.review_buffer").submit(kind)
          end
        end)
      end,
    },
    -- Local reviews
    {
      category = "Local",
      label = "Review local changes",
      run = function()
        M.review_local({})
      end,
    },
    {
      category = "Local",
      label = "Local comments buffer",
      run = function()
        require("review_mode.local_buffer").open()
      end,
    },
    -- suggestions
    {
      category = "Review",
      label = "Preview suggestion on line",
      run = function()
        panel.preview_suggestion("inline")
      end,
    },
    {
      category = "Review",
      label = "Preview suggestion side by side",
      run = function()
        panel.preview_suggestion("split")
      end,
    },
    { category = "Review", label = "Accept all suggestions in file", run = panel.accept_all_suggestions },
    {
      category = "Review",
      label = "Revert trial suggestion",
      run = function()
        panel.revert_suggestion(nil)
      end,
    },
    { category = "Review", label = "List trial suggestions", run = panel.list_trials },
    -- end suggestions (Summary stays last: scripts/fixture.lua selects it)
    { category = "PR", label = "Summary", run = M.summary },
  }
end

-- Local reviews -------------------------------------------------------------------

--- Review two local refs, with no PR and no network. `args` is what
--- :ReviewModeLocal was given: {}, { base }, { base, head } or { "base..head" }.
function M.review_local(args)
  return M.start({ provider = "local", local_args = args or {} })
end

-- End local reviews -----------------------------------------------------------------

-- Checkout ----------------------------------------------------------------------

--- Review a PR in its own detached worktree and tabpage, leaving the current
--- checkout alone. callback(ok, err_or_result).
function M.review_pr(opts, callback)
  checkout.prepare(opts, function(result, err)
    if not result then
      vim.notify("Review Mode checkout: " .. tostring(err), vim.log.levels.ERROR)
      if callback then
        callback(false, err)
      end
      return
    end

    if state.active then
      M.stop()
    end
    M.start({
      root = result.path,
      repo = result.repo,
      pr = result.pr,
      base = result.base,
      head = result.head,
      workspace = "tab",
    })
    if callback then
      callback(true, result)
    end
  end)
end

M.checkout_clean = checkout.clean

function M.config()
  return state.config
end

function M.setup(opts)
  state.config = core.normalize_config(opts)

  if state.config.commands then
    vim.api.nvim_create_user_command("ReviewMode", function()
      M.toggle()
    end, { desc = "Toggle Review Mode (starts the review session if needed)" })
    vim.api.nvim_create_user_command("ReviewModeEnter", M.enter, { desc = "Step into Review Mode" })
    vim.api.nvim_create_user_command(
      "ReviewModeLeave",
      M.leave,
      { desc = "Step out of Review Mode, keeping the session" }
    )
    vim.api.nvim_create_user_command("ReviewModeActions", M.actions, { desc = "Open Review Mode action picker" })
    vim.api.nvim_create_user_command("ReviewModeBrowser", M.open_browser, { desc = "Open the current PR in a browser" })
    vim.api.nvim_create_user_command("ReviewModeCopyUrl", M.copy_url, { desc = "Copy the current PR URL" })
    vim.api.nvim_create_user_command("ReviewModeChecks", M.checks, { desc = "Show current PR checks" })
    vim.api.nvim_create_user_command("ReviewModeStatus", M.status, { desc = "Show current PR status" })
    vim.api.nvim_create_user_command("ReviewModeLocal", function(command)
      M.review_local(command.fargs)
    end, { nargs = "*", desc = "Review local refs: :ReviewModeLocal [<base>] [<head>]" })
    vim.api.nvim_create_user_command("ReviewModeLocalComments", function()
      require("review_mode.local_buffer").open()
    end, { desc = "Open the local comments buffer" })
    vim.api.nvim_create_user_command("ReviewModeStop", M.stop, { desc = "Stop normal Review Mode" })
    vim.api.nvim_create_user_command("ReviewModeRefresh", M.refresh, { desc = "Refresh normal Review Mode" })
    vim.api.nvim_create_user_command("ReviewModeNextChange", M.next_change, { desc = "Alias for ReviewModeNextHunk" })
    vim.api.nvim_create_user_command("ReviewModePrevChange", M.prev_change, { desc = "Alias for ReviewModePrevHunk" })
    vim.api.nvim_create_user_command(
      "ReviewModeNextHunk",
      M.next_hunk,
      { desc = "Jump to next PR hunk in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModePrevHunk",
      M.prev_hunk,
      { desc = "Jump to previous PR hunk in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeNextComment",
      M.next_comment,
      { desc = "Jump to next PR comment in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModePrevComment",
      M.prev_comment,
      { desc = "Jump to previous PR comment in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeNextFile",
      M.next_file,
      { desc = "Jump to next changed PR file in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModePrevFile",
      M.prev_file,
      { desc = "Jump to previous changed PR file in normal review mode" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeOldToggle",
      M.old_toggle,
      { desc = "Toggle old PR base version beside current file" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeDiffLayoutToggle",
      M.toggle_diff_layout,
      { desc = "Toggle PR diff layout between side-by-side and unified" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeDiffFullToggle",
      M.toggle_diff_full_file,
      { desc = "Toggle PR diff context between condensed and full file" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeThread",
      panel.show_thread,
      { desc = "Show PR comments for the current line" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModePanel",
      panel.toggle_panel,
      { desc = "Toggle the PR thread panel beside the current file" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeApplySuggestion",
      panel.apply_suggestion,
      { desc = "Apply the suggestion on the current line to the buffer" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeCompose",
      panel.compose_comment,
      { range = true, desc = "Draft a PR comment for the current line or visual range" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeReply",
      panel.reply,
      { desc = "Reply to PR comment thread on the current line" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeResolveThread",
      -- wrapped: a bare M.resolve_thread would take the command table as its
      -- thread id and never look at the current line
      function()
        M.resolve_thread()
      end,
      { desc = "Resolve PR comment thread on the current line" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeUnresolveThread",
      -- wrapped: a bare M.unresolve_thread would take the command table as its
      -- thread id and never look at the current line
      function()
        M.unresolve_thread()
      end,
      { desc = "Unresolve PR comment thread on the current line" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeComment",
      M.comment,
      { range = true, desc = "Create PR comment for current line or visual range" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeSuggest",
      M.suggest,
      { range = true, desc = "Create PR suggestion for current line or visual range" }
    )
    vim.api.nvim_create_user_command("ReviewModeViewedToggle", function()
      M.toggle_viewed()
    end, { desc = "Toggle viewed state for the current PR file" })
    vim.api.nvim_create_user_command("ReviewModeViewedList", function(command)
      picker.list_viewed(command.args ~= "" and command.args or "all")
    end, {
      nargs = "?",
      complete = function()
        return { "all", "viewed", "unviewed" }
      end,
      desc = "Open PR file picker by viewed state",
    })
    vim.api.nvim_create_user_command(
      "ReviewModeViewedNext",
      M.mark_viewed_next,
      { desc = "Mark current PR file viewed and jump to next unviewed file" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeViewedFeatureToggle",
      M.toggle_viewed_feature,
      { desc = "Toggle PR viewed state" }
    )
    vim.api.nvim_create_user_command("ReviewModeCommentsToggle", M.toggle_comments, { desc = "Toggle PR comments" })
    vim.api.nvim_create_user_command(
      "ReviewModeViewedClear",
      M.clear_viewed,
      { desc = "Clear viewed state for the current PR" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeViewedSync",
      M.sync_viewed,
      { desc = "Pull viewed state from GitHub for the current PR" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeViewedSyncToggle",
      M.toggle_viewed_sync,
      { desc = "Toggle GitHub viewed-state sync" }
    )
    vim.api.nvim_create_user_command("PrViewedToggle", function()
      M.toggle_viewed()
    end, { desc = "Alias for ReviewModeViewedToggle" })
    vim.api.nvim_create_user_command("PrViewedList", function(command)
      picker.list_viewed(command.args ~= "" and command.args or "all")
    end, {
      nargs = "?",
      complete = function()
        return { "all", "viewed", "unviewed" }
      end,
      desc = "Alias for ReviewModeViewedList",
    })
    vim.api.nvim_create_user_command("ReviewModeSummary", M.summary, { desc = "Show Review Mode summary" })
    vim.api.nvim_create_user_command("ReviewModeCheckout", function(command)
      M.review_pr({ pr = command.args })
    end, { nargs = 1, desc = "Review a PR in its own worktree without checking it out" })
    vim.api.nvim_create_user_command("ReviewModeCheckoutClean", function(command)
      M.checkout_clean(command.args ~= "" and command.args or nil)
    end, { nargs = "?", desc = "Remove clean review worktrees" })
    -- Diagnostics and quickfix
    vim.api.nvim_create_user_command("ReviewModeQuickfix", function(command)
      require("review_mode.diagnostics").set_quickfix({ filter = command.args ~= "" and command.args or nil })
    end, {
      nargs = "?",
      complete = function()
        return { "unresolved", "all" }
      end,
      desc = "Fill the quickfix list with PR review threads",
    })
    vim.api.nvim_create_user_command("ReviewModeDiagnosticsToggle", function()
      require("review_mode.diagnostics").toggle()
    end, { desc = "Toggle PR review threads as diagnostics" })
    -- Reactions --
    vim.api.nvim_create_user_command("ReviewModeReact", function(command)
      panel.react(command.args)
    end, {
      nargs = "?",
      complete = function()
        return vim.tbl_map(function(item)
          return item.content
        end, api.reaction_contents)
      end,
      desc = "Toggle a reaction on the latest PR comment on the current line",
    })
    -- edit and delete
    vim.api.nvim_create_user_command(
      "ReviewModeEditComment",
      panel.edit_comment,
      { desc = "Edit your most recent PR comment on the current line" }
    )
    vim.api.nvim_create_user_command(
      "ReviewModeDeleteComment",
      panel.delete_comment,
      { desc = "Delete your most recent PR comment on the current line" }
    )
    -- pending review
    vim.api.nvim_create_user_command("ReviewModePending", function()
      require("review_mode.review_buffer").open()
    end, { desc = "Open the pending review buffer" })
    vim.api.nvim_create_user_command("ReviewModeSubmit", function(command)
      if command.args == "" then
        require("review_mode.review_buffer").open()
        return
      end
      require("review_mode.review_buffer").submit(command.args)
    end, {
      nargs = "?",
      complete = function()
        return { "comment", "approve", "request_changes" }
      end,
      desc = "Submit the pending review",
    })
    -- suggestions
    vim.api.nvim_create_user_command("ReviewModeSuggestionPreview", function(command)
      panel.preview_suggestion(command.args)
    end, {
      nargs = "?",
      complete = function()
        return { "inline", "split" }
      end,
      desc = "Toggle a preview of the suggestion on the current line",
    })
    vim.api.nvim_create_user_command(
      "ReviewModeSuggestionAcceptAll",
      panel.accept_all_suggestions,
      { desc = "Apply every suggestion in the current file, after a confirmation" }
    )
    vim.api.nvim_create_user_command("ReviewModeSuggestionRevert", function(command)
      panel.revert_suggestion(command.args)
    end, { nargs = "?", desc = "Revert a trial suggestion: the one under the cursor, or one by id" })
    vim.api.nvim_create_user_command(
      "ReviewModeSuggestionList",
      panel.list_trials,
      { desc = "List the trial suggestions applied but not saved" }
    )
    -- end suggestions
  end

  if setup_done then
    return
  end

  setup_done = true

  -- Diagnostics and quickfix: requiring it wires its event subscriptions.
  require("review_mode.diagnostics").setup()

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("normal_review_mode", { clear = true }),
    callback = function(args)
      diff.close_stale_side_by_side_pair()
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

  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "TermLeave" }, {
    group = vim.api.nvim_create_augroup("normal_review_mode_head", { clear = true }),
    callback = head_watch.check,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("normal_review_mode_panel", { clear = true }),
    callback = function()
      -- Only movement in the code window changes what the panel should show;
      -- scrolling the panel itself must not redraw it under the cursor.
      if
        state.config.panel.follow_cursor
        and panel.panel_is_open()
        and vim.api.nvim_get_current_win() ~= panel.panel_win()
      then
        panel.schedule_refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("normal_review_mode_old_view", { clear = true }),
    callback = function(args)
      diff.close_side_by_side_pair_for_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("normal_review_mode_old_view_window", { clear = true }),
    callback = function(args)
      diff.close_side_by_side_pair_for_window(tonumber(args.match))
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "GitSignsUpdate",
    group = vim.api.nvim_create_augroup("normal_review_mode_gitsigns", { clear = true }),
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
