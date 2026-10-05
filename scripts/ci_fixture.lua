-- fixture: gh pr REVIEW_MODE_FIXTURE=ci REVIEW_MODE_GH_LOG={tmp}/gh.log
-- CI check-run annotations as diagnostics: fetched for the PR head, in their own
-- namespace, toggled apart from the review threads.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)
local log_path = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

local wait_for = harness.wait_for

-- the fake gh appends one line per CI request
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
local config = {
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  comments = { diagnostics = { enabled = true } },
}
pr.setup(config)

local ci_ns = vim.api.nvim_get_namespaces().review_mode_ci
local thread_ns = vim.api.nvim_get_namespaces().review_mode_diagnostics
assert(ci_ns and thread_ns, "CI and thread diagnostic namespaces must both exist")
assert(ci_ns ~= thread_ns, "CI diagnostics need a namespace of their own")

local function diags(bufnr, ns)
  local list = vim.diagnostic.get(bufnr, { namespace = ns })
  table.sort(list, function(left, right)
    return left.lnum < right.lnum
  end)
  return list
end

-- On by default: starting the review fetches the head's check runs.
pr.start()
vim.cmd("edit file.txt")
local buf = vim.api.nvim_get_current_buf()
wait_for(function()
  return #diags(buf, ci_ns) == 2
end, "expected two CI diagnostics on file.txt")

local lint, long = unpack(diags(buf, ci_ns))
assert(lint.lnum == 1 and lint.end_lnum == 1, "annotation line 2 should be lnum 1")
assert(lint.severity == vim.diagnostic.severity.ERROR, "failure should be an ERROR")
assert(lint.message == "[lint] Unused variable: x is never used", "unexpected message: " .. lint.message)
assert(lint.source == "review-mode CI", "unexpected source: " .. tostring(lint.source))
assert(long.lnum == 3 and long.end_lnum == 4, "multi-line annotation should span start..end")
assert(long.severity == vim.diagnostic.severity.WARN, "warning should be a WARN")
assert(long.message == "[lint] line too long", "a missing title drops the prefix: " .. long.message)

-- ]d walks CI failures: vim.diagnostic.jump lands on the annotation.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.diagnostic.jump({ count = 1, namespace = ci_ns })
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "]d should land on the first CI failure")

local other = api.ci_annotations("nested/other.txt")
assert(#other == 1 and other[1].severity == vim.diagnostic.severity.INFO, "notice should be INFO")
assert(other[1].message == "[test] flaky", "an empty title drops the prefix: " .. other[1].message)

-- One check-run list, then annotations only for the runs that have any.
local log = gh_log()
assert(#log == 3, "expected 3 CI requests, got " .. #log .. ": " .. table.concat(log, "; "))
assert(log[1] == "paginate repos/owner/repo/commits/abc123/check-runs?per_page=100", "check runs: " .. log[1])

-- Thread diagnostics live alongside and toggle independently.
wait_for(function()
  return #diags(buf, thread_ns) == 1
end, "thread diagnostic did not load")
vim.cmd("ReviewModeCIToggle")
assert(#diags(buf, ci_ns) == 0, "toggling CI off should clear CI diagnostics")
assert(#diags(buf, thread_ns) == 1, "toggling CI off must leave thread diagnostics alone")
vim.cmd("ReviewModeDiagnosticsToggle")
vim.cmd("ReviewModeCIToggle")
wait_for(function()
  return #diags(buf, ci_ns) == 2
end, "toggling CI on should refetch and restore")
assert(#diags(buf, thread_ns) == 0, "toggling CI on must not bring thread diagnostics back")
vim.cmd("ReviewModeDiagnosticsToggle")

-- The actions picker offers the toggle, and Summary stays last.
local labels = vim.tbl_map(function(item)
  return item.label
end, pr.action_items())
assert(vim.tbl_contains(labels, "Toggle CI diagnostics"), "actions picker should offer the CI toggle")
assert(labels[#labels] == "Summary", "Summary must stay the last action")

-- Refresh refetches.
wait_for(function()
  return api.session() and require("review_mode.state").state.metadata_loaded
end, "metadata did not load")
local before = #gh_log()
pr.refresh()
wait_for(function()
  return #gh_log() == before + 3
end, "refresh should refetch CI annotations")

-- A failed refetch must not leave the previous fetch's failures on screen.
wait_for(function()
  return #diags(buf, ci_ns) == 2
end, "CI diagnostics did not come back after refresh")
vim.env.REVIEW_MODE_FAIL_CI = "1"
api.reload_ci()
wait_for(function()
  return #diags(buf, ci_ns) == 0
end, "a failed CI fetch should clear stale CI diagnostics")
vim.env.REVIEW_MODE_FAIL_CI = nil

pr.stop()
assert(#vim.diagnostic.get(nil, { namespace = ci_ns }) == 0, "stop should clear CI diagnostics")
assert(#api.ci_annotations("file.txt") == 0, "stop should drop the annotations")

-- ci.diagnostics = false: nothing is fetched.
before = #gh_log()
pr.setup(vim.tbl_extend("force", config, { ci = { diagnostics = false } }))
pr.start()
vim.cmd("edit file.txt")
wait_for(function()
  return api.comment_count("file.txt") > 0
end, "comments did not reload")
vim.wait(200)
assert(#gh_log() == before, "disabled CI diagnostics must not call gh")
assert(#vim.diagnostic.get(nil, { namespace = ci_ns }) == 0, "disabled CI diagnostics set nothing")
pr.stop()
harness.done()
