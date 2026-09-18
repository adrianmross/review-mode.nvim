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
assert(vim.v.shell_error == 0, "could not check out the feature branch for this fixture")

-- A buffer-cycling plugin's keys, set before the review starts. The mode layer
-- must leave them alone: that collision is why <Tab>/<S-Tab> left the defaults.
vim.keymap.set("n", "<Tab>", "<cmd>echo 'next'<cr>", { desc = "bufferline next" })
vim.keymap.set("n", "<S-Tab>", "<cmd>echo 'prev'<cr>", { desc = "bufferline prev" })
-- and one of the user's own leader keys, which the session layer borrows
vim.keymap.set("n", "<leader>rt", "<cmd>echo 'mine'<cr>", { desc = "user rt" })

local function desc(lhs, mode)
  return vim.fn.maparg(lhs, mode or "n", false, true).desc
end

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
-- a non-table comments value must not crash setup
local ok_false = pcall(require("review_mode.state").normalize_config, { comments = false })
assert(ok_false, "comments = false crashed normalize_config")
assert(config.comments.compose == "panel", "comments should draft in the panel by default")
assert(config.mode.keys["<Tab>"] == nil, "<Tab> is still a default mode key")
assert(config.mode.keys["<S-Tab>"] == nil, "<S-Tab> is still a default mode key")
-- gt is Vim's :tabnext, and a checkout review opens in its own tabpage
assert(config.mode.keys["gt"] == nil, "gt is still a default mode key")

pr.start()
wait_for(function()
  return api.is_changed_file("file.txt") and api.comment_count("file.txt") > 0
end, "the review did not load")
assert(api.is_in_mode(), "the review did not enter the mode")

-- bufferline keeps its keys while the review layer is live
assert(vim.fn.maparg("<Tab>", "n", false, true).desc == "bufferline next", "the mode layer took over <Tab>")
assert(vim.fn.maparg("<S-Tab>", "n", false, true).desc == "bufferline prev", "the mode layer took over <S-Tab>")
assert(vim.fn.maparg("gt", "n") == "", "the mode layer took over Vim's gt")

-- session layer: leader actions are live for the whole review
assert(desc("<leader>rt") == "Review: toggle thread panel", "<leader>rt is not the thread panel in a review")
assert(desc("<leader>rf") == "Review: changed files", "<leader>rf is not installed in a review")
-- r is the comment letter: rr comments (in visual mode too), rR forces a new thread
local rr = "Review: comment (replies to a thread on the line)"
assert(desc("<leader>rr") == rr, "<leader>rr is not the comment key")
assert(desc("<leader>rr", "v") == rr, "<leader>rr is not mapped in visual mode")
assert(desc("<leader>rR", "v") == "Review: new thread on line/range", "<leader>rR is not mapped in visual mode")
assert(vim.fn.maparg("<leader>rc", "n") == "", "<leader>rc is still a default key")
assert(desc("]r") == "review-mode ]r", "]r does not jump between threads")
assert(desc("]c") == "review-mode ]c", "the mode layer is not installed")

-- the action picker lists every action with the key bound to it
local by_label = {}
for _, item in ipairs(pr.action_items()) do
  assert(type(item.run) == "function", "action has nothing to run: " .. item.label)
  by_label[item.label] = item
end
assert(by_label["Resolve / unresolve thread"].key == "<leader>rx", "the resolve action does not show <leader>rx")
assert(
  by_label["Comment (reply if a thread is here)"].key == "<leader>rr",
  "the comment action does not show <leader>rr"
)
assert(by_label["Next hunk"].key == "]c", "a mode key is not shown beside its action")
assert(by_label["Expand / collapse unchanged lines (zR / zM)"].key == nil, "an unbound action shows a key")

-- step out: the mode layer goes, the session layer stays
pr.leave()
assert(desc("]c") ~= "review-mode ]c", "stepping out left ]c installed")
assert(desc("<leader>rt") == "Review: toggle thread panel", "stepping out dropped the session keys")
pr.enter()
assert(desc("]c") == "review-mode ]c", "stepping back in did not reinstall ]c")

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

