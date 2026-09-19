-- The PR comment-thread model and its rendering: comments in, threads out,
-- lines plus extmark specs out.
--
-- Nothing here touches plugin state or windows, so the panel, the float, and
-- the fixture all go through the same code path.
local M = {}

local rest_reaction_content = {
  ["+1"] = "THUMBS_UP",
  ["-1"] = "THUMBS_DOWN",
  laugh = "LAUGH",
  hooray = "HOORAY",
  confused = "CONFUSED",
  heart = "HEART",
  rocket = "ROCKET",
  eyes = "EYES",
}

M.highlights = {
  ReviewModeThreadRule = "FloatBorder",
  ReviewModeThreadPath = "Title",
  ReviewModeCommentAuthor = "Function",
  ReviewModeCommentMeta = "Comment",
  ReviewModeCommentCode = "CursorLine",
  ReviewModeCommentCodeLabel = "Comment",
  ReviewModeSuggestionAdd = "DiffAdd",
  ReviewModeSuggestionDelete = "DiffDelete",
  ReviewModeReaction = "Special",
  ReviewModeReactionOwn = "DiagnosticOk",
  ReviewModeResolved = "DiagnosticOk",
  ReviewModeUnresolved = "DiagnosticWarn",
  ReviewModeOutdated = "DiagnosticHint",
  ReviewModePending = "DiagnosticInfo",
  ReviewModeHint = "NonText",
}

local reaction_emoji = {
  THUMBS_UP = "👍",
  THUMBS_DOWN = "👎",
  LAUGH = "😄",
  HOORAY = "🎉",
  CONFUSED = "😕",
  HEART = "❤",
  ROCKET = "🚀",
  EYES = "👀",
}

-- GitHub sends every association; only the ones that say something about
-- standing are worth the width.
local notable_association = {
  OWNER = "owner",
  MEMBER = "member",
  COLLABORATOR = "collaborator",
  CONTRIBUTOR = "contributor",
  FIRST_TIME_CONTRIBUTOR = "first-time",
  FIRST_TIMER = "first-timer",
}

local function width_of(text)
  return vim.fn.strdisplaywidth(text or "")
end

-- os.time reads a broken-down table as local time, so an ISO timestamp parsed
-- straight into it lands one UTC offset away. Measure that offset and undo it.
local function utc_epoch(fields)
  local as_local = os.time(fields)
  if not as_local then
    return nil
  end
  local offset = os.difftime(as_local, os.time(os.date("!*t", as_local)))
  return as_local + offset
end

function M.relative_time(iso, now)
  if type(iso) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return nil
  end

  local epoch = utc_epoch({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
    isdst = false,
  })
  if not epoch then
    return nil
  end

  local delta = (now or os.time()) - epoch
  if delta < 0 then
    delta = 0
  end
  for _, step in ipairs({
    { 60, 1, "just now" },
    { 3600, 60, "m ago" },
    { 86400, 3600, "h ago" },
    { 604800, 86400, "d ago" },
    { 2592000, 604800, "w ago" },
    { 31536000, 2592000, "mo ago" },
  }) do
    if delta < step[1] then
      if step[2] == 1 then
        return step[3]
      end
      return string.format("%d%s", math.floor(delta / step[2]), step[3])
    end
  end
  return string.format("%dy ago", math.max(1, math.floor(delta / 31536000)))
end

