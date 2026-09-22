# Trying a suggestion on for size: apply it, see the T sign, undo it.
#
#   hook    0:00  the suggestion, expanded in the panel
#   answer  0:02  a applies it into the file — a T sign marks the trial edit
#   undo    0:06  a again reverts it; the file is back to the PR as posted
#
#   demo/setup.sh reset      before every retake (WIPES the fixture thread —
#                             see panel.tape's header for how to repost it, or
#                             just record panel.tape first without a reset)
#   demo/record.py demo/scenes/trial.tape
#
# Same fixture as panel.tape: a ```suggestion block already posted on
# src/cart.ts:5.

Output "demo/scenes/trial.gif"

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
Type " rt"
Sleep 7s
Ctrl+W
Type "w"
Sleep 500ms
Type ":6" Enter
Sleep 400ms
Type "za"
Sleep 1000ms
Show

# --- HOOK: the suggestion, already unfolded ----------------------------------
Sleep 1800ms

# --- ANSWER: apply it — the T sign lands on the line -------------------------
Type "a"
Sleep 2600ms

# --- UNDO: apply again reverts the trial -------------------------------------
Type "a"
Sleep 2200ms

Hide
Type ":qa!" Enter
