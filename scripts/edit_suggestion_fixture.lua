-- Your edits, as suggestions.
--
-- file.txt at the PR head (HEAD) is
--   1 one  2 two  3 ""  4 base changed  5 same1 ... 9 same5  10 tail
-- and the PR diff changes lines 2 and 4, so with GitHub's three lines of
-- context a comment can land on lines 1-7, and 8-10 are outside the diff.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

vim.fn.system({ "git", "checkout", "-q", "feature" })
assert(vim.v.shell_error == 0, "could not check out the feature branch for this fixture")

local notes = {}
vim.notify = function(msg)
  notes[#notes + 1] = tostring(msg)
end
local function noted(needle)
  for _, msg in ipairs(notes) do
    if msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
pr.start()
wait_for(function()
  return api.is_changed_file("file.txt")
end, "the review did not load")

vim.cmd.edit("file.txt")
local buf = vim.api.nvim_get_current_buf()
local code_win = vim.api.nvim_get_current_win()
local head = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#head == 10 and head[4] == "base changed", "unexpected fixture file.txt")

local function set(line, text)
  vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { text })
end
local function reset()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, head)
end
local function draft()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:find("review%-mode://suggestion") then
      return win, vim.api.nvim_win_get_buf(win)
    end
  end
  return nil
end

-- Finding edits ---------------------------------------------------------------

