-- fixture: gh pr REVIEW_MODE_FIXTURE=reactions REVIEW_MODE_GH_LOG={tmp}/gh.log
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local log_path = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

local wait_for = harness.wait_for

-- the fake gh appends one line per reaction write
local function gh_log()
  local file = io.open(log_path, "r")
  if not file then
    return {}
  end
  local lines = vim.split(file:read("*a"), "\n", { trimempty = true })
  file:close()
  return lines
end

local pr = require("review_mode")
local api = require("review_mode.api")
local panel = require("review_mode.panel")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local changes = {}
api.on("reaction_changed", function(data)
  changes[#changes + 1] = data
end)

local function react(opts)
  local result
  api.react(opts, function(ok, err)
    result = { ok = ok, err = err }
  end)
  wait_for(function()
    return result ~= nil
  end, "api.react never called back")
  return result
end

pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 2
end, "reaction fixture comments did not load")

local thread = api.threads({ path = "file.txt", line = 2 })[1]
assert(thread and #thread.comments == 2, "expected a two-comment thread")
local first, second = thread.comments[1], thread.comments[2]
assert(first.node_id == "comment_1" and second.node_id == "comment_5", "thread comments lost their node ids")
assert(#api.reaction_contents == 8, "expected eight reaction contents")

-- the viewer's own reaction is highlighted apart from everyone else's
local lines, marks = api.render_threads({ thread }, { width = 80 })
local own, other = {}, {}
for _, mark in ipairs(marks) do
  local text = (lines[mark.row + 1] or ""):sub(mark.col + 1, mark.end_col)
  if mark.hl_group == "ReviewModeReactionOwn" then
    own[#own + 1] = text
  elseif mark.hl_group == "ReviewModeReaction" then
    other[#other + 1] = text
  end
end
assert(#own == 1 and own[1]:match(" 2$"), "own THUMBS_UP should use ReviewModeReactionOwn: " .. vim.inspect(own))
assert(#other == 1 and other[1]:match(" 1$"), "others' HOORAY should use ReviewModeReaction: " .. vim.inspect(other))

-- reacted: toggling removes; not reacted: toggling adds
local result = react({ comment = first, content = "THUMBS_UP" })
assert(result.ok, "remove failed: " .. tostring(result.err))
local log = gh_log()
assert(#log == 1 and log[1]:match("removeReaction") and log[1]:match("subjectId=comment_1"), vim.inspect(log))
assert(log[1]:match("content=THUMBS_UP"), vim.inspect(log))

result = react({ comment = first, content = "HOORAY" })
assert(result.ok, "add failed: " .. tostring(result.err))
log = gh_log()
assert(#log == 2 and log[2]:match("addReaction") and log[2]:match("subjectId=comment_1"), vim.inspect(log))
assert(not log[2]:match("removeReaction"), vim.inspect(log))

assert(#changes == 2, "expected two reaction_changed events")
assert(changes[1].comment_id == 1 and changes[1].content == "THUMBS_UP" and changes[1].added == false)
assert(changes[2].added == true)

-- a comment without a node id (the REST fallback) adds through REST ...
result = react({ comment = { id = 1 }, content = "THUMBS_UP" })
assert(result.ok, "REST add failed: " .. tostring(result.err))
log = gh_log()
assert(#log == 3 and log[3]:match("repos/owner/repo/pulls/comments/1/reactions"), vim.inspect(log))
assert(log[3]:match("--method POST") and log[3]:match("content=%+1"), vim.inspect(log))

-- ... and cannot remove, without ever calling gh
local notify = vim.notify
vim.notify = function() end
result = react({
  comment = { id = 1, reactions = { { content = "THUMBS_UP", count = 1, viewer_has_reacted = true } } },
  content = "THUMBS_UP",
})
vim.notify = notify
assert(result.ok == false and tostring(result.err):match("cannot be removed"), vim.inspect(result))
assert(#gh_log() == 3, "REST removal must not reach gh")

-- panel: + acts on the comment under the cursor, not just the thread's last
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
panel.open_panel()
wait_for(function()
  return panel.panel_is_open()
end, "panel did not open")
local panel_win = panel.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)

local function panel_row(pattern)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:match(pattern) then
      return index
    end
  end
  error("no panel line matches " .. pattern)
end

local ui_select = vim.ui.select
local picked
vim.ui.select = function(items, opts, on_choice)
  picked = { items = items, opts = opts }
  on_choice(items[2])
end
vim.api.nvim_set_current_win(panel_win)
local plus = vim.fn.maparg("+", "n", false, true).callback
assert(plus, "panel has no + mapping")
-- the body line under the first comment's header
vim.api.nvim_win_set_cursor(panel_win, { panel_row("Needs review"), 0 })
plus()
assert(picked.opts.format_item(picked.items[1]):match("yours"), "own reaction should be marked in the picker")
assert(not picked.opts.format_item(picked.items[2]):match("yours"))
wait_for(function()
  return #gh_log() == 4
end, "+ on the first comment did not react")
assert(gh_log()[4]:match("subjectId=comment_1"), vim.inspect(gh_log()))

vim.api.nvim_win_set_cursor(panel_win, { panel_row("Done"), 0 })
plus()
wait_for(function()
  return #gh_log() == 5
end, "+ on the second comment did not react")
assert(gh_log()[5]:match("addReaction") and gh_log()[5]:match("subjectId=comment_5"), vim.inspect(gh_log()))
vim.ui.select = ui_select

pr.stop()
harness.done()
