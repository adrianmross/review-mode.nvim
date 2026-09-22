-- fixture: gh pr REVIEW_MODE_FIXTURE=conversation REVIEW_MODE_GH_LOG={tmp}/gh.log
-- fixture: REVIEW_MODE_FIXTURE=conversation_local
--
-- The PR conversation: issue comments (paginated) and submitted review bodies
-- with their state, in the panel's conversation view, plus a reply that only
-- posts once it is confirmed. The second run is a local review, which has no
-- conversation and must not reach a forge for one.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for
local log_path = os.getenv("REVIEW_MODE_GH_LOG")

-- Wrap before the plugin loads: init.lua keeps its own reference to these.
local util = require("review_mode.util")
local forge_calls = {}
for _, name in ipairs({ "system", "system_async" }) do
  local original = util[name]
  util[name] = function(args, ...)
    if type(args) == "table" and (args[1] == "gh" or args[1] == "glab") then
      forge_calls[#forge_calls + 1] = table.concat(args, " ")
    end
    return original(args, ...)
  end
end

local function gh_log()
  local file = log_path and io.open(log_path, "r")
  if not file then
    return {}
  end
  local lines = vim.split(file:read("*a"), "\n", { trimempty = true })
  file:close()
  return lines
end

local function log_matching(pattern)
  local hits = {}
  for _, line in ipairs(gh_log()) do
    if line:match(pattern) then
      hits[#hits + 1] = line
    end
  end
  return hits
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
  provider = os.getenv("REVIEW_MODE_FIXTURE") == "conversation_local" and "local" or "auto",
})

-- A local review: no conversation, no error, no forge call ----------------------

