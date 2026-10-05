-- fixture: gh pr REVIEW_MODE_AUTHOR_LOG={tmp}/author.log
-- Author mode: stepping through unresolved threads, offering to resolve the
-- threads a mid-review commit touched, and re-requesting review. Runs in its
-- own copy of the repo, since it commits. The gh mock answers the author query
-- with viewerDidAuthor only when REVIEW_MODE_AUTHOR=1, and writes every reply,
-- resolve, people query and re-request to REVIEW_MODE_AUTHOR_LOG.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local log_path = assert(os.getenv("REVIEW_MODE_AUTHOR_LOG"), "REVIEW_MODE_AUTHOR_LOG is required")

local wait_for = harness.wait_for

vim.notify = function() end

local function read_log()
  local file = io.open(log_path, "r")
  if not file then
    return ""
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

-- every confirmation is recorded and answered with `answer`
local prompts, answer = {}, 2
vim.fn.confirm = function(message)
  prompts[#prompts + 1] = message
  return answer
end

local pr = require("review_mode")
local api = require("review_mode.api")
local util = require("review_mode.util")
local state = require("review_mode.state").state
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})
assert(api.config().author.offer_resolve == true, "author.offer_resolve is not on by default")

local moves, last_move = 0, nil
api.on("head_moved", function(ctx)
  moves, last_move = moves + 1, ctx
end)

local function start()
  pr.start()
  wait_for(function()
    return api.comment_count("file.txt") == 3
      and not api.unstable_state().comments_loading
      and api.is_changed_file("nested/other.txt")
  end, "author fixture comments and changed files did not load")
  wait_for(function()
    return state.head_log_stamp ~= nil
  end, "follow-HEAD watcher did not record its reflog baseline")
end

local function git(...)
  local result = vim.system({ "git", ... }, { text = true }):wait()
  assert(result.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. result.stderr)
  return vim.trim(result.stdout)
end

-- One commit per argument, each rewriting the given rows of each file, then
-- follow them all at once. Rows are replaced, never added, so every thread
-- keeps its line.
local round = 0
local function commit_and_follow(...)
  local from = git("rev-parse", "HEAD")
  for _, files in ipairs({ ... }) do
    round = round + 1
    for path, rows in pairs(files) do
      local lines = vim.fn.readfile(path)
      for _, row in ipairs(rows) do
        lines[row] = lines[row] .. " r" .. round
      end
      vim.fn.writefile(lines, path)
      git("add", path)
    end
    git("commit", "-q", "-m", "round " .. round)
  end
  local to = git("rev-parse", "HEAD")
  local before = moves
  wait_for(function()
    vim.api.nvim_exec_autocmds("FocusGained", {})
    return moves > before
  end, "head_moved did not fire for round " .. round)
  assert(
    last_move.from == from and last_move.to == to,
    "head_moved reported the wrong range: " .. vim.inspect(last_move)
  )
  return to
end

local function at()
  return string.format("%s:%d", util.current_relpath(), vim.api.nvim_win_get_cursor(0)[1])
end

start()

-- Worklist ------------------------------------------------------------------------
-- thread_1 (file.txt:2) and thread_3 (nested/other.txt:2) are unresolved;
-- thread_2 (file.txt:4) is resolved and must be stepped over.
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_unresolved()
assert(at() == "file.txt:2", "next unresolved from the top went to " .. at())
pr.next_comment()
assert(at() == "file.txt:4", "]r should still stop at the resolved thread, went to " .. at())
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.next_unresolved()
assert(at() == "nested/other.txt:2", "next unresolved did not cross files past the resolved thread: " .. at())
pr.next_unresolved()
assert(at() == "file.txt:2", "next unresolved did not wrap: " .. at())
api.goto_prev("unresolved")
assert(at() == "nested/other.txt:2", "api.goto_prev('unresolved') went to " .. at())
vim.cmd("ReviewModeNextUnresolved")
assert(at() == "file.txt:2", ":ReviewModeNextUnresolved went to " .. at())

local labels = {}
local items = pr.action_items()
for _, item in ipairs(items) do
  labels[item.label] = true
