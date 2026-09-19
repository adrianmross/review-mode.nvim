local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local glab_log = assert(os.getenv("GLAB_LOG"), "GLAB_LOG is required")

local wait_for = harness.wait_for

-- A GitLab review must never fall through to gh. Wrap before the plugin loads,
-- because init.lua keeps its own reference to system_async.
local util = require("review_mode.util")
local gh_calls = {}
local system_async = util.system_async
util.system_async = function(args, opts, callback)
  if args[1] == "gh" then
    gh_calls[#gh_calls + 1] = table.concat(args, " ")
  end
  return system_async(args, opts, callback)
end

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end

local function notified(fragment)
  for _, message in ipairs(notifications) do
    if message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function log_lines()
  return vim.fn.filereadable(glab_log) == 1 and vim.fn.readfile(glab_log) or {}
end

local function logged(fragment)
  for _, line in ipairs(log_lines()) do
    if line:find(fragment, 1, true) then
      return line
    end
  end
  return nil
end

local providers = require("review_mode.providers")

-- detection, unit style
assert(providers.detect("https://gitlab.com/group/project.git") == "gitlab", "https gitlab.com not detected")
assert(providers.detect("git@gitlab.com:group/project.git") == "gitlab", "scp-style gitlab.com not detected")
assert(providers.detect("ssh://git@gitlab.example.com:2222/g/p.git") == "gitlab", "gitlab.* host not detected")
assert(providers.detect("git@github.com:owner/repo.git") == "github", "github.com detected as gitlab")
assert(providers.detect("https://git.corp.test/g/p.git") == "github", "unknown host should stay github")
assert(
  providers.detect("https://git.corp.test/g/p.git", { "git.corp.test" }) == "gitlab",
  "configured gitlab_hosts not honored"
)

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = true, sync = true },
  auto_open_first_change = false,
})

-- the handoff env picks GitLab even when the remote does not say so
vim.env.GL_REVIEW_MR = "7"
assert(providers.select(vim.uv.cwd()) == "gitlab", "GL_REVIEW_MR did not select gitlab")
vim.env.GL_REVIEW_MR = nil

-- auto-detection from the origin remote drives the real session
local original_url = vim.trim(vim.fn.system({ "git", "remote", "get-url", "origin" }))
vim.fn.system({ "git", "remote", "set-url", "origin", "https://gitlab.com/group/project.git" })
assert(providers.select(vim.uv.cwd()) == "gitlab", "gitlab.com origin did not select gitlab")

pr.start()
wait_for(function()
  local session = api.session()
  return session and session.pr == "7" and session.repo == "group/project" and session.base == "main"
end, "merge request metadata did not load through glab")
assert(api.session().provider == "gitlab", "api.session did not report the gitlab provider")
wait_for(function()
  return api.is_changed_file("file.txt")
end, "changed file map did not load for gitlab")

