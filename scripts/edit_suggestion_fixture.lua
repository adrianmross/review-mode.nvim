-- Your edits, as suggestions.
--
-- file.txt at the PR head (HEAD) is
--   1 one  2 two  3 ""  4 base changed  5 same1 ... 9 same5  10 tail
-- and the PR diff changes lines 2 and 4, so with GitHub's three lines of
-- context a comment can land on lines 1-7, and 8-10 are outside the diff.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

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

vim.fn.confirm = original_confirm
reset()
vim.bo[buf].modified = false
pr.stop()