assert(#api.edits() == 0, "an untouched buffer has no edits")
assert(api.edit_at(4) == nil, "an untouched line is not an edit")

set(4, "base changed twice")
local edits = api.edits()
assert(#edits == 1, "expected one edit, got " .. #edits)
assert(edits[1].start_line == 4 and edits[1].end_line == 4, "the edit should replace line 4")
assert(edits[1].lines[1] == "base changed twice", "the edit should carry the new line")
assert(edits[1].in_diff, "line 4 is inside the PR diff")
assert(api.edit_at(4) and not api.edit_at(5), "edit_at should find the edited line only")
reset()

-- a pure insertion takes the line above into the suggestion
vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "inserted" })
edits = api.edits()
assert(#edits == 1 and edits[1].start_line == 5 and edits[1].end_line == 5, "an insertion should anchor above")
assert(table.concat(edits[1].lines, "|") == "same1|inserted", "an insertion should keep its anchor line")
reset()

-- a pure deletion suggests nothing in place of the lines
vim.api.nvim_buf_set_lines(buf, 5, 6, false, {})
edits = api.edits()
assert(#edits == 1 and edits[1].start_line == 6 and edits[1].end_line == 6, "a deletion replaces the deleted line")
assert(#edits[1].lines == 0, "a deletion suggests no lines")
assert(api.edit_at(6), "the line after a deletion should find it")
reset()

-- outside the diff: found, but flagged, and the comment key says so
set(10, "tail changed")
edits = api.edits()
assert(#edits == 1 and not edits[1].in_diff, "line 10 is outside the PR diff")
vim.api.nvim_win_set_cursor(code_win, { 10, 0 })
pr.comment_or_reply()
assert(draft() == nil, "an edit outside the diff should not open a suggestion draft")
assert(noted("outside the PR diff"), "an edit outside the diff should say why nothing happened")
reset()

-- no merge-base (a missing base ref, so the load resolved none): fail closed,
-- nothing is "in the diff"
local core = require("review_mode.state")
local real_base, real_merge_base = core.state.base, core.state.merge_base
core.state.base, core.state.merge_base = "refs/heads/no-such-base", nil
set(4, "base changed twice")
edits = api.edits()
assert(#edits == 1 and not edits[1].in_diff, "with no merge-base an edit must not count as in the diff")
core.state.base, core.state.merge_base = real_base, real_merge_base
reset()

-- trial suggestions are the reviewer's lines, not your edits
local trial = assert(
  api.accept_suggestion({ id = "t", path = "file.txt", start_line = 2, end_line = 2, lines = { "two trialled" } }),
  "could not apply a trial"
)
assert(#api.edits() == 0, "a trial suggestion should not count as your edit")
api.revert_suggestion(trial.id)
reset()

-- The comment key on an edit -------------------------------------------------

local original_confirm = vim.fn.confirm
vim.fn.confirm = function()
  return 1
end

set(4, "base changed twice")
vim.api.nvim_win_set_cursor(code_win, { 4, 0 })
pr.comment_or_reply()
local win, draft_buf = draft()
assert(win, "the comment key on an edit should open a suggestion draft")
assert(vim.wo[win].winbar:find("file.txt:4-4", 1, true), "the draft should name the lines: " .. vim.wo[win].winbar)
local body = vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)
assert(body[1] == "", "the message line should come first, empty")
assert(
  table.concat(body, "\n"):find("```suggestion\nbase changed twice\n```", 1, true),
  "the block should hold the edit"
)
vim.api.nvim_buf_set_lines(draft_buf, 0, 1, false, { "twice reads better" })

-- the edit moves before posting: undo has to find it where it went
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "a line above" })
vim.api.nvim_set_current_win(win)
pr.composer_submit()
wait_for(function()
  return noted("Posted suggestion on file.txt:4-4")
end, "the suggestion was not posted")
local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(after[1] == "a line above", "undoing the edit clobbered an unrelated one")
assert(after[5] == "base changed", "posting should put HEAD's line back where the edit moved to")
reset()

-- Batch ------------------------------------------------------------------------

vim.api.nvim_set_current_win(code_win)
local pending_before = #api.pending()
set(4, "base changed twice")
set(7, "same3 changed")
set(10, "tail changed")
pr.suggest_edits()
assert(#api.pending() == pending_before + 2, "the two edits inside the diff should be queued")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[4] == "base changed" and lines[7] == "same3", "queued edits should be undone")
assert(lines[10] == "tail changed", "an edit outside the diff should stay")
local bodies = {}
for _, pending in ipairs(api.pending()) do
  bodies[#bodies + 1] = pending.body
end
assert(table.concat(bodies, "\n"):find("same3 changed", 1, true), "a queued suggestion should carry the edit")

-- Batch across the PR ---------------------------------------------------------
--
-- Four edited files: file.txt saved to disk at line 4 with an unsaved edit at
-- line 10 (outside the diff) on top; nested/other.txt saved to disk and never
-- opened; new.txt edited in a buffer only; nested/deeper/more.txt saved to disk
-- but, for this run, not one of the PR's files.
reset()
vim.bo[buf].modified = false
local function disk(path)
  return table.concat(vim.fn.readfile(path), "|")
end
local function loaded(path)
  local bufnr = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  return bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and bufnr or nil
end
local prompt
vim.fn.confirm = function(message)
  prompt = message
  return 1
end

vim.fn.writefile({ "alpha", "-- newer", "omega" }, "nested/other.txt")
vim.fn.writefile({ "deep", "feature saved" }, "nested/deeper/more.txt")
set(4, "base changed twice")
vim.api.nvim_buf_call(buf, function()
  vim.cmd("silent write")
end)
set(10, "tail changed")

-- the current file alone: the others, saved or not, are not this command's
pending_before = #api.pending()
pr.suggest_edits()
assert(#api.pending() == pending_before + 1, "the current-file batch should queue only this file's edit")
assert(not prompt:find("other.txt", 1, true), "the current-file prompt should not list other files: " .. prompt)
assert(not loaded("nested/other.txt"), "the current-file batch should not open other files")
assert(disk("nested/other.txt") == "alpha|-- newer|omega", "the current-file batch touched another file")
assert(disk("file.txt"):find("base changed twice", 1, true), "a buffer with other unsaved work must not be written")
assert(vim.bo[buf].modified, "a buffer left with unsaved work should stay modified")

-- put file.txt's saved edit back in the buffer, and the new.txt edit in one
set(4, "base changed twice")
vim.cmd.edit("new.txt")
local new_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(new_buf, 1, 2, false, { "new two edited" })
vim.api.nvim_set_current_win(code_win)
vim.api.nvim_win_set_buf(code_win, buf)

-- cancelled: nothing queued, and the buffers the batch loaded to read the
-- saved files' edits are gone again, while the ones already open stay, even
-- one with no unsaved changes (more.txt, open but saved)
local more_buf = vim.fn.bufadd(vim.fn.fnamemodify("nested/deeper/more.txt", ":p"))
vim.fn.bufload(more_buf)
local bufs_before = vim.api.nvim_list_bufs()
pending_before = #api.pending()
local confirm_queue = vim.fn.confirm
vim.fn.confirm = function()
  return 2
end
pr.suggest_edits({ all = true })
vim.fn.confirm = confirm_queue
assert(#api.pending() == pending_before, "a cancelled batch should queue nothing")
assert(
  vim.deep_equal(vim.api.nvim_list_bufs(), bufs_before),
  "a cancelled batch should leave no buffers of its own: " .. vim.inspect(vim.api.nvim_list_bufs())
)
vim.api.nvim_buf_delete(more_buf, {})

local state = core.state
local real_order, real_index = vim.deepcopy(state.file_order), vim.deepcopy(state.file_index)
state.file_order = vim.tbl_filter(function(path)
  return path ~= "nested/deeper/more.txt"
end, state.file_order)
state.file_index["nested/deeper/more.txt"] = nil

notes = {}
pr.suggest_edits({ all = true })
state.file_order, state.file_index = real_order, real_index

assert(prompt:find("3 suggestions", 1, true), "the prompt should count every file's edits: " .. prompt)
assert(prompt:find("file.txt: 1 (1 outside the PR diff)", 1, true), "the prompt should count per file: " .. prompt)
assert(prompt:find("nested/other.txt: 1", 1, true), "the prompt should list the saved file: " .. prompt)
assert(prompt:find("new.txt: 1", 1, true), "the prompt should list the buffer-only file: " .. prompt)
assert(prompt:find("left alone: nested/deeper/more.txt", 1, true), "the prompt should name files outside the PR")
assert(#api.pending() == pending_before + 3, "one suggestion per file should be queued")
local queued_paths = {}
for _, pending in ipairs(api.pending()) do
  queued_paths[pending.path] = (queued_paths[pending.path] or 0) + 1
end
assert(queued_paths["nested/other.txt"] == 1 and queued_paths["new.txt"] == 1, "each file's edit should be queued")

-- the saved, unopened file: undone and written back to HEAD
local other_buf = assert(loaded("nested/other.txt"), "the saved file should have been loaded")
assert(disk("nested/other.txt") == "alpha|-- new|omega", "a saved edit should be written back to HEAD's content")
assert(not vim.bo[other_buf].modified, "the written-back buffer should be unmodified")
-- the buffer-only file: undone, the file on disk untouched
assert(vim.api.nvim_buf_get_lines(new_buf, 1, 2, false)[1] == "new two", "the buffer edit should be undone")
assert(disk("new.txt") == "new one|new two", "a buffer-only edit should not write the file")
-- the file with other unsaved work: undone in the buffer, never written
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[4] == "base changed" and lines[10] == "tail changed", "only the in-diff edit should be undone")
assert(disk("file.txt"):find("base changed twice", 1, true), "a buffer with other unsaved work must not be written")
assert(noted("Left unsaved, the buffer has other unsaved changes: file.txt"), "the unwritten file should be named")
-- outside the PR: reported, not touched
assert(disk("nested/deeper/more.txt") == "deep|feature saved", "a file outside the PR should be left alone")
assert(not loaded("nested/deeper/more.txt"), "a file outside the PR should not be opened")

-- a write that fails is reported as such, not as unsaved work of yours
vim.api.nvim_buf_set_lines(other_buf, 1, 2, false, { "-- newest" })
vim.api.nvim_buf_call(other_buf, function()
  vim.cmd("silent write")
end)
local refuse = vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*/nested/other.txt",
  callback = function()
    error("disk says no")
  end,
})
notes = {}
pr.suggest_edits({ all = true })
vim.api.nvim_del_autocmd(refuse)
assert(noted("Could not write back, left modified: nested/other.txt ("), "a failed write should be reported")
assert(noted("disk says no"), "a failed write should carry its error")
assert(not noted("Left unsaved"), "a failed write is not unsaved work: " .. table.concat(notes, "\n"))
assert(vim.bo[other_buf].modified, "a buffer that could not be written stays modified")
assert(disk("nested/other.txt") == "alpha|-- newest|omega", "a failed write should leave the file alone")

-- a file deleted on disk cannot be read to check it: not clean, no crash
vim.api.nvim_win_set_buf(code_win, new_buf)
os.remove("new.txt")
notes = {}
local survived, crash = pcall(pr.suggest_edits)
assert(survived, "a deleted file should not crash the batch: " .. tostring(crash))
vim.api.nvim_win_set_buf(code_win, buf)

vim.fn.confirm = original_confirm
vim.fn.system({ "git", "checkout", "--", "file.txt", "nested", "new.txt" })
reset()
vim.bo[buf].modified = false
vim.bo[new_buf].modified = false
vim.bo[other_buf].modified = false
pr.stop()
harness.done()
