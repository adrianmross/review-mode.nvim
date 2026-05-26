if vim.g.loaded_pr_review == 1 then
  return
end

vim.g.loaded_pr_review = 1

if vim.g.pr_review_auto_setup ~= false then
  require("pr_review").setup()
end