-- discussions become threads
wait_for(function()
  return api.comment_count("file.txt") == 3
end, "MR discussions did not load as comments")
local threads = api.threads({ path = "file.txt", include_resolved = true })
assert(#threads == 2, "expected two diff threads on file.txt, got " .. #threads)
local open_thread, resolved_thread = threads[1], threads[2]
assert(open_thread.id == "disc1" and open_thread.line == 2, "disc1 not anchored to file.txt:2")
assert(not open_thread.is_resolved, "disc1 should be unresolved")
assert(#open_thread.comments == 2, "disc1 lost its reply")
assert(open_thread.comments[1].author == "reviewer", "note author not normalized")
assert(open_thread.comments[2].author == "maintainer", "reply author not normalized")
assert(
  open_thread.comments[1].url == "https://gitlab.com/group/project/-/merge_requests/7#note_11",
  "note url not built from the MR web url"
)
assert(resolved_thread.id == "disc2" and resolved_thread.line == 4, "disc2 not anchored to file.txt:4")
assert(resolved_thread.is_resolved, "disc2 should be resolved from its notes")
assert(#api.threads({ path = "file.txt" }) == 1, "resolved discussion was not hidden by default")
assert(#api.threads({}) == 1, "a non-diff note was placed on a line")

local function run(fn, ...)
  local result
  local args = { ... }
  args[#args + 1] = function(ok, err)
    result = { ok = ok, err = err }
  end
  fn(unpack(args))
  wait_for(function()
    return result ~= nil
  end, "write did not finish")
  assert(result.ok, "write failed: " .. tostring(result.err))
end

local function posted_input()
  local lines = log_lines()
  for index = #lines, 1, -1 do
    local json = lines[index]:match("^INPUT (.+)$")
    if json then
      return vim.json.decode(json)
    end
  end
  return nil
end

-- new thread on an added line: new_line only
run(api.comment, { path = "file.txt", line = 2, body = "On an added line" })
local input = assert(posted_input(), "comment did not post a discussion")
assert(input.body == "On an added line", "comment body not sent")
local position = input.position
assert(position.position_type == "text", "position_type not text")
assert(
  position.base_sha == "basesha" and position.start_sha == "startsha" and position.head_sha == "headsha",
  "position did not carry the MR diff_refs"
)
assert(position.new_path == "file.txt" and position.old_path == "file.txt", "position paths wrong")
assert(position.new_line == 2 and position.old_line == nil, "added line should send new_line only")

-- new thread on an unchanged line: both sides
vim.fn.writefile({}, glab_log)
run(api.comment, { path = "file.txt", line = 6, body = "On a context line" })
position = assert(posted_input(), "context comment did not post").position
assert(position.new_line == 6 and position.old_line == 5, "context line should send new_line 6 and old_line 5")

-- reply by thread id, and by note id
run(api.reply, { thread_id = "disc1", body = "Replying" })
assert(logged("discussions/disc1/notes --raw-field body=Replying"), "reply did not post to the discussion notes")
vim.fn.writefile({}, glab_log)
run(api.reply, { comment_id = 12, body = "By note" })
assert(logged("discussions/disc1/notes --raw-field body=By note"), "reply by note id did not find its discussion")

-- resolve and unresolve
run(api.resolve, "disc1", true)
assert(logged("--method PUT projects/group%2Fproject/merge_requests/7/discussions/disc1 --field resolved=true"))
run(api.resolve, "disc1", false)
assert(logged("--field resolved=false"), "unresolve did not send resolved=false")

-- GitHub-only features fail clearly instead of calling gh
pr.checks()
assert(notified("PR checks is not supported on GitLab yet"), "checks did not report unsupported")
pr.status()
assert(notified("PR status is not supported on GitLab yet"), "status did not report unsupported")
wait_for(function()
  return notified("GitHub viewed-state sync is not supported on GitLab yet")
end, "viewed sync did not report unsupported")
pr.copy_url()
assert(vim.fn.getreg('"') == "https://gitlab.com/group/project/-/merge_requests/7", "copy_url did not use the MR url")

-- and so do the features the GitHub side gained alongside this one
local function unsupported(fn, ...)
  local result
  local args = { ... }
  args[#args + 1] = function(ok, err)
    result = { ok = ok, err = err }
  end
  fn(unpack(args))
  assert(result, "call did not answer its callback")
  assert(not result.ok, "call was not refused")
  assert(tostring(result.err):find("not supported on GitLab yet", 1, true), "wrong refusal: " .. tostring(result.err))
end

local first_comment = api.threads({ path = "file.txt", include_resolved = true })[1].comments[1]
unsupported(api.react, { comment = first_comment, content = "THUMBS_UP" })
unsupported(api.edit_comment, { comment_id = first_comment.id, body = "edited" })
unsupported(api.delete_comment, first_comment.id)
unsupported(api.submit_review, { event = "COMMENT", body = "looks good" })
unsupported(require("review_mode.checkout").prepare, { pr = "7" })

-- so the composer does not offer queueing on GitLab at all
assert(not api.can_add_pending(), "GitLab claims it can queue pending comments")
local draft, draft_err = api.add_pending({ path = "file.txt", line = 2, body = "later" })
assert(not draft, "pending comment was queued on GitLab")
assert(
  tostring(draft_err):find("not supported on GitLab yet", 1, true),
  "wrong pending refusal: " .. tostring(draft_err)
)
assert(#api.pending() == 0, "a pending draft was stored on GitLab")

-- positions are placed on the MR's own diff (start_sha...head_sha) when its
-- commits are here, and a local HEAD elsewhere is warned about
local core = require("review_mode.state")
local main_sha = vim.trim(vim.fn.system({ "git", "rev-parse", "main" }))
core.state.gitlab.diff_refs = { base_sha = main_sha, start_sha = main_sha, head_sha = main_sha }
vim.fn.writefile({}, glab_log)
notifications = {}
run(api.comment, { path = "file.txt", line = 2, body = "Against the MR diff" })
position = assert(posted_input(), "comment on the MR diff did not post").position
assert(
  position.new_line == 2 and position.old_line == 2,
  "line 2 is unchanged in main...main: " .. vim.inspect(position)
)
assert(notified("the MR at"), "a local HEAD other than the MR head was not warned about")

-- a failed diff fails the comment, instead of calling every line unchanged
core.state.gitlab.diff_refs = { base_sha = "basesha", start_sha = "startsha", head_sha = "headsha" }
core.state.base_ref = "refs/review-mode/does-not-exist"
vim.fn.writefile({}, glab_log)
local failed
api.comment({ path = "file.txt", line = 2, body = "Nowhere" }, function(ok, err)
  failed = { ok = ok, err = err }
end)
wait_for(function()
  return failed ~= nil
end, "a comment with a failing diff did not answer")
assert(not failed.ok and tostring(failed.err):find("git diff failed", 1, true), "diff failure: " .. vim.inspect(failed))
assert(not posted_input(), "a comment was posted without its diff")
core.state.base_ref = nil

-- discussions are fetched page by page, bodies intact, JSON nulls as nil
local gitlab = require("review_mode.providers.gitlab")
gitlab.per_page = 2
local paged
gitlab.discussions_async(function(discussions, err)
  paged = discussions or err
end)
wait_for(function()
  return paged ~= nil
end, "paged discussions did not load")
gitlab.per_page = 100
assert(type(paged) == "table" and #paged == 3, "expected three discussions over two pages: " .. vim.inspect(paged))
assert(paged[1].notes[1].body == "- [x] [y] done", "page 1 body: " .. paged[1].notes[1].body)
assert(paged[2].notes[1].body == "[a] [b]", "page 1 second body: " .. paged[2].notes[1].body)
assert(paged[3].notes[1].body == "last] [page", "page 2 body: " .. paged[3].notes[1].body)
local grouped = gitlab.group_discussions(paged)["file.txt"]
assert(grouped[1].side == nil and grouped[1].line == 2, "a new-side note: " .. vim.inspect(grouped[1]))
assert(grouped[2].start_line == 1 and grouped[2].line == 2, "line_range start: " .. vim.inspect(grouped[2]))
local removed = grouped[3]
assert(removed.side == "LEFT", "a note on a removed line is not base-side: " .. vim.inspect(removed))
assert(removed.line == 3 and removed.original_line == 3, "removed-line note lines: " .. vim.inspect(removed))

-- a forced reload that lands while a load is running is not dropped: the
-- running result is superseded and discussions are fetched once more
local github = require("review_mode.github")
local function discussion_fetches()
  local count = 0
  for _, line in ipairs(log_lines()) do
    if line:find("/discussions?per_page=100&page=1", 1, true) then
      count = count + 1
    end
  end
  return count
end
vim.fn.writefile({}, glab_log)
github.load_comments_async({ force = true })
github.load_comments_async({ force = true })
wait_for(function()
  return discussion_fetches() == 2 and not core.state.comments_loading
end, "a forced reload during a GitLab load was dropped: " .. discussion_fetches() .. " fetch(es)")

assert(#gh_calls == 0, "gitlab review called gh: " .. table.concat(gh_calls, "; "))

pr.stop()

-- start's own opts are the session's: GL_REVIEW_* (unset here) never clears them
vim.fn.writefile({}, glab_log)
pr.start({ provider = "gitlab", repo = "group/project", pr = "7", base = "main" })
local session = api.session()
assert(session.repo == "group/project" and session.pr == "7" and session.base == "main", vim.inspect(session))
wait_for(function()
  return logged("mr view 7 --repo https://gitlab.com/group/project --output json")
end, "glab was not asked for the MR start was given")
pr.stop()

-- self-hosted: glab is pointed at the remote's host, not its default gitlab.com
vim.fn.system({ "git", "remote", "set-url", "origin", "git@gitlab.example.com:group/project.git" })
vim.fn.writefile({}, glab_log)
pr.start({ provider = "gitlab", repo = "group/project", pr = "7", base = "main" })
wait_for(function()
  return logged("mr view 7 --repo https://gitlab.example.com/group/project")
    and logged("api --hostname gitlab.example.com projects/group%2Fproject/merge_requests/7/discussions")
end, "glab was not pointed at the self-hosted instance: " .. table.concat(log_lines(), "\n"))
pr.stop()

vim.fn.system({ "git", "remote", "set-url", "origin", original_url })
harness.done()
