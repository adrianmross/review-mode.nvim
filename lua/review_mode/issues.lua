-- Tracker-neutral issue reads. Providers are installed separately and opt-in.
local M = {}
local registered = {}
local core = require("review_mode.state")
local util = require("review_mode.util")

function M.register(name, provider)
  assert(type(name) == "string" and name:match("^[%w_-]+$"), "invalid issue provider name")
  assert(
    type(provider) == "table" and (type(provider.command) == "table" or type(provider.request) == "function"),
    "issue provider needs command argv or request callback"
  )
  registered[name] = provider
end

function M.resolve(root)
  local config = vim.deepcopy(core.state.config.issues or {})
  local project = (config.projects or {})[root]
  config.projects = nil
  config = vim.tbl_deep_extend("force", config, project or {})
  if project and project.command then
    config.command = vim.deepcopy(project.command)
  end
  -- Shared repo metadata selects only an installed provider and data options;
  -- executable overrides belong in the user's editor configuration.
  if not config.provider then
    local path = vim.fs.joinpath(root, ".oci-scm.json")
    if vim.uv.fs_stat(path) then
      local ok, lines = pcall(vim.fn.readfile, path)
      local decoded, repo = false, nil
      if ok then
        decoded, repo = pcall(vim.json.decode, table.concat(lines, "\n"))
      end
      if not decoded or type(repo) ~= "table" or repo.schema ~= "oci-scm.repo.v1" then
        return nil, "Invalid repository issue configuration"
      end
      if type(repo.issues) == "table" then
        config.provider, config.options = repo.issues.provider, repo.issues.options or {}
      end
    end
  end
  if not config.provider then
    return nil, "No issue provider configured for this project"
  end
  if type(config.provider) ~= "string" or not config.provider:match("^[%w_-]+$") then
    return nil, "Invalid issue provider name"
  end
  local provider = registered[config.provider]
  if not provider then
    if config.command then
      provider = { command = config.command, pattern = config.pattern }
    else
      local ok, value = pcall(require, "review_mode.issue_providers." .. config.provider)
      if not ok then
        return nil, "Issue provider " .. config.provider .. " is not installed"
      end
      local valid, err = pcall(M.register, config.provider, value)
      if not valid then
        return nil, tostring(err)
      end
      provider = value
    end
  end
  return config, provider
end

local function valid_response(value, operation)
  if type(value) ~= "table" or value.schema ~= "issue-provider.response.v1" then
    return false
  end
  local function issue(v)
    return type(v) == "table"
      and type(v.key) == "string"
      and v.key ~= ""
      and type(v.title) == "string"
      and v.title ~= ""
  end
  if operation == "get" then
    return issue(value.issue)
  end
  if type(value.items) ~= "table" then
    return false
  end
  for _, v in ipairs(value.items) do
    if not issue(v) then
      return false
    end
  end
  return true
end

function M.request(root, operation, value, opts, callback)
  opts = opts or {}
  if opts.offline and opts.refresh then
    callback(nil, "offline and refresh are mutually exclusive")
    return
  end
  local config, provider = M.resolve(root)
  if not config then
    callback(nil, provider)
    return
  end
  local request = {
    schema = "issue-provider.request.v1",
    operation = operation,
    options = config.options or {},
    offline = opts.offline or false,
    refresh = opts.refresh or false,
  }
  request[operation == "get" and "key" or "query"] = value
  local function finish(result, err)
    if err then
      callback(nil, err)
      return
    end
    if not valid_response(result, operation) then
      callback(nil, "Invalid issue provider response")
      return
    end
    callback(result)
  end
  if provider.request then
    provider.request({ root = root, config = config }, request, finish)
    return
  end
  local argv = vim.deepcopy(config.command or provider.command)
  if type(argv) ~= "table" or #argv == 0 then
    callback(nil, "Issue provider command must be an argv array")
    return
  end
  vim.list_extend(argv, { "--request", vim.json.encode(request) })
  local ok, process = pcall(
    vim.system,
    argv,
    { cwd = root, text = true, timeout = config.timeout_ms or 60000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          finish(nil, result.stderr ~= "" and result.stderr or "Issue provider request failed")
          return
        end
        local decoded, response = pcall(vim.json.decode, result.stdout)
        if not decoded then
          finish(nil, "Issue provider returned invalid JSON")
        else
          finish(response)
        end
      end)
    end
  )
  if not ok then
    finish(nil, tostring(process))
  end
end

function M.keys(text, pattern)
  local result, seen = {}, {}
  if not pattern then
    return result
  end
  for key in text:gmatch(pattern) do
    if not seen[key] then
      result[#result + 1], seen[key] = key, true
    end
  end
  return result
end

local function show(response)
  local issue, cache = response.issue, response.cache or {}
  local lines = {
    "# " .. issue.key .. ": " .. issue.title,
    "",
    "Status: " .. tostring(issue.status or "unknown"),
    "Assignee: " .. tostring(issue.assignee or "unassigned"),
    "Source: " .. tostring(cache.source or "provider") .. (cache.stale and " (stale snapshot)" or ""),
    "Fetched: " .. tostring(cache.fetchedAt or "unknown"),
    tostring(issue.url or ""),
    "",
  }
  vim.list_extend(lines, vim.split(issue.body or "", "\n", { plain = true }))
  util.open_lines_preview(lines, "markdown")
end

function M.view(key, opts)
  local root = core.state.root or util.repo_root() or vim.uv.cwd()
  local config, provider = M.resolve(root)
  if not config then
    vim.notify(provider, vim.log.levels.WARN)
    return
  end
  local generation = core.state.generation
  local function load(selected)
    if not selected then
      return
    end
    M.request(root, "get", selected, opts, function(response, err)
      -- A response from a previous project must not replace the current review.
      if core.state.generation ~= generation or (core.state.root and core.state.root ~= root) then
        return
      end
      if not response then
        vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      show(response)
    end)
  end
  if key and key ~= "" then
    load(key)
    return
  end
  local branch = util.system({ "git", "symbolic-ref", "--short", "HEAD" }, { cwd = root }) or ""
  local keys = M.keys(branch:upper(), config.pattern or provider.pattern)
  if #keys == 1 then
    load(keys[1])
  elseif #keys > 1 then
    vim.ui.select(keys, { prompt = "Linked issue" }, load)
  else
    vim.ui.input({ prompt = "Issue key: " }, load)
  end
end

function M.search(query)
  local root = core.state.root or util.repo_root() or vim.uv.cwd()
  local generation = core.state.generation
  local function current()
    return core.state.generation == generation and (not core.state.root or core.state.root == root)
  end
  M.request(root, "search", query, {}, function(response, err)
    if not current() then
      return
    end
    if not response then
      vim.notify("Review Mode: " .. tostring(err), vim.log.levels.WARN)
      return
    end
    vim.ui.select(response.items, {
      prompt = "Issues",
      format_item = function(v)
        return v.key .. ": " .. v.title
      end,
    }, function(issue)
      if issue and current() then
        M.view(issue.key)
      end
    end)
  end)
end

return M
