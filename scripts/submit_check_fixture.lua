-- The readiness check before submitting: counts from state already in memory,
-- and only the non-zero ones in the APPROVE confirmation.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local capture = assert(os.getenv("REVIEW_MODE_REVIEW_CAPTURE"), "REVIEW_MODE_REVIEW_CAPTURE is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local pr = require("review_mode")
local api = require("review_mode.api")
local review_buffer = require("review_mode.review_buffer")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  follow_head = false,
  viewed = { enabled = true, sync = false },
  auto_open_first_change = false,
})
local state = api.unstable_state()

pr.start()
wait_for(function()
  for _, file in ipairs(api.files()) do
    if not api.hunk_progress(file.path) then
      return false
    end
  end
  return api.is_changed_file("new.txt")
end, "hunks did not load for every changed file")
wait_for(function()
  return #api.ci_annotations("file.txt") == 2 and #api.threads({ include_resolved = true }) == 3
end, "CI annotations and threads did not load")
api.discard_pending()
os.remove(capture)

-- the -U0 hunk headers carry the new-side ranges: "two" (2), "base changed"
-- (4), and new.txt's two added lines
assert(vim.deep_equal(state.hunk_ranges["file.txt"], { { 2, 2 }, { 4, 4 } }), "file.txt hunk ranges wrong")
assert(vim.deep_equal(state.hunk_ranges["new.txt"], { { 1, 2 } }), "new.txt hunk range wrong")

-- constructed state: every file viewed but these three (earlier fixtures leave
-- extra commits in the shared repo), and the first hunk of file.txt viewed
local unviewed = { ["file.txt"] = true, ["nested/other.txt"] = true, ["nested/deeper/more.txt"] = true }
for _, file in ipairs(api.files()) do
  api.set_viewed(file.path, not unviewed[file.path])
end
state.hunk_viewed["file.txt"] = { [state.hunk_hashes["file.txt"][1]] = true }

local counts = api.review_readiness()
assert(counts.unviewed_files == 3, "unviewed files: " .. counts.unviewed_files)
-- file.txt's second hunk, other.txt's and more.txt's; viewed files count none
assert(counts.unviewed_hunks == 3, "unviewed hunks: " .. counts.unviewed_hunks)
-- file.txt:2 is a failure on a changed line; 4-5 is only a warning
assert(counts.ci_failures == 1, "CI failures: " .. counts.ci_failures)
-- thread_1 and thread_3; thread_2 is resolved
assert(counts.unresolved_threads == 2, "unresolved threads: " .. counts.unresolved_threads)
assert(counts.pending == 0, "pending: " .. counts.pending)

-- a failure off the changed lines is not the PR's doing
local ranges = state.hunk_ranges["file.txt"]
state.hunk_ranges["file.txt"] = { { 4, 4 } }
assert(api.review_readiness().ci_failures == 0, "a CI failure on an unchanged line was counted")
state.hunk_ranges["file.txt"] = ranges

-- a posted comment of yours over the failing line answers it
local own = state.comments["file.txt"][1]
assert(own.line == 2, "expected thread_1's comment on line 2")
own.viewer_did_author = true
assert(api.review_readiness().ci_failures == 0, "your posted comment did not answer the CI failure")
own.viewer_did_author = false

local original_confirm = vim.fn.confirm
local prompts = {}
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return 2
end
local function prompt_for(kind)
  prompts = {}
  review_buffer.submit(kind)
  return prompts[1]
end

-- APPROVE lists every non-zero count, and declining sends nothing
local approve = prompt_for("approve")
assert(
  approve
    == "Submit review as APPROVE with 0 pending comments?\n\n"
      .. "  3 files not viewed (3 hunks)\n"
      .. "  1 CI failure on changed lines, not commented on\n"
      .. "  2 unresolved threads",
  "APPROVE prompt wrong:\n" .. tostring(approve)
)
vim.wait(200)
assert(not vim.uv.fs_stat(capture), "a declined review was sent")

-- COMMENT keeps today's prompt: it is routinely sent mid-review
assert(prompt_for("comment") == "Submit review as COMMENT with 0 pending comments?", "COMMENT prompt changed")

-- a pending draft on the failing line answers it, and only non-zero lines show
assert(api.add_pending({ path = "file.txt", line = 2, body = "x is fine" }))
counts = api.review_readiness()
assert(counts.ci_failures == 0 and counts.pending == 1, "a pending draft did not answer the CI failure")
approve = prompt_for("approve")
assert(
  approve
    == "Submit review as APPROVE with 1 pending comment?\n\n  3 files not viewed (3 hunks)\n  2 unresolved threads",
  "APPROVE prompt did not drop the zero line:\n" .. tostring(approve)
)

-- config off: today's prompt, whatever is left
state.config.review.submit_check = false
assert(prompt_for("approve") == "Submit review as APPROVE with 1 pending comment?", "submit_check = false ignored")
state.config.review.submit_check = true

-- nothing to report: today's prompt
for _, file in ipairs(api.files()) do
  api.set_viewed(file.path, true)
end
for _, list in pairs(state.comments) do
  for _, comment in ipairs(list) do
    comment.is_resolved = true
  end
end
counts = api.review_readiness()
assert(counts.unviewed_files == 0 and counts.unviewed_hunks == 0, "viewing every file left unviewed counts")
assert(counts.unresolved_threads == 0, "resolved threads still counted")
assert(
  prompt_for("approve") == "Submit review as APPROVE with 1 pending comment?",
  "nothing to report changed the prompt"
)

vim.fn.confirm = original_confirm
vim.wait(200)
assert(not vim.uv.fs_stat(capture), "a declined review was sent")
assert(#api.pending() == 1, "a declined review cleared the drafts")

api.discard_pending()
pr.stop()
