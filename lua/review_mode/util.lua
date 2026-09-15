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
  vim.system(args, { text = true, cwd = opts.cwd or state.root or vim.uv.cwd() }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, M.trim(result.stderr ~= "" and result.stderr or result.stdout))
        return
      end
      if opts.raw then
        callback(result.stdout, nil)
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
