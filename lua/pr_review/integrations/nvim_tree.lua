local state = require("pr_review")

local Decorator = require("nvim-tree.renderer.decorator"):extend()

local changed_hl = "PrReviewTreeChanged"
local viewed_hl = "PrReviewTreeViewed"

local function ensure_highlights()
  pcall(vim.api.nvim_set_hl, 0, changed_hl, { default = true, fg = "#F59E0B" })
  pcall(vim.api.nvim_set_hl, 0, viewed_hl, { default = true, fg = "#22C55E" })
end

function Decorator:new()
  ensure_highlights()
  self.enabled = true
  self.highlight_range = "name"
  self.icon_placement = "after"
  self.viewed_icon = { str = "✓", hl = { viewed_hl } }
end

local relpath_cache = setmetatable({}, { __mode = "k" })

local function relpath(node)
  local root = state.root()
  if not root or not node.absolute_path then
    return nil
  end

  local cached = relpath_cache[node]
  if cached and cached.root == root and cached.absolute_path == node.absolute_path then
    return cached.rel
  end

  local rel = vim.fs.relpath(root, node.absolute_path)
  if rel == "." then
    rel = nil
  end

  relpath_cache[node] = {
    root = root,
    absolute_path = node.absolute_path,
    rel = rel,
  }

  return rel
end

function Decorator:changed_icon(rel, show_unviewed_count)
  local count = show_unviewed_count and state.unviewed_count(rel) or 0
  local label = count > 0 and string.format("☐ %d", count) or "☐"
  return { str = label, hl = { changed_hl } }
end

function Decorator:comment_icon(rel)
  local count = state.unresolved_comment_count(rel)
  return { str = string.format("◆ %d", count), hl = { "DiagnosticInfo" } }
end

function Decorator:icons(node)
  ensure_highlights()

  local rel = relpath(node)
  if not rel or not state.is_active() then
    return nil
  end

  if state.is_changed_file(rel) then
    local config = state.config()
    local icons = {}
    if config.nvim_tree.show_comments and state.unresolved_comment_count(rel) > 0 then
      icons[#icons + 1] = self:comment_icon(rel)
    end
    if config.nvim_tree.show_viewed and state.is_viewed_file(rel) then
      icons[#icons + 1] = self.viewed_icon
    else
      icons[#icons + 1] = self:changed_icon(rel, config.nvim_tree.show_viewed)
    end
    return icons
  end

  if state.is_changed_dir(rel) then
    local config = state.config()
    local icons = {}
    if config.nvim_tree.show_comments and state.unresolved_comment_count(rel) > 0 then
      icons[#icons + 1] = self:comment_icon(rel)
    end
    if config.nvim_tree.show_viewed and state.is_viewed_dir(rel) then
      icons[#icons + 1] = self.viewed_icon
      return icons
    end
    icons[#icons + 1] = self:changed_icon(rel, config.nvim_tree.show_viewed)
    return icons
  end

  return nil
end

function Decorator:highlight_group(node)
  ensure_highlights()

  local rel = relpath(node)
  if not rel or not state.is_active() then
    return nil
  end

  if state.is_changed_file(rel) then
    local config = state.config()
    if config.nvim_tree.show_viewed and state.is_viewed_file(rel) then
      return viewed_hl
    end
    return changed_hl
  end

  if state.is_changed_dir(rel) then
    local config = state.config()
    if config.nvim_tree.show_viewed and state.is_viewed_dir(rel) then
      return viewed_hl
    end
    return changed_hl
  end

  return nil
end

return Decorator
