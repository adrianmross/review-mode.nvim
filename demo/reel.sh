#!/usr/bin/env bash
# Stitch finished takes (demo/cinema.sh's *.shot.mp4 output) into one reel,
# crossfading from one scene into the next instead of hard-cutting.
#
#   demo/reel.sh demo/suggestion.shot.mp4 demo/scenes/{files,panel,trial,blast,ci,submit}.shot.mp4
#   XFADE=0.8 demo/reel.sh demo/suggestion.shot.mp4 demo/scenes/files.shot.mp4
#
# Every input must already be the same resolution and fps -- that's what
# `demo/cinema.sh`'s fixed backdrop+card canvas gives you for free as long as
# every tape recorded at the same `Set Width`/`Set Height`. This does not
# resize inputs itself: a mismatch is a sign the tapes disagree on canvas size,
# not something to paper over here.
#
# Outputs, beside the first input's directory:
#   demo/reel.mp4   the blog and X
#   demo/reel.gif   the README (GitHub autoplays it)
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: demo/reel.sh <take1.shot.mp4> <take2.shot.mp4> [more...]" >&2; exit 1; }
for f in "$@"; do [ -f "$f" ] || { echo "no such take: $f" >&2; exit 1; }; done

command -v ffmpeg >/dev/null || { echo "ffmpeg is not on PATH" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
out_dir="$here"
duration="${XFADE:-0.6}"   # seconds each handoff overlaps
width="${GIF_WIDTH:-1100}"

sizes=()
for f in "$@"; do
  sizes+=("$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$f")")
done
for s in "${sizes[@]}"; do
  [ "$s" = "${sizes[0]}" ] || {
    echo "reel.sh: inputs are not all the same size (${sizes[*]}) -- re-record the odd one out" \
      "at the same Width/Height as the rest" >&2
    exit 1
  }
done

# Chain N-1 xfades: each one overlaps the tail of what's been built so far with
# the head of the next clip by $duration seconds, so the combined timeline is
# shorter than the sum of the parts by (n-1)*duration.
inputs=()
for f in "$@"; do
  inputs+=("-i" "$f")
done

filters=()
label="[0:v]"
running="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")"
index=1
for f in "${@:2}"; do
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")"
  offset="$(awk -v r="$running" -v d="$duration" 'BEGIN{printf "%.3f", r - d}')"
  next_label="[x${index}]"
  filters+=("${label}[${index}:v]xfade=transition=fade:duration=${duration}:offset=${offset}${next_label}")
  running="$(awk -v r="$running" -v d="$dur" -v x="$duration" 'BEGIN{printf "%.3f", r + d - x}')"
  label="$next_label"
  index=$((index + 1))
done

chain=$(IFS=';'; echo "${filters[*]}")

ffmpeg -v error -y "${inputs[@]}" -filter_complex "$chain" -map "$label" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "${out_dir}/reel.mp4"

ffmpeg -v error -y -i "${out_dir}/reel.mp4" \
  -vf "fps=12,scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  "${out_dir}/reel.gif"

printf '%s (%s KiB, %ss)\n' "${out_dir}/reel.mp4" "$(( $(stat -f%z "${out_dir}/reel.mp4") / 1024 ))" "$running"
printf '%s (%s KiB)\n' "${out_dir}/reel.gif" "$(( $(stat -f%z "${out_dir}/reel.gif") / 1024 ))"
