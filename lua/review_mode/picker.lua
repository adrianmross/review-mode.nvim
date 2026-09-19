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

local picker_hls = {
  add = "ReviewModePickerAdd",
  delete = "ReviewModePickerDelete",
  prompt = "ReviewModePickerPrompt",
  viewed = "ReviewModePickerViewed",
  unviewed = "ReviewModePickerUnviewed",
}

local function ensure_viewed_picker_highlights()
  pcall(vim.api.nvim_set_hl, 0, picker_hls.add, { default = true, fg = "#22C55E" })
  pcall(vim.api.nvim_set_hl, 0, picker_hls.delete, { default = true, fg = "#EF4444" })
  pcall(vim.api.nvim_set_hl, 0, picker_hls.prompt, { default = true, fg = "#38BDF8", bold = true })
  pcall(vim.api.nvim_set_hl, 0, picker_hls.viewed, { default = true, fg = "#22C55E" })
  pcall(vim.api.nvim_set_hl, 0, picker_hls.unviewed, { default = true, fg = "#F59E0B" })
end

local function normalize_viewed_filter(filter)
  filter = filter or "all"
  if filter == "viewed" or filter == "unviewed" then
    return filter
  end
  return "all"
end

local function file_stats(path)
  local entry = api.file(path)
  return { additions = entry and entry.added or 0, deletions = entry and entry.removed or 0 }
end

local function stat_text(value, prefix)
  if value == nil then
    return prefix .. "-"
  end
  return prefix .. tostring(value)
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

-- A row as { text, highlight } segments, so snacks and Telescope can color it
-- and the plain label is just the texts joined. Columns: how much is reviewed,
-- lines added and removed, comment threads (and how many are resolved), path.
local function row_segments(path, viewed, stats, threads, resolved, unresolved)
  local segments = {}
  local function cell(text, hl, width, right)
    local gap = string.rep(" ", math.max(0, (width or 0) - vim.fn.strdisplaywidth(text)))
    if right then
      segments[#segments + 1] = { gap }
    end
    segments[#segments + 1] = { text, hl }
    if not right then
      segments[#segments + 1] = { gap }
    end
    segments[#segments + 1] = { " " }
  end

  if viewed then
    cell("✓", "ReviewModePickerViewed", 4)
  else
    local percent = math.floor(api.review_fraction(path) * 100)
    cell(percent .. "%", percent > 0 and "ReviewModePickerProgress" or "ReviewModePickerProgressNone", 4, true)
  end
  cell("+" .. thousands(stats.additions or 0), "ReviewModePickerAdded", 7, true)
  cell("-" .. thousands(stats.deletions or 0), "ReviewModePickerRemoved", 7, true)

  local width = 8
  if threads > 0 then
    local count = api.comment_count_label(threads)
    segments[#segments + 1] = { count, unresolved > 0 and "ReviewModePickerThreads" or "ReviewModePickerResolved" }
    width = width - vim.fn.strdisplaywidth(count)
    if resolved > 0 then
      local done = " ✓" .. resolved
      segments[#segments + 1] = { done, "ReviewModePickerResolved" }
      width = width - vim.fn.strdisplaywidth(done)
    end
  end
  segments[#segments + 1] = { string.rep(" ", math.max(0, width)) .. " " }

  local dir, name = path:match("^(.*/)([^/]+)$")
  if dir then
    segments[#segments + 1] = { dir, "ReviewModePickerDir" }
    segments[#segments + 1] = { name }
  else
    segments[#segments + 1] = { path }
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

-- Short enough for a picker's border: the rest is in the statusline and
-- :ReviewModeSummary.
local function files_title(filter)
  -- the share and a viewed count only: review_progress() would build every
  -- file's threads just for a title
  local left = 0
  for _, entry in ipairs(api.files()) do
    if not api.is_viewed_file(entry.path) then
      left = left + 1
    end
  end
  return string.format("Files [%s] · %d%% · %d left", filter, api.review_percent(), left)
end

local function viewed_picker_item(path)
  local viewed = api.is_viewed_file(path)
  local unviewed = api.unviewed_count(path)
  local comments = api.unresolved_count(path)
  local threads, resolved = api.thread_counts(path)
  local stats = file_stats(path)
  local segments = row_segments(path, viewed, stats, threads, resolved, comments)
  local entry = api.file(path)
  if entry and entry.whitespace_only then
    segments[#segments + 1] = { "  (whitespace only)", "ReviewModePickerProgressNone" }
  end
  -- trailing space only: Telescope's highlight ranges count from column 0
  local label = (segments_text(segments):gsub("%s+$", ""))

  return {
    path = path,
    viewed = viewed,
    unviewed = unviewed,
    comments = comments,
    additions = stats.additions,
    deletions = stats.deletions,
    segments = segments,
    label = label,
    search = table.concat({
      path,
      viewed and "viewed" or "unviewed",
      comments > 0 and "comments unresolved" or "",
    }, " "),
  }
end

local function viewed_picker_items(filter)
  local items = {}
  for _, entry in ipairs(api.files()) do
    local path = entry.path
    local viewed = api.is_viewed_file(path)
    if filter == "all" or (filter == "viewed" and viewed) or (filter == "unviewed" and not viewed) then
      items[#items + 1] = viewed_picker_item(path)
    end
  end
  return items
end

local function viewed_picker_preview_header(item)
  local stats = file_stats(item.path)
  return {
    item.path,
    string.format(
      "%s  %s  %s",
      item.viewed and "viewed" or "unviewed",
      stat_text(stats.additions, "+"),
      stat_text(stats.deletions, "-")
    ),
    "",
  }
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

local function highlight_diff_preview(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, picker_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    local hl = nil
    if line:match("^%+") and not line:match("^%+%+%+") then
      hl = "DiffAdd"
    elseif line:match("^%-") and not line:match("^%-%-%-") then
      hl = "DiffDelete"
    elseif line:match("^@@") then
      hl = "DiffText"
    end
    if hl then
      vim.api.nvim_buf_set_extmark(bufnr, picker_ns, index - 1, 0, {
        end_col = #line,
        hl_group = hl,
      })
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
      text = item.label,
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
          ["<C-a>"] = { "filter_all", mode = { "i", "n" } },
          ["<C-v>"] = { "filter_viewed", mode = { "i", "n" } },
          ["<C-u>"] = { "filter_unviewed", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-t>"] = "toggle_viewed",
          ["<Tab>"] = "toggle_viewed",
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
            highlight_diff_preview(bufnr)
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
