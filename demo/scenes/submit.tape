# Pending review: queue a comment, check the readiness list, send it.
#
#   hook    0:00  a comment, queued rather than posted alone
#   gap     0:03  <leader>rs opens the pending review — the readiness list
#   answer  0:06  C-s submits it, confirmed once
#
#   demo/setup.sh reset      before every retake (deletes the comment this
#                             take posts, along with everything else)
#   demo/record.py demo/scenes/submit.tape
#
# Posts a real review comment on the demo PR when it runs — that is the
# point (it proves the submit happened), and `setup.sh reset` cleans it up.

Output "demo/scenes/submit.gif"

Require nvim
Require gh

Set Shell "zsh"
Set FontSize 18
Set Width 1400
Set Height 800
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms
Set PlaybackSpeed 1.0

Hide
Type "cd ${REVIEW_MODE_DEMO_DIR:-$HOME/Projects/wiz/worktrunks/review-mode-demo.fix-cart-total}" Enter
Type "clear" Enter
Type "nvim -u ${REVIEW_MODE_PLUGIN_ROOT:-$HOME/Projects/adrianmross/review-mode.nvim}/demo/init.lua src/cart.ts" Enter
Sleep 6s
Type " rm"
Sleep 14s
Type "]c"
Sleep 3s
Down
Sleep 1s
Show

# --- HOOK: one more note, queued instead of posted alone --------------------
Sleep 1200ms
Type " rR"
Sleep 900ms
Type "double check this against the receipt"
Sleep 500ms
Ctrl+P
Sleep 900ms

# --- GAP: the readiness list --------------------------------------------------
Type " rs"
Sleep 1500ms

# --- ANSWER: send it -----------------------------------------------------------
Ctrl+S
Sleep 1000ms
Type "S"
Sleep 1500ms

Hide
Type ":qa!" Enter
