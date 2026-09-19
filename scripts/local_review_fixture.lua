-- Local reviews: two refs, no PR, no network, comments on disk.
--
-- There is deliberately no gh mock on PATH for this run. The point of the
-- feature is that a local review never reaches a forge, so the fixture wraps
-- util.system/util.system_async and asserts nothing ever shells out to gh.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

-- Wrap before the plugin loads: init.lua keeps its own reference to these.
local util = require("review_mode.util")
local forge_calls = {}
local function watch(name)
  local original = util[name]
  util[name] = function(args, ...)
    local command = type(args) == "table" and args[1] or nil
    if command == "gh" or command == "glab" then
      forge_calls[#forge_calls + 1] = table.concat(args, " ")
    end
    return original(args, ...)
  end
end
watch("system")
watch("system_async")

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local function git(args, cwd)
  return vim.trim(vim.fn.system(vim.list_extend({ "git", "-C", cwd or vim.uv.cwd() }, args)))
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local cwd = vim.uv.cwd()
local providers = require("review_mode.providers")
local local_provider = require("review_mode.providers.local")

-- Selection --------------------------------------------------------------------

local origin_url = git({ "remote", "get-url", "origin" })
assert(providers.select(cwd) == "github", "a github remote should still select github")
git({ "remote", "remove", "origin" })
assert(providers.select(cwd) == "local", "a repo with no remote should select local")
git({ "remote", "add", "origin", origin_url })
git({ "update-ref", "refs/remotes/origin/main", "refs/heads/main" })

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
  comments = { enabled = true },
  viewed = { enabled = true },
})
assert(pr.config().provider == "auto", "setup lost the provider default")
assert(require("review_mode.state").normalize_config({ provider = "local" }).provider == "local", "local not accepted")

-- Ref resolution ----------------------------------------------------------------

assert(local_provider.default_branch(cwd) == "main", "default branch was not main")
local main_sha = git({ "rev-parse", "main" })

local resolved = assert(local_provider.resolve({}, cwd), "resolve with no args failed")
assert(resolved.base == main_sha, "base did not default to the merge base with main")
assert(resolved.head_ref == "", "no head argument should mean the working tree")
assert(resolved.pr == "feature", "the store key should be the current branch")

local ranged = assert(local_provider.resolve({ "main..feature" }, cwd), "range form failed")
assert(ranged.base == main_sha and ranged.head_ref == "feature", "main..feature was not split into base and head")
local dotted = assert(local_provider.resolve({ "main...feature" }, cwd), "three-dot range form failed")
assert(dotted.head_ref == "feature", "main...feature was not split into base and head")
assert(not local_provider.resolve({ "no-such-ref" }, cwd), "an unknown base should fail rather than guess")

-- The store lives under --git-common-dir, keyed by branch, so removing a linked
-- worktree (git worktree remove, wt remove) never takes its comments with it.
local main_store = assert(local_provider.store_for(cwd, "feature"), "no store for the main checkout")
assert(main_store:find("/.git/review-mode/feature.json", 1, true), "main store path wrong: " .. main_store)
assert(
  local_provider.store_for(cwd, "feat/x") ~= local_provider.store_for(cwd, "feat_x"),
  "feat/x and feat_x share a comment store"
)

local linked = vim.fs.joinpath(vim.fs.dirname(cwd), "linked")
git({ "worktree", "add", "-q", "-b", "wt/branch", linked, "feature" })
local linked_git_dir = git({ "rev-parse", "--absolute-git-dir" }, linked)
assert(linked_git_dir:find("/worktrees/", 1, true), "not a linked worktree: " .. linked_git_dir)
local linked_store = assert(local_provider.store_for(linked, "wt/branch"), "no store for the linked worktree")
assert(not linked_store:find("/worktrees/", 1, true), "linked worktree store is inside its own git dir")
local function git_dir_of(store)
  return vim.uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(store)))
