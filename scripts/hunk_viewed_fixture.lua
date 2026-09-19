-- fixture: gh pr
-- Hunk-level viewed: mark the hunk under the cursor, see it in the picker and
-- the sign column, skip it on ]c when asked, keep it across sessions, and after
-- a push get back only the hunks whose content changed.
--
-- Runs in a copy of the fixture repo: it moves origin/main so hunks.txt is the
-- only changed file, and commits during the review.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local function sh(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
end

local function commit(lines, message)
  vim.fn.writefile(lines, "hunks.txt")
  sh({ "git", "add", "hunks.txt" })
  sh({ "git", "commit", "-q", "-m", message })
end

commit({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }, "hunks base")
sh({ "git", "update-ref", "refs/remotes/origin/main", "HEAD" })
commit({ "a", "B", "c", "d", "e", "f", "g", "H", "i", "j" }, "hunks feature")

local pr = require("review_mode")
local api = require("review_mode.api")
local viewed = require("review_mode.viewed")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  auto_open_first_change = false,
})

local path = "hunks.txt"

local function hunks()
  local got = nil
  api.hunks(path, function(lines)
    got = lines
  end)
  wait_for(function()
    return got ~= nil
  end, "hunks did not load")
  return got
end

local function progress()
  return { api.hunk_progress(path) }
end

local function viewed_signs()
  local ns = vim.api.nvim_get_namespaces().review_mode_normal
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if vim.trim(mark[4].sign_text or "") == "✓" then
      rows[#rows + 1] = mark[2] + 1
    end
  end
  return rows
end

local function start()
  pr.start()
  -- is_changed_file turns true with the name list; the stored viewed state is
  -- read only once maps_loaded does, after the numstat call
  wait_for(function()
    return api.is_changed_file(path) and state.maps_loaded
  end, "changed file map did not load")
  vim.cmd.edit(path)
  assert(vim.deep_equal(hunks(), { 2, 8 }), "unexpected hunks: " .. vim.inspect(hunks()))
end

-- identical hunks in one file must not share a key
local twins = viewed.hunk_keys({ { "+x" }, { "+x" }, { "+y" } })
assert(twins[1] ~= twins[2], "identical hunks got the same key")
assert(twins[1] == viewed.hunk_keys({ { "+x" } })[1], "a hunk's key is not its content hash")
-- gitsigns' hunk.lines may carry context and "\ No newline" lines that git -U0
-- output does not; the key must come from the +/- lines alone either way
assert(
  viewed.hunk_keys({ { " context", "-x", "\\ No newline at end of file", "+y" } })[1]
    == viewed.hunk_keys({ { "-x", "+y" } })[1],
  "a context line changed the hunk key"
)

start()
assert(vim.deep_equal(progress(), { 0, 2 }), "fresh file should be 0/2: " .. vim.inspect(progress()))

-- the hunk under the cursor is the last one starting at or above it
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd("ReviewModeHunkViewedToggle")
assert(vim.deep_equal(progress(), { 1, 2 }), "marking a hunk did not count: " .. vim.inspect(progress()))
wait_for(function()
  return vim.deep_equal(viewed_signs(), { 2 })
end, "viewed hunk sign missing: " .. vim.inspect(viewed_signs()))

-- the changed-files picker shows progress inside the file
local original_select = vim.ui.select
local labels = nil
vim.ui.select = function(items, opts)
  labels = vim.tbl_map(opts.format_item, items)
end
pr.list_viewed("all")
vim.ui.select = original_select
assert(
  -- one of its two hunks viewed: the file reads half reviewed
  labels and vim.startswith(vim.trim(labels[1]), "50%"),
  "picker label lacks hunk progress: " .. vim.inspect(labels)
)

-- ]c lands on viewed hunks by default, and passes over them when asked
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "]c should stop on a viewed hunk by default")
api.config().viewed.skip_viewed_hunks = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 8, "]c did not skip the viewed hunk")
vim.api.nvim_win_set_cursor(0, { 10, 0 })
pr.prev_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 8, "[c should stop on the unviewed hunk")
api.config().viewed.skip_viewed_hunks = false

