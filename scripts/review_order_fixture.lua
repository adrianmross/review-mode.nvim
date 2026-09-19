-- Reading order: files.order = "smart" reads definitions before their uses,
-- docs after code and tests last; "diff" keeps git's order.
--
-- Its own throwaway repo, so the file list can be shaped to the rules without
-- touching what the shared fixtures expect.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

vim.notify = function() end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/spec", "p")
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
write("README.md", { "# base" })
git({ "add", "." })
git({ "commit", "-q", "-m", "base" })

-- git lists these alphabetically; the story is lexer, parser, app.
git({ "checkout", "-q", "-b", "feature" })
write("README.md", { "# how app uses parser" }) -- docs never pull code around
write("app.lua", { 'local parser = require("parser")', 'local lexer = require("lexer")' })
write("b_test.lua", { 'local app = require("app")' })
write("lexer.lua", { "return {}" })
write("parser.lua", { 'local lexer = require("lexer")' })
-- a cycle: neither can go first on the evidence, so the diff order stands
write("ping.lua", { 'require("pong")' })
write("pong.lua", { 'require("ping")' })
write("spec/parser_spec.lua", { 'local parser = require("parser")' })
write("yarn.lock", { "lexer parser app" })
git({ "add", "." })
git({ "commit", "-q", "-m", "feature" })
vim.cmd.cd(dir)

local git_order = {
  "README.md",
  "app.lua",
  "b_test.lua",
  "lexer.lua",
  "parser.lua",
  "ping.lua",
  "pong.lua",
  "spec/parser_spec.lua",
  "yarn.lock",
}
local smart_order = {
  "lexer.lua",
  "parser.lua",
  "app.lua",
  "ping.lua",
  "pong.lua",
  "README.md",
  "yarn.lock",
  "b_test.lua",
  "spec/parser_spec.lua",
}

-- Pure ------------------------------------------------------------------------------

local order = require("review_mode.order")
assert(order.tier("lua/x.lua") == 1, "code is tier 1")
assert(order.tier("docs/x.lua") == 2 and order.tier("CHANGELOG.md") == 2, "docs are tier 2")
assert(order.tier("Cargo.lock") == 2 and order.tier("package-lock.json") == 2, "lockfiles are tier 2")
for _, path in ipairs({ "tests/a.lua", "src/__tests__/a.ts", "a_test.go", "a.test.ts", "a_spec.rb", "test_a.py" }) do
  assert(order.tier(path) == 3, path .. " is a test")
end
assert(order.stem("lua/init.lua") == nil and order.stem("db.lua") == nil, "generic and short stems name nothing")

-- a three-file cycle next to a free file: the free one goes first, the cycle is
-- broken at its earliest file in diff order, and the rest follow their edges
local sorted = order.sort({ "c.lua", "a.lua", "b.lua", "free.lua" }, {
  ["c.lua"] = { ["a.lua"] = true },
  ["a.lua"] = { ["b.lua"] = true },
  ["b.lua"] = { ["c.lua"] = true, ["free.lua"] = true },
})
assert(vim.deep_equal(sorted, { "free.lua", "c.lua", "b.lua", "a.lua" }), "cycle: " .. vim.inspect(sorted))

-- Session ---------------------------------------------------------------------------

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
})
assert(api.config().files.order == "smart", "smart is the default")

local function paths()
  return vim.tbl_map(function(file)
    return file.path
  end, api.files())
end

local function review(args)
  pr.stop()
  -- or the last session's order could pass for this one's
  assert(#api.files() == 0, "stop left the last session's files behind")
  api.review_local(args)
  wait_for(function()
    -- ]f waits on the whole changed-file map, numstat included
    return api.is_active() and require("review_mode.state").state.maps_loaded and #api.files() == #git_order
  end, "local review did not load")
end

-- the buffer's path relative to the repo; macOS tempdirs sit behind /private
local real_dir = vim.uv.fs_realpath(dir)
local function current()
  local name = vim.api.nvim_buf_get_name(0)
  return vim.fs.relpath(real_dir, vim.uv.fs_realpath(name) or name) or name
end

-- the working tree
review({ "main" })
assert(vim.deep_equal(paths(), smart_order), "smart order: " .. vim.inspect(paths()))

-- ]f walks the same order, and [f wraps from the first file to the last
vim.cmd.enew()
for _, expected in ipairs({ "lexer.lua", "parser.lua", "app.lua", "ping.lua" }) do
  pr.next_file()
  wait_for(function()
    return current() == expected
  end, "]f should reach " .. expected .. ", at " .. current())
end
pr.prev_file()
pr.prev_file()
pr.prev_file()
pr.prev_file()
wait_for(function()
  return current() == "spec/parser_spec.lua"
end, "[f should wrap to the last file, at " .. current())

-- a named head is read from git, not the checkout: main has none of these files
git({ "checkout", "-q", "main" })
review({ "main", "feature" })
assert(vim.deep_equal(paths(), smart_order), "smart order from a ref: " .. vim.inspect(paths()))

api.config().files.order = "diff"
review({ "main", "feature" })
assert(vim.deep_equal(paths(), git_order), "diff order: " .. vim.inspect(paths()))

pr.stop()
print("review order fixture passed")
vim.cmd("qa!")
