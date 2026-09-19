-- Moved code: blocks the review deletes in one place and adds, unchanged, in
-- another. A refactor that moves a function otherwise reads as N new lines.
--
-- Detection is pure Lua over one `git diff --unified=0` of the whole review,
-- run once per load. Each run of added lines is matched against the deleted
-- lines of any file, comparing trimmed text, so re-indented code still counts.
-- A match is a block only when it is at least MIN_LINES long and carries
-- MIN_ALNUM alphanumeric characters (git's own --color-moved threshold), so a
-- stray `end` / `}` / blank run is never "moved".
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")

local state = core.state

local ns = vim.api.nvim_create_namespace("review_mode_moved")
local MIN_LINES = 3
local MIN_ALNUM = 20
-- A line deleted more often than this (`}`, `end`, blank) never starts a block:
-- trying every copy as a start is quadratic, and on the main thread. Blocks
-- still run through such lines; they just start at the next distinctive one.
local MAX_CANDIDATES = 32

M.namespace = ns

local empty = { added = {}, skip = {} }
local result = empty

local function alnum(text)
  return select(2, text:gsub("%w", ""))
end

--- Find moved blocks in a `--unified=0` patch.
---
--- Returns { added = { [path] = { [line] = { path, line, first } } },
---           skip = { [path] = { [hunk_line] = true|false } } }.
--- `added` maps each moved-in line to the line it came from; `first` marks the
--- start of a block. `skip[path][line]` is true for a hunk (keyed by its new
--- start, as the hunk list keys it) whose every non-blank line is moved.
function M.detect(patch)
  local dels, adds, hunks = {}, {}, {}
  local old_path, new_path, hunk
  local old_line, new_line, old_left, new_left = 0, 0, 0, 0

  for line in ((patch or "") .. "\n"):gmatch("(.-)\n") do
    if old_left > 0 or new_left > 0 then
      -- counted from the @@ header, so a deleted "-- comment" (patch line
      -- "--- comment") is never mistaken for a file header
      local sign, text = line:sub(1, 1), vim.trim(line:sub(2))
      if sign == "-" then
        dels[#dels + 1] = { path = old_path, line = old_line, text = text, hunk = hunk }
        old_line, old_left = old_line + 1, old_left - 1
      elseif sign == "+" then
        adds[#adds + 1] = { path = new_path, line = new_line, text = text, hunk = hunk }
        new_line, new_left = new_line + 1, new_left - 1
      end
    else
      local ostart, oc, nstart, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if ostart then
        old_line, old_left = tonumber(ostart), oc == "" and 1 or tonumber(oc)
        new_line, new_left = tonumber(nstart), nc == "" and 1 or tonumber(nc)
        hunk = { path = new_path, line = math.max(1, new_line), moved = false, dirty = false }
        hunks[#hunks + 1] = hunk
      elseif line:match("^diff ") then
        old_path, new_path = nil, nil
      else
        old_path = line:match("^%-%-%- a/(.+)$") or old_path
        new_path = line:match("^%+%+%+ b/(.+)$") or new_path
      end
    end
  end

  local by_text = {}
  for index, del in ipairs(dels) do
    by_text[del.text] = by_text[del.text] or {}
    table.insert(by_text[del.text], index)
  end

  local used = {}
  local i = 1
  while i <= #adds do
    local best, length = nil, 0
    local candidates = by_text[adds[i].text] or {}
    if #candidates > MAX_CANDIDATES then
      candidates = {}
    end
    for _, d in ipairs(candidates) do
      local n = 0
      while
        adds[i + n]
        and dels[d + n]
        and not used[d + n]
        and adds[i + n].hunk == adds[i].hunk
        and dels[d + n].hunk == dels[d].hunk
        and adds[i + n].text == dels[d + n].text
      do
        n = n + 1
      end
      if n > length then
        best, length = d, n
      end
    end

    local chars = 0
    for k = 0, length - 1 do
      chars = chars + alnum(adds[i + k].text)
    end
    if length >= MIN_LINES and chars >= MIN_ALNUM then
      for k = 0, length - 1 do
        local del = dels[best + k]
        used[best + k] = true
        adds[i + k].from = { path = del.path, line = del.line, first = k == 0 }
      end
      i = i + length
    else
      i = i + 1
    end
  end

  local out = { added = {}, skip = {} }
  for index, del in ipairs(dels) do
    del.moved = used[index]
  end
  for _, list in ipairs({ dels, adds }) do
    for _, entry in ipairs(list) do
      local moved = entry.moved or entry.from
      entry.hunk.moved = entry.hunk.moved or moved ~= nil
      -- a blank separator line added next to a moved block is still just the move
      entry.hunk.dirty = entry.hunk.dirty or (not moved and entry.text ~= "")
      if entry.from and entry.path then
        out.added[entry.path] = out.added[entry.path] or {}
        out.added[entry.path][entry.line] = entry.from
      end
    end
  end
  for _, h in ipairs(hunks) do
    if h.path then
      out.skip[h.path] = out.skip[h.path] or {}
      -- two hunks can share a start line; one real change keeps both
      out.skip[h.path][h.line] = out.skip[h.path][h.line] ~= false and h.moved and not h.dirty
    end
  end
  return out
end

--- Whether ]c / [c should pass over the hunk starting at `line` in `path`.
function M.skip_hunk(path, line)
  return state.config.diff.skip_moved == true and result.skip[path] ~= nil and result.skip[path][line] == true
end

--- The moved-in lines of `path`: { [line] = { path, line, first } }.
function M.lines(path)
  return result.added[path] or {}
end

function M.annotate(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local path = state.active and util.buf_relpath(bufnr)
  local lines = path and result.added[path]
  if not lines then
    return
  end

  pcall(vim.api.nvim_set_hl, 0, "ReviewModeMoved", { link = "Comment", default = true })
  local count = vim.api.nvim_buf_line_count(bufnr)
  for line, from in pairs(lines) do
    if line <= count then
      vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
        sign_text = "»",
        sign_hl_group = "ReviewModeMoved",
        virt_text = from.first and { { string.format("moved from %s:%d", from.path, from.line), "ReviewModeMoved" } }
          or nil,
        virt_text_pos = "eol",
        priority = 150,
      })
    end
  end
end

--- Detect moved blocks for the current review, then mark the open buffers.
function M.load()
  result = empty
  if not state.config.diff.detect_moved then
    return
  end

  local generation = state.generation
  util.system_async({
    "git",
    "diff",
    "--unified=0",
    "--find-renames",
    "--no-ext-diff",
    "--no-color",
    core.diff_range(),
  }, { cwd = state.root }, function(patch)
    if not core.is_current(generation) or not patch then
      return
    end

    result = M.detect(patch)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        M.annotate(bufnr)
      end
    end
  end)
end

return M
