local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local gh_log = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function gh_calls(needle)
  local count = 0
  for _, line in ipairs(vim.fn.filereadable(gh_log) == 1 and vim.fn.readfile(gh_log) or {}) do
    if line:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end
local function notified(needle)
  for _, message in ipairs(notifications) do
    if message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local confirm_answer, confirm_prompts = 2, {}
vim.fn.confirm = function(prompt)
  confirm_prompts[#confirm_prompts + 1] = prompt
  return confirm_answer
end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local events = {}
api.on("comment_edited", function(data)
  events[#events + 1] = { "comment_edited", data.comment_id }
end)
api.on("comment_deleted", function(data)
  events[#events + 1] = { "comment_deleted", data.comment_id }
end)

local function settled()
  return not api.unstable_state().comments_loading
end

pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 2 and settled()
end, "edit/delete fixture comments did not load")

-- comment_rows: each comment's header row, so a two-comment thread can be told apart
local lines, _, _, comment_rows = api.render_threads(api.threads({ path = "file.txt" }), { width = 60 })
assert(comment_rows and comment_rows[10] and comment_rows[11], "render did not return comment_rows")
assert(lines[comment_rows[10] + 1]:find("alice", 1, true), "comment_rows[10] is not alice's header")
assert(lines[comment_rows[11] + 1]:find("adrian", 1, true), "comment_rows[11] is not adrian's header")

-- refusals: someone else's comment sends nothing
local refused_err
assert(api.edit_comment({ comment_id = 10, body = "hijack" }, function(ok, err)
  assert(not ok, "edit of someone else's comment reported success")
  refused_err = err
end) == false, "edit of someone else's comment was not refused")
assert(refused_err and refused_err:find("own comments", 1, true), "edit refusal did not say why")
refused_err = nil
api.delete_comment(10, function(ok, err)
  assert(not ok, "delete of someone else's comment reported success")
  refused_err = err
end)
assert(refused_err and refused_err:find("own comments", 1, true), "delete refusal did not say why")
assert(gh_calls("--method") == 0, "a refused write still called gh")

-- panel: the key acts on the comment under the cursor, not just the thread
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.open_panel()
local panel_win = pr.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)
local alice_row, adrian_row
wait_for(function()
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:find("alice", 1, true) then
      alice_row = index
    elseif line:find("adrian", 1, true) then
      adrian_row = index
    end
  end
  return alice_row and adrian_row
end, "panel did not render both comments")

local function panel_key(row, key)
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { row, 0 })
  vim.cmd("normal " .. key)
end

-- dd on alice's comment (cursor on her body line) is refused before any prompt
panel_key(alice_row + 1, "dd")
assert(#confirm_prompts == 0, "delete prompted for someone else's comment")
assert(notified("own comments"), "panel delete did not refuse someone else's comment")

-- dd on your own comment, declined: nothing is sent
panel_key(adrian_row, "dd")
assert(#confirm_prompts == 1, "delete was not confirmed first")
assert(confirm_prompts[1]:find("Renamed in the next push", 1, true), "delete prompt did not show the body")
assert(not confirm_prompts[1]:find("second line", 1, true), "delete prompt showed more than the first line")
-- a write is async, so give one the chance to land before calling it absent
vim.wait(300, function()
  return gh_calls("DELETE") > 0
end, 20)
assert(gh_calls("DELETE") == 0, "declined delete still called gh")

-- e opens the draft prefilled with your comment; declining posts nothing
panel_key(adrian_row, "e")
local composer_buf
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_get_name(buf):find("review-mode://edit", 1, true) then
    composer_buf = buf
  end
end
assert(composer_buf, "e did not open the edit composer")
vim.cmd("stopinsert")
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(composer_buf, 0, -1, false), { "Renamed in the next push", "second line" }),
  "edit composer was not prefilled with the comment body"
)
vim.api.nvim_buf_set_lines(composer_buf, 0, -1, false, { "Renamed in #42" })
confirm_answer = 2
pr.composer_submit()
vim.wait(300, function()
  return gh_calls("PATCH") > 0
end, 20)
assert(gh_calls("PATCH") == 0, "declined edit still called gh")

-- confirmed: PATCH with the new body, then a reload and the hook
local fetches = gh_calls("graphql reviewThreads")
confirm_answer = 1
pr.composer_submit()
wait_for(function()
  return notified("Edited PR comment")
end, "confirmed edit did not report success")
assert(
  gh_calls("--method PATCH repos/owner/repo/pulls/comments/11 -f body=Renamed in #42") == 1,
  "edit did not PATCH the comment with the new body"
)
wait_for(function()
  return gh_calls("graphql reviewThreads") > fetches and settled()
end, "edit did not reload comments")
assert(vim.deep_equal(events[1], { "comment_edited", 11 }), "comment_edited did not fire")

-- confirmed delete: the empty 204 body is a success, not a JSON error
fetches = gh_calls("graphql reviewThreads")
panel_key(adrian_row, "dd")
wait_for(function()
  return notified("Deleted PR comment") or notified("delete failed")
end, "confirmed delete did not finish")
assert(notified("Deleted PR comment"), "delete with an empty 204 body was reported as a failure")
assert(gh_calls("--method DELETE repos/owner/repo/pulls/comments/11") == 1, "delete did not send DELETE")
wait_for(function()
  return gh_calls("graphql reviewThreads") > fetches and settled()
end, "delete did not reload comments")
assert(vim.deep_equal(events[2], { "comment_deleted", 11 }), "comment_deleted did not fire")
pr.close_panel()

-- the command picks your comment on the current line
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("ReviewModeEditComment")
assert(
  vim.api.nvim_buf_get_name(0):find("review-mode://edit", 1, true),
  ":ReviewModeEditComment did not open the composer"
)
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "Renamed in the next push", "command edited the wrong comment")
vim.cmd("stopinsert")
vim.api.nvim_win_close(0, true)

-- REST-loaded comments carry no authorship: refuse rather than guess
for _, comment in ipairs(api.unstable_state().comments["file.txt"]) do
  comment.viewer_did_author = nil
end
refused_err = nil
api.edit_comment({ comment_id = 11, body = "x" }, function(_, err)
  refused_err = err
end)
assert(refused_err and refused_err:find("REST fallback", 1, true), "REST-loaded comment was not refused")

pr.stop()
