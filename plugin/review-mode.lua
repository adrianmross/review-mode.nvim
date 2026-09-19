-- setup() sets this too: with a native pack/*/start install this file is
-- sourced after the user's init.lua, whose setup({ ... }) must not be reset to
-- the defaults by a second, argument-less call here.
if vim.g.loaded_review_mode == 1 then
  return
end

vim.g.loaded_review_mode = 1

if vim.g.review_mode_auto_setup ~= false then
  require("review_mode").setup()
end
