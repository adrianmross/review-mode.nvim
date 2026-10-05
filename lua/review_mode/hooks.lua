-- Events and behavior overrides.
--
-- Two jobs, and they are deliberately separate:
--
--   * emit()     announces that something happened. Every listener runs; return
--                values are ignored. Used for "tell me when a review starts".
--   * resolve()  asks how something should be done, and the answer replaces the
--                built-in behavior. Used for "open the panel my way".
--
-- Each event reaches three audiences, in this order: the plugin's own wiring
-- (on()), the user's `hooks` config table, and a User autocommand. That is also
-- how the feature modules avoid requiring init.lua back: viewed state emits
-- "viewed_changed" rather than calling the tree refresh directly.
local M = {}

local core = require("review_mode.state")

local subscribers = {}
local warned = {}

local function pattern_for(event)
  return "ReviewMode" .. event:gsub("_(%l)", string.upper):gsub("^%l", string.upper)
end

M.pattern_for = pattern_for

--- Subscribe from inside the plugin. Not part of the user-facing API; users get
--- the `hooks` config table and the User autocommands.
--- Returns a function that removes the subscription again.
function M.on(event, fn)
  subscribers[event] = subscribers[event] or {}
  local list = subscribers[event]
  table.insert(list, fn)
  return function()
    for i, current in ipairs(list) do
      if current == fn then
        table.remove(list, i)
        return true
      end
    end
    return false
  end
end

local function user_hook(name)
  local hooks = core.state.config and core.state.config.hooks
  local fn = hooks and hooks[name]
  if type(fn) == "function" then
    return fn
  end
  return nil
end

-- A broken user hook must not take the review down with it, and it must not
-- spam: say it once per hook and carry on with the built-in behavior.
local function call_hook(name, fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  if not warned[name] then
    warned[name] = true
    vim.notify(string.format("Review Mode hook %q failed: %s", name, tostring(result)), vim.log.levels.ERROR)
  end
  return nil
end

--- Announce that something happened. `data` is passed to every listener and
--- becomes the User autocommand's `data`.
function M.emit(event, data)
  for _, fn in ipairs(subscribers[event] or {}) do
    call_hook(event, fn, data)
  end

  local name = "on_" .. event
  local fn = user_hook(name)
  if fn then
    call_hook(name, fn, data)
  end

  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern_for(event),
    modeline = false,
    data = data,
  })
end

--- Ask how something should be done. When the user supplies `hooks[name]` and it
--- returns a non-nil value, that value wins and `fallback` never runs; returning
--- nil means "use the default", so a hook can decide case by case.
function M.resolve(name, ctx, fallback)
  local fn = user_hook(name)
  if fn then
    local result = call_hook(name, fn, ctx)
    if result ~= nil then
      return result
    end
  end
  if fallback then
    return fallback(ctx)
  end
  return nil
end

--- Ask a yes/no question the user can veto. Defaults to `default` when no hook
--- is configured or the hook returns nil.
function M.allow(name, ctx, default)
  local result = M.resolve(name, ctx, nil)
  if result == nil then
    return default
  end
  return result ~= false
end

function M.reset()
  subscribers = {}
  warned = {}
end

return M
