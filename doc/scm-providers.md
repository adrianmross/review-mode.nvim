# SCM providers

GitHub is built in. Other providers are external Lua modules on Neovim's
runtimepath: `review_mode.providers.<name>`. ReviewMode loads the selected module
when a review starts. A missing or invalid provider reports an error; it never
falls back to GitHub. Plugins may also call:

```lua
require("review_mode").register_provider("my_scm", require("my_plugin.provider"))
```

Set a default provider or override it by the absolute Git checkout root. Worktrees
have distinct roots and can have distinct settings. Selection is evaluated on
every `:ReviewMode` start; it does not change global CLI contexts.

```lua
require("review_mode").setup({
  scm = {
    provider = "github",
    projects = {
      ["/absolute/path/to/project"] = {
        provider = "oci",
        args = { "--context", "my-context", "--auth", "security_token", "-R", "repository-ocid" },
        -- pr = "PR-ocid-or-source-branch", -- omit to use the current branch
        base_remote = "origin",
      },
    },
  },
})
```

For external providers, `command` overrides the executable; `args` is an argv list, never a shell string.
Project args replace the default list in full. `pr` selects a PR.
`base_remote` selects the local Git remote used for base diffs; fetch the base
branch before reviewing. Provider/repository/PR keys isolate cached comments
and local viewed state. Configuration lives in your Neovim setup; ReviewMode
does not execute configuration from an untrusted checkout.

The OCI plugin is shipped outside this repository under
`oci-scm/integrations/review-mode.nvim`. Add that directory to runtimepath.
See its README for installation and OCI capabilities.

## Provider interface

A provider exports `command` (executable name), optional `env_prefix`
(default `REVIEW_MODE_`), and `capabilities`. It implements:

| Method | Result |
| --- | --- |
| `metadata(ctx, callback)` | `callback({repo = id, meta = {number = id, baseRefName = branch, headRefOid = sha}}, nil)` |
| `threads(ctx, callback)` | `callback(threads, nil)`; thread shape below |
| `status(ctx, callback)` | Normalized fields: title, state, headRefName, baseRefName, optional URL/review/mergeability |
| `url(ctx, callback)` | PR HTTPS URL or `callback(nil, error)` |
| `reply(ctx, comment, body)` | Synchronous verified result, or `nil, error` |
| `comment(ctx, path, start_line, end_line, body)` | Synchronous verified result, or `nil, error` |

Thread shape:

```lua
{
  id = "thread-id", path = "src/file", line = 10,
  isResolved = false, isOutdated = false,
  comments = { nodes = {
    { id = "comment-id", body = "Review text", author = { login = "reviewer" } },
  } },
}
```

Replies must inherit their root's coordinates when the SCM API omits them.
An outdated comment is not a resolved thread.

`ctx` contains `root`, effective project `config`, `repo`, `pr`, and `head`.
`ctx.json(argv, callback)` runs the selected executable with configured args,
decodes JSON, and discards callbacks from an obsolete review generation.
`ctx.json_sync(argv)` returns decoded JSON/error.
`ctx.system(argv, opts)` runs arbitrary argv in the review root and returns
stdout/error. Provider methods must return errors rather than assume success
after a submission. The core owns caching, UI annotations and navigation.

Optional `checks(ctx, callback)` returns text for the checks preview.
Otherwise checks use the selected executable's `pr checks [PR]` command.
`env_prefix` supplies optional REPO, PR, BASE and HEAD variables.

`capabilities.resolve = true` also requires
`resolve(ctx, comment, resolved)`, returning a verified result/error.
Remote viewed-state sync currently belongs to the built-in GitHub provider;
external providers keep viewed state local and declare `viewed = false`.
Unsupported actions produce a message and make no SCM call.