-- toggling twice unmarks
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.toggle_hunk_viewed()
assert(vim.deep_equal(progress(), { 0, 2 }), "second toggle did not unmark")
pr.toggle_hunk_viewed()

-- the mark is stored locally and survives a new session
pr.stop()
state.viewed_store = nil
state.hunk_viewed = {}
start()
assert(vim.deep_equal(progress(), { 1, 2 }), "hunk viewed state did not persist: " .. vim.inspect(progress()))

-- the file follows its hunks, through the same sync path as <leader>rv
local synced = {}
local original_sync = viewed.sync_viewed_path_to_github_async
viewed.sync_viewed_path_to_github_async = function(sync_path, is_viewed)
  synced[#synced + 1] = { sync_path, is_viewed }
end
assert(not api.is_viewed_file(path), "file was viewed before all its hunks were")
vim.api.nvim_win_set_cursor(0, { 8, 0 })
pr.toggle_hunk_viewed()
assert(vim.deep_equal(progress(), { 2, 2 }), "second hunk was not marked")
assert(api.is_viewed_file(path), "viewing the last hunk did not mark the file viewed")
assert(vim.deep_equal(synced, { { path, true } }), "file mark did not take the sync path: " .. vim.inspect(synced))

-- un-viewing a hunk of a viewed file un-views the file
pr.toggle_hunk_viewed()
assert(not api.is_viewed_file(path), "unmarking a hunk left the file viewed")
assert(synced[2] and synced[2][2] == false, "file unmark did not take the sync path: " .. vim.inspect(synced))

-- a file un-viewed by hand is not re-marked until a hunk toggle completes it
pr.toggle_hunk_viewed()
assert(api.is_viewed_file(path), "completing the hunks again did not re-mark the file")
pr.toggle_viewed()
-- let the debounced refresh run too: nothing but a hunk toggle may re-mark it
vim.wait(150)
assert(not api.is_viewed_file(path) and vim.deep_equal(progress(), { 2, 2 }), "manual un-view was undone")
viewed.sync_viewed_path_to_github_async = original_sync

-- the author pushes: a new hunk on top shifts "b -> B" down a line without
-- changing it, and "h -> H" changes. Only the unchanged one stays viewed.
wait_for(function()
  return state.head_log_stamp ~= nil
end, "follow-HEAD watcher did not record its reflog baseline")
commit({ "top", "a", "B", "c", "d", "e", "f", "g", "H2", "i", "j" }, "hunks push")
wait_for(function()
  vim.api.nvim_exec_autocmds("FocusGained", {})
  if state.maps_loaded and not state.hunks_loaded[path] then
    api.hunks(path, function() end)
  end
  return vim.deep_equal(state.hunks[path], { 1, 3, 9 })
end, "review did not rebuild hunks after the push: " .. vim.inspect(state.hunks[path]))
local keys = state.hunk_hashes[path]
assert(not viewed.is_hunk_viewed(path, keys[1]), "the new hunk came in viewed")
assert(viewed.is_hunk_viewed(path, keys[2]), "the shifted but unchanged hunk lost its viewed mark")
assert(not viewed.is_hunk_viewed(path, keys[3]), "the changed hunk stayed viewed")
assert(vim.deep_equal(progress(), { 1, 3 }), "progress after the push: " .. vim.inspect(progress()))

-- clearing viewed state clears hunks too
pr.clear_viewed()
assert(vim.deep_equal(progress(), { 0, 3 }), "clear_viewed left hunk marks behind")

-- with viewed tracking off there is no progress to report, from either layer
api.config().viewed.enabled = false
assert(viewed.hunk_progress(path) == nil, "viewed.hunk_progress reported progress with tracking off")
assert(api.hunk_progress(path) == nil, "api.hunk_progress reported progress with tracking off")
api.config().viewed.enabled = true

pr.stop()
harness.done()
vim.cmd("qa!")
