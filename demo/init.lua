-- The config the demo recordings run against: this plugin, a colorscheme, and
-- nothing else. Kept deliberately small so a viewer can tell what is the plugin
-- and what is someone's dotfiles.
--
--   nvim -u demo/init.lua
--
-- REVIEW_MODE_DEMO_LSP=1 also starts lua-language-server and
-- typescript-language-server when they are on PATH, for the takes that show
-- definitions and callers (e.g. blast radius).
--
-- REVIEW_MODE_DEMO_SNACKS=<path to a snacks.nvim checkout> puts it on the
-- runtimepath, so the changed-files picker is the real snacks list (arrow
-- keys, preview) instead of the vim.ui.select fallback.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

if vim.env.REVIEW_MODE_DEMO_SNACKS and vim.fn.isdirectory(vim.env.REVIEW_MODE_DEMO_SNACKS) == 1 then
  vim.opt.runtimepath:prepend(vim.env.REVIEW_MODE_DEMO_SNACKS)
end

vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.cmdheight = 1
vim.opt.swapfile = false
vim.opt.fillchars = "eob: "
vim.g.mapleader = " "
vim.cmd.colorscheme("habamax")

require("review_mode").setup({
  -- the recordings are about the review, not about someone's gitsigns setup
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
})

vim.keymap.set("n", "<leader>rm", "<cmd>ReviewMode<cr>", { desc = "Start review mode" })
-- review-mode's diagnostics (CI checks, review threads) work with whatever
-- ]d/[d you already have; the demo needs its own since it has no dotfiles.
vim.keymap.set("n", "]d", function()
  vim.diagnostic.jump({ count = 1, float = true })
end)
vim.keymap.set("n", "[d", function()
  vim.diagnostic.jump({ count = -1, float = true })
end)

vim.o.statusline = "%{%v:lua.require'review_mode'.mode_text()%} %f %=%{%v:lua.require'review_mode'.statusline()%} "

if vim.env.REVIEW_MODE_DEMO_LSP == "1" and vim.fn.executable("lua-language-server") == 1 then
  vim.lsp.config("lua_ls", { settings = { Lua = { diagnostics = { globals = { "vim" } } } } })
  vim.lsp.enable("lua_ls")
end

if vim.env.REVIEW_MODE_DEMO_LSP == "1" and vim.fn.executable("typescript-language-server") == 1 then
  vim.lsp.config("ts_ls", {
    cmd = { "typescript-language-server", "--stdio" },
    filetypes = { "typescript", "typescriptreact", "javascript" },
    root_markers = { "package.json", ".git" },
  })
  vim.lsp.enable("ts_ls")
end
