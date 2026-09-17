---
release: minor
---

Review threads can be published as `vim.diagnostic` entries in their own
namespace, so `]d`/`[d`, `vim.diagnostic.open_float`, Trouble and statusline
diagnostic counts work on review comments. Off by default
(`comments.diagnostics.enabled`), with severities per thread state and a
namespace display that draws nothing, so the diagnostics feed navigation and
counts without duplicating the plugin's own signs and virtual text.

Adds `:ReviewModeQuickfix [unresolved|all]`, `:ReviewModeDiagnosticsToggle`, and
`api.quickfix_items(opts)` / `api.set_quickfix(opts)`.
