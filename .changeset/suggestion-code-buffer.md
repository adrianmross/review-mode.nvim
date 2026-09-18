---
release: patch
---

`<C-g>` in a draft edits the suggestion as code. The lines, or the draft's
existing suggestion block, open in a buffer with the file's filetype, so
highlighting and filetype settings apply. `:w` or `<C-s>` writes them back as
the block, and `q` cancels. `:ReviewModeSuggest` over a range starts there too.
