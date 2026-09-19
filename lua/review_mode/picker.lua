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

local function viewed_picker_status(viewed, unviewed)
  if viewed then
    return "✓"
  end
  return string.format("☐ %d", unviewed)
end

local function viewed_picker_item(path)
  local viewed = api.is_viewed_file(path)
  local unviewed = api.unviewed_count(path)
  local comments = api.unresolved_count(path)
  local stats = file_stats(path)
  local review_icon = viewed_picker_status(viewed, unviewed)
  local comment_icon = comments > 0 and api.comment_count_label(comments) or ""
  local additions = stat_text(stats.additions, "+")
  local deletions = stat_text(stats.deletions, "-")
  local label = vim.trim(string.format("%-4s %5s %5s %-4s %s", review_icon, additions, deletions, comment_icon, path))
  local entry = api.file(path)
  if entry and entry.whitespace_only then
    label = label .. "  (whitespace only)"
  end
  local hunks_viewed, hunks_total = api.hunk_progress(path)
  if not viewed and hunks_viewed and hunks_viewed > 0 then
    label = string.format("%s (%d/%d hunks viewed)", label, hunks_viewed, hunks_total)
  end

  return {
    path = path,
    viewed = viewed,
    unviewed = unviewed,
    comments = comments,
    additions = stats.additions,
    deletions = stats.deletions,
    review_icon = review_icon,
    comment_icon = comment_icon,
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
    prompt = string.format("Review Mode files [%s]", filter),
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
    title = string.format("Review Mode files [%s]", filter),
    items = snacks_items,
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
      prompt_title = string.format("Review Mode files [%s]", filter),
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = item.label,
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

local function open_native_actions_picker(items)
  vim.ui.select(items, {
    prompt = "Review Mode action",
    format_item = action_item_label,
  }, run_action_item)
end

local function open_snacks_actions_picker(items)
  local picker = get_snacks_picker()
  if not picker then
    return false
  end

  picker.pick({
    source = "review_mode_actions",
    title = "Review Mode actions",
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

local function open_telescope_actions_picker(items)
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
      prompt_title = "Review Mode actions",
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

--- Open the action picker over a caller-supplied item list.
function M.actions(items)
  items = items or {}
  for _, provider in ipairs(picker_provider_order()) do
    if provider == "native" then
      open_native_actions_picker(items)
      return
    end

    local ok, opened = pcall(function()
      if provider == "snacks" then
        return open_snacks_actions_picker(items)
      elseif provider == "telescope" then
        return open_telescope_actions_picker(items)
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
