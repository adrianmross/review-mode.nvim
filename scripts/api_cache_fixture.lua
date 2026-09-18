-- Fewer GitHub API calls: gh's response cache for repeating metadata reads, and
-- If-None-Match revalidation of the REST comment list.
--
-- The GraphQL thread query is forced to fail here (REVIEW_MODE_FORCE_REST_COMMENTS)
-- because the REST list is the only comment path that can carry an ETag at all:
-- GraphQL is a POST and GitHub does not answer one with 304.
local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local log_path = assert(os.getenv("REVIEW_MODE_GH_LOG"), "REVIEW_MODE_GH_LOG is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

-- the fake gh appends one line per conditional comment request
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
local util = require("review_mode.util")
local github = require("review_mode.github")

pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

-- gh's own response cache, for read-only metadata that repeats -----------------

assert(
  vim.deep_equal(util.gh_cache_args(), { "--cache", "10m" }),
  "the default metadata cache duration must reach gh as --cache"
)
assert(vim.deep_equal(util.gh_cache_args("45s"), { "--cache", "45s" }), "an explicit duration must be passed through")
for _, off in ipairs({ "", "0", "0s", "  " }) do
  assert(vim.deep_equal(util.gh_cache_args(off), {}), "a zero or empty duration must leave gh uncached: " .. off)
end

-- gh api --include ------------------------------------------------------------

local status, headers, body = util.parse_http_response('HTTP/2.0 200 OK\nEtag: W/"abc"\r\nX-Other: 1\r\n\r\n[{"id":1}]')
assert(status == 200, "the status line must be parsed out of --include output")
assert(headers.etag == 'W/"abc"', "header names must be matched case-insensitively, got " .. tostring(headers.etag))
assert(body == '[{"id":1}]', "the body must survive the header split, got " .. tostring(body))
status, headers, body = util.parse_http_response('HTTP/2.0 304 Not Modified\nEtag: "abc"\r\n\r\n')
assert(status == 304 and headers.etag == '"abc"' and body == "", "a 304 has headers and an empty body")
assert(util.parse_http_response("gh: command not found") == nil, "output with no status line is not a response")

-- First load: no ETag on disk yet, so the page is downloaded -------------------

pr.start()
wait_for(function()
  return api.comment_count("file.txt") == 2
end, "the REST comment fetch did not load PR comments")

local stats = api.request_stats()
assert(stats.calls > 0, "gh invocations must be counted")
assert(stats.not_modified == 0, "nothing can be revalidated before an ETag is stored")

-- ETags are per page, not per collection, so the cache holds one per page --
-- next to that page's payload, because a 304 carries no body of its own.
local cached = github.read_comment_cache("owner/repo#123")
assert(type(cached) == "table" and type(cached.rest_pages) == "table", "the comment cache must store per-page ETags")
assert(type(cached.rest_pages[1]) == "table", "page 1 must be stored under its own page number")
assert(
  cached.rest_pages[1].etag == '"etag-1-1"',
  "page 1 must store its own ETag, got " .. tostring(cached.rest_pages[1].etag)
)
assert(#cached.rest_pages[1].comments == 2, "a page's payload is stored so a later 304 can be served from it")
assert(cached.rest_pages[2] == nil, "only the pages actually walked are written back")

-- Second load, unchanged upstream: 304, served from the cache, free ------------

api.reload_comments()
wait_for(function()
  return api.request_stats().not_modified == 1
end, "an unchanged page must be revalidated with If-None-Match and answer 304")
wait_for(function()
  return api.comment_count("file.txt") == 2
end, "a 304 must still leave the cached comments loaded")

local log = gh_log()
assert(#log == 2, "expected two conditional comment requests, got " .. #log)
assert(log[1]:match("if%-none%-match=none$"), "the first fetch has nothing to revalidate against: " .. log[1])
assert(log[2]:match('if%-none%-match="etag%-1%-1"$'), "the second fetch must send the stored ETag: " .. log[2])

-- ... and a 304 refreshes the cache timestamp, so the next load inside the TTL
-- spends no gh process at all.
local before = api.request_stats().calls
github.load_comments_async()
vim.wait(200)
assert(
  api.request_stats().calls == before,
  "a comment load inside the TTL must not spawn gh at all, spent " .. (api.request_stats().calls - before)
)

-- Third load, page changed upstream: 200 replaces that page's ETag ------------

vim.env.REVIEW_MODE_ETAG_GENERATION = "2"
api.reload_comments()
wait_for(function()
  local entry = github.read_comment_cache("owner/repo#123")
  return entry and entry.rest_pages and entry.rest_pages[1] and entry.rest_pages[1].etag == '"etag-2-1"'
end, "a changed page must answer 200 and replace its stored ETag")
assert(api.request_stats().not_modified == 1, "a mismatched ETag is not a 304")
assert(api.comment_count("file.txt") == 2, "the replaced page must still load its comments")

-- :ReviewModeSummary is a rate-limit report, so it belongs to a forge session --

local function summary_text()
  local captured = {}
  local notify = vim.notify
  vim.notify = function(message)
    captured[#captured + 1] = tostring(message)
  end
  local ok, err = pcall(pr.summary)
  vim.notify = notify
  assert(ok, err)
  return table.concat(captured, "\n")
end

local forge_summary = summary_text()
assert(
  forge_summary:find("gh invocations", 1, true),
  "a GitHub session must report its gh invocations: " .. forge_summary
)
assert(forge_summary:find("304", 1, true), "a GitHub session must report its 304 answers: " .. forge_summary)

pr.stop()

-- A local review has no rate limit and never spawns a forge CLI, so the summary
-- says nothing about one rather than reporting zero against a tool it never
-- intended to use. api.request_stats() still answers, correctly, zero.
pr.review_local({ "main..feature" })
wait_for(function()
  local session = api.session()
  return session ~= nil and session.provider == "local"
end, "review_local did not start a local session")

local local_summary = summary_text()
assert(local_summary:find("Files:", 1, true), "the rest of the summary must still be there: " .. local_summary)
assert(not local_summary:find("gh", 1, true), "a local review's summary must not mention gh: " .. local_summary)
assert(not local_summary:find("304", 1, true), "a local review's summary must not mention 304: " .. local_summary)
-- and the line is left out because the provider is local, not because the count
-- happens to be zero: the counter is per Neovim process, so it still carries
-- the GitHub session's calls here and the summary stays silent regardless.
assert(api.request_stats().calls > 0, "this process already spent gh calls before the local session started")

pr.stop()
