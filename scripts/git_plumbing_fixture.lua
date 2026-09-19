-- Git plumbing: every review diff goes through review_mode.git, so file names
-- and the user's git config cannot break the parsers.
--
-- Builds its own repos: a name with a space, a non-ASCII name, a file under a
-- b/ directory (what diff.noprefix makes ambiguous), two renames with edits
-- (inside a shared directory and not), a deleted "-- a/b ..." Lua comment (a
-- "--- a/b ..." line in the patch), and a base branch that moved on after the
-- PR branched. Each repo sets hostile config locally: diff.noprefix, or
-- diff.mnemonicPrefix, and a diff.external that prints junk.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local pr = require("review_mode")
local api = require("review_mode.api")
local gitmod = require("review_mode.git")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local function numbered(prefix, count)
  local lines = {}
  for i = 1, count do
    lines[i] = string.format("%s line %d with enough text to match", prefix, i)
  end
  return lines
end

local function build_repo(config)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(args)
    local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, args))
    assert(vim.v.shell_error == 0, "git " .. table.concat(args, " ") .. ": " .. out)
    return vim.trim(out)
  end
  local function write(name, lines)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. name), "p")
    vim.fn.writefile(lines, dir .. "/" .. name)
  end

  git({ "init", "-q" })
  git({ "config", "user.email", "test@example.com" })
  git({ "config", "user.name", "Test" })
  git({ "config", "core.hooksPath", dir .. "/nohooks" })
  git({ "checkout", "-q", "-B", "main" })
  write("a b.txt", { "one", "two", "three" })
  write("café.txt", { "un", "deux", "trois" })
  write("b/ratio.txt", { "left", "right" })
  write("dir/before.lua", numbered("dir", 10))
  write("gone.txt", numbered("gone", 10))
  write("code.lua", { "local M = {}", "-- a/b is the ratio", "local ratio = 1", "local keep = true", "return M" })
  write("shared.txt", numbered("shared", 10))
  git({ "add", "." })
  git({ "commit", "-q", "-m", "base" })
  local merge_base = git({ "rev-parse", "HEAD" })

  git({ "checkout", "-q", "-b", "feature" })
  write("a b.txt", { "one", "two changed", "three" })
  write("café.txt", { "un", "deux changé", "trois" })
  write("b/ratio.txt", { "left", "right changed" })
  git({ "mv", "dir/before.lua", "dir/after.lua" })
  local lines = numbered("dir", 10)
  lines[5] = "dir line 5 edited"
  write("dir/after.lua", lines)
  git({ "mv", "gone.txt", "zed.txt" })
  lines = numbered("gone", 10)
  lines[7] = "gone line 7 edited"
  write("zed.txt", lines)
  -- two hunks, so a header read inside the first misfiles the second
  write("code.lua", { "local M = {}", "local ratio = 1", "local keep = true", "return M -- done" })
  lines = numbered("shared", 10)
  lines[1] = "shared line 1 from the PR"
  write("shared.txt", lines)
  git({ "add", "-A" })
  git({ "commit", "-q", "-m", "feature" })

  -- main moves on after the PR branched
  git({ "checkout", "-q", "main" })
  lines = numbered("shared", 10)
  lines[10] = "shared line 10 from main"
  write("shared.txt", lines)
  git({ "commit", "-q", "-am", "main moves on" })
  git({ "checkout", "-q", "feature" })
  git({ "remote", "add", "origin", "." })
  git({ "update-ref", "refs/remotes/origin/main", "refs/heads/main" })

  -- hostile config, local to this repo (the harness isolates global config)
  for key, value in pairs(config) do
    git({ "config", key, value })
  end
  local junk = dir .. "/.git/junk-diff"
  vim.fn.writefile({ "#!/bin/sh", "echo 'external diff output'" }, junk)
  vim.fn.setfperm(junk, "rwxr-xr-x")
  git({ "config", "diff.external", junk })
  return dir, merge_base
end

local function lines_of(pattern)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):find(pattern) then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
end

local function hunks(path)
  local result
  api.hunks(path, function(lines)
    result = lines
  end)
  wait_for(function()
    return result ~= nil
  end, "hunks did not load for " .. path)
  return result
end