--- Reactions as one line of text plus byte spans, so the viewer's own reactions
--- can be highlighted apart from everyone else's. Returns nil when there are none.
--- Each span is { col, end_col, own }.
function M.reaction_spans(groups)
  local text, spans = "", {}
  for _, group in ipairs(groups or {}) do
    local count = tonumber(group.count) or 0
    if count > 0 then
      if text ~= "" then
        text = text .. "  "
      end
      local part = string.format("%s %d", reaction_emoji[group.content] or "?", count)
      spans[#spans + 1] = { #text, #text + #part, group.viewer_has_reacted == true }
      text = text .. part
    end
  end
  if text == "" then
    return nil
  end
  return text, spans
end

function M.reactions_text(groups)
  return (M.reaction_spans(groups))
end

local function wrap(text, width)
  local out = {}
  width = math.max(20, width)
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if paragraph:match("^%s*$") then
      out[#out + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line == "" then
          line = word
        elseif width_of(line .. " " .. word) <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      if line ~= "" then
        out[#out + 1] = line
      end
    end
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return out
end

-- Split a comment body into prose runs and fenced code runs, so code can be
-- drawn as code instead of as more prose.
function M.split_body(body)
  local segments = {}
  local text = {}
  local code = nil

  local function flush_text()
    if #text > 0 then
      segments[#segments + 1] = { kind = "text", lines = text }
      text = {}
    end
  end

  for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
    local lang = line:match("^%s*```(%S*)%s*$")
    if code and line:match("^%s*```%s*$") then
      segments[#segments + 1] = code
      code = nil
    elseif lang and not code then
      flush_text()
      code = { kind = lang == "suggestion" and "suggestion" or "code", lang = lang, lines = {} }
    elseif code then
      code.lines[#code.lines + 1] = line
    else
      text[#text + 1] = line
    end
  end

  if code then
    segments[#segments + 1] = code
  end
  flush_text()
  return segments
end

function M.suggestion_body(comment)
  for _, segment in ipairs(M.split_body(comment and comment.body)) do
    if segment.kind == "suggestion" then
      return segment.lines
    end
  end
  return nil
end

local Writer = {}
Writer.__index = Writer

local function writer()
  return setmetatable({ lines = {}, marks = {} }, Writer)
end

function Writer:add(text, hl, line_hl)
  self.lines[#self.lines + 1] = text or ""
  local row = #self.lines - 1
  if hl then
    self.marks[#self.marks + 1] = { row = row, col = 0, end_col = #self.lines[row + 1], hl_group = hl }
  end
  if line_hl then
    self.marks[#self.marks + 1] = { row = row, line_hl_group = line_hl }
  end
  return row
end

function Writer:span(row, col, end_col, hl)
  self.marks[#self.marks + 1] = { row = row, col = col, end_col = end_col, hl_group = hl }
end

function Writer:blank()
  if #self.lines > 0 and self.lines[#self.lines] ~= "" then
    self:add("")
  end
end

local function thread_state(thread)
  if thread.is_resolved then
    return "resolved", "ReviewModeResolved"
  end
  if thread.is_outdated then
    return "outdated", "ReviewModeOutdated"
  end
  return "open", "ReviewModeUnresolved"
end

local function rule(label, width, trailing)
  local text = "── " .. label .. " "
  local used = width_of(text) + width_of(trailing or "")
  if used < width then
    text = text .. string.rep("─", width - used - 1) .. " "
  end
  return text .. (trailing or "")
end

local function write_code(out, lines, label, indent)
  local fence_row = out:add(indent .. "┌ " .. label, "ReviewModeCommentCodeLabel")
  out:span(fence_row, #indent, #indent + #"┌", "ReviewModeThreadRule")
  for _, line in ipairs(lines) do
    out:add(indent .. "│ " .. line, nil, "ReviewModeCommentCode")
  end
  out:add(indent .. "└", "ReviewModeThreadRule")
end

-- A suggestion is a replacement for the lines it is anchored to, so show it as
-- the diff it will become rather than as an opaque block of new code.
local function write_suggestion(out, new_lines, original_lines, indent)
  local fence_row = out:add(indent .. "┌ suggestion", "ReviewModeCommentCodeLabel")
  out:span(fence_row, #indent, #indent + #"┌", "ReviewModeThreadRule")
  for _, line in ipairs(original_lines or {}) do
    out:add(indent .. "│-" .. line, nil, "ReviewModeSuggestionDelete")
  end
  for _, line in ipairs(new_lines) do
    out:add(indent .. "│+" .. line, nil, "ReviewModeSuggestionAdd")
  end
  if #new_lines == 0 then
    out:add(indent .. "│+", nil, "ReviewModeSuggestionAdd")
  end
  out:add(indent .. "└", "ReviewModeThreadRule")
end

local function write_comment(out, comment, index, opts)
  local indent = "   "
  local author = comment.author or "reviewer"
  local prefix = index == 1 and " " or " ↳ "
  local header = prefix .. author

  local meta = {}
  local association = notable_association[comment.association]
  if association then
    meta[#meta + 1] = association
  end
  local when = M.relative_time(comment.created_at, opts.now)
  if when then
    meta[#meta + 1] = when
  end
  if comment.is_pending then
    meta[#meta + 1] = "pending"
  elseif comment.is_sending then
    meta[#meta + 1] = "sending…"
  end

  local row = out:add(header .. (#meta > 0 and ("  " .. table.concat(meta, " · ")) or ""))
  out:span(row, #prefix, #prefix + #author, "ReviewModeCommentAuthor")
  if #meta > 0 then
    out:span(
      row,
      #header,
      -1,
      (comment.is_pending or comment.is_sending) and "ReviewModePending" or "ReviewModeCommentMeta"
    )
  end

  for index, segment in ipairs(M.split_body(comment.body)) do
    if segment.kind == "text" then
      local body = vim.trim(table.concat(segment.lines, "\n"))
      if body ~= "" then
        for _, line in ipairs(wrap(body, opts.width - #indent)) do
          out:add(line == "" and "" or (indent .. line))
        end
      end
    else
      -- code needs air around it, or it reads as one more paragraph
      if index > 1 then
        out:blank()
      end
      if segment.kind == "suggestion" then
        write_suggestion(out, segment.lines, opts.original_lines, indent)
      else
        write_code(out, segment.lines, segment.lang ~= "" and segment.lang or "code", indent)
      end
      out:blank()
    end
  end

  local reactions, spans = M.reaction_spans(comment.reactions)
  if reactions then
    local reaction_row = out:add(indent .. reactions)
    for _, span in ipairs(spans) do
      out:span(
        reaction_row,
        #indent + span[1],
        #indent + span[2],
        span[3] and "ReviewModeReactionOwn" or "ReviewModeReaction"
      )
    end
  end
  return row
end

--- Render threads into buffer lines plus extmark specs.
---
--- @param threads table list of normalized threads
--- @param opts table width, now, original_lines, empty, hint
--- @return table lines, table marks, table rows keyed by thread id, table header rows keyed by comment id
function M.render(threads, opts)
  opts = opts or {}
  opts.width = math.max(30, tonumber(opts.width) or 60)
  local out = writer()
  local rows = {}
  local comment_rows = {}

  if not threads or #threads == 0 then
    out:add(opts.empty or "No PR comments here", "ReviewModeHint")
    if opts.hint then
      out:blank()
      for _, line in ipairs(wrap(opts.hint, opts.width)) do
        out:add(line, "ReviewModeHint")
      end
    end
    return out.lines, out.marks, rows, comment_rows
  end

  for index, thread in ipairs(threads) do
    if index > 1 then
      out:blank()
    end

    local label, state_hl = thread_state(thread)
    local location = thread.path or "?"
    if thread.line then
      location = string.format("%s:%s", location, thread.line)
    end
    local badge = "● " .. label
    local replies = #(thread.comments or {})
    if replies > 1 then
      badge = string.format("↩ %d  %s", replies - 1, badge)
    end

    local row = out:add(rule(location, opts.width, badge))
    rows[thread.id or tostring(index)] = row
    out:span(row, #"── ", #"── " + #location, "ReviewModeThreadPath")
    out:span(row, #out.lines[row + 1] - #badge, -1, state_hl)

    for comment_index, comment in ipairs(thread.comments or {}) do
      if comment_index > 1 then
        out:blank()
      end
      local comment_row = write_comment(out, comment, comment_index, {
        width = opts.width,
        now = opts.now,
        -- a thread's own context wins, so two suggestions on one line do not
        -- both render the first one's replaced lines
        original_lines = comment_index == 1 and (thread.original_lines or opts.original_lines) or nil,
      })
      if comment.id then
        comment_rows[comment.id] = comment_row
      end
    end
  end

  if opts.hint then
    out:blank()
    out:add(string.rep("─", opts.width - 1), "ReviewModeThreadRule")
    for _, line in ipairs(wrap(opts.hint, opts.width)) do
      out:add(line, "ReviewModeHint")
    end
  end

  return out.lines, out.marks, rows, comment_rows
end

--- Write rendered lines and their marks into a scratch buffer.
function M.apply(bufnr, namespace, lines, marks)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, mark in ipairs(marks or {}) do
    local text = lines[mark.row + 1] or ""
    local col = math.min(mark.col or 0, #text)
    local end_col = mark.end_col
    if end_col and end_col < 0 then
      end_col = #text
    elseif end_col then
      end_col = math.min(end_col, #text)
    end

    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, mark.row, col, {
      end_col = end_col,
      hl_group = mark.hl_group,
      line_hl_group = mark.line_hl_group,
    })
  end
end

--- One-line summary for the end-of-line virtual text on an annotated line.
function M.virtual_text(thread, opts)
  opts = opts or {}
  local comments = thread.comments or {}
  local last = comments[#comments] or {}
  local body = vim.trim((last.body or ""):match("([^\n\r]+)") or "")
  if body == "" then
    body = "comment"
  end

  local limit = tonumber(opts.max_width) or 60
  if width_of(body) > limit then
    body = vim.fn.strcharpart(body, 0, limit - 1) .. "…"
  end

  local suffix = {}
  if #comments > 1 then
    suffix[#suffix + 1] = string.format("↩%d", #comments - 1)
  end
  local reactions = M.reactions_text(last.reactions)
  if reactions then
    suffix[#suffix + 1] = reactions
  end
  if thread.is_resolved then
    suffix[#suffix + 1] = "✓"
  elseif thread.is_outdated then
    suffix[#suffix + 1] = "⌁"
  end

  return string.format("%s: %s", last.author or "reviewer", body),
    #suffix > 0 and ("  " .. table.concat(suffix, " ")) or nil
end

-- Model ----------------------------------------------------------------------

--- Rename a REST review comment onto the same shape the GraphQL path produces,
--- so everything downstream sees one comment.
function M.normalize_rest(comment)
  local reactions = {}
  for key, content in pairs(rest_reaction_content) do
    local count = tonumber((comment.reactions or {})[key]) or 0
    if count > 0 then
      reactions[#reactions + 1] = { content = content, count = count }
    end
  end
  table.sort(reactions, function(left, right)
    return left.content < right.content
  end)

  return {
    id = comment.id,
    node_id = comment.node_id,
    -- REST has no thread id; a reply names the comment it answers, which is the
    -- closest stand-in and keeps replies grouped with their parent.
    thread_id = comment.in_reply_to_id and ("rest:" .. tostring(comment.in_reply_to_id)) or nil,
    path = comment.path,
    line = comment.line,
    original_line = comment.original_line,
    start_line = comment.start_line,
    body = comment.body,
    user = comment.user and { login = comment.user.login } or nil,
    created_at = comment.created_at,
    url = comment.html_url,
    association = comment.author_association,
    reactions = #reactions > 0 and reactions or nil,
  }
end

--- Group a path's flat comment list into threads.
---
--- Comments are stored flat because that is what signs and counts need. Every
--- normalized comment already carries its thread id, so this works for the
--- GraphQL path, the REST fallback, and a cache written by an older version
--- alike.
function M.threads(list, path)
  local order, by_id = {}, {}
  for index, comment in ipairs(list or {}) do
    local id = comment.thread_id or ("comment:" .. tostring(comment.id))
    local thread = by_id[id]
    if not thread then
      thread = {
        id = id,
        seq = index,
        path = path,
        line = tonumber(comment.line) or tonumber(comment.original_line) or tonumber(comment.start_line),
        start_line = tonumber(comment.start_line),
        is_resolved = comment.is_resolved == true,
        is_outdated = comment.is_outdated == true,
        comments = {},
      }
      by_id[id] = thread
      order[#order + 1] = thread
    end

    thread.comments[#thread.comments + 1] = {
      id = comment.id,
      node_id = comment.node_id,
      author = comment.user and comment.user.login or nil,
      -- the REST fallback has an id but no name; comments cached before
      -- these were fetched have neither
      author_id = comment.user and comment.user.id or nil,
      author_name = comment.user and comment.user.name or nil,
      association = comment.association,
      created_at = comment.created_at,
      body = comment.body,
      url = comment.url,
      reactions = comment.reactions,
      viewer_did_author = comment.viewer_did_author,
      is_pending = comment.is_pending,
      is_sending = comment.is_sending,
    }
  end

  table.sort(order, function(left, right)
    local left_line, right_line = left.line or math.huge, right.line or math.huge
    if left_line == right_line then
      return left.seq < right.seq
    end
    return left_line < right_line
  end)
  return order
end

function M.covers_line(thread, line)
  local last = thread.line
  if not last then
    return false
  end
  return line >= (thread.start_line or last) and line <= last
end

function M.on_line(threads, line)
  local results = {}
  for _, thread in ipairs(threads) do
    if M.covers_line(thread, line) then
      results[#results + 1] = thread
    end
  end
  return results
end

function M.visible(threads, show_resolved)
  if show_resolved then
    return threads
  end

  local visible = {}
  for _, thread in ipairs(threads) do
    if not thread.is_resolved then
      visible[#visible + 1] = thread
    end
  end
  -- An all-resolved file still has something to say; falling back to the full
  -- list beats showing "no comments" over a line that visibly has a sign.
  return #visible > 0 and visible or threads
end

-- Reactions ------------------------------------------------------------------

--- The reactions GitHub accepts, in GitHub's order: { content, emoji }.
M.reaction_contents = {}
for _, content in ipairs({ "THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES" }) do
  M.reaction_contents[#M.reaction_contents + 1] = { content = content, emoji = reaction_emoji[content] }
end

--- The REST spelling ("+1", "laugh", ...) of a GraphQL reaction content, or nil.
function M.rest_reaction_key(content)
  for key, value in pairs(rest_reaction_content) do
    if value == content then
      return key
    end
  end
  return nil
end

return M