end
assert(
  git_dir_of(linked_store) == git_dir_of(main_store),
  "linked worktree store is not in the common git dir: " .. linked_store
)

-- an old store (under the worktree's own git dir, "_" for "/") is carried over
local legacy = vim.fs.joinpath(linked_git_dir, "review-mode", "wt_branch.json")
vim.fn.mkdir(vim.fs.dirname(legacy), "p")
vim.fn.writefile(
  { '{"version":1,"next_id":2,"threads":[{"id":"t1","path":"file.txt","line":2,"comments":[]}]}' },
  legacy
)
local migrated = assert(local_provider.resolve({}, linked), "resolve in the linked worktree failed")
assert(migrated.pr == "wt/branch", "the store key is not the linked worktree's branch: " .. tostring(migrated.pr))
assert(migrated.local_store == linked_store, "resolve did not use the common-dir store")
assert(vim.fn.filereadable(linked_store) == 1, "the old store was not migrated to " .. linked_store)
assert(read(linked_store) == read(legacy), "the migrated store lost content")

-- `main HEAD` keys by the branch HEAD is on, not "HEAD" shared by every branch
local by_head = assert(local_provider.resolve({ "main", "HEAD" }, linked), "resolve main HEAD failed")
assert(by_head.pr == "wt/branch", "HEAD was not resolved to its branch: " .. tostring(by_head.pr))

git({ "worktree", "remove", "--force", linked })
assert(vim.fn.filereadable(linked_store) == 1, "removing the worktree deleted its local comments")
git({ "branch", "-D", "wt/branch" })

-- A local review of the working tree ---------------------------------------------

pr.review_local({})
wait_for(function()
  return api.is_active() and api.is_changed_file("file.txt")
end, "local review did not load its changed files")

local session = assert(api.session(), "no session after review_local")
assert(session.provider == "local", "session did not report the local provider")
assert(session.base == main_sha, "session base is not the merge base")
assert(api.base_ref() == main_sha, "base_ref rewrote a resolved sha")
assert(require("review_mode.state").diff_range() == main_sha, "working-tree review should diff the base alone")
for _, path in ipairs({ "file.txt", "new.txt", "nested/other.txt", "nested/deeper/more.txt" }) do
  assert(api.is_changed_file(path), path .. " is missing from the local review")
end
-- numstat is a second git call, so it lands a beat after the name-status one
wait_for(function()
  return api.file("file.txt").added > 0
end, "file stats did not load for a local review")

-- the working tree is the head, so an uncommitted edit is part of the review
local dirty = "nested/deeper/more.txt"
vim.fn.writefile({ "deep", "feature", "worktree only" }, dirty)
pr.refresh()
-- refresh clears the file map and rebuilds it asynchronously; everything below
-- reads api.files(), so wait for it to come back rather than racing it
wait_for(function()
  return api.file("file.txt") ~= nil and api.file(dirty) ~= nil
end, "refresh did not rebuild the changed-file map")
local worktree_diff
wait_for(function()
  api.file_diff(dirty, function(text)
    worktree_diff = text
  end)
  return worktree_diff ~= nil
end, "file_diff did not answer")
assert(worktree_diff:find("worktree only", 1, true), "an uncommitted edit was left out of a working-tree review")

-- Local comments -----------------------------------------------------------------

local store = assert(api.local_store(), "no local comment store on the session")
assert(store == main_store, "session store is not the one store_for computes")
vim.fn.delete(store)
api.reload_comments()
assert(api.comment_count("file.txt") == 0, "a fresh store should hold no comments")

local function run(fn, ...)
  local result
  local args = { ... }
  args[#args + 1] = function(ok, err)
    result = { ok = ok, err = err }
  end
  fn(unpack(args))
  wait_for(function()
    return result ~= nil
  end, "write did not answer its callback")
  assert(result.ok, "write failed: " .. tostring(result.err))
  return result.err
end

local thread =
  run(api.local_comment, { path = "file.txt", start_line = 2, end_line = 2, body = "why two?", author = "agent" })
assert(thread and thread.id == "t1", "local_comment did not answer the thread it created")
assert(api.comment_count("file.txt") == 1, "local comment did not reach state.comments")

local threads = api.threads({ path = "file.txt" })
assert(#threads == 1 and threads[1].id == "t1", "local comment did not become a thread")
assert(threads[1].line == 2 and threads[1].start_line == 2, "local thread lost its anchor")
assert(threads[1].comments[1].author == "agent", "the author opt was ignored")
assert(threads[1].comments[1].body == "why two?", "the body did not round-trip")

-- the author defaults to git user.name, which the fixture repo sets to Test
run(api.local_comment, { path = "nested/other.txt", line = 2, body = "renamed?" })
assert(
  api.threads({ path = "nested/other.txt" })[1].comments[1].author == "Test",
  "author did not default to user.name"
)

-- On disk: under the git dir, never tracked, structured and readable.
assert(vim.fn.filereadable(store) == 1, "the store was not written")
assert(
  vim.fn.system({ "git", "ls-files", "--error-unmatch", store }) and vim.v.shell_error ~= 0,
  "the store is tracked"
)
local text = read(store)
local doc = vim.json.decode(text)
assert(doc.version == 1 and doc.next_id == 3, "store header wrong: " .. text)
assert(#doc.threads == 2, "store did not keep both threads")
assert(text:find('\n  "threads": ', 1, true), "the store is not indented")
assert(text:find('\n      "id": "t1"', 1, true), "a thread is not indented inside the list")
local order = { "comments", "id", "line", "path", "resolved", "start_line" }
local at = 0
for _, key in ipairs(order) do
  local found = assert(text:find('"' .. key .. '":', at + 1, true), key .. " missing from the stored thread")
  assert(found > at, "stored keys are not in a stable sorted order: " .. key)
  at = found
end

-- Replies, resolve, edit, delete --------------------------------------------------

run(api.reply, { thread_id = "t1", body = "because it is two" })
threads = api.threads({ path = "file.txt" })
assert(#threads[1].comments == 2, "reply did not join the thread")
assert(threads[1].comments[2].body == "because it is two", "reply body lost")

run(api.resolve, "t1", true)
assert(api.threads({ path = "file.txt", include_resolved = true })[1].is_resolved, "resolve did not stick")
assert(api.unresolved_count("file.txt") == 0, "a resolved local thread still counts as unresolved")
run(api.resolve, "t1", false)
assert(not api.threads({ path = "file.txt" })[1].is_resolved, "unresolve did not stick")

assert(api.can_modify_comment("c3"), "a local comment should be editable")
run(api.edit_comment, { comment_id = "c3", body = "because it is two, actually" })
assert(api.threads({ path = "file.txt" })[1].comments[2].body == "because it is two, actually", "edit did not stick")

run(api.delete_comment, "c3")
assert(#api.threads({ path = "file.txt" })[1].comments == 1, "delete did not remove the reply")
run(api.delete_comment, "c2")
assert(api.comment_count("nested/other.txt") == 0, "deleting the last comment left the thread behind")
assert(#vim.json.decode(read(store)).threads == 1, "an empty thread was kept on disk")

-- and it all survives a reload from disk, which is what an agent relies on
api.reload_comments()
assert(api.comment_count("file.txt") == 1, "comments did not survive a reload")
assert(api.threads({ path = "file.txt" })[1].comments[1].body == "why two?", "reloaded comment body wrong")

-- The rest of the plugin, unchanged ------------------------------------------------

local items = api.quickfix_items({ filter = "all" })
assert(#items == 1 and items[1].lnum == 2, "a local thread did not reach the quickfix list: " .. vim.inspect(items))
assert(items[1].text:find("why two?", 1, true), "quickfix text lost the comment body")

assert(vim.deep_equal(api.comment_paths(), { "file.txt" }), "comment_paths did not list the commented file")

local buffer = require("review_mode.local_buffer")
buffer.open()
local listed = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
assert(vim.api.nvim_buf_get_name(0):find("review-mode://local", 1, true), "the local buffer has the wrong name")
local joined = table.concat(listed, "\n")
assert(joined:find("file.txt (1)", 1, true), "the local buffer did not group by file with a count: " .. joined)
assert(joined:find("why two?", 1, true), "the local buffer did not render the thread")
assert(joined:find("agent", 1, true), "the local buffer did not render the author")
buffer.close()

-- A named head: the ref is the right-hand side, not the working tree -------------

pr.stop()
assert(require("review_mode.state").diff_range() == "origin/main...HEAD", "stopping did not restore PR diff semantics")

pr.review_local({ "main..feature" })
wait_for(function()
  return api.is_active() and api.is_changed_file("file.txt")
end, "ranged local review did not load its changed files")
assert(
  require("review_mode.state").diff_range() == main_sha .. "..feature",
  "a named head is not the diff's right side"
)

local ranged_diff
wait_for(function()
  api.file_diff(dirty, function(text)
    ranged_diff = text or ""
  end)
  return ranged_diff ~= nil
end, "file_diff did not answer for the ranged review")
assert(not ranged_diff:find("worktree only", 1, true), "a ranged review picked up an uncommitted edit")

-- comments are keyed by the head, so the branch's store is the same file
assert(api.local_store() == main_store, "a named head did not reuse the branch's store")
assert(api.comment_count("file.txt") == 1, "the stored comment did not load for the ranged review")

-- the PR-only actions refuse instead of asking gh about a branch
local function notified(fragment)
  for _, message in ipairs(notifications) do
    if message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end
pr.checks()
assert(notified("PR checks is not supported in a local review"), "checks did not refuse in a local review")
pr.status()
assert(notified("PR status is not supported in a local review"), "status did not refuse in a local review")
pr.copy_url()
wait_for(function()
  return notified("a local review has no PR to open")
end, "copy_url did not refuse in a local review")
-- a local review has nowhere to submit to: refused up front, never confirmed
local original_confirm, confirmed = vim.fn.confirm, false
vim.fn.confirm = function()
  confirmed = true
  return 1
end
require("review_mode.review_buffer").submit("approve")
vim.fn.confirm = original_confirm
assert(not confirmed, "a local review asked to confirm a submission it cannot make")
assert(notified("Submitting a review is not supported in a local review"), "submit did not refuse in a local review")

-- a local review cannot queue drafts for a review, so the composer does not
-- offer it only to refuse (and lose the text)
vim.cmd.edit("file.txt")
pr.compose_comment()
vim.cmd("stopinsert")
assert(vim.bo.filetype == "markdown", "the composer did not open in a local review")
assert(not vim.wo.winbar:find("C-p", 1, true), "a local review's composer offered C-p pending")
assert(vim.fn.maparg("<C-p>", "n") == "", "a local review's composer mapped <C-p>")
assert(not api.can_add_pending(), "a local review claims it can queue drafts")
require("review_mode.panel").composer_cancel()

-- a store that no longer parses is set aside, never treated as empty and
-- written over by the next comment
local corrupt_text = '{"version":1,"threads":[ half written'
vim.fn.writefile({ corrupt_text }, main_store)
run(api.local_comment, { path = "file.txt", line = 2, body = "after the damage" })
local aside = vim.fn.glob(main_store .. ".corrupt-*", false, true)
assert(#aside == 1, "a corrupt local store was not kept aside")
assert(read(aside[1]) == corrupt_text, "the corrupt local store was overwritten")
assert(notified("kept it as"), "setting the corrupt store aside was not announced")
assert(#vim.json.decode(read(main_store)).threads == 1, "the new comment did not start a fresh store")

pr.stop()
vim.fn.writefile({ "deep", "feature" }, dirty)
assert(#forge_calls == 0, "a local review shelled out to a forge: " .. table.concat(forge_calls, "; "))
harness.done()
