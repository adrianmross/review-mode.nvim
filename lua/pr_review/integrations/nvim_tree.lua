local state = require("pr_review")

local Decorator = require("nvim-tree.renderer.decorator"):extend()

function Decorator:new()
  self.enabled = true
  self.highlight_range = "name"
  self.icon_placement = "after"
  self.changed_icon = { str = "●", hl = { "DiagnosticWarn" } }
  self.viewed_icon = { str = "✓", hl = { "DiagnosticOk" } }
  self.comment_icon = { str = "◆", hl = { "DiagnosticInfo" } }
  self.folder_icon = { str = "•", hl = { "DiagnosticInfo" } }
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

function Decorator:icons(node)
  local rel = relpath(node)
  if not rel or not state.is_active() then
    return nil
  end

  if state.is_changed_file(rel) then
    local config = state.config()
    local icons = {}
    if config.nvim_tree.show_comments and state.comment_count(rel) > 0 then
      icons[#icons + 1] = self.comment_icon
    end
    if config.nvim_tree.show_viewed and state.is_viewed_file(rel) then
      icons[#icons + 1] = self.viewed_icon
    else
      icons[#icons + 1] = self.changed_icon
    end
    return icons
  end

  if state.is_changed_dir(rel) then
    return { self.folder_icon }
  end

  return nil
end

function Decorator:highlight_group(node)
  local rel = relpath(node)
  if not rel or not state.is_active() then
    return nil
  end

  if state.is_changed_file(rel) then
    local config = state.config()
    if config.nvim_tree.show_viewed and state.is_viewed_file(rel) then
      return "DiagnosticOk"
    end
    return "DiagnosticWarn"
  end

  if state.is_changed_dir(rel) then
    return "DiagnosticInfo"
  end

  return nil
end

return Decorator
