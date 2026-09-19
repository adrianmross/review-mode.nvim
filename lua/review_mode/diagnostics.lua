-- Review threads as vim.diagnostic entries and a quickfix list.
--
-- A UI consumer like the panel: review data comes only through review_mode.api
-- (plus util and hooks), and scripts/validate.sh enforces that.
--
-- The plugin already draws its own signs and virtual text, so by default the
-- namespace displays nothing. The diagnostics are there to feed the builtins
-- (]d/[d, vim.diagnostic.open_float, statusline counts, Trouble), not to draw.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

M.namespace = vim.api.nvim_create_namespace("review_mode_diagnostics")

local qf_types = { "E", "W", "I", "N" }

local function config()
  return api.config().comments.diagnostics or {}
end

local function severity(thread)
  local levels = config().severity or {}
  local key = thread.is_resolved and "resolved" or thread.is_outdated and "outdated" or "unresolved"
  local value = levels[key]
  if type(value) == "string" then
    value = vim.diagnostic.severity[value:upper()]
  end
  return value or vim.diagnostic.severity.INFO
end

local function summary(thread)
  local comments = thread.comments or {}
  local last = comments[#comments] or {}
  local body = vim.trim((last.body or ""):match("([^\n\r]+)") or "")
  local text = string.format("%s: %s", last.author or "reviewer", body ~= "" and body or "comment")
  if #comments > 1 then
    local replies = #comments - 1
    text = text .. string.format(" (%d %s)", replies, replies == 1 and "reply" or "replies")
  end
  return text
end

-- Threads with a line in the file as the PR leaves it: a base-side (LEFT)
-- thread numbers the old file, so it has no line here.
local function threads(path, include_resolved)
  local out = {}
  for _, thread in ipairs(api.threads({ path = path, include_resolved = include_resolved })) do
    if thread.line and thread.side ~= "LEFT" then
      out[#out + 1] = thread
    end
  end
  return out
end

local function enabled()
  return api.is_active() and api.config().comments.enabled and config().enabled == true
end

--- Set (or clear) the diagnostics for one buffer.
function M.refresh_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = util.buf_relpath(bufnr)
  -- Keyed on comments alone, like the plugin's own signs: comments can land
  -- before the changed-file map, and nothing announces the map loading.
  if not enabled() or not path then
    vim.diagnostic.reset(M.namespace, bufnr)
    return
  end

  local items = {}
  for _, thread in ipairs(threads(path, api.config().comments.show_resolved)) do
    local last = thread.comments[#thread.comments] or {}
    items[#items + 1] = {
      lnum = (thread.start_line or thread.line) - 1,
      end_lnum = thread.line - 1,
      col = 0,
      severity = severity(thread),
      message = summary(thread),
      source = "review-mode",
      user_data = { thread_id = thread.id, url = last.url },
    }
  end
  vim.diagnostic.set(M.namespace, bufnr, items)
end

--- Apply the display config and refresh every loaded buffer.
function M.refresh()
  vim.diagnostic.config(config().display or {}, M.namespace)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_buffer(bufnr)
    end
  end
end

function M.clear()
  vim.diagnostic.reset(M.namespace)
end

function M.toggle()
  local cfg = api.config().comments
  cfg.diagnostics = cfg.diagnostics or {}
  cfg.diagnostics.enabled = not cfg.diagnostics.enabled
  M.refresh()
  vim.notify("Review Mode diagnostics " .. (cfg.diagnostics.enabled and "enabled" or "disabled"))
end

--- Quickfix items for every thread across the changed files.
--- opts.filter is "unresolved" or "all"; it defaults to comments.show_resolved.
function M.quickfix_items(opts)
  opts = opts or {}
  local session = api.session()
  if not session then
    return {}
  end
  local filter = opts.filter or (api.config().comments.show_resolved and "all" or "unresolved")

  local items = {}
  for _, file in ipairs(api.files()) do
    for _, thread in ipairs(threads(file.path, filter == "all")) do
      items[#items + 1] = {
        filename = vim.fs.joinpath(session.root, file.path),
        lnum = thread.start_line or thread.line,
        end_lnum = thread.line,
        col = 1,
        type = qf_types[severity(thread)] or "I",
        text = summary(thread) .. (thread.is_resolved and " [resolved]" or ""),
        user_data = { thread_id = thread.id },
      }
    end
  end
  return items
end

--- Fill the quickfix list with review threads and open it (opts.open = false
--- to only set it).
function M.set_quickfix(opts)
  opts = opts or {}
  if not util.ensure_active() then
    return
  end
  local session = api.session()
  vim.fn.setqflist({}, " ", {
    title = string.format("Review Mode: %s#%s threads", session.repo, session.pr),
    items = M.quickfix_items(opts),
  })
  if opts.open ~= false then
    vim.cmd("copen")
  end
end

-- CI annotations --------------------------------------------------------------
-- Their own namespace and source, so they toggle apart from the threads. Nothing
-- else draws CI failures, so this namespace keeps vim.diagnostic's display.

M.ci_namespace = vim.api.nvim_create_namespace("review_mode_ci")

local function ci_enabled()
  local ci = api.config().ci
  return api.is_active() and type(ci) == "table" and ci.diagnostics == true
end

function M.refresh_ci_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = util.buf_relpath(bufnr)
  if not ci_enabled() or not path then
    vim.diagnostic.reset(M.ci_namespace, bufnr)
    return
  end

  local items = {}
  for _, annotation in ipairs(api.ci_annotations(path)) do
    items[#items + 1] = {
      lnum = annotation.start_line - 1,
      end_lnum = annotation.end_line - 1,
      col = 0,
      severity = annotation.severity,
      message = annotation.message,
      source = "review-mode CI",
      user_data = { check = annotation.check },
    }
  end
  vim.diagnostic.set(M.ci_namespace, bufnr, items)
end

function M.refresh_ci()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_ci_buffer(bufnr)
    end
  end
end

function M.toggle_ci()
  local cfg = api.config()
  cfg.ci = type(cfg.ci) == "table" and cfg.ci or {}
  cfg.ci.diagnostics = not cfg.ci.diagnostics
  if cfg.ci.diagnostics and api.is_active() then
    api.reload_ci()
  else
    M.refresh_ci()
  end
  vim.notify("Review Mode CI diagnostics " .. (cfg.ci.diagnostics and "enabled" or "disabled"))
end

function M.setup()
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("review_mode_diagnostics", { clear = true }),
    callback = function(args)
      if api.is_active() then
        M.refresh_buffer(args.buf)
        M.refresh_ci_buffer(args.buf)
      end
    end,
  })
end

-- Registered after the functions they call exist.
hooks.on("comments_loaded", M.refresh)
hooks.on("viewed_changed", M.refresh)
hooks.on("stop", M.clear)
hooks.on("ci_loaded", M.refresh_ci)
hooks.on("stop", function()
  vim.diagnostic.reset(M.ci_namespace)
end)

return M
