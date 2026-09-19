-- Loaded first by every fixture, before the plugin:
--
--   local harness = dofile(os.getenv("REVIEW_MODE_PLUGIN_ROOT") .. "/scripts/lib/prelude.lua")
--   ...
--   harness.done() -- the last statement
--
-- Puts the plugin on the path, and makes the ways a headless fixture can pass
-- without running its assertions fail instead:
--   * vim.ui.select, vim.ui.input and vim.fn.confirm error unless the fixture
--     stubs them. Headless, the real select and input read EOF and end the
--     script with exit 0, and confirm silently answers 1.
--   * done() writes $REVIEW_MODE_DONE, and validate.sh fails a fixture that
--     exits without it: one that stopped early passed nothing.
-- Errors in scheduled callbacks and autocmds do not change the exit code; the
-- runner in validate.sh catches those from stderr.
local root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")
local fixture = vim.fn.fnamemodify(_G.arg and _G.arg[0] or "fixture", ":t")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- recorded as well as raised, so a caller that pcalls the prompt away still
-- fails the fixture at done()
local unstubbed = {}
local function forbid(name)
  return function()
    local message = string.format("unstubbed %s in %s: stub it", name, fixture)
    unstubbed[#unstubbed + 1] = message
    error(message, 2)
  end
end
vim.ui.select = forbid("vim.ui.select")
vim.ui.input = forbid("vim.ui.input")
vim.fn.confirm = forbid("vim.fn.confirm")

local M = {}

function M.wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

function M.done()
  assert(#unstubbed == 0, table.concat(unstubbed, "\n"))
  local sentinel = os.getenv("REVIEW_MODE_DONE")
  if sentinel then
    assert(io.open(sentinel, "w")):close()
  end
end

return M
