local repo_root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required")

vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function win_with_ft(ft)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == ft then
      return win
    end
  end
  return nil
end

vim.fn.system({ "git", "checkout", "-q", "feature" })

-- A buffer-cycling plugin's keys, set before the review starts. The mode layer
-- must leave them alone: that collision is why <Tab>/<S-Tab> left the defaults.
vim.keymap.set("n", "<Tab>", "<cmd>echo 'next'<cr>", { desc = "bufferline next" })
vim.keymap.set("n", "<S-Tab>", "<cmd>echo 'prev'<cr>", { desc = "bufferline prev" })

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local config = pr.config()
assert(config.comments.virtual_text == false, "end-of-line summaries should be off by default")
assert(config.comments.compose == "panel", "comments should draft in the panel by default")
assert(config.mode.keys["<Tab>"] == nil, "<Tab> is still a default mode key")
assert(config.mode.keys["<S-Tab>"] == nil, "<S-Tab> is still a default mode key")

pr.start()
wait_for(function()
  return api.is_changed_file("file.txt") and api.comment_count("file.txt") > 0
end, "the review did not load")
assert(api.is_in_mode(), "the review did not enter the mode")

-- bufferline keeps its keys while the review layer is live
assert(vim.fn.maparg("<Tab>", "n", false, true).desc == "bufferline next", "the mode layer took over <Tab>")
assert(vim.fn.maparg("<S-Tab>", "n", false, true).desc == "bufferline prev", "the mode layer took over <S-Tab>")

-- the comment sign stays; the end-of-line text does not
vim.cmd.edit("file.txt")
local ns = vim.api.nvim_get_namespaces().review_mode_normal
wait_for(function()
  return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) > 0
end, "no comment sign was placed")
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
  local details = mark[4]
  assert(details.sign_text and vim.trim(details.sign_text) ~= "", "the comment sign is gone")
  assert(details.virt_text == nil, "end-of-line text is still drawn by default")
end

-- :ReviewModeComment drafts in the thread panel, never the one-line prompt
vim.ui.input = function()
  error("comment used the one-line prompt instead of the panel")
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.comment()
assert(pr.panel_is_open(), "commenting did not open the thread panel")
local draft = win_with_ft("markdown")
assert(draft, "commenting did not open a draft")
assert(vim.wo[draft].winbar:find("file.txt:2-2", 1, true), "the draft targets the wrong line: " .. vim.wo[draft].winbar)
local code_win = vim.fn.win_getid(vim.fn.bufwinnr(vim.fn.bufnr("file.txt")))
vim.api.nvim_set_current_win(draft)
pr.composer_cancel()
-- discarding the draft must return to the code, not strand you in the panel
assert(vim.api.nvim_get_current_win() == code_win, "cancelling the draft left focus in the panel")

-- a visual range survives opening the panel
pr.comment({ range = 2, line1 = 2, line2 = 4 })
draft = win_with_ft("markdown")
assert(draft and vim.wo[draft].winbar:find("file.txt:2-4", 1, true), "the draft lost the range")
pr.composer_cancel()
pr.close_panel()

-- compose = "prompt" keeps the one-line prompt, with no panel
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  comments = { compose = "prompt" },
})
local prompted = nil
vim.ui.input = function(opts)
  prompted = opts.prompt
end
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
pr.comment()
assert(prompted and prompted:find("file.txt:2-2", 1, true), 'compose = "prompt" did not use the prompt')
assert(not pr.panel_is_open(), 'compose = "prompt" opened the panel anyway')

pr.stop()
