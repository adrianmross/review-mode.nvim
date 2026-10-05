-- fixture: gh pr REVIEW_MODE_FIXTURE=suggestions
-- Suggestion preview, trial apply, revert and accept-all.
--
-- The mock branch this runs against (REVIEW_MODE_FIXTURE=suggestions) puts
-- three suggestions in file.txt at lines 2, 4 and 10, the first of them two
-- lines long, plus a fourth thread with no suggestion at all. That shape is the
-- point: accept-all has to apply them bottom-up, because the first one makes
-- the file a line longer than the others were anchored against.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

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
  return api.comment_count("file.txt") == 4
end, "comments did not load")

vim.cmd("edit file.txt")
local buf = vim.api.nvim_get_current_buf()

local function lines()
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local original = lines()
assert(#original == 10 and original[2] == "two" and original[10] == "tail", "unexpected fixture file.txt")

-- Listing ---------------------------------------------------------------------

local entries = api.suggestions("file.txt")
assert(#entries == 3, "expected three suggestion-bearing threads, got " .. #entries)
assert(
  entries[1].start_line == 2 and entries[2].start_line == 4 and entries[3].start_line == 10,
  "suggestions should come back in line order"
)
assert(table.concat(entries[1].lines, "|") == "two improved|two extra", "unexpected suggestion body")
assert(entries[2].path == "file.txt" and entries[2].end_line == 4, "entry should carry its path and range")
assert(#api.suggestions_at("file.txt", 4) == 1, "line 4 carries a suggestion")
assert(#api.suggestions_at("file.txt", 6) == 0, "line 6's thread has no suggestion block")

-- Inline preview --------------------------------------------------------------

local preview_ns = vim.api.nvim_get_namespaces().review_mode_suggestion_preview
assert(preview_ns, "the preview namespace was not created")

assert(api.preview_suggestion(entries[1], { buf = buf }) == true, "preview should turn on")
local marks = vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, { details = true })
assert(#marks == 1, "expected one preview extmark, got " .. #marks)
assert(marks[1][2] == 1, "the preview belongs on the suggestion's own first line")
local details = marks[1][4]
assert(details.virt_lines and #details.virt_lines == 2, "the suggested lines should render as virtual lines")
assert(details.virt_lines[1][1][1] == "two improved", "unexpected first virtual line")
assert(details.virt_lines[1][1][2] == "ReviewModeSuggestionAdd", "virtual lines should reuse the add highlight")
assert(details.hl_group == "ReviewModeSuggestionDelete", "the replaced range should read as a deletion")
assert(table.concat(lines(), "\n") == table.concat(original, "\n"), "a preview must not touch the buffer")

assert(api.preview_suggestion(entries[1], { buf = buf }) == false, "preview should toggle off")
assert(#vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, {}) == 0, "toggling off should clear the extmark")

-- Side-by-side preview --------------------------------------------------------

assert(api.preview_suggestion(entries[2], { buf = buf, layout = "split" }) == true, "split preview should open")
local scratch, scratch_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local win_buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_get_name(win_buf):match("pr%-suggestion://file%.txt$") then
    scratch, scratch_win = win_buf, win
  end
end
assert(scratch, "the suggested version should be in a window of its own")
assert(vim.wo[scratch_win].diff, "the split should use the diff machinery, not a plain split")
local suggested = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
assert(#suggested == 10 and suggested[4] == "base improved", "the scratch side is the file with the suggestion in it")
assert(suggested[1] == original[1] and suggested[10] == original[10], "the rest of the file is untouched")
assert(table.concat(lines(), "\n") == table.concat(original, "\n"), "the real buffer is untouched")
assert(api.preview_suggestion(entries[2], { buf = buf, layout = "split" }) == false, "split preview should toggle off")
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "toggling off should close the split")

-- Preview meets trial -----------------------------------------------------------

-- The reported sequence: preview a suggestion, apply it, preview again. The
-- open preview must not outlive the apply (its deletion paint and ghost lines
-- would sit over the applied text), and a second preview must not show the
-- suggestion twice: once applied, preview shows what the trial replaced.
local function preview_marks()
  return vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, { details = true })
end
assert(api.preview_suggestion(entries[2], { buf = buf }) == true, "preview should turn on")
assert(api.accept_suggestion(entries[2], { buf = buf }), "applying over an open preview failed")
assert(#preview_marks() == 0, "applying left the preview drawn over the applied lines")

assert(api.preview_suggestion(entries[2], { buf = buf }) == true, "previewing an applied suggestion should turn on")
local before = preview_marks()
assert(#before == 1, "expected one preview of the applied suggestion, got " .. #before)
local shown = before[1][4]
assert(shown.virt_lines[1][1][1] == "base changed", "an applied suggestion should preview what it replaced")
assert(shown.virt_lines[1][1][2] == "ReviewModeSuggestionDelete", "the replaced lines should read as a deletion")
assert(shown.virt_lines_above, "the replaced lines belong above the applied ones, as in a diff")
assert(shown.hl_group ~= "ReviewModeSuggestionDelete", "the applied lines are not a deletion")
assert(lines()[4] == "base improved", "previewing must not touch the applied trial")
assert(api.preview_suggestion(entries[2], { buf = buf }) == false, "the applied-suggestion preview should toggle off")
assert(#preview_marks() == 0, "toggling off should clear it")

-- side by side, an applied suggestion compares against the lines it replaced
assert(api.preview_suggestion(entries[2], { buf = buf, layout = "split" }) == true, "split preview should open")
local other
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local win_buf = vim.api.nvim_win_get_buf(win)
  if win_buf ~= buf then
    other = vim.api.nvim_buf_get_lines(win_buf, 0, -1, false)
  end
end
assert(other and other[4] == "base changed", "the split of an applied suggestion should show the original")
assert(api.preview_suggestion(entries[2], { buf = buf, layout = "split" }) == false, "split preview should close")
-- reverting closes a split of what the trial replaced, which would be stale
assert(api.preview_suggestion(entries[2], { buf = buf, layout = "split" }) == true, "split preview should reopen")
assert(api.revert_suggestion(), "reverting under an open split failed")
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "reverting left the split of the original open")
assert(api.accept_suggestion(entries[2], { buf = buf }), "re-applying after the split revert failed")

-- the apply key toggles: on an applied suggestion it reverts
vim.api.nvim_win_set_cursor(0, { 4, 0 })
pr.apply_suggestion()
assert(lines()[4] == "base changed", "applying an applied suggestion should revert it")
assert(#api.suggestion_trials() == 0, "the toggle-off left a trial behind")
pr.apply_suggestion()
assert(lines()[4] == "base improved", "the apply key should apply again after a revert")
assert(api.revert_suggestion(), "cleaning up the toggled trial failed")
assert(table.concat(lines(), "\n") == table.concat(original, "\n"), "the buffer should be back to the original")

-- Trial apply and revert ------------------------------------------------------

local trial_ns = vim.api.nvim_get_namespaces().review_mode_suggestion_trial
assert(trial_ns, "the trial namespace was not created")

local accepted, reverted = {}, {}
api.on("suggestion_accepted", function(ctx)
  accepted[#accepted + 1] = ctx
end)
api.on("suggestion_reverted", function(ctx)
  reverted[#reverted + 1] = ctx
end)

local trial = assert(api.accept_suggestion(entries[2], { buf = buf }), "accepting the line 4 suggestion failed")
assert(lines()[4] == "base improved", "the trial should be written into the buffer")
assert(vim.bo[buf].modified, "a trial is an unsaved change")
assert(#api.suggestion_trials() == 1, "the trial should be listed as live")
assert(api.suggestion_trials()[1].line == 4, "the trial should report the line it sits on")

local trial_marks = vim.api.nvim_buf_get_extmarks(buf, trial_ns, 0, -1, { details = true })
assert(#trial_marks == 1, "a trial should leave exactly one mark")
assert(trial_marks[1][4].sign_text, "a trial should be signed")
assert(trial_marks[1][4].virt_text, "a trial should say so in virtual text")
assert(#accepted == 1 and accepted[1].path == "file.txt" and accepted[1].line == 4, "suggestion_accepted did not fire")
assert(api.accept_suggestion(entries[2], { buf = buf }) == nil, "the same suggestion must not be trialled twice")

-- The revert has to find the lines where they are now, not where the suggestion
-- was anchored: edit above the trial and it moves down two lines.
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted header", "and another" })
assert(api.suggestion_trials()[1].line == 6, "the trial should follow an edit above it")

assert(api.revert_suggestion(trial.id), "reverting the trial failed")
local after = lines()
assert(after[1] == "inserted header" and after[2] == "and another", "revert must not clobber unrelated edits")
assert(after[6] == "base changed", "revert must restore the original line where the trial ended up")
assert(#after == 12, "revert should leave the unrelated edit's two lines in place, got " .. #after)
assert(#api.suggestion_trials() == 0, "a reverted trial is no longer live")
assert(#reverted == 1 and reverted[1].id == trial.id, "suggestion_reverted did not fire")

-- Typing inside a trial widens its mark, so a revert would throw that typing
-- away with it: it asks first, and keeping the edits keeps the trial.
vim.api.nvim_buf_set_lines(buf, 0, 2, false, {})
local before_edit = lines()
local edited = assert(api.accept_suggestion(entries[2], { buf = buf }), "re-applying the line 4 suggestion failed")
vim.api.nvim_buf_set_text(buf, 3, #"base improved", 3, #"base improved", { " by hand" })
assert(lines()[4] == "base improved by hand", "the hand edit did not land inside the trial")
local forbidden_confirm, revert_prompts = vim.fn.confirm, {}
local revert_answer = 2
vim.fn.confirm = function(prompt)
  revert_prompts[#revert_prompts + 1] = prompt
  return revert_answer
end
local kept = api.revert_suggestion(edited.id)
assert(#revert_prompts == 1, "reverting an edited trial did not ask first")
assert(not kept and lines()[4] == "base improved by hand", "declining the revert still dropped the hand edit")
assert(#api.suggestion_trials() == 1, "declining the revert forgot the trial")
revert_answer = 1
assert(api.revert_suggestion(edited.id), "confirming the revert of an edited trial failed")
assert(vim.deep_equal(lines(), before_edit), "a confirmed revert did not restore the original lines")
vim.fn.confirm = forbidden_confirm
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted header", "and another" })

-- Accept all ------------------------------------------------------------------

-- Extmarks outlive a reload, so pruning dead marks is not enough to notice one:
-- a reload that keeps the buffer loaded (:checktime autoread) fires only
-- BufReadPost, and the trials it invalidates have to go then too, or a later
-- revert writes the old lines into re-read text.
assert(api.accept_suggestion(entries[3], { buf = buf }), "accepting the line 10 suggestion failed")
vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
assert(#api.suggestion_trials() == 0, "a re-read buffer must drop the trials it invalidates")
assert(
  #vim.api.nvim_buf_get_extmarks(buf, trial_ns, 0, -1, {}) == 0,
  "a dropped trial must take its sign and label with it"
)

-- A preview is buffer decoration: a reload drops it, and the next toggle has to
-- put it back up rather than report the one that is no longer there.
assert(api.preview_suggestion(entries[3], { buf = buf }) == true, "preview should be up before the reload")

vim.cmd("edit!")
buf = vim.api.nvim_get_current_buf()
assert(#api.suggestion_trials() == 0, "reloading a buffer drops the trials it was tracking")
assert(#vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, {}) == 0, "reloading a buffer drops its previews")
assert(api.preview_suggestion(entries[3], { buf = buf }) == true, "the preview should come back after a reload")
assert(api.preview_suggestion(entries[3], { buf = buf }) == false, "and toggle off again")

local applied, err = api.accept_all_suggestions("file.txt", { buf = buf })
assert(applied == 3, string.format("expected three applications, got %d (%s)", applied, tostring(err)))

-- Applied top-down instead of bottom-up, the first suggestion's extra line
-- would push every later one onto the wrong lines, and this is what catches it.
local want = {
  "one",
  "two improved",
  "two extra",
  "",
  "base improved",
  "same1",
  "same2",
  "same3",
  "same4",
  "same5",
  "tail improved",
}
local result = lines()
assert(#result == #want, string.format("expected %d lines after accept-all, got %d", #want, #result))
for index = 1, #want do
  assert(
    result[index] == want[index],
    string.format("line %d should be %q, got %q", index, want[index], tostring(result[index]))
  )
end

assert(api.accept_all_suggestions("file.txt", { buf = buf }) == 0, "live trials must not be applied a second time")
assert(#api.suggestion_trials() == 3, "all three trials should still be live")

for _, live in ipairs(api.suggestion_trials()) do
  assert(api.revert_suggestion(live.id), "reverting trial " .. live.id .. " failed")
end
local back = lines()
assert(#back == #original, string.format("reverting everything should restore 10 lines, got %d", #back))
for index = 1, #original do
  assert(back[index] == original[index], string.format("line %d did not come back: %q", index, tostring(back[index])))
end
assert(#api.suggestion_trials() == 0, "no trials should be left")

-- Commands --------------------------------------------------------------------

vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("ReviewModeSuggestionPreview")
assert(#vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, {}) == 1, ":ReviewModeSuggestionPreview should show one")
vim.cmd("ReviewModeSuggestionPreview")
assert(#vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, {}) == 0, ":ReviewModeSuggestionPreview should toggle")

vim.cmd("ReviewModeApplySuggestion")
assert(#api.suggestion_trials() == 1, "applying from the command is a trial too")
vim.cmd("ReviewModeSuggestionList")
pcall(vim.cmd, "fclose!")
vim.cmd("ReviewModeSuggestionRevert")
assert(#api.suggestion_trials() == 0, ":ReviewModeSuggestionRevert undoes the trial under the cursor")
assert(lines()[2] == "two", "the reverted line should be the original one")

-- The action picker must still end on Summary (scripts/fixture.lua selects the
-- last action), with the suggestion entries ahead of it.
local actions = pr.action_items()
assert(actions[#actions].label == "Summary", "Summary must stay the last action")
local labels = {}
for _, action in ipairs(actions) do
  labels[action.label] = true
end
assert(labels["Accept all suggestions in file"], "accept-all should be in the action picker")
assert(labels["Preview suggestion side by side"], "the split preview should be in the action picker")

-- Stopping the session forgets its trials; the buffer keeps the text.
vim.cmd("ReviewModeApplySuggestion")
assert(#api.suggestion_trials() == 1, "expected one live trial before stopping")
pr.stop()
assert(#api.suggestion_trials() == 0, "stopping the session forgets its trials")
assert(lines()[2] == "two improved", "stopping does not undo what was already written")

-- Local reviews ------------------------------------------------------------------

-- A local review keeps its comments on disk and can anchor one to a path the
-- review did not change. api.suggestions(nil) -- "every suggestion in this
-- review", the call an agent driving a headless review makes -- has to find
-- those too, so it walks the paths that carry comments rather than the
-- changed-file list.
local function git(args)
  return vim.trim(vim.fn.system(vim.list_extend({ "git" }, args)))
end

git({ "checkout", "-q", "-b", "suggestion-local", "feature" })
vim.fn.writefile({ "new one", "new two", "new three" }, "new.txt")
git({ "add", "new.txt" })
git({ "commit", "-q", "-m", "local head" })

pr.review_local({ "feature..suggestion-local" })
wait_for(function()
  return api.is_active() and api.is_changed_file("new.txt")
end, "the local review did not load")
assert(api.session().provider == "local", "expected a local review")
assert(not api.is_changed_file("file.txt"), "file.txt has to be outside this review's changed files")

local posted = 0
local function post(path, line, body)
  api.comment({ path = path, line = line, body = body }, function()
    posted = posted + 1
  end)
end
post("new.txt", 1, "```suggestion\nnew one local\n```")
post("file.txt", 2, "```suggestion\ntwo local\n```")
wait_for(function()
  return posted == 2
end, "the local comments were not stored")

-- new.txt is a changed file that carries comments and file.txt is not, so this
-- is also the case where the two sources could overlap.
local seen = {}
for _, entry in ipairs(api.comment_paths()) do
  assert(not seen[entry], "comment_paths listed " .. entry .. " twice")
  seen[entry] = true
end
assert(seen["new.txt"] and seen["file.txt"], "comment_paths should cover the changed and the unchanged path")

local all = api.suggestions(nil)
assert(#all == 2, "api.suggestions(nil) should find both local suggestions, got " .. #all)
assert(all[1].path == "new.txt", "changed files come first, in review order, got " .. all[1].path)
assert(all[2].path == "file.txt", "the unchanged path's suggestion is missing, got " .. all[2].path)
local by_id = {}
for _, entry in ipairs(all) do
  assert(not by_id[entry.id], "api.suggestions(nil) listed a suggestion twice")
  by_id[entry.id] = true
end

-- The rest of the machinery is provider-agnostic, so prove it on a local thread.
local outside = api.suggestions("file.txt")
assert(#outside == 1 and table.concat(outside[1].lines, "|") == "two local", "unexpected local suggestion body")
vim.cmd("edit! file.txt")
local local_buf = vim.api.nvim_get_current_buf()
local local_trial = assert(api.accept_suggestion(outside[1], { buf = local_buf }), "a local suggestion should apply")
assert(vim.api.nvim_buf_get_lines(local_buf, 1, 2, false)[1] == "two local", "the local suggestion was not applied")
assert(api.revert_suggestion(local_trial.id), "a local trial should revert")
assert(vim.api.nvim_buf_get_lines(local_buf, 1, 2, false)[1] == "two", "reverting a local trial restores the line")

pr.stop()
git({ "checkout", "-q", "feature" })
harness.done()
