-- Nothing the user typed or made is lost: drafts are never dropped unasked, a
-- failed post leaves its text in the " register, and a store that cannot be
-- read is set aside rather than written over. The gh mock reads
-- REVIEW_MODE_FAIL_POST from this process's env.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local prompts, answer = {}, nil
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return assert(answer, "unexpected confirm: " .. prompt)
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

-- A viewed store that no longer parses, in place before the session reads it.
local viewed_path = vim.fs.joinpath(vim.fn.stdpath("state"), "never-lose-viewed.json")
vim.fn.mkdir(vim.fs.dirname(viewed_path), "p")
local corrupt_text = '{"owner/repo#1":{"viewed":{"a.txt":tru'
vim.fn.writefile({ corrupt_text }, viewed_path)

local pr = require("review_mode")
local api = require("review_mode.api")
local panel = require("review_mode.panel")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = true, state_path = viewed_path },
  auto_open_first_change = false,
})

local function start()
  pr.start()
  wait_for(function()
    return api.is_changed_file("file.txt")
      and api.comment_count("file.txt") > 0
      and not api.unstable_state().comments_loading
  end, "the review did not load")
end
start()

-- Stores ----------------------------------------------------------------------

-- the store is read once metadata is in, which may be after the file map
local aside
wait_for(function()
  aside = vim.fn.glob(viewed_path .. ".corrupt-*", false, true)
  return #aside == 1
end, "a corrupt viewed store was not kept aside")
assert(read(aside[1]) == corrupt_text, "the corrupt viewed store was overwritten")

-- two Neovims, two PRs, one file: each write merges into what is on disk now
api.set_viewed("file.txt", true)
local disk = vim.json.decode(read(viewed_path))
assert(disk["owner/repo#123"].viewed["file.txt"], "marking a file viewed was not written")
disk["other/repo#7"] = { viewed = { ["theirs.txt"] = true }, order = { "theirs.txt" }, sync_queue = {} }
vim.fn.writefile({ vim.json.encode(disk) }, viewed_path)
api.set_viewed("new.txt", true)
disk = vim.json.decode(read(viewed_path))
assert(disk["other/repo#7"], "a write from this Neovim erased another Neovim's PR")
assert(disk["other/repo#7"].viewed["theirs.txt"], "the other PR's viewed files were lost")
assert(disk["owner/repo#123"].viewed["new.txt"], "this PR's own write is missing")
assert(#vim.fn.glob(viewed_path .. ".tmp*", false, true) == 0, "an atomic write left its temp file behind")

-- Composer --------------------------------------------------------------------

vim.cmd.edit("file.txt")
local code_win = vim.api.nvim_get_current_win()
local function compose(text, line)
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_win_set_cursor(code_win, { line or 3, 0 })
  pr.compose_comment()
  vim.cmd("stopinsert")
  if text then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  end
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end
local function composer_text(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- opening a second composer over a non-empty draft asks; keeping it keeps it
local first_buf, first_win = compose("my first draft")
prompts, answer = {}, 2
compose()
assert(#prompts == 1 and prompts[1]:find("Discard this draft?", 1, true), "a second composer did not ask")
assert(composer_text(first_buf) == "my first draft", "keeping the draft did not keep its text")
assert(vim.api.nvim_get_current_win() == first_win, "keeping the draft did not go back to it")
-- discarding it replaces it, and nothing lands in the register
vim.fn.setreg('"', "untouched")
prompts, answer = {}, 1
local second_buf = compose("second draft")
assert(#prompts == 1 and not vim.api.nvim_buf_is_valid(first_buf), "discarding did not replace the draft")
assert(vim.fn.getreg('"') == "untouched", "a discarded draft was still put in the register")

-- closing the panel over a draft asks too; keeping it keeps the panel
pr.open_panel()
assert(panel.panel_is_open(), "the panel did not open")
prompts, answer = {}, 2
pr.close_panel()
assert(#prompts == 1, "closing the panel over a draft did not ask")
assert(panel.panel_is_open() and composer_text(second_buf) == "second draft", "keeping the draft closed something")

-- nobody to ask: the panel window closed under it, or the session stopping
answer = nil
local panel_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "review-thread" then
    panel_win = win
  end
end
vim.api.nvim_win_close(assert(panel_win, "no panel window"), true)
wait_for(function()
  return not vim.api.nvim_buf_is_valid(second_buf)
end, "closing the panel window did not close its draft")
assert(vim.fn.getreg('"') == "second draft", "a draft closed with the panel window was not kept")

local stop_buf = compose("typed before stopping")
pr.stop()
assert(not vim.api.nvim_buf_is_valid(stop_buf), "stopping did not close the draft")
assert(vim.fn.getreg('"') == "typed before stopping", "stopping dropped the draft")
start()

-- and :q! on the draft window itself
local quit_buf = compose("closed with :q")
vim.cmd("quit!")
assert(not vim.api.nvim_buf_is_valid(quit_buf), ":q did not close the draft")
assert(vim.fn.getreg('"') == "closed with :q", ":q dropped the draft")

-- Failed posts ------------------------------------------------------------------

local function wait_register(text, message)
  wait_for(function()
    return vim.fn.getreg('"') == text
  end, message)
end

-- a new comment gh refuses
vim.env.REVIEW_MODE_FAIL_POST = "1"
vim.fn.setreg('"', "")
compose("doomed through the composer")
answer = 1
panel.composer_submit()
wait_register("doomed through the composer", "a failed comment post lost the draft")
vim.env.REVIEW_MODE_FAIL_POST = nil

-- an edit gh refuses (the mock only accepts edits to comment 11); comment 1 is
-- made the viewer's own so the edit composer opens on it
vim.fn.setreg('"', "")
for _, comment in ipairs(api.unstable_state().comments["file.txt"]) do
  comment.viewer_did_author = comment.id == 1
end
vim.api.nvim_set_current_win(code_win)
vim.api.nvim_win_set_cursor(code_win, { 2, 0 })
panel.edit_comment()
vim.cmd("stopinsert")
assert(
  vim.api.nvim_buf_get_name(0):find("review-mode://edit", 1, true),
  "the edit composer did not open: " .. table.concat(notifications, "; ")
)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my edited text" })
panel.composer_submit()
wait_register("my edited text", "a failed edit lost the draft")

-- a reply to a thread that is gone by the time it posts
vim.fn.setreg('"', "")
vim.api.nvim_set_current_win(code_win)
panel.reply_to({ id = "thread_gone", path = "file.txt", line = 2, comments = { { id = 999, author = "someone" } } })
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "reply to nowhere" })
panel.composer_submit()
wait_register("reply to nowhere", "a reply to a missing thread lost the draft")
answer = nil

pr.stop()
assert(#prompts > 0, "no prompt was ever answered")
print("never lose work fixture passed")
harness.done()
vim.cmd("qa!")
