-- Blast radius: callers of changed functions that the PR left alone.
--
-- Runs a local review over its own throwaway repo of Lua files (lua is a parser
-- bundled with Neovim, so treesitter works under -u NONE), with the LSP stubbed:
-- the point is the range intersection and subtraction, not a language server.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local function notified(pattern)
  for _, message in ipairs(notifications) do
    if message:find(pattern) then
      return true
    end
  end
  return false
end

-- A repo of its own: main has the base, the working tree is the "PR".
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, args))
  assert(vim.v.shell_error == 0, "git " .. table.concat(args, " ") .. ": " .. out)
end
local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end

git({ "init", "-q" })
git({ "config", "core.hooksPath", dir .. "/.nohooks" })
git({ "config", "user.email", "test@example.com" })
git({ "config", "user.name", "Test" })
git({ "checkout", "-q", "-B", "main" })
write("lib.lua", {
  "local M = {}",
  "",
  "function M.parse(text)",
  "  return text",
  "end",
  "",
  "function M.helper(x)",
  "  return x",
  "end",
  "",
  "return M",
})
write("caller_a.lua", { 'local lib = require("lib")', 'return lib.parse("a")' })
write("caller_b.lua", { 'local lib = require("lib")', 'local v = lib.parse("b")', "local w = lib.helper(1)" })
git({ "add", "." })
git({ "commit", "-q", "-m", "base" })
-- parse's signature changes and caller_a is updated; caller_b is not.
-- helper changes only in its body. The new anonymous callback is not a
-- function anyone calls by name, least of all "pcall".
write("lib.lua", {
  "local M = {}",
  "",
  "function M.parse(text, opts)",
  "  return text",
  "end",
  "",
  "function M.helper(x)",
  "  return x + 1",
  "end",
  "pcall(function(y) end)",
  "return M",
})
write("caller_a.lua", { 'local lib = require("lib")', 'return lib.parse("a", {})' })
vim.cmd.cd(dir)

local blast = require("review_mode.blast_radius")

-- Pure: changed lines, overlap, subtraction ------------------------------------

local diff = table.concat({
  "diff --git a/x.lua b/x.lua",
  "--- a/x.lua",
  "+++ b/x.lua",
  "@@ -1,4 +1,5 @@",
  " keep",
  "-old",
  "+new",
  "+added",
  " keep",
  "@@ -10,2 +11,2 @@",
  "-gone",
  " ctx",
  "+tail",
  "+++ an added line that starts with ++ is content, not a header",
  "+after",
  "diff --git a/y.lua b/y.lua",
  "--- a/y.lua",
  "+++ /dev/null",
  "@@ -1 +0,0 @@",
  "-deleted file",
}, "\n")
local ranges = blast.changed_lines(diff)
assert(vim.deep_equal(ranges["x.lua"], { { 2, 3 }, { 12, 14 } }), "changed_lines: " .. vim.inspect(ranges))
assert(ranges["y.lua"] == nil, "a deleted file has no head-side lines")
assert(blast.overlaps(ranges["x.lua"], 3) and not blast.overlaps(ranges["x.lua"], 4), "overlaps edge")
assert(blast.overlaps(ranges["x.lua"], 4, 12), "a range spanning a hunk overlaps it")

local kept = blast.untouched({
  { path = "x.lua", lnum = 2, col = 1 },
  { path = "x.lua", lnum = 5, col = 1 },
  { path = "x.lua", lnum = 5, col = 1 },
  { path = "z.lua", lnum = 2, col = 1 },
}, ranges)
assert(#kept == 2 and kept[1].lnum == 5 and kept[2].path == "z.lua", "untouched: " .. vim.inspect(kept))

-- Session ------------------------------------------------------------------------

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
})

local labels = vim.tbl_map(function(item)
  return item.label
end, pr.action_items())
assert(vim.tbl_contains(labels, "Blast radius: callers of changed functions this PR missed"), "no action entry")
assert(labels[#labels]:find("Summary"), "Summary must stay the last action")
assert(vim.fn.exists(":ReviewModeBlastRadius") == 2, ":ReviewModeBlastRadius is missing")

api.review_local({ "main" })
wait_for(function()
  return api.is_active() and api.is_changed_file("lib.lua") and api.is_changed_file("caller_a.lua")
end, "local review did not load")

vim.cmd("filetype on") -- -u NONE leaves detection off
vim.cmd("edit lib.lua")
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].filetype == "lua", "lib.lua should be lua")

