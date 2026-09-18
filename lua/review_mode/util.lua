-- Small shared helpers: process calls, JSON on disk, and float previews.
--
-- These only reach into the session for its repo root (as a default cwd), so
-- every feature module can require this without pulling in the plugin.
local M = {}

local state = require("review_mode.state").state

function M.env_value(name)
  local value = vim.env[name]
  if value and value ~= "" then
    return value
  end
  return nil
end

function M.trim(value)
  return vim.trim(value or "")
end

function M.system(args, opts)
  opts = opts or {}
  M.count_call(args)
  local result = vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }):wait()
  if result.code ~= 0 then
    return nil, M.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  if opts.raw then
    return result.stdout
  end
  return M.trim(result.stdout)
end

function M.system_async(args, opts, callback)
  opts = opts or {}
  M.count_call(args)
  vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }, function(result)
    vim.schedule(function()
      local failed = result.code ~= 0
      if failed and not opts.any_exit then
        callback(nil, M.trim(result.stderr ~= "" and result.stderr or result.stdout))
        return
      end
      if opts.raw or opts.any_exit then
        callback(result.stdout, failed and M.trim(result.stderr) or nil)
        return
      end
      callback(M.trim(result.stdout), nil)
    end)
  end)
end

function M.gh_json_async(args, callback)
  local full = vim.list_extend({ "gh" }, args)
  M.system_async(full, {}, function(stdout, err)
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

-- API call accounting and conditional requests ---------------------------------
-- Fewer API calls is only a claim until something counts them, so every gh (or
-- glab) spawn is tallied here. review_mode.api.request_stats() reads this and
-- :ReviewModeSummary prints it.
--
-- This counts processes, not network requests: `gh --cache` still spawns gh and
-- still shows up in `calls`, it just answers from gh's own response cache
-- instead of the API. `not_modified` is the one that is unambiguously free --
-- a 304 costs nothing against the rate limit.
M.stats = { calls = 0, not_modified = 0 }

function M.count_call(args)
  local bin = type(args) == "table" and args[1] or nil
  if bin == "gh" or bin == "glab" then
    M.stats.calls = M.stats.calls + 1
  end
end

function M.request_stats()
  return vim.deepcopy(M.stats)
end

--- The `--cache` flag for a read-only gh call that repeats and tolerates
--- staleness, or nothing when the duration is unset, "0" or "0s".
function M.gh_cache_args(duration)
  duration = M.trim(duration or state.config.performance.gh_metadata_cache)
  if duration == "" or duration:match("^0%a*$") then
    return {}
  end
  return { "--cache", duration }
end

--- Split `gh api --include` output into its status, headers and body. gh writes
--- the status line with a bare \n and the headers with CRLF, so accept either.
--- Header names come back lowercased.
function M.parse_http_response(text)
  text = text or ""
  local status = tonumber(text:match("^HTTP/[%d.]+ (%d+)"))
  if not status then
    return nil
  end

  local headers = {}
  local offset = 1
  while true do
    local line_end = text:find("\n", offset, true)
    if not line_end then
      offset = #text + 1
      break
    end
    local line = text:sub(offset, line_end - 1):gsub("\r$", "")
    offset = line_end + 1
    if line == "" then
      break
    end
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end

  return status, headers, text:sub(offset)
end

--- `gh api --include`, parsed. A conditional request that matches makes gh exit
--- 1 with "gh: HTTP 304" on stderr while still printing the status line and
--- headers on stdout, so this keeps the output whatever the exit code was and
--- lets the caller decide what the status means.
--- callback({ status, headers, body }, err)
function M.gh_include_async(args, callback)
  M.system_async(vim.list_extend({ "gh" }, args), { any_exit = true }, function(stdout, err)
    local status, headers, body = M.parse_http_response(stdout)
    if not status then
      callback(nil, err or "gh printed no HTTP status line")
      return
    end
    if status == 304 then
      M.stats.not_modified = M.stats.not_modified + 1
    end
    callback({ status = status, headers = headers, body = body }, nil)
  end)
end

-- End API call accounting ------------------------------------------------------

function M.open_lines_preview(lines, filetype, opts)
  opts = opts or {}
  local preview_filetype = filetype or "markdown"
  local bufnr = vim.lsp.util.open_floating_preview(lines, preview_filetype, {
    border = "rounded",
    focusable = true,
    max_width = opts.max_width or math.floor(vim.o.columns * 0.75),
    max_height = opts.max_height or math.floor(vim.o.lines * 0.65),
  })
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].filetype = preview_filetype
  end
end

function M.repo_root()
  local cwd = vim.uv.cwd()
  if vim.fs.root then
    local root = vim.fs.root(cwd, ".git")
    if root then
      return root
    end
  end
  return M.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
end

function M.split_blob_lines(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.read_json_file(path)
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

function M.write_json_file(path, value)
  local dir = vim.fs.dirname(path)
  if dir then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

function M.buf_relpath(bufnr)
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

function M.current_relpath()
  return M.buf_relpath(0)
end

function M.clamp_line(line)
  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  return math.max(1, math.min(line or 1, max_line))
end

function M.ensure_active()
  if state.active then
    return true
  end

  vim.notify("Review Mode is not active", vim.log.levels.WARN)
  return false
end

-- Redrawing the statusline is pointless with no UI attached, and doing it
-- synchronously while diff windows are being torn down segfaults Neovim 0.11
-- (reproducible ~70% of headless runs: open the base diff, toggle the layout
-- twice, end the session). pcall cannot catch that. Skip it when nothing is
-- displaying, and otherwise let the stack unwind first.
function M.redraw_status()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end

  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
    pcall(vim.cmd, "redrawtabline")
  end)
end

--- Open a URL in the system browser.
function M.open_url(url, callback)
  local cmd
  if vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  elseif vim.fn.has("win32") == 1 then
    cmd = { "cmd", "/c", "start", "", url }
  else
    cmd = { "xdg-open", url }
  end

  M.system_async(cmd, {}, function(_, err)
    if err then
      vim.notify("Review Mode browser: " .. tostring(err), vim.log.levels.ERROR)
    end
    if callback then
      callback(err == nil, err)
    end
  end)
end

function M.visual_range(command)
  if command and command.range and command.range > 0 then
    return command.line1, command.line2
  end

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

function M.selected_text(start_line, end_line)
  return table.concat(vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false), "\n")
end

return M
