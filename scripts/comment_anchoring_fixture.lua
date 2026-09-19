-- fixture: gh pr REVIEW_MODE_THREADS_FILE={tmp}/threads.json REVIEW_MODE_GH_LOG={tmp}/gh.log REVIEW_MODE_AUTHOR_LOG={tmp}/gh.log
-- Where review threads anchor, and which thread a line action lands on:
-- replies to the thread's first comment, forced reloads that arrive mid-load,
-- threads past the end of the buffer, outdated and base-side (LEFT) threads,
-- resolved threads on a line, synthetic ids, suggestion fences and CRLF bodies,
-- long threads, and unresolved counts by thread.
local harness = dofile(os.getenv("REVIEW_MODE_PLUGIN_ROOT") .. "/scripts/lib/prelude.lua")
local gh_log = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")
local threads_file = assert(os.getenv("REVIEW_MODE_THREADS_FILE"), "REVIEW_MODE_THREADS_FILE is required")

local wait_for = harness.wait_for

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

local confirm_answer = 1
vim.fn.confirm = function()
  return confirm_answer
end
local inputs = 0
vim.ui.input = function()
  inputs = inputs + 1
end

-- The payload -----------------------------------------------------------------

local function comment(id, author, body, extra)
  return vim.tbl_extend("force", {
    id = "comment_" .. id,
    databaseId = id,
    body = body,
    author = { login = author },
    createdAt = "2024-01-02T03:04:05Z",
    url = "https://github.com/owner/repo/pull/123#discussion_r" .. id,
    state = "SUBMITTED",
    authorAssociation = "NONE",
    viewerDidAuthor = false,
    reactionGroups = {},
  }, extra or {})
end

-- extra.more is the cursor of a further page of comments
local function thread(id, path, line, comments, extra)
  extra = extra or {}
  local more = extra.more
  extra.more = nil
  return vim.tbl_extend("force", {
    id = id,
    path = path,
    line = line,
    originalLine = line,
    diffSide = "RIGHT",
    isResolved = false,
    isOutdated = false,
    comments = { pageInfo = { hasNextPage = more ~= nil, endCursor = more }, nodes = comments },
  }, extra)
end

-- file.txt on the feature branch has 10 lines: one, two, "", base changed,
-- same1..same5, tail
local payload = {
  data = {
    repository = {
      pullRequest = {
        reviewThreads = {
          pageInfo = { hasNextPage = false },
          nodes = {
            -- a conversation: the reply must go to 41, the first comment
            thread("thread_a", "file.txt", 2, {
              comment(41, "alice", "Please rename this"),
              comment(11, "adrian", "Renamed", { viewerDidAuthor = true }),
            }, { more = "cur1" }),
            -- outdated: GitHub has dropped the live lines
            thread("thread_b", "file.txt", nil, {
              comment(51, "alice", "```suggestion\nnew five\n```", { originalLine = 5, originalStartLine = 4 }),
            }, { originalLine = 5, originalStartLine = 4, isOutdated = true }),
            -- on a deleted line: 6 numbers the base file
            thread("thread_c", "file.txt", 6, {
              comment(61, "alice", "```suggestion\nbase side\n```"),
            }, { diffSide = "LEFT" }),
            -- past the end of the buffer
            thread("thread_d", "file.txt", 50, {
              comment(71, "alice", "```suggestion\nbeyond\n```"),
            }),
            thread("thread_e", "file.txt", 8, { comment(81, "alice", "Plain note") }),
            -- CRLF, and a four-backtick fence holding a ``` line
            thread("thread_g", "file.txt", 9, {
              comment(91, "alice", "Use this\r\n\r\n````suggestion\r\nsame5 fixed\r\n```\r\ninner\r\n````"),
            }),
            -- the only thread in its file, and resolved
            thread("thread_f", "nested/other.txt", 2, {
              comment(95, "alice", "```suggestion\n-- settled\n```"),
            }, { isResolved = true }),
          },
        },
      },
    },
  },
}
vim.fn.writefile({ vim.json.encode(payload) }, threads_file)
vim.fn.writefile({
  vim.json.encode({
    data = {
      node = {
        comments = { pageInfo = { hasNextPage = false }, nodes = { comment(43, "bob", "Third comment") } },
      },
    },
  }),
}, threads_file .. ".page")

