# CI on the line: a failing check shown as a diagnostic, where the failure is.
#
#   hook    0:00  the file, quiet, no red anywhere obvious yet
#   answer  0:02  ]d jumps to the CI failure and opens it in place
#
#   demo/setup.sh reset      before every retake (does not touch CI runs)
#   demo/record.py demo/scenes/ci.tape
#
# Needs a failed check run with an annotation on src/cart.ts's changed line —
# a GitHub Actions workflow on the demo repo's default branch that emits
# `::error file=src/cart.ts,line=5::...`. review-mode loads it into its own
# CI diagnostic namespace (on by default); ]d/[d are the demo's own mapping
# (demo/init.lua), since the plugin leaves diagnostic navigation to whatever
# you already bind.

Output "demo/scenes/ci.gif"

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
Type "gg"
Sleep 1s
Show

# --- HOOK: the file, top of buffer --------------------------------------------
Sleep 1500ms

# --- ANSWER: jump to the CI failure -------------------------------------------
Type "]d"
Sleep 4500ms

Hide
Type ":qa!" Enter
