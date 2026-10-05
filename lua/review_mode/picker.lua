-- The changed-file picker and the action picker, over snacks.nvim, Telescope,
-- or plain vim.ui.select.
--
-- Provider selection lives here so nothing else has to care which is installed.
--
-- Like the panel, review data reaches this module only through review_mode.api.
-- review_mode.util is shared infrastructure rather than a review internal, so
-- requiring it directly is deliberate; the API does not re-export it, because a
-- passthrough would blur the boundary it is meant to draw.
local M = {}

local api = require("review_mode.api")
local util = require("review_mode.util")

local picker_ns = vim.api.nvim_create_namespace("review_mode_picker")

local function configured_picker_provider()
  return ((api.config().picker or {}).provider or "auto")
end

local function picker_provider_order()
  local provider = configured_picker_provider()
  if provider == "auto" then
    return { "snacks", "telescope", "native" }
  end
  if provider == "native" then
    return { "native" }
  end
  return { provider, "native" }
end

local function notify_picker_error(provider, err)
  if configured_picker_provider() == provider then
    vim.notify(
      string.format("Review Mode picker: %s failed, using native picker: %s", provider, tostring(err)),
      vim.log.levels.WARN
    )
  end
end

local function get_snacks_picker()
  local snacks = rawget(_G, "Snacks")
  if snacks and snacks.picker and snacks.picker.pick then
    return snacks.picker
  end

  local ok, mod = pcall(require, "snacks")
  if ok and mod and mod.picker and mod.picker.pick then
    return mod.picker
  end
  return nil
end

local function close_picker_object(picker)
  if picker and type(picker.close) == "function" then
    pcall(function()
      picker:close()
    end)
  end
end

local function normalize_viewed_filter(filter)
  filter = filter or "all"
  if filter == "viewed" or filter == "unviewed" then
    return filter
  end
  return "all"
end

-- Colors for the file rows, linked to standard groups so any colorscheme
-- carries them; override any ReviewModePicker* group to restyle.
local picker_highlights = {
  ReviewModePickerAdded = "Added",
  ReviewModePickerRemoved = "Removed",
  ReviewModePickerProgress = "DiagnosticInfo",
  ReviewModePickerProgressNone = "Comment",
  ReviewModePickerViewed = "DiagnosticOk",
  ReviewModePickerThreads = "DiagnosticWarn",
  ReviewModePickerResolved = "DiagnosticOk",
  ReviewModePickerDir = "Comment",
  ReviewModePickerTitle = "Title",
  ReviewModePickerUnviewed = "DiagnosticWarn",
  ReviewModePickerMeta = "Comment",
}

local function ensure_picker_highlights()
  for name, link in pairs(picker_highlights) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- 5449 -> "5,449"
local function thousands(value)
  local text, count = tostring(value), 0
  repeat
    text, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until count == 0
  return text
end
M._thousands = thousands

-- 39 -> "39", 1234 -> "1.2k", 12345 -> "12k", 1234567 -> "1.2M": a row's
-- counts stay a few columns wide, and the preview shows the exact figure.
local function short_count(value)
  value = tonumber(value) or 0
  if value < 1000 then
    return tostring(value)
  end
  -- rounded, not truncated: 9,960 is "10k", and 999,999 is "1M", not "1000k"
  local scaled, suffix = value / 1e3, "k"
  if scaled >= 999.5 then
    scaled, suffix = value / 1e6, "M"
  end
  if scaled < 9.95 then
    return (string.format("%.1f", scaled):gsub("%.0$", "")) .. suffix
  end
  return string.format("%.0f", scaled) .. suffix
end
M._short_count = short_count

-- git's name-status letter, as the word GitHub uses
local status_words = { A = "added", D = "deleted", R = "renamed", C = "copied", M = "modified" }

local function file_status(entry)
  return status_words[tostring(entry and entry.status or ""):sub(1, 1)] or "modified"
end

local function ci_failures(path)
  local count = 0
  for _, annotation in ipairs(api.ci_annotations(path) or {}) do
    if annotation.severity == vim.diagnostic.severity.ERROR then
      count = count + 1
    end
  end
  return count
end

