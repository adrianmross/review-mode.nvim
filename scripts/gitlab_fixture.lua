local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local glab_log = assert(os.getenv("GLAB_LOG"), "GLAB_LOG is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

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

local draft, draft_err = api.add_pending({ path = "file.txt", line = 2, body = "later" })
assert(not draft, "pending comment was queued on GitLab")
assert(
  tostring(draft_err):find("not supported on GitLab yet", 1, true),
  "wrong pending refusal: " .. tostring(draft_err)
)
assert(#api.pending() == 0, "a pending draft was stored on GitLab")

assert(#gh_calls == 0, "gitlab review called gh: " .. table.concat(gh_calls, "; "))

pr.stop()
vim.fn.system({ "git", "remote", "set-url", "origin", original_url })
