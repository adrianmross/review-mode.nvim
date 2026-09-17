local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local capture = assert(os.getenv("REVIEW_MODE_REVIEW_CAPTURE"), "REVIEW_MODE_REVIEW_CAPTURE is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function has_line(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local pr = require("review_mode")
local api = require("review_mode.api")
local review_buffer = require("review_mode.review_buffer")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local submitted = {}
api.on("review_submitted", function(ctx)
  submitted[#submitted + 1] = ctx
end)

local function start()
  pr.start()
  wait_for(function()
    return api.is_changed_file("file.txt")
  end, "changed file map did not load")
end

start()
api.discard_pending()
os.remove(capture)

-- the composer's <C-p> queues a new comment instead of posting it
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.compose_comment()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Needs a test", "second line" })
vim.api.nvim_feedkeys(vim.keycode("<C-p>"), "mx", false)
assert(#api.pending() == 1, "<C-p> did not add a pending comment")
assert(vim.bo.filetype ~= "markdown", "<C-p> left the composer open")

local range = assert(api.add_pending({ path = "file.txt", start_line = 4, end_line = 5, body = "Rename these" }))
assert(range.start_line == 4 and range.end_line == 5 and range.side == "RIGHT", "draft shape is wrong")
assert(not api.add_pending({ path = "file.txt", line = 2, body = "  " }), "an empty draft was accepted")

-- drafts show up as pending threads
local threads = api.threads({ path = "file.txt", line = 2 })
local lines = api.render_threads(threads, { width = 60 })
assert(has_line(lines, "Needs a test") and has_line(lines, "pending"), "draft is not rendered as a pending thread")

-- drafts persist through the end of the session
pr.stop()
assert(#api.pending() == 0, "drafts leaked out of the session")
start()
assert(#api.pending() == 2, "drafts did not persist across stop/start")

-- the review buffer lists them, and dd drops one
review_buffer.open()
assert(vim.api.nvim_buf_get_name(0) == "review-mode://review", "review buffer did not open")
local review_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(has_line(review_lines, "file.txt:2  Needs a test"), "review buffer does not list the line draft")
assert(has_line(review_lines, "file.txt:4-5  Rename these"), "review buffer does not list the range draft")
local extra = assert(api.add_pending({ path = "nested/other.txt", line = 2, body = "drop me" }))
review_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for row, line in ipairs(review_lines) do
  if line:find("drop me", 1, true) then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
end
vim.cmd("normal dd")
assert(#api.pending() == 2, "dd did not drop the draft under the cursor")
for _, draft in ipairs(api.pending()) do
  assert(draft.id ~= extra.id, "dd dropped the wrong draft")
end

-- REQUEST_CHANGES needs a body, and that is caught before anything is sent
local rejected
api.submit_review({ event = "REQUEST_CHANGES", body = "" }, function(ok, err)
  rejected = { ok = ok, err = err }
end)
assert(rejected and rejected.ok == false and rejected.err:find("body", 1, true), "empty REQUEST_CHANGES was accepted")

-- declining the confirmation sends nothing
local original_confirm = vim.fn.confirm
local prompts = {}
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return 2
end
review_buffer.submit("approve")
vim.wait(200)
assert(prompts[1] and prompts[1]:find("APPROVE with 2 pending comments", 1, true), "submit was not confirmed")
assert(not vim.uv.fs_stat(capture), "a declined review was sent")
assert(#api.pending() == 2, "a declined review cleared the drafts")

-- a failed submission keeps the drafts
vim.env.REVIEW_MODE_FAIL_REVIEW = "1"
local failed
api.submit_review({ event = "COMMENT", body = "x" }, function(ok, err)
  failed = { ok = ok, err = err }
end)
wait_for(function()
  return failed ~= nil
end, "failed submission never called back")
vim.env.REVIEW_MODE_FAIL_REVIEW = nil
assert(
  failed.ok == false and tostring(failed.err):find("forced review submission failure", 1, true),
  "failure not reported"
)
assert(#api.pending() == 2, "a failed submission cleared the drafts")

-- a confirmed submission sends the event, body and every draft, then clears them
vim.fn.confirm = function()
  return 1
end
local body_row = vim.api.nvim_buf_line_count(0)
vim.api.nvim_buf_set_lines(0, body_row - 1, body_row, false, { "Please address these." })
review_buffer.submit("request_changes")
wait_for(function()
  return #submitted == 1
end, "review was not submitted")
vim.fn.confirm = original_confirm

local sent = vim.json.decode(table.concat(vim.fn.readfile(capture), "\n"))
assert(sent.event == "REQUEST_CHANGES", "wrong review event")
assert(sent.body == "Please address these.", "wrong review body")
assert(sent.commit_id == "abc123", "review not anchored to the PR head")
assert(#sent.comments == 2, "review did not carry every draft")
local line_comment, range_comment = sent.comments[1], sent.comments[2]
assert(line_comment.path == "file.txt" and line_comment.line == 2 and line_comment.side == "RIGHT", "line draft wrong")
assert(line_comment.body == "Needs a test\nsecond line" and line_comment.start_line == nil, "line draft body wrong")
assert(range_comment.start_line == 4 and range_comment.line == 5 and range_comment.start_side == "RIGHT", "range wrong")
assert(submitted[1].event == "REQUEST_CHANGES" and submitted[1].count == 2, "review_submitted payload wrong")
assert(#api.pending() == 0, "a successful submission kept the drafts")
assert(vim.api.nvim_buf_get_name(0) ~= "review-mode://review", "review buffer stayed open after submitting")

-- APPROVE needs neither drafts nor a body
local approved
api.submit_review({ event = "APPROVE" }, function(ok)
  approved = ok
end)
wait_for(function()
  return approved ~= nil
end, "approve never called back")
assert(approved == true, "a bare APPROVE was rejected")
sent = vim.json.decode(table.concat(vim.fn.readfile(capture), "\n"))
assert(sent.event == "APPROVE" and sent.body == nil and sent.comments == nil, "bare APPROVE payload wrong")

pr.stop()