--- The base side of `path` as the side-by-side diff shows it.
local function base_side(dir, path)
  pr.config().diff.layout = "side_by_side"
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. path))
  pr.old_toggle()
  wait_for(function()
    return lines_of("pr%-base://") ~= nil
  end, "base diff did not open for " .. path .. ": " .. tostring(notifications[#notifications]))
  local lines = lines_of("pr%-base://")
  pr.old_toggle()
  wait_for(function()
    return lines_of("pr%-base://") == nil
  end, "base diff did not close for " .. path)
  return lines
end

local function check(config)
  local label = vim.inspect(config)
  local dir, merge_base = build_repo(config)
  vim.cmd.cd(dir)
  pr.start()
  wait_for(function()
    return #api.files() == 7
  end, label .. ": changed files did not load: " .. vim.inspect(api.files()))

  -- keyed by the real path: a trailing tab, quoting, or a/ b/ c/ w/ prefixes
  -- would each leave these empty
  local expected = {
    ["a b.txt"] = { 2 },
    ["café.txt"] = { 2 },
    ["b/ratio.txt"] = { 2 },
    ["code.lua"] = { 1, 4 },
    ["shared.txt"] = { 1 },
    -- a rename shows only its real edit, not a whole-file add
    ["dir/after.lua"] = { 5 },
    ["zed.txt"] = { 7 },
  }
  for path, want in pairs(expected) do
    assert(api.is_changed_file(path), label .. ": " .. path .. " is not a changed file")
    local got = hunks(path)
    assert(vim.deep_equal(got, want), label .. ": hunks for " .. path .. ": " .. vim.inspect(got))
  end

  -- numstat counts reach renamed files, with and without a shared directory
  for _, path in ipairs({ "zed.txt", "dir/after.lua", "a b.txt", "café.txt" }) do
    local file = api.file(path)
    assert(file.added == 1 and file.removed == 1, label .. ": numstat for " .. path .. ": " .. vim.inspect(file))
  end
  assert(api.file("zed.txt").status:match("^R"), label .. ": zed.txt is not a rename")

  -- the buffer is recognized: ]c walks its hunks
  for _, path in ipairs({ "a b.txt", "café.txt" }) do
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    pr.next_hunk()
    assert(vim.api.nvim_win_get_cursor(0)[1] == 2, label .. ": ]c did not reach the hunk in " .. path)
  end

  -- the base side is read from the merge base, not main's moved-on tip
  wait_for(function()
    return api.unstable_state().merge_base == merge_base
  end, label .. ": merge base not resolved: " .. tostring(api.unstable_state().merge_base))
  local shared = base_side(dir, "shared.txt")
  assert(shared[10] == numbered("shared", 10)[10], label .. ": base diff shows main's later change: " .. shared[10])

  -- a renamed file's base side is its old path's content
  local renamed = base_side(dir, "zed.txt")
  assert(vim.deep_equal(renamed, numbered("gone", 10)), label .. ": renamed base side: " .. vim.inspect(renamed))

  -- unified: the deleted "-- a/b ..." comment keeps its content, and only the
  -- real headers are rewritten
  pr.config().diff.layout = "unified"
  vim.cmd.edit(dir .. "/code.lua")
  pr.old_toggle()
  wait_for(function()
    return lines_of("pr%-diff://") ~= nil
  end, label .. ": unified diff did not open: " .. tostring(notifications[#notifications]))
  local unified = lines_of("pr%-diff://")
  assert(
    vim.tbl_contains(unified, "--- a/b is the ratio"),
    label .. ": unified lost the comment: " .. vim.inspect(unified)
  )
  assert(vim.tbl_contains(unified, "+return M -- done"), label .. ": unified diff missing: " .. vim.inspect(unified))
  pr.old_toggle()
  wait_for(function()
    return lines_of("pr%-diff://") == nil
  end, label .. ": unified diff did not close")

  -- the other patch readers, on the same real patch
  local patch = vim.fn.system(gitmod.diff({ "-U0", "--no-renames", merge_base, "HEAD", "--", "code.lua" }))
  local ranges = require("review_mode.author").changed_ranges(patch)
  assert(
    vim.deep_equal(ranges, { ["code.lua"] = { { 2, 2 }, { 5, 5 } } }),
    label .. ": author ranges: " .. vim.inspect(ranges)
  )
  local added = require("review_mode.blast_radius").changed_lines(patch)
  assert(
    vim.deep_equal(added, { ["code.lua"] = { { 4, 4 } } }),
    label .. ": blast radius lines: " .. vim.inspect(added)
  )
  local old_path, old_line = require("review_mode.providers.gitlab").line_position(patch, 3)
  assert(
    old_path == "code.lua" and old_line == 4,
    label .. ": gitlab position: " .. tostring(old_path) .. ":" .. tostring(old_line)
  )

  pr.stop()
end

check({ ["diff.noprefix"] = "true" })
check({ ["diff.mnemonicPrefix"] = "true" })

-- The parser on its own: C-quoted names, a binary file, "\ No newline".
local files = gitmod.parse_patch(table.concat({
  'diff --git "a/tab\\there" "b/tab\\there"',
  '--- "a/tab\\there"',
  '+++ "b/tab\\there"',
  "@@ -1 +1 @@",
  "-old",
  "\\ No newline at end of file",
  "+new",
  "\\ No newline at end of file",
  "diff --git a/img.png b/img.png",
  "index 1234567..89abcde 100644",
  "Binary files a/img.png and b/img.png differ",
}, "\n"))
assert(files[1].new_path == "tab\there" and #files[1].hunks[1].lines == 4, "quoted path: " .. vim.inspect(files[1]))
assert(files[2].binary and files[2].new_path == "img.png", "binary file: " .. vim.inspect(files[2]))

print("git plumbing fixture passed")
harness.done()