-- the one comment key replies where a thread is, and starts one where none is
local function draft_title()
  local win = win_with_ft("markdown")
  local title = win and vim.wo[win].winbar or ""
  if win then
    vim.api.nvim_set_current_win(win)
    pr.composer_cancel()
  end
  return title
end
vim.api.nvim_set_current_win(code_win)
assert(#api.threads({ path = "file.txt", line = 2 }) > 0, "fixture: expected a thread on line 2")
vim.api.nvim_win_set_cursor(code_win, { 2, 0 })
pr.comment_or_reply()
assert(draft_title():find("Reply to", 1, true), "<leader>rr on a thread did not reply")
local bare
for line = 1, vim.api.nvim_buf_line_count(0) do
  if #api.threads({ path = "file.txt", line = line }) == 0 then
    bare = line
    break
  end
end
assert(bare, "fixture: expected a line without a thread")
vim.api.nvim_win_set_cursor(code_win, { bare, 0 })
pr.comment_or_reply()
local title = draft_title()
assert(title:find("file.txt:" .. bare, 1, true), "<leader>rr on a bare line did not start a thread: " .. title)
-- a range never replies, even over a thread
pr.comment_or_reply({ range = 2, line1 = 2, line2 = 3 })
title = draft_title()
assert(title:find("file.txt:2-3", 1, true), "<leader>rr on a range did not start a thread: " .. title)
pr.close_panel()

-- in a diff window ]c stays Vim's change jump
vim.cmd("tabnew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d", "e" })
vim.cmd("diffthis | vnew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "X", "e" })
vim.cmd("diffthis")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
pr.next_hunk()
assert(vim.api.nvim_win_get_cursor(0)[1] == 4, "]c in a diff window did not jump to the change")
vim.cmd("diffoff! | tabclose!")

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

-- <leader>rx toggles the thread on the current line
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local seen = {}
local notify = vim.notify
vim.notify = function(msg)
  seen[#seen + 1] = tostring(msg)
end
pr.toggle_resolve()
vim.wait(3000, function()
  for _, m in ipairs(seen) do
    if m:find("Resolved PR review thread", 1, true) then
      return true
    end
  end
  return false
end, 20)
vim.notify = notify
local resolved = false
for _, m in ipairs(seen) do
  resolved = resolved or m:find("Resolved PR review thread", 1, true) ~= nil
end
assert(resolved, "toggle_resolve did not resolve the open thread")

-- the session ends: its keys go, and the user's own mapping comes back
pr.stop()
assert(desc("<leader>rt") == "user rt", "ending the review did not restore the user's <leader>rt")
assert(vim.fn.maparg("<leader>rf", "n") == "", "ending the review left <leader>rf mapped")

-- session.keys = {} installs none
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  session = { keys = {} },
})
pr.start()
vim.wait(2000, function()
  return api.is_active()
end, 20)
assert(desc("<leader>rt") == "user rt", "session.keys = {} still installed <leader>rt")
assert(vim.fn.maparg("<leader>rf", "n") == "", "session.keys = {} still installed <leader>rf")
pr.stop()

-- mode.keys = {} installs none (documented, but never honored before)
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  viewed = { enabled = false },
  auto_open_first_change = false,
  mode = { keys = {} },
  session = { keys = { ["<leader>rq"] = false } },
})
assert(vim.tbl_isempty(pr.config().mode.keys), "mode.keys = {} still merged in the defaults")
pr.start()
vim.wait(2000, function()
  return api.is_active()
end, 20)
assert(desc("]c") ~= "review-mode ]c", "mode.keys = {} still installed ]c")
-- a false value drops just that key and keeps the rest
assert(vim.fn.maparg("<leader>rq", "n") == "", "session key set to false was still installed")
assert(desc("<leader>rt") == "Review: toggle thread panel", "dropping one session key dropped the others")
pr.stop()
