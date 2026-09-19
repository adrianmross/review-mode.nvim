-- Committing trial suggestions, crediting the suggesters.
--
-- Runs in a copy of the fixture repo, since it commits. file.txt at HEAD is
--   1 one  2 two  3 ""  4 base changed  5 same1 ... 9 same5  10 tail
-- and the mock (REVIEW_MODE_FIXTURE=suggestions) suggests lines 2 and 4 as
-- reviewer (id 101, "Rita Reviewer") and line 10 as alice (no id, no name).
--
-- The point to prove: the commit holds the trial lines and nothing else. The
-- user's own edits, saved and unsaved, stay out of it and stay unstaged.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local function git(args)
  return vim.trim(vim.fn.system(vim.list_extend({ "git" }, args)))
end

git({ "checkout", "-q", "feature" })
assert(git({ "status", "--porcelain", "--untracked-files=no" }) == "", "the fixture repo should start clean")

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

local prompts = {}
local answer = 3
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return answer
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
  return api.comment_count("file.txt") == 4
end, "comments did not load")

vim.cmd("edit file.txt")
local buf = vim.api.nvim_get_current_buf()
local head_before = git({ "rev-parse", "HEAD" })

-- Nothing to commit ---------------------------------------------------------------

vim.cmd("ReviewModeSuggestionCommit")
assert(noted("no trial suggestions to commit"), "with no trials, say so")
assert(#prompts == 0, "with no trials, nothing to confirm")

-- The user's own edits: one saved, one not ---------------------------------------

-- line 7, saved to disk; line 1, unsaved and right above a suggestion
vim.api.nvim_buf_set_lines(buf, 6, 7, false, { "same3 mine, saved" })
vim.cmd("silent write")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "one mine, unsaved" })

