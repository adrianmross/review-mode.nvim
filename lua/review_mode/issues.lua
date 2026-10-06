-- Optional bridge: UI, configuration and providers belong to issues.nvim.
local M = {}
local core = require("review_mode.state")
local util = require("review_mode.util")

local function invoke(method, value, opts)
  local ok, issues = pcall(require, "issues")
  if not ok then
    vim.notify("Install and configure adrianmross/issues.nvim to use issue context", vim.log.levels.WARN)
    return
  end
  opts = vim.tbl_extend("force", opts or {}, {
    root = core.state.root or util.repo_root() or vim.uv.cwd(),
  })
  local generation = core.state.generation
  opts.current = function()
    return core.state.generation == generation and (not core.state.root or core.state.root == opts.root)
  end
  issues[method](value, opts)
end

function M.view(key, opts)
  invoke("view", key, opts)
end

function M.search(query)
  invoke("search", query)
end

return M
