-- Docs drift check: nvim --headless -u NONE -i NONE -l scripts/check-docs.lua
--
-- Fails (exit 1, one line per problem) when
--   * a registered :ReviewMode* / :Pr* command has no *:Name* tag in the vimdoc
--     or no mention in README.md,
--   * a |link| in the vimdoc points at a tag the vimdoc does not define and
--     Neovim's own help does not either (the allowlist below),
--   * an event the plugin emits is missing from the *review-mode-events* section.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local function read(path)
  return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
end

local doc = read("doc/review-mode.txt")
local readme = read("README.md")
local problems = {}
local function fail(fmt, ...)
  problems[#problems + 1] = string.format(fmt, ...)
end

-- Neovim help tags the vimdoc may link to.
local known = { User = true, ["vim.diagnostic"] = true, ["vim.ui.select"] = true }

-- Tags as :helptags sees them: *name* between whitespace or line ends. Links
-- as the help syntax draws them, outside >...< code blocks.
local tags, links = {}, {}
local in_code = false
for line in (doc .. "\n"):gmatch("(.-)\n") do
  if in_code and (line:match("^<") or line:match("^%S")) then
    in_code = false
  end
  if not in_code then
    for tag in (" " .. line .. " "):gmatch("%s%*([^*%s]+)%*%f[%s]") do
      tags[tag] = true
    end
    for link in line:gmatch("|([^|%s]+)|") do
      links[#links + 1] = link
    end
  end
  if line:match("^>$") or line:match("%s>$") then
    in_code = true
  end
end

-- (a) commands
require("review_mode").setup({})
local names = vim.tbl_keys(vim.api.nvim_get_commands({}))
table.sort(names)
for _, name in ipairs(names) do
  if name:match("^ReviewMode") or name:match("^Pr") then
    if not tags[":" .. name] then
      fail("command :%s has no *:%s* tag in doc/review-mode.txt", name, name)
    end
    if not readme:find(":" .. name .. "%f[^%w]") then
      fail("command :%s is not mentioned in README.md", name)
    end
  end
end

-- (b) links
local seen = {}
for _, link in ipairs(links) do
  if not tags[link] and not known[link] and not seen[link] then
    seen[link] = true
    fail("link |%s| has no target tag", link)
  end
end

-- (c) events: every name hooks.emit is called with, plus the public list
local events = {}
for _, name in ipairs(require("review_mode.api").events) do
  events[name] = true
end
for _, file in ipairs(vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)) do
  local src = table.concat(vim.fn.readfile(file), "\n")
  for name in src:gmatch('hooks%.emit%("([%w_]+)"') do
    events[name] = true
  end
end
local section = doc:match("%*review%-mode%-events%*(.-)\n====") or doc:match("%*review%-mode%-events%*(.*)") or ""
local pattern_for = require("review_mode.hooks").pattern_for
for _, name in ipairs(vim.fn.sort(vim.tbl_keys(events))) do
  local line = section:match("\n%s+" .. name .. "%s+(%S+)")
  if not line then
    fail("event %s is not listed in *review-mode-events*", name)
  elseif line ~= pattern_for(name) then
    fail("event %s is listed as User %s, but fires %s", name, line, pattern_for(name))
  end
end

if #problems > 0 then
  io.stderr:write("check-docs: " .. #problems .. " problem(s)\n  " .. table.concat(problems, "\n  ") .. "\n")
  os.exit(1)
end
print(("check-docs: ok (%d commands, %d links, %d events)"):format(#names, #links, vim.tbl_count(events)))
