# Blast radius: a changed function's signature, and the caller the PR left alone.
#
#   hook    0:00  cursor on the signature the PR changed
#   answer  0:02  :ReviewModeBlastRadius finds the untouched caller and opens it
#
#   demo/setup.sh reset      before every retake
#   demo/record.py demo/scenes/blast.tape
#
# Needs an LSP with references support attached to src/cart.ts:
#
#   REVIEW_MODE_DEMO_LSP=1
#   typescript-language-server on PATH
#   a compiled tree-sitter typescript parser on the runtimepath (nvim ships
#   neither the server nor the parser; see demo/init.lua's comment)

Output "demo/scenes/blast.gif"

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
Show

# --- HOOK: on the signature the PR changed -----------------------------------
Sleep 1500ms

# --- ANSWER: find the caller the PR didn't touch -----------------------------
Type ":ReviewModeBlastRadius" Enter
Sleep 5000ms

Hide
Type ":qa!" Enter