assert(api.accept_all_suggestions("file.txt", { buf = buf }) == 3, "all three suggestions should apply")
assert(#api.suggestion_trials() == 3, "expected three trials")

-- Declined ---------------------------------------------------------------------

answer = 3
vim.cmd("ReviewModeSuggestionCommit")
assert(#prompts == 1, "committing should ask first")
assert(git({ "rev-parse", "HEAD" }) == head_before, "a declined confirmation must not commit")
assert(#api.suggestion_trials() == 3, "a declined confirmation keeps the trials")

local prompt = prompts[1]
for _, needle in ipairs({ "file.txt:2  from reviewer", "file.txt:5  from reviewer", "file.txt:11  from alice" }) do
  assert(prompt:find(needle, 1, true), "the confirmation should list " .. needle .. ":\n" .. prompt)
end
assert(prompt:find("Apply suggestions from code review", 1, true), "the confirmation should show the message")

-- Staged work is not swept in ---------------------------------------------------

vim.fn.writefile({ "alpha", "-- staged", "omega" }, "nested/other.txt")
git({ "add", "nested/other.txt" })
vim.cmd("ReviewModeSuggestionCommit")
assert(noted("you have staged changes"), "staged changes should refuse the commit")
assert(#prompts == 1, "a refused commit asks nothing")
git({ "reset", "-q", "--", "nested/other.txt" })
git({ "checkout", "--", "nested/other.txt" })

-- An edited trial is refused -----------------------------------------------------

local tail_row = #vim.api.nvim_buf_get_lines(buf, 0, -1, false) - 1
vim.api.nvim_buf_set_text(buf, tail_row, 0, tail_row, 0, { "my " })
vim.cmd("ReviewModeSuggestionCommit")
assert(noted("the trial suggestion was edited"), "a trial with the user's typing in it should be refused")
assert(git({ "rev-parse", "HEAD" }) == head_before, "a refused commit must not commit")
vim.api.nvim_buf_set_text(buf, tail_row, 0, tail_row, 3, { "" })

-- A failed commit leaves everything as it was --------------------------------------

-- validate.sh points core.hooksPath at an empty directory, so .git/hooks would
-- never run; point this copy at a hooks directory of its own for the one call.
local hooks_path = git({ "config", "core.hooksPath" })
local hooks_dir = git({ "rev-parse", "--absolute-git-dir" }) .. "/fixture-hooks"
vim.fn.mkdir(hooks_dir, "p")
vim.fn.writefile({ "#!/bin/sh", "echo 'pre-commit says no' >&2", "exit 1" }, hooks_dir .. "/pre-commit")
vim.fn.setfperm(hooks_dir .. "/pre-commit", "rwxr-xr-x")
git({ "config", "core.hooksPath", hooks_dir })
answer = 1
vim.cmd("ReviewModeSuggestionCommit")
git({ "config", "core.hooksPath", hooks_path })
vim.fn.delete(hooks_dir, "rf")

assert(git({ "rev-parse", "HEAD" }) == head_before, "a failed commit must not commit")
vim.fn.system({ "git", "diff", "--cached", "--quiet" })
assert(vim.v.shell_error == 0, "a failed commit must put the index back to HEAD:\n" .. git({ "diff", "--cached" }))
assert(noted("git commit failed: pre-commit says no"), "a failed commit should say why")
assert(#api.suggestion_trials() == 3, "a failed commit keeps the trials")
local kept = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(kept[1] == "one mine, unsaved" and kept[8] == "same3 mine, saved", "a failed commit keeps the user's edits")
local on_disk = table.concat(vim.fn.readfile("file.txt"), "\n")
assert(
  on_disk:find("same3 mine, saved", 1, true) and not on_disk:find("improved", 1, true),
  "a failed commit leaves the file on disk alone:\n" .. on_disk
)

-- Commit, and resolve the threads -------------------------------------------------

local resolved = {}
api.resolve = function(thread_id, value)
  resolved[#resolved + 1] = thread_id .. "=" .. tostring(value)
end

answer = 2
vim.cmd("ReviewModeSuggestionCommit")
assert(git({ "rev-parse", "HEAD~1" }) == head_before, "expected exactly one new commit")

local committed = git({ "show", "HEAD:file.txt" })
assert(committed == table.concat({
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
}, "\n"), "the commit should hold the trial lines and nothing else:\n" .. committed)
assert(git({ "show", "--name-only", "--format=", "HEAD" }) == "file.txt", "the commit should touch file.txt only")

local message = git({ "show", "-s", "--format=%B", "HEAD" })
assert(message == table.concat({
  "Apply suggestions from code review",
  "",
  "Co-authored-by: Rita Reviewer <101+reviewer@users.noreply.github.com>",
  "Co-authored-by: alice <alice@users.noreply.github.com>",
}, "\n"), "unexpected commit message:\n" .. message)

-- the user's edits survive, on disk and unstaged, and nothing is left staged
assert(git({ "diff", "--cached", "--name-only" }) == "", "nothing should be left staged")
local unstaged = git({ "diff", "-U0", "--", "file.txt" })
assert(unstaged:find("+one mine, unsaved", 1, true), "the unsaved edit should be on disk, unstaged:\n" .. unstaged)
assert(unstaged:find("+same3 mine, saved", 1, true), "the saved edit should stay unstaged:\n" .. unstaged)
assert(not unstaged:find("improved", 1, true), "the trial lines should be committed, not left unstaged:\n" .. unstaged)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[1] == "one mine, unsaved" and lines[8] == "same3 mine, saved", "the buffer keeps the user's edits")
assert(not vim.bo[buf].modified, "the buffer should be written")

assert(#api.suggestion_trials() == 0, "committed trials should be forgotten")
local trial_ns = vim.api.nvim_get_namespaces().review_mode_suggestion_trial
assert(#vim.api.nvim_buf_get_extmarks(buf, trial_ns, 0, -1, {}) == 0, "committed trials should lose their marks")
assert(noted("Committed 3 suggestions as"), "the commit should be reported")
table.sort(resolved)
assert(
  table.concat(resolved, " ") == "thread_s1=true thread_s2=true thread_s4=true",
  "each suggestion thread should be resolved once: " .. table.concat(resolved, " ")
)

-- Edits at the edges of a trial ---------------------------------------------------

-- A trial over HEAD lines 6-8 (same1, same2, same3), with the user's edit right
-- at one of its edges. Edits beside the replaced lines are the user's own and
-- stay out of the commit; edits into them cannot be told apart from the trial.
local head_lines = vim.split(git({ "show", "HEAD:file.txt" }), "\n", { plain = true })
assert(head_lines[6] == "same1" and head_lines[8] == "same3", "unexpected HEAD for the edge cases")
local expected = vim.list_slice(head_lines, 1, 5)
vim.list_extend(expected, { "same mid" })
vim.list_extend(expected, vim.list_slice(head_lines, 9, #head_lines))
expected = table.concat(expected, "\n") .. "\n"

local case_id = 0
local function edge(name, before, after, start_line, end_line)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, head_lines)
  if before then
    before()
  end
  case_id = case_id + 1
  local trial = assert(api.accept_suggestion({
    id = "edge_" .. case_id,
    path = "file.txt",
    start_line = start_line or 6,
    end_line = end_line or 8,
    lines = { "same mid" },
  }, { buf = buf }))
  if after then
    after()
  end
  local plan, err = api.suggestion_commit_plan()
  -- cleanup: several cases edit inside the trial, and reverting one asks first
  answer = 1
  api.revert_suggestion(trial.id)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, head_lines)
  return plan, err, name
end

local function safe(plan, err, name)
  assert(plan, name .. " should be committable: " .. tostring(err))
  assert(plan.files[1].content == expected, name .. " leaked into the commit:\n" .. plan.files[1].content)
end
local function refused(needle, plan, err, name)
  assert(
    not plan and tostring(err):find(needle, 1, true),
    name .. " should be refused with '" .. needle .. "': " .. tostring(err)
  )
end

-- the trial sits on row 5 (0-based) once applied
safe(edge("deleting the line right above", nil, function()
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, {})
end))
safe(edge("deleting the line right below", nil, function()
  vim.api.nvim_buf_set_lines(buf, 6, 7, false, {})
end))
safe(edge("inserting right below", nil, function()
  vim.api.nvim_buf_set_lines(buf, 6, 6, false, { "mine below" })
end))
safe(edge("inserting at the end of the line above", nil, function()
  vim.api.nvim_buf_set_text(buf, 4, #head_lines[5], 4, #head_lines[5], { "", "mine above" })
end))
-- a line opened at the trial's first row joins the trial: the mark's gravity
-- takes it in, so it reads as the user's typing inside the trial
refused(
  "the trial suggestion was edited",
  edge("inserting at the trial's first row", nil, function()
    vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "mine above" })
  end)
)
-- edits made to the lines before the trial replaced them
refused(
  "was edited around the trial suggestion",
  edge("editing inside the replaced lines", function()
    vim.api.nvim_buf_set_lines(buf, 6, 7, false, { "same2 mine" })
  end)
)
refused(
  "was edited around the trial suggestion",
  edge("deleting inside the replaced lines", function()
    vim.api.nvim_buf_set_lines(buf, 6, 7, false, {})
  end, nil, 6, 7)
)
refused(
  "was edited around the trial suggestion",
  edge("inserting inside the replaced lines", function()
    vim.api.nvim_buf_set_lines(buf, 6, 6, false, { "mine inside" })
  end, nil, 6, 9)
)

-- A display name is user-controlled: it must not add a trailer of its own.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, head_lines)
local hostile = assert(api.accept_suggestion({
  id = "hostile",
  path = "file.txt",
  start_line = 6,
  end_line = 8,
  lines = { "same mid" },
  suggester = { login = "eve\n", id = 7, name = "Eve\nCo-authored-by: Mallory <m@x>" },
}, { buf = buf }))
local hostile_plan = assert(api.suggestion_commit_plan())
assert(
  hostile_plan.message
    == "Apply suggestion from code review\n\nCo-authored-by: Eve Co-authored-by: Mallory m@x <7+eve@users.noreply.github.com>\n",
  "a hostile name should stay on one trailer line:\n" .. hostile_plan.message
)
api.revert_suggestion(hostile.id)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, head_lines)
vim.bo[buf].modified = false

pr.stop()

-- Local reviews: committed, but nobody to credit -------------------------------------

git({ "checkout", "-q", "-b", "commit-local" })
vim.fn.writefile({ "new one", "new two", "new three" }, "new.txt")
git({ "add", "new.txt" })
git({ "commit", "-q", "-m", "local head" })

pr.review_local({ "feature..commit-local" })
wait_for(function()
  return api.is_active() and api.is_changed_file("new.txt")
end, "the local review did not load")
local posted = false
api.comment({ path = "new.txt", line = 3, body = "```suggestion\nnew three, local\n```" }, function()
  posted = true
end)
wait_for(function()
  return posted
end, "the local comment was not stored")

vim.cmd("edit new.txt")
-- Local comments all count as the viewer's, which would skip the trailer on
-- its own; pretend this one is someone else's, so only the provider check
-- keeps a made-up GitHub address out of the message.
local local_entry = api.suggestions("new.txt")[1]
local_entry.suggester.is_viewer = false
assert(api.accept_suggestion(local_entry), "the local suggestion should apply")
local plan = assert(api.suggestion_commit_plan())
assert(
  plan.message == "Apply suggestion from code review\n",
  "a local review commits without trailers: " .. plan.message
)
assert(api.commit_suggestions(plan), "the local commit failed")
assert(git({ "show", "HEAD:new.txt" }):find("new three, local", 1, true), "the local suggestion should be committed")

pr.stop()
harness.done()
