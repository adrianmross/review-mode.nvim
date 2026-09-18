-- Shared review session state.
--
-- One mutable table, deliberately: the session is a singleton and every module
-- reads and writes the same fields. Keeping it here rather than in init.lua
-- lets the feature modules require it instead of being handed a context object.
--
-- Nothing in here may require another review_mode module, or the requires cycle.
local M = {}

local default_comment_sign_text = ""

local defaults = {
  auto_open_first_change = true,
  follow_head = true,
  -- What :ReviewMode does on a branch with no PR: "local" reviews it against
  -- the default branch's merge base, "error" reports that there is no PR.
  no_pr = "local",
  -- "auto" | "github" | "gitlab" | "local"; auto reads the origin remote's
  -- host, and falls back to "local" when there is no remote to read
  provider = "auto",
  -- self-hosted GitLab hosts that auto should treat as GitLab
  gitlab_hosts = {},
  comments = {
    enabled = true,
    cache_ttl_seconds = 300,
    sign_text = default_comment_sign_text,
    sign_hl_group = "DiagnosticInfo",
    virtual_text = false,
    -- where :ReviewModeComment drafts: "panel" (the thread panel's composer)
    -- or "prompt" (a one-line vim.ui.input)
    compose = "panel",
    show_resolved = false,
    -- Diagnostics: review threads as vim.diagnostic entries ------------------
    -- Off by default: once on, ]d/[d, statusline counts and Trouble mix review
    -- comments in with LSP diagnostics. display stays off so the namespace
    -- feeds navigation and floats without re-drawing the plugin's own signs.
    diagnostics = {
      enabled = false,
      severity = { unresolved = "INFO", outdated = "HINT", resolved = "HINT" },
      display = { signs = false, virtual_text = false, underline = false },
    },
    -- End diagnostics ---------------------------------------------------------
    -- Resolve feedback --------------------------------------------------------
    -- How long the line of a just-resolved (or just-unresolved) thread stays
    -- marked, in milliseconds. 0 turns the confirmation off.
    resolve_flash_ms = 1200,
    -- End resolve feedback ------------------------------------------------------
    -- Conditional requests ----------------------------------------------------
    -- Revalidate the REST comment list with If-None-Match instead of
    -- re-downloading it once cache_ttl_seconds is up. A 304 costs nothing
    -- against the rate limit and only refreshes the cache timestamp. ETags are
    -- per page on GitHub, so one is stored per page and each page is
    -- revalidated on its own. The GraphQL thread query is a POST and cannot do
    -- this; it still goes by cache_ttl_seconds.
    conditional_requests = true,
    -- End conditional requests -------------------------------------------------
  },
  panel = {
    auto_open = false,
    follow_cursor = true,
    position = "right",
    width = 60,
  },
  diff = {
    fast_diffopt = "internal,filler,closeoff,indent-heuristic,linematch:0",
    full_file = false,
    layout = "side_by_side",
    partial_line_highlights = true,
    unified_context = 3,
    use_fast_diffopt = true,
  },
  gitsigns = {
    enabled = true,
  },
  nvim_tree = {
    enabled = true,
    show_comments = true,
    show_viewed = true,
  },
  mode = {
    enabled = true,
    workspace = "inplace",
    signs_when_out = true,
    gitsigns_follows = true,
    keys = {
      ["]h"] = "next_hunk",
      ["[h"] = "prev_hunk",
      ["]c"] = "next_comment",
      ["[c"] = "prev_comment",
      ["]f"] = "next_file",
      ["[f"] = "prev_file",
      ["<Esc>"] = "leave",
    },
  },
  -- Keys for the whole session: installed by :ReviewMode, removed by
  -- :ReviewModeStop, and kept while you step out of the mode. Everything here is
  -- <leader>-prefixed, so it shadows nothing in stock Vim; the mode layer above
  -- holds the keys that do (]c is Vim's own diff jump), which is why only those
  -- go away when you step out. A value is an action name, a function, or
  -- { action, mode = { "n", "v" } }. Set session.keys = {} to install none.
  session = {
    keys = {
      ["<leader>rt"] = "toggle_panel",
      ["<leader>rc"] = { "comment", mode = { "n", "v" } },
      ["<leader>rr"] = "reply",
      ["<leader>rR"] = "toggle_resolve",
      ["<leader>rl"] = "list_viewed",
      ["<leader>rv"] = "toggle_viewed",
      ["<leader>rd"] = "old_toggle",
      ["<leader>rD"] = "toggle_diff_layout",
      ["<leader>rf"] = "toggle_diff_full_file",
      ["<leader>ra"] = "actions",
      ["<leader>rS"] = "open_pending",
      ["<leader>rq"] = "stop",
    },
  },
  picker = {
    provider = "auto",
  },
  -- Observers (on_*) are told what happened; overrides are asked how to do
  -- something and their return value replaces the built-in behavior.
  hooks = {},
  viewed = {
    enabled = true,
    sync = false,
    state_path = nil,
  },
  performance = {
    ui_refresh_debounce_ms = 50,
    hunk_prefetch = {
      enabled = true,
      count = 8,
      concurrency = 2,
      focused_delay_ms = 0,
      gitsigns_delay_ms = 5,
    },
    background_hunk_scan = {
      enabled = true,
      max_files = 5000,
      delay_ms = 250,
    },
    -- gh response cache -------------------------------------------------------
    -- Duration passed to `gh api --cache` for reads that repeat and cannot go
    -- stale in a way that misleads. "0" or "" turns it off.
    --
    -- Today that is the PR's GraphQL node id, which never changes. Everything
    -- else is deliberately left out: the PR's head SHA is re-read precisely to
    -- notice that HEAD moved, :ReviewModeStatus and :ReviewModeChecks are run to
    -- see what changed, the viewed-state query would resurrect stale marks, and
    -- the comment list uses If-None-Match instead -- fresh *and* free.
    -- `--cache` is a flag of `gh api` alone; `gh pr view` and `gh repo view`
    -- reject it.
    gh_metadata_cache = "10m",
    -- End gh response cache ----------------------------------------------------
  },
  commands = true,
  -- review a PR without checking it out (:ReviewModeCheckout). Review worktrees
  -- are only ever removed by :ReviewModeCheckoutClean; "manual" is the only mode.
  checkout = {
    cleanup = "manual",
  },
}

local state = {
  active = false,
  config = vim.deepcopy(defaults),
  repo = nil,
  pr = nil,
  base = nil,
  head = nil,
  root = nil,
  files = {},
  file_stats = {},
  file_order = {},
  file_index = {},
  dirs = {},
  hunks = {},
  hunks_loaded = {},
  hunks_loading = {},
  hunk_callbacks = {},
  prefetch_queue = {},
  prefetch_seen = {},
  prefetch_active = 0,
  background_hunk_scan_loading = false,
  comments = {},
  comment_threads = {},
  comments_loading = false,
  viewed = {},
  viewed_order = {},
  viewed_sync_queue = {},
  viewed_store = nil,
  dir_totals = nil,
  viewed_loading = false,
  viewed_sync_loading = false,
  pr_node_id = nil,
  generation = 0,
  maps_loaded = false,
  maps_loading = false,
  metadata_loaded = false,
  ui_refresh_pending = false,
  old_win = nil,
  old_buf = nil,
  old_target_win = nil,
  old_target_buf = nil,
  old_loading = false,
  old_diffopt = nil,
  old_fold_options = nil,
  old_layout = nil,
  old_path = nil,
  old_closing = false,
  gitsigns_base_applied = false,
  in_mode = false,
  thread_highlights_set = false,
  panel_win = nil,
  panel_buf = nil,
  panel_threads = nil,
  panel_rows = nil,
  panel_target = nil,
  panel_refresh_pending = false,
  composer_win = nil,
  composer_buf = nil,
  composer_source = nil,
  composer_submit = nil,
  composer_prompt = nil,
  head_log_path = nil,
  head_log_stamp = nil,
  saved_keys = {},
  saved_session_keys = {},
  workspace_tab = nil,
  return_tab = nil,
  -- per-session override of config.mode.workspace ("tab" for checkout reviews)
  workspace = nil,
  -- Local reviews ------------------------------------------------------------
  -- the right-hand side of every review diff: nil for a PR (always HEAD), "" for
  -- a local review of the working tree, or a ref to compare against instead
  head_ref = nil,
  -- <git-dir>/review-mode/<key>.json while a local review is active
  local_store = nil,
  -- End local reviews ---------------------------------------------------------
}

M.defaults = defaults
M.state = state
M.default_comment_sign_text = default_comment_sign_text

function M.normalize_config(opts)
  opts = opts or {}
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if config.diff.layout ~= "side_by_side" and config.diff.layout ~= "unified" then
    config.diff.layout = defaults.diff.layout
  end
  config.diff.unified_context = math.max(0, tonumber(config.diff.unified_context) or defaults.diff.unified_context)

  local mode = config.mode or {}
  if mode.workspace ~= "inplace" and mode.workspace ~= "tab" then
    mode.workspace = defaults.mode.workspace
  end
  if type(mode.keys) ~= "table" then
    mode.keys = {}
  end
  config.mode = mode

  local panel = config.panel or {}
  if panel.position ~= "left" and panel.position ~= "right" then
    panel.position = defaults.panel.position
  end
  panel.width = math.max(30, tonumber(panel.width) or defaults.panel.width)
  config.panel = panel

  if config.no_pr ~= "local" and config.no_pr ~= "error" then
    config.no_pr = defaults.no_pr
  end

  if config.comments.compose ~= "panel" and config.comments.compose ~= "prompt" then
    config.comments.compose = defaults.comments.compose
  end

  config.session = config.session or {}
  if type(config.session.keys) ~= "table" then
    config.session.keys = {}
  end

  -- tbl_deep_extend merges an empty table as "nothing to add", so an explicit
  -- keys = {} used to leave every default in place. Honor it as "none"; any
  -- other table merges over the defaults, and a false value drops one key.
  for _, layer in ipairs({ "mode", "session" }) do
    local given = opts[layer] and opts[layer].keys
    if type(given) == "table" and next(given) == nil then
      config[layer].keys = {}
    end
  end

  if type(config.hooks) ~= "table" then
    config.hooks = {}
  end

  local picker = config.picker or {}
  if
    picker.provider ~= "auto"
    and picker.provider ~= "native"
    and picker.provider ~= "snacks"
    and picker.provider ~= "telescope"
  then
    picker.provider = defaults.picker.provider
  end
  config.picker = picker

  if
    config.provider ~= "auto"
    and config.provider ~= "github"
    and config.provider ~= "gitlab"
    and config.provider ~= "local"
  then
    config.provider = defaults.provider
  end
  if type(config.gitlab_hosts) ~= "table" then
    config.gitlab_hosts = {}
  end

  return config
end

function M.base_ref()
  local base = state.base or "main"
  if base:match("^origin/") or base:match("^refs/") or base:match("^%x%x%x%x%x%x%x+") then
    return base
  end
  return "origin/" .. base
end

-- Local reviews -----------------------------------------------------------------

--- The range every review `git diff` runs over.
---
--- A PR review always compares its base against HEAD, and passing nothing new
--- keeps exactly that. A local review may name its own head instead, and an
--- empty head_ref means the working tree, so uncommitted edits are part of the
--- review.
function M.diff_range()
  local head = state.head_ref
  if head == nil then
    return M.base_ref() .. "...HEAD"
  end
  if head == "" then
    return M.base_ref()
  end
  return M.base_ref() .. ".." .. head
end

-- End local reviews ---------------------------------------------------------------

function M.cache_key()
  if not state.repo or not state.pr then
    return nil
  end
  return string.format("%s#%s", state.repo, state.pr)
end

function M.next_generation()
  state.generation = state.generation + 1
  return state.generation
end

function M.is_current(generation)
  return state.active and state.generation == generation
end

function M.reset_changed_data()
  state.files = {}
  state.file_stats = {}
  state.file_order = {}
  state.file_index = {}
  state.dirs = {}
  state.hunks = {}
  state.hunks_loaded = {}
  state.hunks_loading = {}
  state.hunk_callbacks = {}
  state.prefetch_queue = {}
  state.prefetch_seen = {}
  state.prefetch_active = 0
  state.background_hunk_scan_loading = false
  state.maps_loaded = false
  state.maps_loading = false
end

function M.reset_review_data()
  M.reset_changed_data()
  state.comments = {}
  state.comment_threads = {}
  state.comments_loading = false
  state.viewed = {}
  state.viewed_order = {}
  state.viewed_sync_queue = {}
  state.viewed_loading = false
  state.viewed_sync_loading = false
  state.pr_node_id = nil
end

function M.repo_parts()
  local owner, name = tostring(state.repo or ""):match("^([^/]+)/(.+)$")
  return owner, name
end

return M
