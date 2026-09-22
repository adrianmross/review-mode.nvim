# The hero demo, cut as a story rather than a feature tour:
#
#   hook    0:00  a wrong number on screen, in code anyone can read
#   gap     0:04  you can see the fix; the PR page cannot help you write it
#   loss    0:07  what reviewers do instead: describe the fix in prose
#   mess    0:11  and hand-build a ```suggestion block, indentation and all
#   clarity 0:15  so instead: just fix the code, in the file, with your tools
#   answer  0:19  <leader>rr turns the edit into the suggestion and undoes it
#
# Timing is deliberate. A person reads before typing, mistypes, backs up, and
# pauses after something lands — the beats below do all three, because a take
# with none of them reads as a robot.
#
#   demo/setup.sh            once, to build the demo repo and its PR
#   demo/setup.sh reset      before every retake
#   vhs demo/suggestion.tape from the plugin's checkout
#
# Render this for the terminal, then take it into Cap Studio to zoom the two
# moments that matter (the edit, and the draft opening) and burn in
# demo/suggestion.srt.

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
Set TypingSpeed 55ms
Set PlaybackSpeed 1.0

# --- setup, off camera -------------------------------------------------------
Hide
Type "cd ${REVIEW_MODE_DEMO_DIR:-$HOME/Projects/adrianmross/review-mode-demo}" Enter
Type "clear" Enter
Type "nvim -u ${REVIEW_MODE_PLUGIN_ROOT:-$HOME/Projects/adrianmross/review-mode.nvim}/demo/init.lua" Enter
Sleep 2s
Show

# --- HOOK: the review opens on the bug ---------------------------------------
# One keystroke in, and the PR is ordinary buffers with the cursor on the hunk.
Type " rm"
Sleep 2500ms
Type "]c"
Sleep 2s

# --- GAP: you can see the fix ------------------------------------------------
# A beat on the line itself: qty is counted in the summary and never charged.
Down Down
Sleep 900ms
Up
Sleep 1800ms

# --- LOSS + MESS: the way this normally goes ---------------------------------
# Start the comment a reviewer would leave, then think better of it: prose
# about a fix, and a suggestion block hand-indented by eye.
Type " rr"
Sleep 1200ms
Type "this misses qty — can you multiply by"
Sleep 700ms
Type " i.qt"
Sleep 400ms
Backspace@120ms 3
Sleep 600ms
Type "quantity and re-run the"
Sleep 900ms
Escape
Sleep 700ms
Type "q"
Sleep 1500ms

# --- CLARITY: fix it in the file instead -------------------------------------
# The buffer is the real file, so the fix is a normal edit with normal tools.
Set TypingSpeed 45ms
Type "ci("
Sleep 500ms
Type "items.reduce((sum, i) => sum + i.price * i.qtty"
Sleep 400ms
Backspace@110ms 2
Sleep 300ms
Type "y, 0)"
Escape
Sleep 2200ms

# --- ANSWER: the edit becomes the suggestion ---------------------------------
Set TypingSpeed 55ms
Type " rr"
Sleep 2800ms
Type "qty was dropped here, so a cart of 3 bills as 1."
Sleep 1600ms
Ctrl+S
Sleep 900ms
Type "y"
Sleep 2600ms

# --- LAND: the working tree matches the PR again -----------------------------
# The suggestion is on GitHub; the edit that wrote it is gone.
Sleep 2200ms

Hide
Type ":qa!" Enter
