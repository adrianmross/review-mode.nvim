-- Optional issue providers never load or authenticate until explicitly selected.
local harness = os.getenv("REVIEW_MODE_PLUGIN_ROOT")
  and dofile(os.getenv("REVIEW_MODE_PLUGIN_ROOT") .. "/scripts/lib/prelude.lua")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local review = require("review_mode")
local core = require("review_mode.state")
local issues = require("review_mode.issues")
review.setup({})
assert(not package.loaded["review_mode.issue_providers.jira"])
local missing
issues.request(vim.uv.cwd(), "get", "EX-1", {}, function(_, err)
  missing = err
end)
assert(missing:find("No issue provider"))

local calls = {}
review.register_issue_provider("fixture", {
  pattern = "%u+%-%d+",
  request = function(context, request, callback)
    calls[#calls + 1] = { context = context, request = request }
    callback({
      schema = "issue-provider.response.v1",
      issue = { key = request.key, title = "Issue context", body = "Acceptance criteria" },
      cache = { source = "cache", fetchedAt = 42, stale = true },
    })
  end,
})
review.setup({
  issues = {
    provider = "fixture",
    options = { target = "one" },
    projects = { ["/project/two"] = { options = { target = "two" } } },
  },
})
local result
issues.request("/project/two", "get", "EX-1", { offline = true }, function(value, err)
  assert(not err)
  result = value
end)
assert(result.issue.title == "Issue context" and result.cache.stale)
assert(calls[1].request.options.target == "two" and calls[1].request.offline)
assert(#issues.keys("EX-1 EX-1 EX-2", "%u+%-%d+") == 2)

local system = vim.system
vim.system = function(argv, opts, callback)
  assert(opts.cwd == "/project/command")
  assert(argv[1] == "fixture-provider" and argv[2] == "--request")
  local request = vim.json.decode(argv[3])
  assert(request.operation == "search" and request.query == "security")
  callback({
    code = 0,
    stdout = vim.json.encode({ schema = "issue-provider.response.v1", items = { { key = "EX-2", title = "Search" } } }),
    stderr = "",
  })
  return {}
end
review.setup({ issues = { provider = "command", command = { "fixture-provider" } } })
local search
issues.request("/project/command", "search", "security", {}, function(value, err)
  assert(not err)
  search = value
end)
assert(vim.wait(1000, function()
  return search ~= nil
end))
assert(search.items[1].key == "EX-2")
vim.system = system

review.register_issue_provider("invalid", {
  request = function(_, _, callback)
    callback({ schema = "wrong" })
  end,
})
review.setup({ issues = { provider = "invalid" } })
local invalid
issues.request(vim.uv.cwd(), "get", "EX-1", {}, function(_, err)
  invalid = err
end)
assert(invalid:find("Invalid issue provider response"))
assert(core.state.config.issues.provider == "invalid")
local shared = vim.fn.tempname()
vim.fn.mkdir(shared, "p")
local shared_config = { schema = "oci-scm.repo.v1", issues = { provider = "fixture", options = { target = "shared" } } }
local encoded_config = vim.json.encode(shared_config)
vim.fn.writefile({ encoded_config }, shared .. "/.oci-scm.json")
review.setup({})
local selected = assert(issues.resolve(shared))
assert(selected.provider == "fixture" and selected.options.target == "shared")
vim.fn.writefile({ "invalid json" }, shared .. "/.oci-scm.json")
local invalid_config, config_err = issues.resolve(shared)
assert(not invalid_config and config_err:find("Invalid repository"))
assert(vim.fn.filereadable(shared .. "/.oci-scm.json") == 1, "configuration was renamed or deleted")
vim.fn.delete(shared, "rf")
print(
  "issues fixture: optional loading, per-project selection, command contract, stale provenance and invalid responses passed"
)
if harness then
  harness.done()
end
vim.cmd("qa!")
