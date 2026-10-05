-- fixture: gh pr
-- Optimistic posting: a comment or reply shows at once, marked sending, is
-- swapped for GitHub's answer without a duplicate, and on failure is taken
-- back with its text left in the unnamed register. The gh mock reads
-- REVIEW_MODE_POST_DELAY and REVIEW_MODE_FAIL_POST from this process's env.
local harness = dofile(
  assert(os.getenv("REVIEW_MODE_PLUGIN_ROOT"), "REVIEW_MODE_PLUGIN_ROOT is required") .. "/scripts/lib/prelude.lua"
)

local wait_for = harness.wait_for

local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end
local function notified(needle)
  for _, message in ipairs(notifications) do
    if message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local pr = require("review_mode")
local api = require("review_mode.api")
pr.setup({
  gitsigns = { enabled = false },
  nvim_tree = { enabled = false },
  comments = { enabled = true },
  viewed = { enabled = false },
  auto_open_first_change = false,
})

local posted = 0
api.on("comment_posted", function()
  posted = posted + 1
end)

local function settled()
  return not api.unstable_state().comments_loading
end

-- every comment on file.txt, with how many are still sending
local function comments()
  local out, sending = {}, 0
  for _, thread in ipairs(api.threads({ path = "file.txt", include_resolved = true })) do
    for _, comment in ipairs(thread.comments) do
      out[#out + 1] = comment
      sending = sending + (comment.is_sending and 1 or 0)
    end
  end
  return out, sending
end
local function count_body(body)
  local n = 0
  for _, comment in ipairs(comments()) do
    n = n + (comment.body == body and 1 or 0)
  end
  return n
end

pr.start()
wait_for(function()
  return api.comment_count("file.txt") > 0 and settled()
end, "optimistic fixture comments did not load")

-- new thread, slow network: it shows before gh answers
vim.env.REVIEW_MODE_POST_DELAY = "1"
local done, result
assert(api.comment({ path = "file.txt", line = 3, body = "optimistic hello" }, function(ok)
  done, result = true, ok
end))
local on_line = api.threads({ path = "file.txt", line = 3 })
assert(#on_line == 1, "new comment did not show before gh answered")
assert(on_line[1].comments[1].is_sending and on_line[1].comments[1].body == "optimistic hello", "placeholder wrong")
local lines = api.render_threads(on_line, { width = 60 })
assert(table.concat(lines, "\n"):find("sending…", 1, true), "placeholder is not marked sending")
assert(posted == 0, "comment_posted fired before gh answered")

wait_for(function()
  return done
end, "comment post did not settle")
assert(result == true and posted == 1, "comment post did not succeed once")
local _, sending = comments()
assert(sending == 0, "placeholder survived success")
assert(count_body("optimistic hello") == 0, "placeholder body still shown after success")
assert(count_body("created") == 1, "real comment is missing or duplicated after success")
wait_for(settled, "reload after comment did not finish")

-- reply, slow network: it joins its thread at once, and its sign turns pending
vim.cmd.edit("file.txt")
local ns = vim.api.nvim_get_namespaces().review_mode_normal
local function sign_hl(row)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { row, 0 }, { row, -1 }, { details = true })) do
    if mark[4].sign_hl_group then
      return mark[4].sign_hl_group
    end
  end
end
wait_for(function()
  return sign_hl(1) ~= nil
end, "no comment sign on line 2")
assert(sign_hl(1) ~= "ReviewModePending", "thread_1 sign was pending before the reply")
done = false
assert(api.reply({ thread_id = "thread_1", body = "optimistic reply" }, function(ok)
  done, result = true, ok
end))
local thread = api.threads({ path = "file.txt", line = 2 })[1]
local last = thread.comments[#thread.comments]
assert(thread.id == "thread_1" and last.is_sending and last.body == "optimistic reply", "reply did not show at once")
assert(sign_hl(1) == "ReviewModePending", "a sending reply did not mark its thread's sign pending")
wait_for(function()
  return done
end, "reply did not settle")
assert(result == true and posted == 2, "reply did not succeed once")
thread = api.threads({ path = "file.txt", line = 2 })[1]
last = thread.comments[#thread.comments]
assert(last.body == "replied" and not last.is_sending, "real reply did not replace the placeholder")
assert(count_body("optimistic reply") == 0 and count_body("replied") == 1, "reply duplicated")
wait_for(settled, "reload after reply did not finish")

-- reply by the id of a comment that is not the thread's last: still shown at once
done = false
assert(api.reply({ comment_id = 2, body = "reply to the first" }, function(ok)
  done, result = true, ok
end))
thread = api.threads({ path = "file.txt", line = 4, include_resolved = true })[1]
last = thread.comments[#thread.comments]
assert(thread.id == "thread_2" and last.is_sending, "reply to a non-last comment did not show at once")
wait_for(function()
  return done
end, "reply to a non-last comment did not settle")
assert(result == true, "reply to a non-last comment failed")
wait_for(settled, "reload after the second reply did not finish")

-- failure: taken back, text kept, no event
vim.env.REVIEW_MODE_POST_DELAY = nil
vim.env.REVIEW_MODE_FAIL_POST = "1"
vim.fn.setreg('"', "")
done = false
api.comment({ path = "file.txt", line = 3, body = "doomed comment" }, function(ok)
  done, result = true, ok
end)
assert(count_body("doomed comment") == 1, "failing comment did not show while sending")
wait_for(function()
  return done
end, "failing comment did not settle")
assert(result == false and posted == 3, "failed comment reported success or fired comment_posted")
assert(count_body("doomed comment") == 0, "failed comment placeholder was not removed")
assert(vim.fn.getreg('"') == "doomed comment", "failed comment text was not kept in the register")
assert(notified('" register'), "failure did not say where the text went")

vim.fn.setreg('"', "")
done = false
api.reply({ thread_id = "thread_1", body = "doomed reply" }, function(ok)
  done, result = true, ok
end)
assert(count_body("doomed reply") == 1, "failing reply did not show while sending")
wait_for(function()
  return done
end, "failing reply did not settle")
assert(result == false and posted == 3, "failed reply reported success or fired comment_posted")
assert(count_body("doomed reply") == 0, "failed reply placeholder was not removed")
assert(vim.fn.getreg('"') == "doomed reply", "failed reply text was not kept in the register")

print("optimistic comments fixture passed")
harness.done()
vim.cmd("qa!")
