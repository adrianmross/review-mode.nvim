local M = {}

local ns = vim.api.nvim_create_namespace "pr_review_normal"
local cache_dir = vim.fs.joinpath(vim.fn.stdpath "cache", "pr-review-comments")
local defaults = {
  auto_open_first_change = true,
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
  },
  gitsigns = {
    enabled = true,
  },
  nvim_tree = {
    enabled = true,
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
  dirs = {},
  hunks = {},
  comments = {},
  comments_loading = false,
  old_win = nil,
  old_buf = nil,
}

local setup_done = false

local function trim(value)
  return vim.trim(value or "")
end

local function system(args, opts)
  opts = opts or {}
  local result = vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }):wait()
  if result.code ~= 0 then
    return nil, trim(result.stderr ~= "" and result.stderr or result.stdout)
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

local function repo_slug()
  if vim.env.GH_REVIEW_REPO and vim.env.GH_REVIEW_REPO ~= "" then
    return vim.env.GH_REVIEW_REPO
  end
  return system({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" })
end

local function pr_number()
  if vim.env.GH_REVIEW_PR and vim.env.GH_REVIEW_PR ~= "" then
    return vim.env.GH_REVIEW_PR
  end
  return system({ "gh", "pr", "view", "--json", "number", "-q", ".number" })
end

local function pr_meta()
  local pr = pr_number()
  if not pr then
    return nil, "Unable to determine PR number"
  end

  local meta, err = gh_json({
    "pr",
    "view",
    pr,
    "--json",
    "baseRefName,headRefOid,number",
  })
  if not meta then
    return nil, err
  end

  return meta, nil
end

local function repo_root()
  return system({ "git", "rev-parse", "--show-toplevel" }, { cwd = vim.uv.cwd() })
end

local function base_ref()
  return "origin/" .. (state.base or "main")
end

local function cache_key()
  if not state.repo or not state.pr then
    return nil
  end
  return string.format("%s#%s", state.repo, state.pr)
end

local function cache_path(key)
  return vim.fs.joinpath(cache_dir, key:gsub("[^%w_.-]", "_") .. ".json")
end

local function read_comment_cache(key)
  local path = cache_path(key)
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

local function write_comment_cache(key, grouped)
  vim.fn.mkdir(cache_dir, "p")
  vim.fn.writefile({ vim.json.encode({ fetched_at = os.time(), grouped = grouped }) }, cache_path(key))
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
  return (os.time() - tonumber(cached.fetched_at or 0)) < state.config.comments.cache_ttl_seconds
end

local function current_relpath()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or not state.root then
    return nil
  end
  return vim.fs.relpath(state.root, name)
end

local function current_file_index(path)
  path = path or current_relpath()
  if not path then
    return nil
  end

  for index, changed_path in ipairs(state.file_order) do
    if changed_path == path then
      return index
    end
  end
  return nil
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
  vim.cmd "normal! zz"
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
    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      sign_text = "●",
      sign_hl_group = "DiagnosticInfo",
      number_hl_group = "DiagnosticInfo",
      virt_text = {
        { " " .. comment_summary(line_comments[#line_comments]), "DiagnosticVirtualTextInfo" },
      },
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

local function load_comments_async()
  if not state.config.comments.enabled or not state.active or state.comments_loading then
    return
  end

  local fresh = hydrate_comments()
  refresh_comments_ui()
  if fresh then
    return
  end

  state.comments_loading = true
  gh_json_async({
    "api",
    string.format("repos/%s/pulls/%s/comments?per_page=100", state.repo, state.pr),
  }, function(comments, err)
    state.comments_loading = false
    if not comments then
      vim.notify("Failed to load PR comments: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      return
    end

    state.comments = group_comments(comments)
    local key = cache_key()
    if key then
      write_comment_cache(key, state.comments)
    end
    refresh_comments_ui()
  end)
end

local function build_changed_maps()
  state.files = {}
  state.file_order = {}
  state.dirs = {}
  state.hunks = {}

  local output = system({ "git", "diff", "--name-status", "--find-renames", base_ref() .. "...HEAD" }, { cwd = state.root })
  for line in (output or ""):gmatch("[^\n]+") do
    local status, rest = line:match("^(%S+)%s+(.+)$")
    if status and rest then
      local path = rest:match("[^\t]+$") or rest
      state.files[path] = status
      if not status:match("^D") then
        state.file_order[#state.file_order + 1] = path
      end

      local dir = vim.fs.dirname(path)
      while dir and dir ~= "." and dir ~= "" do
        state.dirs[dir] = true
        dir = vim.fs.dirname(dir)
      end
    end
  end

  local current_path = nil
  local patch = system(
    { "git", "diff", "--unified=0", "--find-renames", "--diff-filter=ACMRT", base_ref() .. "...HEAD" },
    { cwd = state.root }
  )

  for line in (patch or ""):gmatch("[^\n]+") do
    local path = line:match("^%+%+%+ b/(.+)$")
    if path then
      current_path = path
      state.hunks[current_path] = state.hunks[current_path] or {}
    elseif line:match("^%+%+%+ /dev/null$") then
      current_path = nil
    elseif current_path then
      local new_start = line:match("^@@ %-%d+,?%d* %+(%d+),?%d* @@")
      if new_start then
        state.hunks[current_path][#state.hunks[current_path] + 1] = math.max(1, tonumber(new_start) or 1)
      end
    end
  end
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
  if not ensure_active() or #state.file_order == 0 then
    return
  end

  local index = current_file_index() or (delta > 0 and 0 or 1)
  local next_index = ((index - 1 + delta) % #state.file_order) + 1
  local path = state.file_order[next_index]
  jump_to_path(path, first_hunk_line(path))
end

local function jump_hunk(delta)
  if not ensure_active() then
    return
  end

  local path = current_relpath()
  local hunks = path and state.hunks[path] or nil
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

local function set_gitsigns_base()
  if not state.config.gitsigns.enabled then
    return
  end

  vim.schedule(function()
    local ok, gitsigns = pcall(require, "gitsigns")
    if ok and gitsigns.change_base then
      gitsigns.change_base(base_ref(), true)
      return
    end
    pcall(vim.cmd, "Gitsigns change_base " .. base_ref() .. " --global")
  end)
end

function M.start()
  local root, root_err = repo_root()
  if not root then
    vim.notify("PR review mode: " .. tostring(root_err or "not in a git repo"), vim.log.levels.ERROR)
    return
  end

  state.root = root
  state.repo = repo_slug()

  local meta, meta_err = pr_meta()
  if not meta then
    vim.notify("PR review mode: " .. tostring(meta_err or "could not load PR metadata"), vim.log.levels.ERROR)
    return
  end

  state.pr = tostring(meta.number or pr_number())
  state.base = meta.baseRefName or "main"
  state.head = meta.headRefOid
  state.active = true

  build_changed_maps()
  set_gitsigns_base()
  load_comments_async()
  refresh_tree()
  annotate_open_buffers()
  if state.config.auto_open_first_change then
    open_initial_change()
  end

  vim.notify(string.format("PR review mode: %s#%s against %s", state.repo or "repo", state.pr or "?", state.base))
end

function M.stop()
  state.active = false
  state.files = {}
  state.file_order = {}
  state.dirs = {}
  state.hunks = {}
  state.comments = {}
  state.comments_loading = false
  annotate_open_buffers()
  refresh_tree()
  vim.notify "PR review mode stopped"
end

function M.refresh()
  if not state.active then
    M.start()
    return
  end

  build_changed_maps()
  state.comments = {}
  load_comments_async()
  refresh_tree()
  annotate_open_buffers()
end

function M.old_toggle()
  local path = current_relpath()
  if not path then
    vim.notify("PR review old version: current buffer is not under repo root", vim.log.levels.WARN)
    return
  end

  if state.old_win and vim.api.nvim_win_is_valid(state.old_win) then
    vim.api.nvim_win_close(state.old_win, true)
    state.old_win = nil
    state.old_buf = nil
    pcall(vim.cmd, "diffoff!")
    return
  end

  local content, err = system({ "git", "show", base_ref() .. ":" .. path }, { cwd = state.root })
  if not content then
    vim.notify("PR review old version: " .. tostring(err or "file not present at base"), vim.log.levels.WARN)
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd "vsplit"
  state.old_win = vim.api.nvim_get_current_win()
  state.old_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.old_win, state.old_buf)
  vim.api.nvim_buf_set_name(state.old_buf, "pr-base://" .. base_ref() .. "/" .. path)
  vim.api.nvim_buf_set_lines(state.old_buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
  vim.bo[state.old_buf].buftype = "nofile"
  vim.bo[state.old_buf].bufhidden = "wipe"
  vim.bo[state.old_buf].modifiable = false
  vim.bo[state.old_buf].readonly = true
  vim.bo[state.old_buf].filetype = vim.bo[vim.api.nvim_win_get_buf(current_win)].filetype
  vim.cmd "diffthis"
  vim.api.nvim_set_current_win(current_win)
  vim.cmd "diffthis"
end

function M.next_change()
  jump_hunk(1)
end

function M.prev_change()
  jump_hunk(-1)
end

function M.next_file()
  jump_changed_file(1)
end

function M.prev_file()
  jump_changed_file(-1)
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
    vim.notify "Submitted PR thread reply"
  end)
end

local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return line, line
  end

  local start_pos = vim.fn.getpos "v"
  local end_pos = vim.fn.getpos "."
  local start_line = math.min(start_pos[2], end_pos[2])
  local end_line = math.max(start_pos[2], end_pos[2])
  vim.cmd "normal! \27"
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

    local commit_id = state.head or system({ "gh", "pr", "view", state.pr, "--json", "headRefOid", "-q", ".headRefOid" })
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

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if state.config.commands then
    vim.api.nvim_create_user_command("PrReviewStart", M.start, { desc = "Start normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewStop", M.stop, { desc = "Stop normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewRefresh", M.refresh, { desc = "Refresh normal PR review mode" })
    vim.api.nvim_create_user_command("PrReviewNextChange", M.next_change, { desc = "Jump to next PR change in normal review mode" })
    vim.api.nvim_create_user_command("PrReviewPrevChange", M.prev_change, { desc = "Jump to previous PR change in normal review mode" })
    vim.api.nvim_create_user_command("PrReviewNextFile", M.next_file, { desc = "Jump to next changed PR file in normal review mode" })
    vim.api.nvim_create_user_command("PrReviewPrevFile", M.prev_file, { desc = "Jump to previous changed PR file in normal review mode" })
    vim.api.nvim_create_user_command("PrReviewOldToggle", M.old_toggle, { desc = "Toggle old PR base version beside current file" })
    vim.api.nvim_create_user_command("PrReviewThread", M.show_thread, { desc = "Show PR comments for the current line" })
    vim.api.nvim_create_user_command("PrReviewReply", M.reply, { desc = "Reply to PR comment thread on the current line" })
    vim.api.nvim_create_user_command(
      "PrReviewComment",
      M.comment,
      { range = true, desc = "Create PR review comment for current line or visual range" }
    )
  end

  if setup_done then
    return
  end

  setup_done = true

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("normal_pr_review", { clear = true }),
    callback = function(args)
      annotate_buffer(args.buf)
    end,
  })
end

return M