end
assert(labels["Next unresolved thread"] and labels["Previous unresolved thread"], "worklist actions are missing")
assert(labels["Re-request review from past reviewers"], "re-request action is missing")
assert(items[#items].label == "Summary", "Summary is no longer the last action")

-- Not the author: a commit on a thread's line offers nothing ------------------------
commit_and_follow({ ["file.txt"] = { 2 } })
wait_for(function()
  return has(read_log(), "people")
end, "authorship was never asked")
vim.wait(300)
assert(#prompts == 0, "offered to resolve threads on a PR the viewer did not write")
assert(not has(read_log(), "reply "), "replied on a PR the viewer did not write")

-- The author, declining: the offer names only the touched unresolved thread -------
pr.stop()
vim.env.REVIEW_MODE_AUTHOR = "1"
start()
local sha = commit_and_follow({ ["file.txt"] = { 2, 4 } })
wait_for(function()
  return #prompts == 1
end, "the author was not offered to resolve the thread the commit touched")
local prompt = prompts[1]
assert(has(prompt, "Fixed in `" .. sha:sub(1, 7) .. "`"), "the offer does not name the commit: " .. prompt)
assert(has(prompt, "file.txt:2"), "the offer does not list the touched thread: " .. prompt)
assert(not has(prompt, "file.txt:4"), "the offer lists a resolved thread: " .. prompt)
assert(not has(prompt, "nested/other.txt"), "the offer lists a thread the commit did not touch: " .. prompt)
vim.wait(300)
assert(not has(read_log(), "reply ") and not has(read_log(), "resolve "), "declining still wrote to the PR")

-- a commit elsewhere in a file with a thread does not touch the thread
commit_and_follow({ ["file.txt"] = { 8 } })
vim.wait(300)
assert(#prompts == 1, "offered a thread whose lines the commit did not change: " .. tostring(prompts[2]))

-- The author, accepting: every touched thread gets the reply, then is resolved.
-- Two commits land before HEAD is looked at, so the range spans both.
answer = 1
sha = commit_and_follow({ ["nested/other.txt"] = { 2 } }, { ["file.txt"] = { 2 } })
wait_for(function()
  local text = read_log()
  return has(text, "threadId=thread_1") and has(text, "threadId=thread_3")
end, "accepting did not resolve both touched threads: " .. read_log())
assert(#prompts == 2, "expected one confirmation for the commit, got " .. #prompts - 1)
local body = "body=Fixed in `" .. sha:sub(1, 7) .. "`"
local text = read_log()
assert(has(text, "comments/1/replies --method POST -f " .. body), "thread_1 did not get the reply: " .. text)
assert(has(text, "comments/3/replies --method POST -f " .. body), "thread_3 did not get the reply: " .. text)
assert(not has(text, "comments/2/replies"), "the resolved thread got a reply: " .. text)

-- Moving HEAD back is not a fix: no offer ------------------------------------------
git("reset", "-q", "--hard", "HEAD~1")
local before = moves
wait_for(function()
  vim.api.nvim_exec_autocmds("FocusGained", {})
  return moves > before
end, "head_moved did not fire for the reset")
vim.wait(300)
assert(#prompts == 2, "a reset was offered as a fix")

-- Switched off: no offer ------------------------------------------------------------
api.config().author.offer_resolve = false
commit_and_follow({ ["file.txt"] = { 2 } })
vim.wait(300)
assert(#prompts == 2, "author.offer_resolve = false still offered")
api.config().author.offer_resolve = true

-- Re-request review ------------------------------------------------------------------
local author = require("review_mode.author")
local result = nil
answer = 2
author.rerequest(function(ok, err)
  result = { ok, err }
end)
wait_for(function()
  return result ~= nil
end, "declined re-request never finished")
prompt = prompts[#prompts]
assert(result[1] == false and result[2] == "cancelled", "declined re-request: " .. vim.inspect(result))
assert(has(prompt, "alice, bob"), "the re-request does not name the reviewers once each: " .. prompt)
assert(not has(prompt, "adrian") and not has(prompt, "ci-bot"), "the re-request names the author or a bot: " .. prompt)
assert(not has(read_log(), "rerequest"), "a declined re-request still posted")

answer, result = 1, nil
author.rerequest(function(ok, err)
  result = { ok, err }
end)
wait_for(function()
  return result ~= nil
end, "re-request never finished")
assert(result[1] == true, "re-request failed: " .. vim.inspect(result))
text = read_log()
assert(
  has(text, "requested_reviewers -f reviewers[]=alice -f reviewers[]=bob\n"),
  "re-request did not post exactly alice and bob: " .. text
)

pr.stop()
print("author fixture passed")
harness.done()
vim.cmd("qa!")
