if vim.g.loaded_review_mode == 1 then
  return
end

vim.g.loaded_review_mode = 1

if vim.g.review_mode_auto_setup ~= false then
  require("review_mode").setup()
end
