---
release: patch
---

Sessions end one way: a failed start, a restart and `:ReviewModeStop` all tear
down the same state and fire `ReviewModeStop`, and stop is quiet with nothing
running. Leaving the mode hands back your global mappings (not a buffer's `]c`
from gitsigns), a pack install no longer resets your `setup()` options, a
missing `gh` is a clean error, local reviews never call `gh` when HEAD moves,
stale hunks from before a commit no longer land, `mode.signs_when_out = false`
holds across buffers, the base diff restores your window options and survives
`:close` of the file window, `]f` works from the base pane and unified diff, the
unified diff no longer flags every file "No newline at end of file", viewed sync
keeps local marks and tells GitHub when you clear, and `:checkhealth` asks for
Neovim 0.11 and only the forge CLI your checkout uses.
