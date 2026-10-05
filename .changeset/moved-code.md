---
release: patch
---

Code a PR moves without changing is now marked as moved instead of new: moved-in lines get a `»` sign and the block's first line says where it came from (`moved from a.lua:120`), and `]c` / `[c` pass over hunks that only move code (`diff.skip_moved`, on by default; toggle it from the actions picker). Set `diff.detect_moved = false` to turn detection off.
