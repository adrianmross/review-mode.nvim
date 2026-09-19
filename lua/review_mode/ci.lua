-- CI failures: check-run annotations on the PR head, grouped by file.
--
-- Only runs that report annotations are asked for them, so a green PR costs a
-- single call. Loading ends with a "ci_loaded" event; review_mode.diagnostics
-- turns the result into its own diagnostic namespace.
local M = {}

local core = require("review_mode.state")
local util = require("review_mode.util")
local hooks = require("review_mode.hooks")

local state = core.state

local severities = {
  failure = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  notice = vim.diagnostic.severity.INFO,
}

-- path -> annotations, for the session that fetched them
local by_path = {}
-- bumped per load, so a reload supersedes a fetch still in flight
local load_id = 0

function M.enabled()
  local ci = state.config.ci
  return type(ci) == "table" and ci.diagnostics == true
end

function M.annotations(path)
  return by_path[path] or {}
end

function M.clear()
  by_path = {}
end

-- `gh api --paginate --jq` applies the filter per page; @json keeps each result
-- on one line whatever the payload holds, so stdout splits cleanly on "\n".
local function gh_lines(endpoint, jq, callback)
  util.system_async({ "gh", "api", "--paginate", endpoint, "--jq", jq }, {}, function(stdout, err)
    if not stdout then
      callback(nil, err)
      return
    end
    local rows = {}
    for line in vim.gsplit(stdout, "\n", { trimempty = true }) do
      local ok, row = pcall(vim.json.decode, line)
      if ok and type(row) == "table" then
        rows[#rows + 1] = row
      end
    end
    callback(rows)
  end)
end

local function warn(err)
  vim.notify("Review Mode: could not load CI annotations: " .. tostring(err), vim.log.levels.WARN)
end

--- Fetch the annotations of every check run on the PR head. GitHub only: local
--- reviews and GitLab have no check runs to ask.
function M.load_async()
  M.clear()
  if not M.enabled() or state.provider == "local" or state.provider == "gitlab" or not state.repo or not state.head then
    hooks.emit("ci_loaded", {})
    return
  end

  load_id = load_id + 1
  local id, generation = load_id, state.generation
  local function current()
    return id == load_id and core.is_current(generation)
  end
  local repo = state.repo
  gh_lines(
    string.format("repos/%s/commits/%s/check-runs?per_page=100", repo, state.head),
    -- ids as strings: they already pass 1e11, where a Lua number would print in
    -- exponent form long before it lost precision
    ".check_runs[] | select(.output.annotations_count > 0) | [(.id | tostring), .name] | @json",
    function(runs, err)
      if not current() then
        return
      end
      if not runs then
        -- by_path is already empty; announce it so stale diagnostics go too
        warn(err)
        hooks.emit("ci_loaded", {})
        return
      end

      local pending = #runs + 1
      local collected = {}
      local function done()
        pending = pending - 1
        if pending > 0 or not current() then
          return
        end
        by_path = collected
        hooks.emit("ci_loaded", { head = state.head })
      end

      for _, run in ipairs(runs) do
        local run_id, name = run[1], run[2]
        gh_lines(
          string.format("repos/%s/check-runs/%s/annotations?per_page=100", repo, run_id),
          ".[] | [.path, .start_line, .end_line, .annotation_level, .title, .message] | @json",
          function(rows, run_err)
            if not rows then
              warn(run_err)
            end
            for _, row in ipairs(rows or {}) do
              local path, first, last, level, title, message = unpack(row, 1, 6)
              if type(path) == "string" and tonumber(first) then
                local text = message ~= vim.NIL and message or ""
                if type(title) == "string" and title ~= "" then
                  text = title .. ": " .. text
                end
                collected[path] = collected[path] or {}
                table.insert(collected[path], {
                  check = name,
                  start_line = tonumber(first),
                  end_line = tonumber(last) or tonumber(first),
                  severity = severities[level] or vim.diagnostic.severity.INFO,
                  message = string.format("[%s] %s", name, text),
                })
              end
            end
            done()
          end
        )
      end
      done()
    end
  )
end

hooks.on("stop", M.clear)

return M