-- Unit: the comment model ---------------------------------------------------------

local comments_ui = require("review_mode.comments")

-- REST fallback: a reply names its parent, and both land in one thread
local rest = {
  comments_ui.normalize_rest({ id = 200, path = "file.txt", line = 2, body = "parent", user = { login = "a" } }),
  comments_ui.normalize_rest({
    id = 201,
    in_reply_to_id = 200,
    path = "file.txt",
    line = 2,
    body = "reply",
    user = { login = "b" },
  }),
}
local rest_threads = comments_ui.threads(rest, "file.txt")
assert(#rest_threads == 1, "REST fallback did not group a reply with its parent")
assert(#rest_threads[1].comments == 2, "REST fallback thread lost a comment")

-- fences: tildes, indentation, and a longer fence holding a shorter one
assert(
  vim.deep_equal(comments_ui.suggestion_body({ body = "~~~suggestion\nx\n~~~" }), { "x" }),
  "a ~~~ suggestion fence was not recognized"
)
assert(
  vim.deep_equal(comments_ui.suggestion_body({ body = "  ```suggestion\nx\n  ```" }), { "x" }),
  "an indented suggestion fence was not recognized"
)
assert(
  vim.deep_equal(comments_ui.suggestion_body({ body = "````suggestion\na\n```\nb\n````" }), { "a", "```", "b" }),
  "a ```` suggestion did not keep its inner ``` line"
)
-- CRLF bodies carry no "\r" into the suggested lines
assert(
  vim.deep_equal(comments_ui.suggestion_body({ body = "```suggestion\r\nx\r\n```" }), { "x" }),
  "a CRLF suggestion kept its carriage returns"
)

-- The session -------------------------------------------------------------------

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local function settled()
  return not api.unstable_state().comments_loading
end

local function find_thread(path, id)
  for _, candidate in ipairs(api.threads({ path = path, include_resolved = true })) do
    if candidate.id == id then
      return candidate
    end
  end
  return nil
end

pr.start()
wait_for(function()
  return find_thread("file.txt", "thread_a") ~= nil and settled()
end, "anchoring fixture comments did not load")

-- a thread longer than the first page of comments is fetched whole
local thread_a = find_thread("file.txt", "thread_a")
assert(#thread_a.comments == 3, "a thread's comments past the first page were not fetched")
assert(gh_calls("after=cur1") == 1, "the second page of a thread's comments was not asked for")

-- unresolved counts are threads: thread_a's three comments are one
assert(api.unresolved_count("file.txt") == 6, "unresolved_count counted comments, not threads")

-- outdated: the live line is gone; the original range is kept apart from it
local thread_b = find_thread("file.txt", "thread_b")
assert(thread_b.is_outdated, "outdated thread not marked outdated")
assert(thread_b.original_line == 5 and thread_b.original_start_line == 4, "outdated thread lost its original range")

-- signs --------------------------------------------------------------------------
-- opening the file annotates it (BufReadPost/BufEnter), which must survive a
-- thread past the end of the buffer
local annotated, annotate_err = pcall(vim.cmd.edit, "file.txt")
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_get_namespaces()["review_mode_normal"]
assert(annotated, "annotating a buffer with a thread past its end failed: " .. tostring(annotate_err))

local sign_rows = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].sign_text and mark[4].priority == 160 then
    sign_rows[mark[2] + 1] = true
  end
end
assert(sign_rows[2] and sign_rows[8] and sign_rows[9], "an in-range thread lost its sign")
-- a comment on a deleted line numbers the base file, not this one
assert(not sign_rows[6], "a base-side (LEFT) thread was signed on the new file's line")
assert(#api.threads_at("file.txt", 6) == 0, "a base-side (LEFT) thread was found on the new file's line")

-- the panel still lists it, marked as on the base side
local rendered = table.concat(api.render_threads({ find_thread("file.txt", "thread_c") }, { width = 60 }), "\n")
assert(rendered:find("file.txt:6 (base)", 1, true), "the panel did not mark a base-side thread")

-- author mode never offers a base-side thread as "fixed"
local author = require("review_mode.author")
assert(#author.touched_threads({ ["file.txt"] = { { 6, 6 } } }) == 0, "author mode matched a base-side thread")
assert(#author.touched_threads({ ["file.txt"] = { { 8, 8 } } }) == 1, "author mode missed a touched thread")

-- suggestions --------------------------------------------------------------------
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local trial, err = api.accept_suggestion(thread_b, { buf = buf })
assert(not trial and tostring(err):find("outdated", 1, true), "an outdated suggestion was accepted")
local shown, preview_err = api.preview_suggestion(thread_b, { buf = buf })
assert(shown == nil and tostring(preview_err):find("outdated", 1, true), "an outdated suggestion was previewed")
trial, err = api.accept_suggestion(find_thread("file.txt", "thread_c"), { buf = buf })
assert(not trial and tostring(err):find("base side", 1, true), "a base-side suggestion was accepted")
trial, err = api.accept_suggestion(find_thread("file.txt", "thread_d"), { buf = buf })
assert(not trial and tostring(err):find("anchored to line 50", 1, true), "a suggestion past the end was accepted")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before), "a refused suggestion changed the buffer")

local listed = {}
for _, entry in ipairs(api.suggestions("file.txt")) do
  listed[entry.id] = true
end
assert(not listed.thread_b and not listed.thread_c, "suggestions listed an outdated or base-side thread")

-- the CRLF, four-backtick suggestion goes in as three clean lines
trial = assert(api.accept_suggestion(find_thread("file.txt", "thread_g"), { buf = buf }))
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 8, 11, false), { "same5 fixed", "```", "inner" }),
  "the ```` suggestion was not applied whole"
)
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  assert(not line:find("\r", 1, true), "an accepted suggestion carried a carriage return")
end
assert(api.revert_suggestion(trial.id), "trial did not revert")