if os.getenv("REVIEW_MODE_FIXTURE") == "conversation_local" then
  pr.review_local({})
  wait_for(function()
    return api.is_active() and api.is_changed_file("file.txt")
  end, "local review did not load its changed files")

  assert(api.session().provider == "local", "the local run is not a local review")
  assert(vim.deep_equal(api.conversation(), {}), "a local review should have an empty conversation")
  -- the load is async elsewhere, so give it the chance to do the wrong thing
  vim.wait(200)
  assert(vim.deep_equal(api.conversation(), {}), "a local review filled its conversation from somewhere")
  assert(#forge_calls == 0, "a local review reached a forge: " .. vim.inspect(forge_calls))

  panel.open_panel()
  wait_for(function()
    return panel.panel_is_open()
  end, "panel did not open in the local review")
  local panel_buf = vim.api.nvim_win_get_buf(panel.panel_win())
  vim.api.nvim_set_current_win(panel.panel_win())
  assert(vim.fn.maparg("c", "n", false, true).callback, "the panel has no c mapping")()
  local text = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
  assert(text:match("local review has no PR conversation"), "local conversation view: " .. text)
  assert(#forge_calls == 0, "the conversation view reached a forge: " .. vim.inspect(forge_calls))

  pr.stop()
  harness.done()
  return
end

-- The GitHub run ----------------------------------------------------------------

local loaded = {}
api.on("conversation_loaded", function(data)
  loaded[#loaded + 1] = data
end)

pr.start()
wait_for(function()
  return api.is_active() and api.comment_count("file.txt") > 0
end, "the PR session did not load")

-- api.conversation() starts the load and the event says when it is there
assert(vim.deep_equal(api.conversation(), {}), "the conversation should not be loaded synchronously")
wait_for(function()
  return #api.conversation() == 3
end, "the conversation did not load its three entries")
assert(#loaded == 1 and loaded[1].count == 3, "conversation_loaded: " .. vim.inspect(loaded))

-- Pagination: the Link header's second page holds the last comment
local pages = log_matching("issues/123/comments")
assert(#pages == 2, "expected two conversation page requests, got " .. vim.inspect(pages))
assert(pages[1]:match("per_page=100") and not pages[1]:match("page=2"), vim.inspect(pages))
assert(pages[2]:match("page=2"), "the second page was not fetched: " .. vim.inspect(pages))

-- Time order, across both sources: comment, review, comment from page two
local entries = api.conversation()
assert(entries[1].id == 201 and entries[1].kind == "comment", vim.inspect(entries[1]))
assert(entries[2].kind == "review" and entries[2].id == 301, vim.inspect(entries[2]))
assert(entries[2].review_state == "APPROVED", "the review body lost its state: " .. vim.inspect(entries[2]))
assert(entries[2].author == "carol" and entries[2].body:match("one question about the cache"), vim.inspect(entries[2]))
assert(entries[3].id == 202 and entries[3].author == "bob", "page two is missing: " .. vim.inspect(entries[3]))
-- a review with an empty body said nothing beyond its verdict
for _, entry in ipairs(entries) do
  assert(entry.id ~= 302, "a review with an empty body was kept")
end
-- reactions come through in the shape the renderer draws
assert(entries[1].reactions and entries[1].reactions[1].content == "THUMBS_UP", vim.inspect(entries[1].reactions))

-- The panel's conversation view --------------------------------------------------

vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
panel.open_panel()
wait_for(function()
  return panel.panel_is_open()
end, "panel did not open")
local panel_win = panel.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
end

assert(not panel_text():match("Conversation"), "the panel opened on the conversation instead of the threads")
vim.api.nvim_set_current_win(panel_win)
local toggle = assert(vim.fn.maparg("c", "n", false, true).callback, "the panel has no c mapping")
toggle()

local text = panel_text()
assert(text:match("── Conversation"), "no conversation header: " .. text)
assert(text:match("Why this approach%?"), "the first issue comment is missing: " .. text)
assert(text:match("And the second page holds this one"), "page two did not render: " .. text)
assert(text:match("one question about the cache"), "the review body did not render: " .. text)
-- the same author/time/reaction styling threads get, plus the review's verdict
assert(text:match(" carol  owner · approved · "), "the review's state did not render: " .. text)
assert(text:match(" alice  member · "), "an issue comment lost its author styling: " .. text)
assert(text:match("👍 2"), "reactions did not render: " .. text)
assert(text:match("r comment · c back to threads"), "the conversation hint is missing: " .. text)

-- c goes back to the threads
toggle()
assert(not panel_text():match("── Conversation"), "c did not toggle back to the threads")
toggle()

-- Reloading ------------------------------------------------------------------------

local function page_requests()
  return #log_matching("issues/123/comments%?")
end

-- <C-l> reloads whichever view is showing: the conversation is fetched apart
-- from the threads, so reloading comments would leave it as it was
local before, rounds = page_requests(), #loaded
vim.api.nvim_set_current_win(panel_win)
assert(vim.fn.maparg("<C-l>", "n", false, true).callback, "the panel has no <C-l> mapping")()
wait_for(function()
  return #loaded == rounds + 1
end, "<C-l> in the conversation view did not refetch the conversation")
assert(page_requests() == before + 2, "<C-l> did not walk the conversation's pages: " .. vim.inspect(gh_log()))

-- A forced reload issued while one is in flight is not dropped: the running
-- load cannot hold what forced the second one, so it runs again.
before, rounds = page_requests(), #loaded
api.reload_conversation()
api.reload_conversation()
wait_for(function()
  return #loaded == rounds + 1
end, "the first forced reload never finished")
wait_for(function()
  return page_requests() == before + 4
end, "a forced reload issued mid-flight was dropped: " .. vim.inspect(gh_log()))
assert(#api.conversation() == 3, "the queued reload lost the conversation")

-- Replying ------------------------------------------------------------------------

local function posts()
  return log_matching("POST repos/owner/repo/issues/123/comments")
end
assert(#posts() == 0, "something posted before the reply")

local answer = 2
vim.fn.confirm = function()
  return answer
end
local notifications = {}
local notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local function draft(body)
  vim.api.nvim_set_current_win(panel_win)
  assert(vim.fn.maparg("r", "n", false, true).callback, "the panel has no r mapping")()
  local composer = vim.api.nvim_get_current_buf()
  assert(
    vim.api.nvim_buf_get_name(composer):match("review%-mode://conversation"),
    "r did not open the conversation draft"
  )
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, vim.split(body, "\n"))
  vim.cmd("stopinsert")
  panel.composer_submit()
end

-- declining the confirmation posts nothing and keeps the draft
draft("Answering in the conversation")
vim.wait(200)
assert(#posts() == 0, "a declined confirmation still posted: " .. vim.inspect(gh_log()))

answer = 1
rounds = #loaded
panel.composer_submit()
wait_for(function()
  return #posts() == 1
end, "the confirmed reply never reached the issues endpoint")
local post = posts()[1]
assert(post:match("body=Answering in the conversation"), "the body did not reach gh: " .. post)
assert(not post:match("pulls/123"), "the reply went to the pulls endpoint: " .. post)
wait_for(function()
  return #notifications > 0 and notifications[#notifications]:match("Posted a comment on the PR conversation")
end, "no confirmation notification: " .. vim.inspect(notifications))

-- the post refreshes the conversation
wait_for(function()
  return #loaded > rounds
end, "the post did not reload the conversation")

vim.notify = notify
pr.stop()
harness.done()
