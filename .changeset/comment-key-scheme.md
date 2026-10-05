---
release: minor
---

One comment key. `<leader>rr` comments on the line: it replies to the thread
already there, starts one where there is none, and always starts one over a
visual range; a line with several threads asks which. `<leader>rR` starts a new
thread even over an existing one. `<leader>rc` is gone.

`r` is the comment letter throughout, and the panel's keys are the session keys
without `<leader>r`:

- hunks move to `]c`/`[c` (Vim's own change jump in a diff window), threads to
  `]r`/`[r`; `]h` is gone
- resolve `rR` → `rx` (panel `R` → `x`), pending review `rS` → `rs` (panel
  `S` → `s`), changed files `rl` → `rf`; full-file diff moves to the actions
  picker
- panel: `r` replies (or starts a thread when empty), `R` starts one, `dd`
  deletes, `<C-l>` reloads, `]r`/`[r` move
- `<Esc>` no longer leaves the mode — `<leader>rm` steps in and out; set
  `mode.keys["<Esc>"] = "leave"` to keep it
