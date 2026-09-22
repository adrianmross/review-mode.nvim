# The thread panel: open it beside the code, and unfold a suggestion in place.
#
#   hook    0:00  a thread is sitting on the changed line
#   gap     0:02  <leader>rt opens the panel next to it
#   answer  0:04  za unfolds the suggestion the panel folded by default
#
#   demo/setup.sh reset      before every retake (this WIPES the fixture
#                             thread below — repost it before recording, e.g.
#                             gh api repos/<demo repo>/pulls/<pr>/comments
#                             -f body='...' -f commit_id=... -f path=src/cart.ts
#                             -F line=5 -f side=RIGHT)
#   demo/record.py demo/scenes/panel.tape
#
# Needs a PR comment with a ```suggestion block already sitting on
# src/cart.ts:5 — this is the same thread demo/suggestion.tape posts, so
# recording that scene first (without a reset in between) also satisfies it.

Output "demo/scenes/panel.gif"

Require nvim
Require gh

Set Shell "zsh"
Set FontSize 18
Set Width 1400
Set Height 620
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
Sleep 4s
Type " rt"
Sleep 500ms
Show

# --- HOOK: sitting on the thread's line --------------------------------------
Sleep 1500ms

# --- GAP: open the panel ------------------------------------------------------
Type " rt"
Sleep 1200ms
Ctrl+W
Type "w"
Sleep 500ms
Type ":6" Enter
Sleep 400ms

# --- ANSWER: unfold the suggestion in place -----------------------------------
Type "za"
Sleep 3200ms

Hide
Type ":qa!" Enter
