-- The one way review code runs `git diff`, and the one parser for its output.
--
-- A user's git config can reshape a patch: diff.noprefix drops the a/ b/
-- prefixes, diff.mnemonicPrefix swaps them for c/ w/ i/, diff.external replaces
-- the output wholesale, and core.quotePath (on by default) prints a non-ASCII
-- name as "caf\303\251.txt". Every diff goes through M.diff so none of that
-- reaches a parser, and every patch goes through M.parse_patch so a deleted
-- "-- comment" line (patch line "--- comment") is never read as a file header.
local M = {}

--- `git diff` with output that does not depend on the user's config. `args`
--- follow the "diff" subcommand.
function M.diff(args)
  return vim.list_extend({
    "git",
    "-c",
    "core.quotePath=false",
    "diff",
    "--no-ext-diff",
    "--no-color",
    "--src-prefix=a/",
    "--dst-prefix=b/",
  }, args)
end

--- The paths to diff for `paths`: a renamed file also needs its old path, or
--- git limits by the pathspec before detecting the rename and shows an add.
function M.pathspec(paths, renames)
  local out = {}
  for _, path in ipairs(paths) do
    out[#out + 1] = path
    if renames and renames[path] then
      out[#out + 1] = renames[path]
    end
  end
  return out
end

--- Records of a `--name-status -z` or `--numstat -z` listing. -z never quotes a
--- name, and a rename's two paths come as separate fields.
---   name-status: { status = "R100", path = new, old_path = old }
---   numstat:     { additions = "3", deletions = "1", path = new, old_path = old }
function M.parse_z(output, numstat)
  local fields = vim.split(output or "", "\0", { plain = true })
  local out, i = {}, 1
  while i <= #fields do
    local field = fields[i]
    local entry
    if numstat then
      local additions, deletions, path = field:match("^(%S+)\t(%S+)\t(.*)$")
      if additions then
        entry = { additions = additions, deletions = deletions, path = path }
      end
    elseif field:match("^%u") then
      entry = { status = field }
      i = i + 1
      entry.path = fields[i]
    end
    -- a rename or copy: the path field is empty (numstat) or the old path
    -- (name-status), and the new path follows
    if entry and (entry.path == "" or (entry.status and entry.status:match("^[RC]"))) then
      entry.old_path = entry.path ~= "" and entry.path or fields[i + 1]
      entry.path = entry.path ~= "" and fields[i + 1] or fields[i + 2]
      i = i + (numstat and 2 or 1)
    end
    if entry and entry.path and entry.path ~= "" then
      out[#out + 1] = entry
    end
    i = i + 1
  end
  return out
end

-- A header path: C-quoted when it holds a quote, backslash or control
-- character, even with core.quotePath off; a trailing tab when it holds a space.
local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
local function header_path(text, prefix)
  text = text:gsub("\t$", "")
  if text == "/dev/null" then
    return nil
  end
  if text:match('^".*"$') then
    text = text:sub(2, -2):gsub("\\(%d%d%d)", function(octal)
      return string.char(tonumber(octal, 8))
    end)
    text = text:gsub("\\(.)", function(char)
      return escapes[char] or char
    end)
  end
  if prefix and vim.startswith(text, prefix) then
    text = text:sub(#prefix + 1)
  end
  return text
end

--- Parse a unified patch as `git diff` prints it (with M.diff's a/ b/ prefixes).
---
--- Returns a list of files { old_path, new_path, status, binary, hunks }, where
--- old_path is nil for an added file, new_path nil for a deleted one, status is
--- "A", "D", "R" or "M", and each hunk is { old_start, old_count, new_start,
--- new_count, lines }. `lines` is the body as printed: " ", "-", "+" and
--- "\ No newline" lines. A body runs to the next "@@" or "diff " line (in a
--- patch without "diff " lines, until its @@ counts are used up), so a "--- x"
--- inside it is a deleted "-- x", never a header.
function M.parse_patch(text)
  local files, file, hunk = {}, nil, nil
  local old_left, new_left = 0, 0

  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    local in_body = hunk and (file.git or old_left > 0 or new_left > 0) and not line:match("^@@ ")
    if line:match("^diff ") then
      hunk, old_left, new_left = nil, 0, 0
      file = { status = "M", hunks = {}, git = true }
      files[#files + 1] = file
      -- a/P b/P: the only path a binary or mode-only change prints, and
      -- unambiguous when both sides match
      local rest = line:match("^diff %-%-git (.+)$")
      if rest and #rest % 2 == 1 then
        local half = (#rest - 1) / 2
        local left, right = rest:sub(1, half), rest:sub(half + 2)
        if left:sub(3) == right:sub(3) then
          file.old_path, file.new_path = header_path(left, "a/"), header_path(right, "b/")
        end
      end
    elseif in_body then
      hunk.lines[#hunk.lines + 1] = line
      local sign = line:sub(1, 1)
      if sign == "-" then
        old_left = old_left - 1
      elseif sign == "+" then
        new_left = new_left - 1
      elseif sign ~= "\\" then
        -- context; a trimmed empty last line reads as context too
        old_left, new_left = old_left - 1, new_left - 1
      end
    elseif line:match("^\\") and hunk then
      hunk.lines[#hunk.lines + 1] = line
    else
      local ostart, oc, nstart, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if ostart and file then
        hunk = {
          old_start = tonumber(ostart),
          old_count = oc == "" and 1 or tonumber(oc),
          new_start = tonumber(nstart),
          new_count = nc == "" and 1 or tonumber(nc),
          lines = {},
        }
        old_left, new_left = hunk.old_count, hunk.new_count
        file.hunks[#file.hunks + 1] = hunk
      elseif line:match("^%-%-%- ") then
        -- a patch without "diff " lines starts its file here
        if not file or hunk then
          hunk = nil
          file = { status = "M", hunks = {} }
          files[#files + 1] = file
        end
        file.old_path = header_path(line:sub(5), "a/")
        if not file.old_path then
          file.status = "A"
        end
      elseif line:match("^%+%+%+ ") and file then
        file.new_path = header_path(line:sub(5), "b/")
        if not file.new_path then
          file.status = "D"
        end
      elseif file and not hunk then
        local from, to = line:match("^rename from (.+)$"), line:match("^rename to (.+)$")
        if from then
          file.old_path, file.status = header_path(from), "R"
        elseif to then
          file.new_path, file.status = header_path(to), "R"
        elseif line:match("^new file mode") then
          file.old_path, file.status = nil, "A"
        elseif line:match("^deleted file mode") then
          file.new_path, file.status = nil, "D"
        elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
          file.binary = true
        end
      end
    end
  end
  return files
end

return M
