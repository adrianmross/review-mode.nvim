-- Blast radius: callers of the functions a PR changes that the PR left alone.
--
-- Line-by-line review cannot see that a signature changed and four callers
-- elsewhere were not updated. A review in a real checkout has the reviewer's
-- LSP, so ask it: find the function definitions the PR changes (treesitter),
-- ask the language server for their references, and drop the ones that sit on
-- lines the PR itself changed. What is left goes to the quickfix list.
--
-- On demand only: nothing here runs, or loads an LSP, until it is asked for.
-- Reaches review data through review_mode.api only, like the bundled UI.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")

-- Function-like node types across the bundled and common parsers. Matching on
-- type rather than a per-language query keeps it language-agnostic.
M.function_types = {
  function_declaration = true, -- lua, js/ts, go
  function_definition = true, -- lua (anonymous), python, c
  local_function = true, -- older lua parsers
  method_definition = true, -- js/ts
  method_declaration = true, -- go, java
  function_item = true, -- rust
  arrow_function = true, -- js/ts
  function_expression = true, -- js/ts
  constructor_declaration = true, -- java
}

-- Pure ------------------------------------------------------------------------

--- New-side lines each file's diff adds or rewrites, as
--- { [path] = { { start, end }, ... } }, 1-based and inclusive. Only "+" lines
--- count: a pure deletion leaves no line on the head side to point at.
---
--- The patch is read by review_mode.git, so an added line that reads "++ x"
--- is content, not a header.
function M.changed_lines(diff)
  local by_path = {}
  for _, file in ipairs(require("review_mode.git").parse_patch(diff)) do
    local path = file.new_path
    if path then
      local ranges = by_path[path] or {}
      by_path[path] = ranges
      for _, hunk in ipairs(file.hunks) do
        local line = hunk.new_start
        for _, text in ipairs(hunk.lines) do
          local mark = text:sub(1, 1)
          if mark == "+" then
            local last = ranges[#ranges]
            if last and last[2] == line - 1 then
              last[2] = line
            else
              ranges[#ranges + 1] = { line, line }
            end
            line = line + 1
          elseif mark ~= "-" and mark ~= "\\" then
            line = line + 1
          end
        end
      end
    end
  end
  return by_path
end

--- True when [first, last] overlaps any of the ranges.
function M.overlaps(ranges, first, last)
  last = last or first
  for _, range in ipairs(ranges or {}) do
    if first <= range[2] and last >= range[1] then
      return true
    end
  end
  return false
end

--- References that land outside the PR's changed lines. refs are
--- { path, lnum, col } with paths relative to the review root; ranges is
--- M.changed_lines output. Duplicates (several clients) are dropped.
function M.untouched(refs, ranges)
  local out, seen = {}, {}
  for _, ref in ipairs(refs) do
    local key = string.format("%s:%d:%d", ref.path, ref.lnum, ref.col)
    if not seen[key] and not M.overlaps(ranges[ref.path], ref.lnum) then
      seen[key] = true
      out[#out + 1] = ref
    end
  end
  return out
end

--- Flatten buf_request_all results into { filename, path, lnum, col }, 1-based,
--- path relative to root (or absolute when the file is outside it).
function M.locations(results, root)
  local refs = {}
  -- through symlinks (macOS /var is /private/var), or relpath misses the root
  root = root and (vim.uv.fs_realpath(root) or root)
  for _, response in pairs(results or {}) do
    for _, location in ipairs(response.result or {}) do
      local uri = location.uri or location.targetUri
      local range = location.range or location.targetSelectionRange or location.targetRange
      if uri and range then
        local fname = vim.uri_to_fname(uri)
        fname = vim.uv.fs_realpath(fname) or fname
        refs[#refs + 1] = {
          filename = fname,
          path = root and vim.fs.relpath(root, fname) or fname,
          lnum = range.start.line + 1,
          col = range.start.character + 1,
        }
      end
    end
  end
  return refs
end

-- Treesitter ------------------------------------------------------------------

-- The node naming a function: its own name field, or for an anonymous function
-- the thing it is assigned to (local f = function, const f = () =>). Never a
-- call it is passed to, so a callback is not mistaken for its caller.
local function name_node(node)
  local name, current = node:field("name")[1], node
  for _ = 1, 3 do
    if name then
      break
    end
    current = current:parent()
    if not current or current:type():find("call") or current:type():find("argument") then
      return nil
    end
    local first = current:named_child(0)
    name = current:field("name")[1] or (first and first ~= node and first:field("name")[1])
  end
  -- M.parse / M:parse / obj.parse: the identifier references resolve on is last
  while name and name:named_child_count() > 0 do
    name = name:named_child(name:named_child_count() - 1)
  end
  return name
end

--- Function definitions in a buffer that the changed ranges touch, as
--- { name, line, col, signature = bool }. The signature is the first line
--- through the end of the parameter list; with opts.all, functions changed only
--- in their body are listed too. Returns nil and an error without a parser.
function M.changed_functions(bufnr, ranges, opts)
  opts = opts or {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return nil, "no treesitter parser for filetype '" .. vim.bo[bufnr].filetype .. "'"
  end
  local root = parser:parse()[1]:root()

  local out = {}
  local function visit(node)
    if M.function_types[node:type()] then
      local start_row, _, end_row = node:range()
      local params = node:field("parameters")[1]
      local sig_end = params and select(3, params:range()) or start_row
      local signature = M.overlaps(ranges, start_row + 1, sig_end + 1)
      local name = name_node(node)
      if name and (signature or (opts.all and M.overlaps(ranges, start_row + 1, end_row + 1))) then
        local row, col = name:range()
        out[#out + 1] = {
          name = vim.treesitter.get_node_text(name, bufnr),
          line = row + 1,
          col = col,
          signature = signature,
        }
      end
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end
  visit(root)
  return out
end

-- LSP -------------------------------------------------------------------------

--- Ask every attached server for the references to fn. callback(results, err),
--- results as vim.lsp.buf_request_all hands them over. Gives up after
--- timeout ms.
function M.references(bufnr, fn, timeout, callback)
  local done = false
  local function finish(results, err)
    if not done then
      done = true
      callback(results, err)
    end
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, fn.line - 1, fn.line, false)[1] or ""
  local client = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/references" })[1]
  local encoding = client and client.offset_encoding or "utf-16"
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = fn.line - 1, character = vim.str_utfindex(line, encoding, fn.col, false) },
    context = { includeDeclaration = false },
  }
  local cancel = vim.lsp.buf_request_all(bufnr, "textDocument/references", params, function(results)
    finish(results, nil)
  end)
  vim.defer_fn(function()
    if not done and type(cancel) == "function" then
      pcall(cancel)
    end
    finish(nil, string.format("timed out after %d ms", timeout))
  end, timeout)
end

-- Command ---------------------------------------------------------------------

local function notify(message, level)
  vim.notify("Review Mode blast radius: " .. message, level or vim.log.levels.INFO)
end

--- Fill the quickfix list with callers of the current file's changed functions
--- that the PR did not touch. opts.all includes functions changed only in their
--- body; opts.timeout (ms, default 5000) bounds each LSP request; opts.open =
--- false only sets the list. callback(items, err) when given.
function M.run(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if not util.ensure_active() then
    return callback(nil, "not active")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local path = util.buf_relpath(bufnr)
  local function fail(message, level)
    notify(message, level or vim.log.levels.WARN)
    callback(nil, message)
  end
  if not path or not api.is_changed_file(path) then
    return fail("the current buffer is not a file this PR changes")
  end
  if #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/references" }) == 0 then
    return fail("no LSP client with references support is attached to " .. path)
  end

  -- "." diffs every file at once: callers live in other files, and whether they
  -- were touched is a question about those files' changed lines.
  api.file_diff(".", function(diff, err)
    if not diff then
      return fail("git diff failed: " .. tostring(err), vim.log.levels.ERROR)
    end
    local ranges = M.changed_lines(diff)
    local fns, ts_err = M.changed_functions(bufnr, ranges[path] or {}, opts)
    if not fns then
      return fail(ts_err)
    end
    if #fns == 0 then
      notify(string.format("no changed function %sin %s", opts.all and "" or "signatures ", path))
      return callback({}, nil)
    end

    local root, items, errors = api.root(), {}, {}
    local function step(index)
      local fn = fns[index]
      if not fn then
        vim.fn.setqflist({}, " ", { title = "Review Mode: blast radius of " .. path, items = items })
        if #items == 0 then
          notify(string.format("every caller of %d changed function(s) is in this PR", #fns))
        elseif opts.open ~= false then
          vim.cmd("copen")
        end
        if #errors > 0 then
          notify(table.concat(errors, "; "), vim.log.levels.WARN)
        end
        return callback(items, nil)
      end
      M.references(bufnr, fn, opts.timeout or 5000, function(results, ref_err)
        if ref_err then
          errors[#errors + 1] = fn.name .. ": " .. ref_err
        end
        for _, ref in ipairs(M.untouched(M.locations(results, root), ranges)) do
          items[#items + 1] = {
            filename = ref.filename,
            lnum = ref.lnum,
            col = ref.col,
            text = string.format("%s → caller not changed in this PR", fn.name),
          }
        end
        step(index + 1)
      end)
    end
    step(1)
  end)
end

return M
