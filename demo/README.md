# The recordings

One demo carries this plugin: a reviewer fixes the code in the file, and the fix
becomes a GitHub suggestion. Everything here exists so that take is scripted and
re-renderable rather than performed again every time the UI moves.

```bash
brew install vhs                 # ttyd + ffmpeg come with it
bash demo/setup.sh               # the demo repo and its PR, once
vhs demo/suggestion.tape         # -> demo/suggestion.gif and .mp4
bash demo/setup.sh reset         # before each retake
```

- `suggestion.tape` — the take, beat by beat (hook, gap, loss, mess, clarity,
  answer). Timing is part of the script: reading pauses, a mistyped word, a
  backspace. A take without them reads as a robot.
- `init.lua` — the config it runs against: this plugin, a colorscheme, nothing
  else, so nobody mistakes someone's dotfiles for the plugin.
- `setup.sh` — `adrianmross/review-mode-demo` and a PR whose bug is obvious at a
  glance: a cart total that ignores quantity. `reset` deletes what a take posted.
- `suggestion.srt` — the captions, cut to the beats.

## Finishing it

VHS gives a clean terminal at a constant scale, which is the right raw footage
and the wrong final cut: nothing directs the eye. Take `suggestion.mp4` into
[Cap](https://cap.so) (MIT, Studio mode) and add what a viewer needs:

- **Zoom** on two moments only — the edit landing in the file, and the draft
  opening with the block already filled in. Everything else stays wide.
- **Cursor smoothing** on, so the motion reads as a hand rather than a teleport.
- **Captions** from `suggestion.srt`, one line at a time, bottom third.
- **No music, no intro card.** The first frame is code with a bug in it.

Export twice: a GIF at 1200px for the README (GitHub autoplays it; keep it under
8 MB, raise `PlaybackSpeed` before you drop quality), and the MP4 for the blog
and X.

## Other takes worth having

Each is its own tape, same structure, one idea:

- **Blast radius** — a changed signature, and the callers the PR did not touch.
- **CI on the line** — a failing check as a diagnostic where the failure is.
- **Commit with credit** — applying suggestions and committing them with the
  reviewer as co-author.
