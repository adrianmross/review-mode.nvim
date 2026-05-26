local state = require "pr_review"

local Decorator = require("nvim-tree.renderer.decorator"):extend()

function Decorator:new()
  self.enabled = true
  self.highlight_range = "name"
  self.icon_placement = "after"
  self.changed_icon = { str = "●", hl = { "DiagnosticWarn" } }
  self.folder_icon = { str = "•", hl = { "DiagnosticInfo" } }
end

local function relpath(node)
  local root = state.root()
  if not root or not node.absolute_path then
    return nil
  end

  local rel = vim.fs.relpath(root, node.absolute_path)
  if rel == "." then
    return nil
  end

  return rel
end

function Decorator:icons(node)
  local rel = relpath(node)
  if not rel or not state.is_active() then
    return nil
  end

  if state.is_changed_file(rel) then
    return { self.changed_icon }
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
    return "DiagnosticWarn"
  end

  if state.is_changed_dir(rel) then
    return "DiagnosticInfo"
  end

  return nil
end

return Decorator
