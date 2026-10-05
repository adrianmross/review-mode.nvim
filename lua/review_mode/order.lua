-- Reading order: the changed files as a story, not as git sorts them.
--
-- git lists a PR alphabetically, so a reviewer meets the callers of a new
-- function before the function, and the tests before the code they test.
-- "smart" reorders in three tiers, each kept in the diff's own order unless a
-- rule below moves a file:
--
--   1. code, with a file that another changed file mentions ahead of it
--   2. docs and lockfiles
--   3. tests
--
-- "Mentions" is deliberately dumb: file B depends on file A when B's first
-- 64 KiB contain A's file name, extension dropped, as a whole word. That is a
-- table lookup per word read, with no process per file and no LSP, which would
-- not be attached yet at startup anyway. A cycle, or a false match that makes
-- one, falls back to the diff order for the files caught in it.
local M = {}

local test_dirs = { test = true, tests = true, spec = true, specs = true, __tests__ = true, fixtures = true }
local test_names = { "_test%.", "%.test%.", "_spec%.", "%.spec%.", "_fixture%.", "^test_.+%.py$" }
local doc_exts = { md = true, markdown = true, rst = true, txt = true, adoc = true, lock = true }
local doc_dirs = { doc = true, docs = true }
local doc_names = { "^package%-lock%.json$", "%-lock%.yaml$", "^go%.sum$", "^LICENSE", "^CHANGELOG" }
-- names nothing else uses for the module: a require of "pkg.util" names pkg
-- too, so taking the directory name instead would tie init.lua to every file
local generic_stems = { init = true, index = true, mod = true, main = true, __init__ = true }

local CODE, DOCS, TESTS = 1, 2, 3

local function matches_any(name, patterns)
  for _, pattern in ipairs(patterns) do
    if name:find(pattern) then
      return true
    end
  end
  return false
end

--- Which tier a path reads in: 1 code, 2 docs and lockfiles, 3 tests.
function M.tier(path)
  local segments = vim.split(path, "/", { plain = true })
  local name = segments[#segments]
  for index = 1, #segments - 1 do
    if test_dirs[segments[index]] then
      return TESTS
    end
  end
  if matches_any(name, test_names) then
    return TESTS
  end
  if doc_dirs[segments[1]] or doc_exts[name:match("%.([^.]+)$") or ""] or matches_any(name, doc_names) then
    return DOCS
  end
  return CODE
end

--- The word another file would use to name this one, or nil.
function M.stem(path)
  local stem = vim.fs.basename(path):gsub("%.[^.]*$", "")
  -- two letters is noise: "a" and "db" turn up in every file
  if generic_stems[stem] or #stem < 3 then
    return nil
  end
  return stem
end

--- Order paths (given in diff order) by tier, then definitions before uses.
--- deps[b][a] = true means b mentions a. Pure, so the fixture can drive it.
function M.sort(paths, deps)
  local tier_of = {}
  local tiers = { {}, {}, {} }
  for _, path in ipairs(paths) do
    tier_of[path] = M.tier(path)
    table.insert(tiers[tier_of[path]], path)
  end

  local out = {}
  for _, remaining in ipairs(tiers) do
    local done = {}
    -- ponytail: O(n^2) scan for the first ready file; fine for the few
    -- thousand files a review can hold, a heap if that ever changes
    while #remaining > 0 do
      local pick = 1
      for index, path in ipairs(remaining) do
        local ready = true
        for dep in pairs(deps[path] or {}) do
          -- only a pending file in this tier can hold another back
          if not done[dep] and tier_of[dep] == tier_of[path] then
            ready = false
            break
          end
        end
        if ready then
          pick = index
          break
        end
      end
      -- nothing ready means a cycle: the earliest file in diff order breaks it
      local path = table.remove(remaining, pick)
      done[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

-- Imports and requires sit at the top of a file; reading past this finds
-- little but costs time on generated or vendored files.
M.read_limit = 64 * 1024

--- Who mentions whom among paths: deps[b][a] = true when b names a.
--- read(path) returns the head-side content, or nil for a file it cannot read.
function M.dependencies(paths, read)
  -- stems that are one word are looked up among a file's words; the rare
  -- "my-lib" kind is searched for as plain text instead
  local owners, odd = {}, {}
  for _, path in ipairs(paths) do
    local stem = M.tier(path) ~= DOCS and M.stem(path)
    if stem then
      if not owners[stem] then
        owners[stem] = {}
        if not stem:match("^[%w_]+$") then
          odd[#odd + 1] = stem
        end
      end
      table.insert(owners[stem], path)
    end
  end

  local deps = {}
  local function add(path, stem)
    for _, owner in ipairs(owners[stem]) do
      if owner ~= path then
        deps[path] = deps[path] or {}
        deps[path][owner] = true
      end
    end
  end
  for _, path in ipairs(paths) do
    local content = M.tier(path) ~= DOCS and read(path)
    -- a NUL byte means binary: nothing in it names a module
    if content and not content:find("\0", 1, true) then
      local seen = {}
      for word in content:gmatch("[%w_]+") do
        if owners[word] and not seen[word] then
          seen[word] = true
          add(path, word)
        end
      end
      for _, stem in ipairs(odd) do
        if content:find(stem, 1, true) then
          add(path, stem)
        end
      end
    end
  end
  return deps
end

--- A reader for the review's head side. nil or "" (a PR, or a local review of
--- the working tree) is what is on disk; a named head_ref is read from git, all
--- files in one `git cat-file --batch`, so it is one process however many.
function M.reader(root, head_ref, paths)
  if not head_ref or head_ref == "" then
    return function(path)
      local file = io.open(root .. "/" .. path, "rb")
      if not file then
        return nil
      end
      local content = file:read(M.read_limit)
      file:close()
      return content
    end
  end

  -- docs are never read, and a lockfile can run to megabytes
  local wanted, request = {}, {}
  for _, path in ipairs(paths) do
    if M.tier(path) ~= DOCS then
      wanted[#wanted + 1] = path
      request[#request + 1] = head_ref .. ":" .. path
    end
  end
  local result = vim
    .system({ "git", "cat-file", "--batch" }, { cwd = root, stdin = table.concat(request, "\n") .. "\n" })
    :wait()
  local blobs, output, at = {}, result.stdout or "", 1
  for _, path in ipairs(wanted) do
    -- "<oid> <type> <size>\n<content>\n", or "<name> missing\n"
    local header_end = output:find("\n", at, true)
    if not header_end then
      break
    end
    local size = tonumber(output:sub(at, header_end - 1):match(" blob (%d+)$"))
    at = header_end + 1
    if size then
      blobs[path] = output:sub(at, at + math.min(size, M.read_limit) - 1)
      at = at + size + 1
    end
  end
  return function(path)
    return blobs[path]
  end
end

--- Reorder state.file_order (and file_index) by config.files.order.
function M.apply(state)
  if state.config.files.order ~= "smart" or #state.file_order < 2 then
    return
  end
  local read = M.reader(state.root, state.head_ref, state.file_order)
  local deps = M.dependencies(state.file_order, read)
  state.file_order = M.sort(state.file_order, deps)
  state.file_index = {}
  for index, path in ipairs(state.file_order) do
    state.file_index[path] = index
  end
end

return M
