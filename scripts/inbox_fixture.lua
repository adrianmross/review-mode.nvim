-- :ReviewModeInbox: PRs waiting on you, from one gh call, with no session
-- running; choosing one reviews it in its own worktree.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local gh_log = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(10000, predicate, 20), message)
end

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = cwd }):wait()
  assert(result.code == 0, "git " .. table.concat(args, " ") .. ": " .. result.stderr)
  return vim.trim(result.stdout)
end

local function gh_calls()
  local file = io.open(gh_log)
  if not file then
    return {}
  end
  local lines = vim.split(vim.trim(file:read("*a")), "\n", { trimempty = true })
  file:close()
  return lines
end

local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level }
end

-- see scripts/fixture.lua: an unstubbed select ends the script with status 0
vim.ui.select = function()
  error("unexpected vim.ui.select call")
end

local pr = require("review_mode")
local api = require("review_mode.api")
local inbox = require("review_mode.inbox")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = false },
  viewed = { enabled = false },
  follow_head = false,
  picker = { provider = "native" },
})

local function open_inbox(command)
  local shown
  vim.ui.select = function(items, opts, callback)
    shown = { items = items, opts = opts, callback = callback }
  end
  vim.cmd(command)
  wait_for(function()
    return shown ~= nil
  end, command .. " did not open a picker")
  vim.ui.select = function()
    error("unexpected vim.ui.select call")
  end
  return shown
end

-- 1. no session needed; one gh call lists the PRs, CI state included
assert(not api.is_active(), "a session is already running")
local shown = open_inbox("ReviewModeInbox")
local calls = gh_calls()
assert(#calls == 1, "inbox should make exactly one gh call, made " .. vim.inspect(calls))
assert(calls[1]:find("pr list", 1, true), "inbox did not use gh pr list: " .. calls[1])
assert(calls[1]:find("--search review-requested:@me", 1, true), "inbox did not ask for review requests: " .. calls[1])
assert(calls[1]:find("statusCheckRollup", 1, true), "inbox did not fetch CI state in the same call")
assert(calls[1]:find("--repo owner/repo", 1, true), "inbox ignored GH_REVIEW_REPO: " .. calls[1])
assert(shown.opts.prompt:find("inbox", 1, true), "picker was not titled as the inbox: " .. shown.opts.prompt)

-- 2. each row: number, size, CI state, age, draft marker, title, author
local labels = vim.tbl_map(shown.opts.format_item, shown.items)
local draft, ready = labels[1], labels[2]
for _, part in ipairs({ "#7", "+12", "−3", "✗", "[draft]", "Fix flaky test", "@alice" }) do
  assert(draft:find(part, 1, true), "draft row is missing " .. part .. ": " .. draft)
end
assert(draft:match("%s%d+d%s"), "draft row has no age: " .. draft)
for _, part in ipairs({ "#123", "+40", "−0", "…", "Improve review tools", "@bob" }) do
  assert(ready:find(part, 1, true), "ready row is missing " .. part .. ": " .. ready)
end
assert(not ready:find("[draft]", 1, true), "a ready PR was marked draft: " .. ready)

-- CI symbols, directly
assert(inbox.ci_symbol({}) == "", "no checks should show nothing")
assert(inbox.ci_symbol({ { status = "COMPLETED", conclusion = "SUCCESS" }, { state = "SUCCESS" } }) == "✓")
assert(inbox.ci_symbol({ { status = "QUEUED", conclusion = "" }, { state = "SUCCESS" } }) == "…")
assert(inbox.ci_symbol({ { status = "IN_PROGRESS" }, { state = "ERROR" } }) == "✗", "a failure outranks pending")
assert(inbox.age("2024-01-01T00:00:00Z", os.time({ year = 2024, month = 1, day = 1, hour = 3 })) == "3h")

-- 3. scopes: "mine" asks for authored PRs, "all" for every open PR
local mine = table.concat(inbox.args("mine"), " ")
assert(mine:find("--search author:@me", 1, true), "mine scope: " .. mine)
local all = table.concat(inbox.args("all"), " ")
assert(not all:find("--search", 1, true), "all scope should not search: " .. all)
local saved_repo = vim.env.GH_REVIEW_REPO
vim.env.GH_REVIEW_REPO = nil
assert(not table.concat(inbox.args("requested"), " "):find("--repo", 1, true), "no repo known: let gh use the cwd")
vim.env.GH_REVIEW_REPO = saved_repo
inbox.open("nope")
assert(notifications[#notifications].msg:find("unknown scope", 1, true), "a bad scope was not reported")

-- a GitLab review gets a clear answer, not gh's error, and no gh call
local real_session = api.session
api.session = function()
  return { provider = "gitlab", repo = "group/project" }
end
inbox.open()
api.session = real_session
assert(
  notifications[#notifications].msg:find("inbox is GitHub-only", 1, true),
  "a GitLab review was not told the inbox is GitHub-only: " .. notifications[#notifications].msg
)
assert(#gh_calls() == 1, "the inbox called gh during a GitLab review")

-- 4. the inbox is in the action picker, and Summary still ends it
local actions = pr.action_items()
local found = false
for _, item in ipairs(actions) do
  found = found or item.label:find("inbox", 1, true) ~= nil
end
assert(found, "no inbox entry in the action picker")
assert(actions[#actions].label == "Summary", "Summary must stay the last action")

-- 5. choosing a PR reviews it in its own worktree, not this checkout
local user_repo = vim.uv.cwd()
local user_branch = git({ "rev-parse", "--abbrev-ref", "HEAD" }, user_repo)
git({ "update-ref", "refs/pull/123/head", "feature" })
shown.callback(shown.items[2])
wait_for(function()
  return api.is_active() and api.is_changed_file("file.txt")
end, "choosing a PR did not start its review")
local session = api.session()
assert(tostring(session.pr) == "123", "reviewing the wrong PR: " .. tostring(session.pr))
assert(session.repo == "owner/repo", "reviewing the wrong repo: " .. tostring(session.repo))
assert(session.root:find("pr-123", 1, true), "review is not in a worktree: " .. session.root)
assert(git({ "rev-parse", "--abbrev-ref", "HEAD" }, user_repo) == user_branch, "the inbox changed the user's checkout")

local tree = session.root
pr.stop()
git({ "worktree", "remove", "--force", tree }, user_repo)
