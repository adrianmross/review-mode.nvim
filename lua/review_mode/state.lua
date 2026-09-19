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
  -- when the PR is yours and a commit lands mid-review, offer (always with a
  -- confirmation) to reply "Fixed in <sha>" to the unresolved threads it
  -- changed, and resolve them
  author = { offer_resolve = true },
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
    -- hide whitespace-only changes, like git diff -w / GitHub's ?w=1
    ignore_whitespace = false,
    layout = "side_by_side",
    partial_line_highlights = true,
    unified_context = 3,
    use_fast_diffopt = true,
    -- mark lines a PR moves unchanged ("moved from a.lua:12"), and let ]c / [c
    -- pass over hunks that are nothing but moved code
    detect_moved = true,
    skip_moved = true,
  },
  -- CI check-run annotations on the PR head as vim.diagnostic entries, in a
  -- namespace of their own (GitHub only)
  ci = {
    diagnostics = true,
  },
  review = {
    -- before an APPROVE, list what the review has not covered yet (unviewed
    -- files and hunks, CI failures you have not commented on, unresolved
    -- threads) in the confirmation
    submit_check = true,
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
    -- ]c is a hunk, as in stock Vim and gitsigns (in a diff window it stays
    -- Vim's own change jump); ]r is a thread, since r is the comment letter.
    keys = {
      ["]c"] = "next_hunk",
      ["[c"] = "prev_hunk",
      ["]r"] = "next_comment",
      ["[r"] = "prev_comment",
      ["]f"] = "next_file",
      ["[f"] = "prev_file",
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
      -- one comment key: replies when a thread is on the line, else starts one
      ["<leader>rr"] = { "comment_or_reply", mode = { "n", "v" } },
      ["<leader>rR"] = { "comment", mode = { "n", "v" } },
      ["<leader>rx"] = "toggle_resolve",
      ["<leader>rf"] = "list_viewed",
      ["<leader>rv"] = "toggle_viewed",
      ["<leader>rh"] = "toggle_hunk_viewed",
      ["<leader>rd"] = "old_toggle",
      ["<leader>rD"] = "toggle_diff_layout",
      ["<leader>ra"] = "actions",
      ["<leader>rs"] = "open_pending",
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
    -- ]c / [c pass over hunks you marked viewed
    skip_viewed_hunks = false,
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
  -- the order ]f / [f, the next-unviewed jump and the file picker walk the PR
  -- in: "smart" reads code before the files that use it, then docs and
  -- lockfiles, then tests (see lua/review_mode/order.lua); "diff" is git's
  -- alphabetical order
  files = {
    order = "smart",
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
  -- per renamed (or copied) path, the path it had at the base
  renames = {},
  -- the sha the base side of the review is read from (see M.base_rev)
  merge_base = nil,
  file_stats = {},
  file_order = {},
  file_index = {},
  dirs = {},
  hunks = {},
  hunks_loaded = {},
  hunks_loading = {},
  -- per path, a content key for each entry of hunks (see viewed.hunk_keys)
  hunk_hashes = {},
  -- per path, { first, last } new-side lines for each entry of hunks
  hunk_ranges = {},
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
  -- per path, the hunk keys marked viewed
  hunk_viewed = {},
  viewed_sync_queue = {},
  viewed_store = nil,
  dir_totals = nil,
  viewed_loading = false,
  viewed_sync_loading = false,
  viewed_sync_pending = false,
  pr_node_id = nil,
  generation = 0,
  maps_loaded = false,
  maps_loading = false,
  -- bumped whenever the changed-file maps are dropped: a follow-HEAD reload
  -- keeps the session's generation, so hunk loads started against the old HEAD
  -- check this one before they write
  maps_generation = 0,
  metadata_loaded = false,
  ui_refresh_pending = false,
  old_win = nil,
  old_buf = nil,
  old_target_win = nil,
  old_target_buf = nil,
  old_loading = false,
  old_diffopt = nil,
  old_window_options = nil,
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
  -- <git-common-dir>/review-mode/<key>.json while a local review is active
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

  -- "force" lets a non-table (comments = false) replace the whole table; the
  -- documented off switch is comments.enabled = false, so treat anything else
  -- as the defaults rather than crash on the next field read
  if type(config.comments) ~= "table" then
    config.comments = vim.deepcopy(defaults.comments)
  end
  if config.comments.compose ~= "panel" and config.comments.compose ~= "prompt" then
    config.comments.compose = defaults.comments.compose
  end
  -- the same for files = false: the order is read on every changed-file load
  if type(config.files) ~= "table" then
    config.files = vim.deepcopy(defaults.files)
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
  -- a checkout fetches the base from the PR's own repo into a ref of its own
  if state.base_ref then
    return state.base_ref
  end
  local base = state.base or "main"
  -- a full object name only: "20250101-release" is a branch, not a commit
  local sha = base:match("^%x+$") and (#base == 40 or #base == 64)
  if sha or base:match("^origin/") or base:match("^refs/") then
    return base
  end
  return "origin/" .. base
end

--- The commit the base side of the review is read from (`git show`, the
--- gitsigns base): the merge base `diff_range` compares from, not the tip of
--- the base branch, which has moved on once main gets new commits. A local
--- review's base already is that merge base (see providers/local.lua); a PR
--- review resolves it on each load into state.merge_base.
function M.base_rev()
  return state.merge_base or M.base_ref()
end

--- The path `path` had at the base: its old name when the review renames it.
function M.base_path(path)
  return state.renames[path] or path
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

-- host of the session's origin remote, looked up once per session
local origin = {}
local function origin_host()
  if origin.root ~= state.root or origin.generation ~= state.generation then
    local out = vim.system({ "git", "remote", "get-url", "origin" }, { cwd = state.root, text = true }):wait()
    local url = out.code == 0 and vim.trim(out.stdout) or ""
    -- only a URL (scheme://host/...) or scp form (host:path) names a host; a
    -- path remote (".", ../repo, /srv/repo.git, other-clone) does not. A host
    -- needs no dot: "localhost" or an intranet name is a host all the same.
    local is_url = url:find("://", 1, true) or url:match("^[^/]+:[^/]")
    local host = is_url and require("review_mode.providers").remote_host(url) or nil
    origin = { root = state.root, generation = state.generation, host = host or "" }
  end
  return origin.host
end

--- The key a PR's comment cache and viewed state are stored under. GitHub on
--- github.com keeps the plain repo#pr it always had; anything else is scoped,
--- so a GitLab project, an Enterprise repo and github.com's same-named repo,
--- or two clones' local reviews of the same branch never share an entry.
function M.cache_key()
  if not state.repo or not state.pr then
    return nil
  end
  local key = string.format("%s#%s", state.repo, state.pr)
  if state.provider == "local" then
    -- the store path is under the clone's own .git, so it tells clones apart
    return string.format("local:%s:%s", vim.fn.sha256(tostring(state.local_store)):sub(1, 12), key)
  end
  if state.provider == "gitlab" then
    return string.format("gitlab:%s:%s", require("review_mode.providers.gitlab").host(), key)
  end
  local host = state.root and origin_host() or ""
  if host ~= "" and host ~= "github.com" then
    return string.format("github:%s:%s", host, key)
  end
  return key
end

function M.next_generation()
  state.generation = state.generation + 1
  return state.generation
end

function M.is_current(generation)
  return state.active and state.generation == generation
end

--- A token for work against the changed-file maps as they are now, and whether
--- that work is still current: same session, and the maps not rebuilt since.
function M.maps_token()
  return { generation = state.generation, maps = state.maps_generation }
end

function M.maps_current(token)
  return M.is_current(token.generation) and state.maps_generation == token.maps
end

function M.reset_changed_data()
  state.maps_generation = state.maps_generation + 1
  state.files = {}
  state.renames = {}
  state.file_stats = {}
  state.file_order = {}
  state.file_index = {}
  state.dirs = {}
  state.hunks = {}
  state.hunks_loaded = {}
  state.hunks_loading = {}
  state.hunk_hashes = {}
  state.hunk_ranges = {}
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
  state.merge_base = nil
  state.comments = {}
  state.comment_threads = {}
  state.comments_loading = false
  state.viewed = {}
  state.viewed_order = {}
  state.hunk_viewed = {}
  state.viewed_sync_queue = {}
  state.viewed_loading = false
  state.viewed_sync_loading = false
  state.viewed_sync_pending = false
  state.pr_node_id = nil
end

function M.repo_parts()
  local owner, name = tostring(state.repo or ""):match("^([^/]+)/(.+)$")
  return owner, name
end

return M
