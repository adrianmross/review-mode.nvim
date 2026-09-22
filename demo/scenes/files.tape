# The changed-files picker: open it, move down the list, jump into a file.
#
#   hook    0:00  the picker opens over the review, files ranked by what's left
#   answer  0:03  moving down the list, then <CR> jumps straight into a file
#
#   demo/setup.sh reset      before every retake
#   demo/record.py demo/scenes/files.tape
#
# Needs REVIEW_MODE_DEMO_SNACKS=<path to a snacks.nvim checkout> so the picker
# is the real floating list (arrow keys, live preview) instead of the
# vim.ui.select fallback the plugin uses when nothing richer is on the
# runtimepath.

Output "demo/scenes/files.gif"

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
Show

# --- HOOK: open the picker over the review --------------------------------
Sleep 1500ms
Type ":ReviewModeViewedList" Enter
Sleep 1200ms

# --- move down the list, watch the preview follow --------------------------
Down
Sleep 700ms
Down
Sleep 900ms

# --- ANSWER: jump into the highlighted file ---------------------------------
Enter
Sleep 2000ms

Hide
Type ":qa!" Enter