-- What a file is, as GitHub-style qualifiers in its searchable text, so the
-- picker's own fuzzy query filters on them: `is:unviewed`, `has:comments`,
-- and with fzf syntax `!is:viewed` or `'is:added`.
local function qualifiers(facts)
  local out = { facts.viewed and "is:viewed" or "is:unviewed", "is:" .. facts.status }
  -- strictly between: every hunk seen but the file not yet marked is not "partial"
  if not facts.viewed and facts.fraction > 0 and facts.fraction < 1 then
    out[#out + 1] = "is:partial"
  end
  if facts.threads > 0 then
    out[#out + 1] = "has:comments"
    out[#out + 1] = facts.unresolved > 0 and "is:unresolved" or "is:resolved"
  end
  if facts.ci_failures > 0 then
    out[#out + 1] = "has:ci-failure"
  end
  return out
end

-- A row's cells before layout, each a list of { text, highlight } segments.
-- Columns: how much is reviewed, lines added, lines removed, threads. A zero
-- count is left blank rather than printed, so a new file reads "+39".
local function row_cells(facts)
  local progress
  if facts.viewed then
    progress = { { "✓", "ReviewModePickerViewed" } }
  else
    local percent = math.floor(facts.fraction * 100)
    progress = { { percent .. "%", percent > 0 and "ReviewModePickerProgress" or "ReviewModePickerProgressNone" } }
  end

  local threads = {}
  if facts.threads > 0 then
    threads[1] = {
      api.comment_count_label(facts.threads),
      facts.unresolved > 0 and "ReviewModePickerThreads" or "ReviewModePickerResolved",
    }
    if facts.resolved > 0 then
      threads[2] = { " ✓" .. facts.resolved, "ReviewModePickerResolved" }
    end
  end

  return {
    progress,
    facts.added > 0 and { { "+" .. short_count(facts.added), "ReviewModePickerAdded" } } or {},
    facts.removed > 0 and { { "−" .. short_count(facts.removed), "ReviewModePickerRemoved" } } or {},
    threads,
  }
end

local function cell_width(cell)
  local width = 0
  for _, segment in ipairs(cell) do
    width = width + vim.fn.strdisplaywidth(segment[1])
  end
  return width
end

-- Lay a row out against the widest cell of each column in the list, so the
-- columns are as narrow as this PR allows. A column no file uses takes no space.
-- The first two columns right-align (numbers read against their ones place);
-- removed follows added directly, like "+39 −2" in a diffstat.
local function row_segments(item, widths)
  local segments = {}
  for column, cell in ipairs(item.cells) do
    local width = widths[column]
    if width > 0 then
      local gap = { string.rep(" ", width - cell_width(cell)) }
      if column <= 2 then
        segments[#segments + 1] = gap
      end
      vim.list_extend(segments, cell)
      if column > 2 then
        segments[#segments + 1] = gap
      end
      segments[#segments + 1] = { column == 2 and " " or "  " }
    end
  end

  local dir, name = item.path:match("^(.*/)([^/]+)$")
  if dir then
    segments[#segments + 1] = { dir, "ReviewModePickerDir" }
    segments[#segments + 1] = { name }
  else
    segments[#segments + 1] = { item.path }
  end
  if item.whitespace_only then
    segments[#segments + 1] = { "  (whitespace only)", "ReviewModePickerProgressNone" }
  end
  return segments
end

local function segments_text(segments)
  local parts = {}
  for _, segment in ipairs(segments) do
    parts[#parts + 1] = segment[1]
  end
  return table.concat(parts)
end

-- Telescope wants the text plus byte ranges for each highlight.
local function segments_highlights(segments)
  local out, col = {}, 0
  for _, segment in ipairs(segments) do
    if segment[2] then
      out[#out + 1] = { { col, col + #segment[1] }, segment[2] }
    end
    col = col + #segment[1]
  end
  return out
end

-- The orders the list can be put in, cycled with <C-s>; "review" is the
-- reading order the rest of the plugin walks.
local sorts = {
  { key = "review", label = "reading order" },
  {
    key = "unreviewed",
    label = "least reviewed",
    less = function(a, b)
      return a.fraction < b.fraction
    end,
  },
  {
    key = "size",
    label = "largest",
    less = function(a, b)
      return a.added + a.removed > b.added + b.removed
    end,
  },
  {
    key = "comments",
    label = "most comments",
    less = function(a, b)
      if a.unresolved ~= b.unresolved then
        return a.unresolved > b.unresolved
      end
      return a.threads > b.threads
    end,
  },
  {
    key = "path",
    label = "path",
    less = function(a, b)
      return a.path < b.path
    end,
  },
}
local sort_index = 1

local function next_sort()
  sort_index = sort_index % #sorts + 1
end

-- Short enough for a picker's border: the rest is in the statusline and
-- :ReviewModeSummary. The order is named only when it is not the default.
local function files_title(filter)
  -- the share and a viewed count only: review_progress() would build every
  -- file's threads just for a title
  local left = 0
  for _, entry in ipairs(api.files()) do
    if not api.is_viewed_file(entry.path) then
      left = left + 1
    end
  end
  local title = string.format("Files [%s] · %d%% · %d left", filter, api.review_percent(), left)
  if sort_index > 1 then
    title = title .. " · by " .. sorts[sort_index].label
  end
  return title
end

local function viewed_picker_item(path, index)
  local entry = api.file(path)
  local threads, resolved = api.thread_counts(path)
  local facts = {
    path = path,
    index = index,
    viewed = api.is_viewed_file(path),
    fraction = api.review_fraction(path),
    added = entry and entry.added or 0,
    removed = entry and entry.removed or 0,
    threads = threads,
    resolved = resolved,
    unresolved = api.unresolved_count(path),
    status = file_status(entry),
    ci_failures = ci_failures(path),
    whitespace_only = entry and entry.whitespace_only or false,
  }
  facts.cells = row_cells(facts)
  facts.qualifiers = table.concat(qualifiers(facts), " ")
  facts.search = path .. " " .. facts.qualifiers
  return facts
end

local function viewed_picker_items(filter)
  local items = {}
  for index, entry in ipairs(api.files()) do
    local path = entry.path
    local viewed = api.is_viewed_file(path)
    if filter == "all" or (filter == "viewed" and viewed) or (filter == "unviewed" and not viewed) then
      items[#items + 1] = viewed_picker_item(path, index)
    end
  end

  local less = sorts[sort_index].less
  if less then
    -- stable: ties keep the reading order
    table.sort(items, function(a, b)
      if less(a, b) then
        return true
      elseif less(b, a) then
        return false
      end
      return a.index < b.index
    end)
  end

  local widths = { 0, 0, 0, 0 }
  for _, item in ipairs(items) do
    for column, cell in ipairs(item.cells) do
      widths[column] = math.max(widths[column], cell_width(cell))
    end
  end
  for _, item in ipairs(items) do
    item.segments = row_segments(item, widths)
    -- trailing space only: Telescope's highlight ranges count from column 0
    item.label = (segments_text(item.segments):gsub("%s+$", ""))
  end
  return items
end

-- The preview's header: everything the row abbreviates, spelled out, as
-- segment lines so it can be colored like the row.
local function preview_header(item)
  local dir, name = item.path:match("^(.*/)([^/]+)$")
  local title = dir and { { dir, "ReviewModePickerDir" }, { name, "ReviewModePickerTitle" } }
    or { { item.path, "ReviewModePickerTitle" } }
  title[#title + 1] = { "  " .. item.status, "ReviewModePickerProgressNone" }

  local state
  if item.viewed then
    state = { { "✓ viewed", "ReviewModePickerViewed" } }
  else
    local seen, total = api.hunk_progress(item.path)
    local text = string.format("%d%% reviewed", math.floor(item.fraction * 100))
    if seen and total and total > 0 then
      text = text .. string.format(" · %d/%d hunks", seen, total)
    end
    state = { { text, item.fraction > 0 and "ReviewModePickerProgress" or "ReviewModePickerUnviewed" } }
  end
  vim.list_extend(state, {
    { "   " },
    { "+" .. thousands(item.added), "ReviewModePickerAdded" },
    { " " },
    { "−" .. thousands(item.removed), "ReviewModePickerRemoved" },
  })

  local lines = { title, state }
  local notes = {}
  if item.threads > 0 then
    notes[#notes + 1] = {
      string.format("%d open", item.unresolved),
      item.unresolved > 0 and "ReviewModePickerThreads" or "ReviewModePickerResolved",
    }
    notes[#notes + 1] = { string.format(" · %d resolved", item.resolved), "ReviewModePickerResolved" }
    table.insert(notes, 1, { api.comment_count_label(item.threads) .. " threads: " })
  end
  if item.ci_failures > 0 then
    if #notes > 0 then
      notes[#notes + 1] = { "   " }
    end
    notes[#notes + 1] = { string.format("✗ %d CI failure(s)", item.ci_failures), "ReviewModePickerRemoved" }
  end
  if item.whitespace_only then
    notes[#notes + 1] = { (#notes > 0 and "   " or "") .. "whitespace only", "ReviewModePickerProgressNone" }
  end
  if #notes > 0 then
    lines[#lines + 1] = notes
  end
  return lines
end

local function viewed_picker_preview_header(item)
  local lines = {}
  for _, segments in ipairs(preview_header(item)) do
    lines[#lines + 1] = segments_text(segments)
  end
  lines[#lines + 1] = ""
  return lines
end

local function viewed_picker_preview_lines(item, diff)
  local lines = viewed_picker_preview_header(item)
  if not diff or diff == "" then
    lines[#lines + 1] = "No diff preview available"
    return lines
  end

  for line in diff:gmatch("[^\n]+") do
    lines[#lines + 1] = line
    if #lines >= math.max(20, vim.o.lines - 8) then
      lines[#lines + 1] = "..."
      break
    end
  end

  return lines
end

-- The lines to show for `item` right now, plus, when the diff has to be
-- fetched, a later render(lines) once it lands.
--
-- A cached diff is returned outright, so revisiting a file does not flicker.
-- Otherwise this returns a placeholder and shells out asynchronously: a blocking
-- git diff per newly selected row stalls the editor for anyone holding `j`.
--
-- still_showing() is the crux. Selection moves faster than git returns, so by
-- the time a diff lands the preview may be on another file, and a late write
-- must not land there. Each provider answers it from the path it last painted.
local function viewed_picker_preview(item, preview_cache, still_showing, render)
  if not item then
    return { "No matching PR files" }
  end

  local cached = preview_cache[item.path]
  if cached then
    return viewed_picker_preview_lines(item, cached)
  end

  api.file_diff(item.path, function(diff)
    preview_cache[item.path] = diff or ""
    if still_showing() then
      render(viewed_picker_preview_lines(item, preview_cache[item.path]))
    end
  end)

  local lines = viewed_picker_preview_header(item)
  lines[#lines + 1] = "Loading diff..."
  return lines
end

-- Color a preview: the header's segments as the row colors them, then the diff
-- below it. Done with extmarks rather than left to filetype highlighting, so it
-- reads the same in every colorscheme and in both snacks and Telescope.
local function highlight_preview(bufnr, item)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ensure_picker_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, picker_ns, 0, -1)

  local header = item and preview_header(item) or {}
  for row, segments in ipairs(header) do
    for _, range in ipairs(segments_highlights(segments)) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, picker_ns, row - 1, range[1][1], {
        end_col = range[1][2],
        hl_group = range[2],
      })
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = #header + 1, #lines do
    local line = lines[index]
    local hl
    if line:match("^%+%+%+ ") or line:match("^%-%-%- ") or line:match("^diff %-%-git ") then
      hl = "ReviewModePickerMeta"
    elseif line:match("^index ") or line:match("^new file mode") or line:match("^deleted file mode") then
      hl = "ReviewModePickerMeta"
    elseif line:match("^similarity index") or line:match("^rename ") then
      hl = "ReviewModePickerMeta"
    elseif line:match("^%+") then
      hl = "DiffAdd"
    elseif line:match("^%-") then
      hl = "DiffDelete"
    elseif line:match("^@@") then
      hl = "DiffText"
    end
    if hl then
      vim.api.nvim_buf_set_extmark(bufnr, picker_ns, index - 1, 0, { end_col = #line, hl_group = hl })
    end
  end
end

local function viewed_picker_items_for_provider(filter)
  return viewed_picker_items(normalize_viewed_filter(filter))
end

local function open_native_viewed_picker(filter)
  filter = normalize_viewed_filter(filter)
  local items = viewed_picker_items_for_provider(filter)
  if #items == 0 then
    local message = filter == "all" and "Review Mode: no changed PR files"
      or string.format("Review Mode: no %s PR files", filter)
    vim.notify(message, vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt = files_title(filter),
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      api.goto_file(item.path, 1)
    end
  end)
end

local function open_snacks_viewed_picker(filter)
  local picker = get_snacks_picker()
  if not picker then
    return false
  end

  filter = normalize_viewed_filter(filter)
  local preview_cache = {}
  local showing = nil
  local snacks_items = vim.tbl_map(function(item)
    return {
      -- matched against the row as shown, then its qualifiers (is:unviewed,
      -- has:comments...): snacks highlights a match by its position in this
      -- text, so the visible part must come first and read exactly as drawn
      text = item.label .. "  " .. item.qualifiers,
      item = item,
      file = item.path,
    }
  end, viewed_picker_items_for_provider(filter))

  picker.pick({
    source = "review_mode_files",
    title = files_title(filter),
    items = snacks_items,
    format = function(entry)
      return (entry.item or entry).segments
    end,
    -- built per selection, and the diff behind it is fetched asynchronously
    preview = function(ctx)
      local item = ctx.item and (ctx.item.item or ctx.item)
      local preview = ctx.preview
      showing = item and item.path or nil
      local function render(lines)
        -- pcall: the preview window can be gone by the time a late diff lands.
        pcall(function()
          preview:set_lines(lines)
          preview:highlight({ ft = "diff" })
          highlight_preview(ctx.buf or (preview.win and preview.win.buf), item)
        end)
      end
      preview:reset()
      render(viewed_picker_preview(item, preview_cache, function()
        return showing == item.path
      end, render))
      return true
    end,
    confirm = function(instance, selected)
      local item = selected and (selected.item or selected)
      if not item then
        return
      end
      close_picker_object(instance)
      api.goto_file(item.path, 1)
    end,
    actions = {
      toggle_viewed = function(instance, selected)
        local item = selected and (selected.item or selected)
        if not item then
          return
        end
        close_picker_object(instance)
        api.set_viewed(item.path, not api.is_viewed_file(item.path))
        vim.schedule(function()
          M.list_viewed(filter)
        end)
      end,
      cycle_sort = function(instance)
        close_picker_object(instance)
        next_sort()
        vim.schedule(function()
          M.list_viewed(filter)
        end)
      end,
      filter_all = function(instance)
        close_picker_object(instance)
        vim.schedule(function()
          M.list_viewed("all")
        end)
      end,
      filter_viewed = function(instance)
        close_picker_object(instance)
        vim.schedule(function()
          M.list_viewed("viewed")
        end)
      end,
      filter_unviewed = function(instance)
        close_picker_object(instance)
        vim.schedule(function()
          M.list_viewed("unviewed")
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-t>"] = { "toggle_viewed", mode = { "i", "n" } },
          ["<Tab>"] = { "toggle_viewed", mode = { "i", "n" } },
          ["<C-s>"] = { "cycle_sort", mode = { "i", "n" } },
          ["<C-a>"] = { "filter_all", mode = { "i", "n" } },
          ["<C-v>"] = { "filter_viewed", mode = { "i", "n" } },
          ["<C-u>"] = { "filter_unviewed", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-t>"] = "toggle_viewed",
          ["<Tab>"] = "toggle_viewed",
          ["<C-s>"] = "cycle_sort",
          s = "cycle_sort",
          a = "filter_all",
          v = "filter_viewed",
          u = "filter_unviewed",
        },
      },
    },
  })
  return true
end

local function open_telescope_viewed_picker(filter)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_previewers and ok_conf and ok_actions and ok_state) then
    return false
  end

  filter = normalize_viewed_filter(filter)
  local preview_cache = {}
  local showing = nil
  local items = viewed_picker_items_for_provider(filter)
  local function refresh_filter(prompt_bufnr, next_filter)
    actions.close(prompt_bufnr)
    vim.schedule(function()
      M.list_viewed(next_filter)
    end)
  end

  pickers
    .new({}, {
      prompt_title = files_title(filter),
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = function()
              return item.label, segments_highlights(item.segments)
            end,
            ordinal = item.search,
            path = item.path,
          }
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Preview",
        define_preview = function(self, entry)
          local item = entry and entry.value
          local bufnr = self.state.bufnr
          showing = item and item.path or nil
          vim.bo[bufnr].filetype = "diff"
          local function render(lines)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            highlight_preview(bufnr, item)
          end
          render(viewed_picker_preview(item, preview_cache, function()
            return showing == item.path and vim.api.nvim_buf_is_valid(bufnr)
          end, render))
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection and selection.value then
            api.goto_file(selection.value.path, 1)
          end
        end)
        local function toggle_selected()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection and selection.value then
            api.set_viewed(selection.value.path, not api.is_viewed_file(selection.value.path))
            vim.schedule(function()
              M.list_viewed(filter)
            end)
          end
        end
        map({ "i", "n" }, "<C-t>", toggle_selected)
        map({ "i", "n" }, "<Tab>", toggle_selected)
        map({ "i", "n" }, "<C-s>", function()
          next_sort()
          refresh_filter(prompt_bufnr, filter)
        end)
        map({ "i", "n" }, "<C-a>", function()
          refresh_filter(prompt_bufnr, "all")
        end)
        map({ "i", "n" }, "<C-v>", function()
          refresh_filter(prompt_bufnr, "viewed")
        end)
        map({ "i", "n" }, "<C-u>", function()
          refresh_filter(prompt_bufnr, "unviewed")
        end)
        return true
      end,
    })
    :find()
  return true
end

local function open_viewed_picker(filter)
  for _, provider in ipairs(picker_provider_order()) do
    if provider == "native" then
      open_native_viewed_picker(filter)
      return
    end

    local ok, opened = pcall(function()
      if provider == "snacks" then
        return open_snacks_viewed_picker(filter)
      elseif provider == "telescope" then
        return open_telescope_viewed_picker(filter)
      end
      return false
    end)
    if ok and opened then
      return
    end
    if not ok then
      notify_picker_error(provider, opened)
    end
  end
end

function M.list_viewed(filter)
  if not util.ensure_active() then
    return
  end

  ensure_picker_highlights()
  open_viewed_picker(filter)
end

-- the bound key goes last, so the picker is also the key reference and typing
-- "rx" finds the action behind <leader>rx
local function action_item_label(item)
  local label = string.format("%-8s %s", item.category or "Review", item.label)
  if item.key then
    label = string.format("%-46s %s", label, item.key)
  end
  return label
end

local function run_action_item(item)
  if item and item.run then
    item.run()
  end
end

local function open_native_actions_picker(items, title)
  vim.ui.select(items, {
    prompt = title or "Review Mode action",
    format_item = action_item_label,
  }, run_action_item)
end

local function open_snacks_actions_picker(items, title)
  local picker = get_snacks_picker()
  if not picker then
    return false
  end

  picker.pick({
    source = "review_mode_actions",
    title = title or "Review Mode actions",
    items = vim.tbl_map(function(item)
      return {
        text = action_item_label(item),
        item = item,
        preview = {
          text = string.format("# %s\n\n%s", item.label, item.category or "Review"),
          ft = "markdown",
          loc = false,
        },
      }
    end, items),
    preview = "preview",
    confirm = function(instance, selected)
      close_picker_object(instance)
      run_action_item(selected and (selected.item or selected))
    end,
  })
  return true
end

local function open_telescope_actions_picker(items, title)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
    return false
  end

  pickers
    .new({}, {
      prompt_title = title or "Review Mode actions",
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = action_item_label(item),
            ordinal = action_item_label(item),
          }
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          run_action_item(selection and selection.value)
        end)
        return true
      end,
    })
    :find()
  return true
end

--- Open the action picker over a caller-supplied item list, titled `title`.
--- Without one, snacks and Telescope title it "Review Mode actions" and the
--- native vim.ui.select prompt reads "Review Mode action".
function M.actions(items, title)
  items = items or {}
  for _, provider in ipairs(picker_provider_order()) do
    if provider == "native" then
      open_native_actions_picker(items, title)
      return
    end

    local ok, opened = pcall(function()
      if provider == "snacks" then
        return open_snacks_actions_picker(items, title)
      elseif provider == "telescope" then
        return open_telescope_actions_picker(items, title)
      end
      return false
    end)
    if ok and opened then
      return
    end
    if not ok then
      notify_picker_error(provider, opened)
    end
  end
end

return M
