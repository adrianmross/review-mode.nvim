local M = {}
local providers =
  { github = { command = "gh", env_prefix = "GH_REVIEW_", capabilities = { viewed = true, resolve = true } } }

function M.register(name, provider)
  assert(type(name) == "string" and name:match("^[%w_-]+$"), "invalid SCM provider name")
  assert(type(provider) == "table" and type(provider.command) == "string", "provider.command is required")
  if name ~= "github" then
    for _, method in ipairs({ "metadata", "threads", "reply", "comment", "status", "url" }) do
      assert(type(provider[method]) == "function", "provider." .. method .. " is required")
    end
  end
  if name ~= "github" then
    assert(
      not (provider.capabilities or {}).viewed,
      "remote viewed sync currently requires the built-in github provider"
    )
    if (provider.capabilities or {}).resolve then
      assert(type(provider.resolve) == "function", "provider.resolve is required")
    end
  end
  providers[name] = provider
end

function M.resolve(config, root)
  local effective = vim.deepcopy(config)
  local project = (effective.projects or {})[root]
  effective.projects = nil
  effective = vim.tbl_deep_extend("force", effective, project or {})
  if project and project.args then
    effective.args = vim.deepcopy(project.args)
  end
  local name = effective.provider or "github"
  if not providers[name] then
    local ok, provider = pcall(require, "review_mode.providers." .. name)
    if not ok then
      return nil, "SCM provider " .. name .. " is not installed: " .. tostring(provider)
    end
    local valid, err = pcall(M.register, name, provider)
    if not valid then
      return nil, err
    end
  end
  return effective, providers[name]
end

function M.command(config, provider, args)
  local command = { config.command or provider.command }
  vim.list_extend(command, config.args or {})
  return vim.list_extend(command, args)
end

return M
