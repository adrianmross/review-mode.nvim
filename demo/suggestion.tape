# The one demo: a reviewer fixes the code in the file, and the fix becomes a
# GitHub suggestion. ~22s, sized for a README.
#
#   demo/setup.sh            once, to build the demo repo and its PR
#   vhs demo/suggestion.tape from the plugin's checkout
#   demo/setup.sh reset      before every retake (deletes the demo comments)
#
# Every keystroke is here on purpose: re-render it after a UI change rather than
# re-recording by hand.

Output "demo/suggestion.gif"
Output "demo/suggestion.mp4"

Require nvim
Require gh

Set Shell "zsh"
Set FontSize 18
Set Width 1400
Set Height 800
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0

# --- setup, off camera -------------------------------------------------------
Hide
Type "cd ${REVIEW_MODE_DEMO_DIR:-$HOME/Projects/adrianmross/review-mode-demo}" Enter
Type "clear" Enter
Type "nvim -u ${REVIEW_MODE_PLUGIN_ROOT:-$HOME/Projects/adrianmross/review-mode.nvim}/demo/init.lua src/cart.ts" Enter
Sleep 3s
Show

# --- 1. start the review -----------------------------------------------------
# The PR opens in ordinary buffers: no special UI, your own LSP still attached.
Type " rm"
Sleep 3s

# --- 2. land on the hunk under review ---------------------------------------
Type "]c"
Sleep 1500ms

# --- 3. fix it in the file, like you would any bug ---------------------------
# The reviewer rewrites the line itself rather than describing the fix in prose.
Type "ci("
Sleep 400ms
Type "items.reduce((sum, i) => sum + i.price * i.qty, 0)"
Escape
Sleep 2s

# --- 4. the edit becomes the suggestion --------------------------------------
# <leader>rr on an edited line opens the draft with the ```suggestion block
# already filled in from the diff against the PR head.
Type " rr"
Sleep 3s

# --- 5. say why, then post ---------------------------------------------------
Type "qty was dropped here, so a cart of 3 billed as 1."
Sleep 1500ms
Ctrl+S
Sleep 1s
Type "y"
Sleep 3s

# --- 6. the file is clean again ----------------------------------------------
# Posting undid the edit: the suggestion lives on GitHub, the working tree
# matches the PR.
Sleep 2500ms

Hide
Type ":qa!" Enter
