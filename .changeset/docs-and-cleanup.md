---
release: patch
---

The help file now tags every command (including :ReviewModeLocal,
:ReviewModeLocalComments and the :ReviewModeNextChange / :PrViewed* aliases),
has API and events sections and a complete table of contents, and both options
blocks list every default, session keys included. scripts/check-docs.lua
catches the next drift. Removed dead code: unused locals in init.lua, the
never-read viewed order (older state files still load), and unused exports in
diff, util and the providers. Reviewing a PR with :ReviewModeCheckout while a
session runs no longer prints an extra "stopped".
