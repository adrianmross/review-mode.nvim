-- fixture: gh
local harness = dofile(os.getenv("REVIEW_MODE_PLUGIN_ROOT") .. "/scripts/lib/prelude.lua")
local root = assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"))
vim.opt.runtimepath:prepend(root)
local review = require("review_mode")
local api = require("review_mode.api")
local seen = {}
local provider = {
  command = "fixture-scm",
  env_prefix = "FIXTURE_REVIEW_",
  capabilities = {},
  metadata = function(ctx, callback)
    assert(ctx.config.args[1] == "--project", "project arguments missing")
    vim.schedule(function()
      callback({ repo = "fixture-repo", meta = { number = "fixture-pr", baseRefName = "main", headRefOid = "abc123" } })
    end)
  end,
  threads = function(_, callback)
    callback({
      {
        id = "root-thread",
        path = "file.txt",
        line = 2,
        isResolved = false,
        comments = {
          nodes = {
            { id = "root-comment", body = "External provider comment", author = { login = "reviewer" } },
            { id = "reply-comment", body = "External provider reply", author = { login = "author" } },
          },
        },
      },
    })
  end,
  reply = function(_, target, body)
    seen.reply = { target.thread_id, body }
    return { verified = true }
  end,
  comment = function(_, path, start_line, end_line, body)
    seen.comment = { path, start_line, end_line, body }
    return { verified = true }
  end,
  status = function(_, callback)
    callback({ title = "External PR", state = "OPEN" })
  end,
  url = function(_, callback)
    callback("https://example.test/pr/fixture")
  end,
}
review.register_provider("fixture", provider)
local project = vim.uv.cwd()
review.setup({
  auto_open_first_change = false,
  provider = "github",
  follow_head = false,
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  scm = {
    args = { "inherited", "must-not-leak" },
    projects = { [project] = {
      provider = "fixture",
      args = { "--project" },
    } },
  },
})
local selected = review.scm_config(project)
assert(selected.provider == "fixture" and #selected.args == 1, "project configuration leaked default arguments")
assert(review.scm_config(project .. "/another").provider == "github", "provider leaked to another project")
local unknown, err = require("review_mode.scm").resolve({ provider = "missing-fixture" }, project)
assert(not unknown and err:find("not installed", 1, true), "missing provider silently fell back")
review.start()
assert(
  vim.wait(5000, function()
    return api.comment_count("file.txt") == 2
  end, 20),
  "provider comments not loaded"
)
vim.cmd.edit("file.txt")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local marks =
  vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().review_mode_normal, 0, -1, { details = true })
assert(#marks > 0, "external comments did not reach gutter annotations")
api.reply({ thread_id = "root-thread", body = "My provider reply" }, function(ok, err)
  assert(ok, err)
end)
assert(seen.reply[1] == "root-thread" and seen.reply[2] == "My provider reply", "reply did not use provider")
api.comment({ path = "file.txt", line = 2, body = "My provider reply" }, function(ok, err)
  assert(ok, err)
end)
assert(
  seen.comment and seen.comment[1] == "file.txt" and seen.comment[4] == "My provider reply",
  "inline comment did not use provider"
)
api.resolve("root-thread", true, function(ok)
  assert(not ok, "unsupported resolution submitted")
end)
review.copy_url()
assert(vim.fn.getreg('"') == "https://example.test/pr/fixture", "provider URL not used")
review.stop()
harness.done()
print("provider fixture passed")
vim.cmd.qa()
