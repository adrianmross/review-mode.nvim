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

## Other takes

`demo/scenes/` carries six more, each its own tape, same structure, one idea:
the changed-files picker (`files`), the thread panel (`panel`), trying a
suggestion on for size (`trial`), blast radius (`blast`), a CI failure as a
diagnostic (`ci`), and pending review → submit (`submit`). Record and reset
them the same way as `suggestion.tape`; `panel`/`trial` additionally need a
posted suggestion comment as a fixture (see each tape's header).

## The combined reel

`demo/reel.sh` stitches finished takes (`cinema.sh`'s `*.shot.mp4` output)
into one video, crossfading from one scene into the next:

```bash
for f in demo/suggestion.gif demo/scenes/{files,panel,trial,blast,ci,submit}.gif; do
  TILT=$([ "$f" = demo/suggestion.gif ] && echo 1 || echo 0) demo/cinema.sh "$f"
done
demo/reel.sh demo/suggestion.shot.mp4 demo/scenes/{files,panel,trial,blast,ci,submit}.shot.mp4
```

Every take ends with a few seconds of dead air — asciinema/agg hold the last
frame (and the tmux `[detached]` message on its way out) well past where the
content actually ends. That's invisible in a standalone GIF but shows up as a
blank beat mid-crossfade in a combined reel. Re-render tighter-tailed sources
before handing them to `cinema.sh` for the reel specifically (leave the
committed `*.gif`/`*.shot.mp4` alone — their 3s hold is correct for viewing
one take on its own):

```bash
agg --font-size 18 --theme dracula --last-frame-duration 0.3 demo/scenes/<name>.cast /tmp/<name>.gif
cp demo/scenes/<name>.srt demo/scenes/<name>.keys.json /tmp/
TILT=0 demo/cinema.sh /tmp/<name>.gif
```

(`suggestion.gif` predates keeping its `.cast`; trim its `.shot.mp4`'s dead
tail directly instead, e.g. `ffmpeg -i demo/suggestion.shot.mp4 -t 43.7 -c copy ...` —
re-check the exact cut point if the tape changes.)