local lib_ranges = { { 3, 3 }, { 8, 8 }, { 10, 10 } }
local fns = assert(blast.changed_functions(buf, lib_ranges))
assert(#fns == 1 and fns[1].name == "parse", "only parse's signature changed: " .. vim.inspect(fns))
assert(fns[1].line == 3 and fns[1].col == 11 and fns[1].signature, "parse position: " .. vim.inspect(fns[1]))
local all = assert(blast.changed_functions(buf, lib_ranges, { all = true }))
assert(#all == 2 and all[2].name == "helper" and not all[2].signature, "all: " .. vim.inspect(all))

-- No LSP -------------------------------------------------------------------------

local done, result, err
local function run(opts)
  done, result, err = false, nil, nil
  blast.run(vim.tbl_extend("force", { open = false }, opts or {}), function(items, e)
    done, result, err = true, items, e
  end)
  wait_for(function()
    return done
  end, "blast radius did not finish")
end

run()
assert(result == nil and err:find("no LSP client"), "without an LSP it should say so: " .. tostring(err))
assert(notified("no LSP client"), "the missing LSP was not reported")

-- A fake LSP ---------------------------------------------------------------------

local function location(name, line)
  local uri = vim.uri_from_fname(dir .. "/" .. name)
  local range = { start = { line = line - 1, character = 10 }, ["end"] = { line = line - 1, character = 15 } }
  return { uri = uri, range = range }
end

-- by the 0-based line the request is made at
local answers = {
  [2] = { location("caller_a.lua", 2), location("caller_b.lua", 2) }, -- parse
  [6] = { location("caller_b.lua", 3) }, -- helper
}
local requests, cancelled, silent = {}, 0, false
local get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return { { id = 1, offset_encoding = "utf-16" } }
end
vim.lsp.buf_request_all = function(bufnr, method, params, handler)
  requests[#requests + 1] = { bufnr = bufnr, method = method, params = params }
  if not silent then
    vim.schedule(function()
      -- two clients answering the same caller must not list it twice
      local found = answers[params.position.line] or {}
      handler({ [1] = { result = found }, [2] = { result = found } })
    end)
  end
  return function()
    cancelled = cancelled + 1
  end
end

run()
assert(err == nil, "unexpected error: " .. tostring(err))
assert(#requests == 1 and requests[1].method == "textDocument/references", "one references request for parse")
local position = requests[1].params.position
assert(position.line == 2 and position.character == 11, "request position: " .. vim.inspect(position))
assert(requests[1].params.context.includeDeclaration == false, "the declaration is not a caller")
assert(#result == 1, "caller_a was updated by the PR, so only caller_b remains: " .. vim.inspect(result))
assert(result[1].filename:match("caller_b%.lua$") and result[1].lnum == 2, "wrong caller: " .. vim.inspect(result))
assert(result[1].text == "parse → caller not changed in this PR", "text: " .. result[1].text)
local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(#qf.items == 1 and qf.items[1].lnum == 2, "quickfix was not filled")
assert(qf.title == "Review Mode: blast radius of lib.lua", "title: " .. qf.title)

-- The bang form takes body-only changes too.
requests = {}
run({ all = true })
assert(#requests == 2 and #result == 2, "all should ask about parse and helper: " .. vim.inspect(result))
assert(result[2].text:find("^helper") and result[2].lnum == 3, "helper's caller: " .. vim.inspect(result[2]))

-- A server that never answers is given up on, and the request cancelled.
silent, notifications = true, {}
run({ timeout = 50 })
assert(#result == 0 and cancelled == 1, "a silent server should time out and be cancelled")
assert(notified("parse: timed out after 50 ms"), "the timeout was not reported")

vim.lsp.get_clients = get_clients -- the real one runs on exit
harness.done()
vim.cmd("qa!")
