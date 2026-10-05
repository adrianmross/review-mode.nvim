---
release: patch
---

Fix a draft composer leaving you in insert mode in the wrong buffer. `<C-s>`
(post), `<C-p>` (queue) and `<C-g>` (suggest) are all mapped in insert mode too
— that's how you normally finish typing a comment, without pressing `<Esc>`
first — but `close_composer` moved focus back to the code window without
leaving insert mode, so the code window inherited it. The next keys you typed
landed in your file instead of running as commands.

Reproducer: `<leader>rr`, type a comment, `<C-s>` straight from insert mode,
then type a normal-mode command. It used to insert text into the file; it now
runs the command.