-- a resolved-only file: its threads are resolved, so there is nothing to accept
assert(#api.threads({ path = "nested/other.txt" }) == 0, "api.threads returned resolved threads unasked")
assert(#api.suggestions("nested/other.txt") == 0, "suggestions listed a resolved thread")
assert(#api.threads({ path = "nested/other.txt", include_resolved = true }) == 1, "the resolved thread is gone")

-- synthetic ids are never sent to GitHub ---------------------------------------
local refused
api.resolve("pending:1", true, function(ok, resolve_err)
  refused = not ok and resolve_err
end)
assert(refused, "resolving a pending thread was not refused")
api.resolve("sending:1", true)
vim.wait(200, function()
  return gh_calls("threadId=pending:") + gh_calls("threadId=sending:") > 0
end, 20)
assert(gh_calls("threadId=pending:") + gh_calls("threadId=sending:") == 0, "a synthetic thread id was sent to GitHub")

-- replies go to the thread's first comment ----------------------------------------
local replied
api.reply({ thread_id = "thread_a", body = "api reply" }, function(ok)
  replied = ok
end)
wait_for(function()
  return replied ~= nil
end, "api reply did not finish")
assert(
  gh_calls("comments/41/replies --method POST -f body=api reply") == 1,
  "api reply did not go to the first comment"
)

replied = nil
api.reply({ comment_id = 43, body = "reply by comment" }, function(ok)
  replied = ok
end)
wait_for(function()
  return replied ~= nil
end, "reply by comment id did not finish")
assert(
  gh_calls("comments/41/replies --method POST -f body=reply by comment") == 1,
  "a reply naming a later comment did not go to the first"
)

local function composer()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    local kind = name:match("review%-mode://(%a+)$")
    if kind and kind ~= "suggestion" then
      return vim.api.nvim_win_get_buf(win), kind, win
    end
  end
  return nil
end

wait_for(settled, "reload after the replies did not finish")
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.reply()
local reply_buf, kind = composer()
assert(reply_buf and kind == "reply", "the panel reply did not open")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(reply_buf, 0, -1, false, { "panel reply" })
confirm_answer = 1
pr.composer_submit()
wait_for(function()
  return notified("Submitted PR thread reply") or notified("reply failed")
end, "panel reply did not finish")
assert(
  gh_calls("comments/41/replies --method POST -f body=panel reply") == 1,
  "panel reply did not go to the first comment"
)

-- after a delete, the panel has no comment under its cursor ------------------------
wait_for(settled, "reload after the panel reply did not finish")
vim.cmd("only")
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.open_panel()
local panel_win = pr.panel_win()
local panel_buf = vim.api.nvim_win_get_buf(panel_win)
local own_row
wait_for(function()
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:find("adrian", 1, true) then
      own_row = index
    end
  end
  return own_row
end, "the panel did not render your comment")
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { own_row, 0 })
confirm_answer = 1
vim.cmd("normal dd")
notifications = {}
vim.cmd("normal e")
assert(not composer(), "edit after a delete opened a draft for another comment")
assert(notified("no PR comment here"), "edit after a delete did not say there is no comment")
wait_for(function()
  return notified("Deleted PR comment") and settled()
end, "delete did not finish")
pr.close_panel()

-- a resolved thread on a line is still the thread on that line --------------------
vim.cmd("only")
vim.cmd.edit("nested/other.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.comment_or_reply()
reply_buf, kind = composer()
assert(reply_buf and kind == "reply", "comment_or_reply on a resolved thread did not reply to it")
confirm_answer = 1
pr.composer_cancel()
vim.cmd("only")
vim.cmd.edit("nested/other.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.toggle_resolve()
wait_for(function()
  return gh_calls("threadId=thread_f") > 0
end, "x on a resolved thread did not unresolve it")
assert(gh_calls("unresolveReviewThread") == 1, "x on a resolved thread did not unresolve it")

-- the composer finds a ```` or indented suggestion block --------------------------
wait_for(settled, "reload after unresolving did not finish")
vim.cmd("only")
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 10, 0 })
pr.compose_comment({ range = 0 })
local draft_buf, _, draft_win = composer()
assert(draft_buf, "the comment composer did not open")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(draft_buf, 0, -1, false, { "msg", "````suggestion", "a", "```", "b", "````" })
vim.api.nvim_set_current_win(draft_win)
pr.composer_suggest()
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "a", "```", "b" }),
  "the composer did not find the ```` suggestion block"
)
vim.cmd("write")
assert(
  vim.deep_equal(
    vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false),
    { "msg", "````suggestion", "a", "```", "b", "````" }
  ),
  "writing the suggestion back broke its fence"
)
confirm_answer = 1
pr.composer_cancel()

-- :ReviewModeSuggest drafts in the panel even with compose = "prompt" -----------
vim.cmd("only")
api.unstable_state().config.comments.compose = "prompt"
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 10, 0 })
pr.suggest({ range = 0 })
assert(inputs == 0, "a suggestion went to the one-line prompt")
assert(
  vim.api.nvim_buf_get_name(0):find("review-mode://suggestion-code", 1, true),
  "the suggestion editor did not open"
)
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "tail" }),
  "the suggestion did not start from the line"
)
vim.cmd("normal q")
confirm_answer = 1
pr.composer_cancel()

-- a forced reload that arrives mid-load is not dropped ------------------------------
wait_for(settled, "comments did not settle before the reload test")
local fetches = gh_calls("graphql reviewThreads")
api.reload_comments()
api.reload_comments()
wait_for(function()
  return gh_calls("graphql reviewThreads") >= fetches + 2 and settled()
end, "a forced reload during a running load was dropped")
assert(not api.unstable_state().comments_reload_queued, "a queued reload was left behind")

pr.stop()
harness.done()
