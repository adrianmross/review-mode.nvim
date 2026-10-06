-- The base plugin remains usable without issues.nvim.
local harness = os.getenv("REVIEW_MODE_PLUGIN_ROOT")
  and dofile(os.getenv("REVIEW_MODE_PLUGIN_ROOT") .. "/scripts/lib/prelude.lua")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local review = require("review_mode")
local core = require("review_mode.state")
review.setup({})
assert(not package.loaded.issues, "optional plugin loaded at setup")
local notice
local notify = vim.notify
vim.notify = function(message)
  notice = message
end
vim.cmd("ReviewModeIssue EX-1")
assert(notice:find("issues.nvim"))
local calls = {}
package.preload.issues = function()
  return {
    view = function(key, opts)
      calls[#calls + 1] = { key = key, opts = opts }
    end,
    search = function(query, opts)
      calls[#calls + 1] = { query = query, opts = opts }
    end,
  }
end
core.state.root = "/project/review"
vim.cmd("ReviewModeIssueOffline EX-1")
assert(calls[1].key == "EX-1" and calls[1].opts.offline)
assert(calls[1].opts.root == core.state.root and calls[1].opts.current())
core.state.generation = core.state.generation + 1
assert(not calls[1].opts.current(), "old review response still current")
vim.cmd("ReviewModeIssueSearch security")
assert(calls[2].query == "security" and calls[2].opts.root == core.state.root)
vim.notify = notify
package.loaded.issues = nil
package.preload.issues = nil
print("issues bridge fixture: optional dependency, delegation and stale review guard passed")
if harness then
  harness.done()
end
vim.cmd("qa!")
