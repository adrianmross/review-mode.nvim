#!/usr/bin/env bash
# Finish a raw take: zoom the moments that matter, burn the captions, write the
# files the README and the blog want.
#
#   demo/finish.sh demo/suggestion.gif
#   ZOOMS="3.0:9.5:0.62:0.42 21:28:0.55:0.78" demo/finish.sh demo/suggestion.gif
#
# A raw terminal capture is the right footage and the wrong final cut: every
# frame is the same size, so nothing tells the eye where to look. This crops in
# on the two beats that carry the story and leaves the rest wide.
#
# ZOOMS is a list of START:END:CX:CY, seconds and a focus point in 0..1 of the
# frame. Everything outside them plays wide. The defaults match the beats of
# suggestion.tape as recorded: the fix being typed into the file, and the draft
# opening with the block already in it. Re-time them when the tape changes --
# the timestamps come from the cast, not from guesswork:
#
#   python3 - <<EOF
#   import json; t=0
#   for e in (json.loads(l) for l in open("demo/suggestion.cast").read().splitlines()[1:] if l.strip()):
#       t += e[0]
#       if e[1] == "o" and "Suggest your edit" in e[2]: print(round(t, 1)); break
#   EOF
#
# Outputs, beside the input:
#   <name>.final.mp4   the blog and X
#   <name>.final.gif   the README (GitHub autoplays it)
set -euo pipefail

src="${1:?usage: demo/finish.sh <take.gif|take.mp4>}"
[ -f "$src" ] || { echo "no such take: $src" >&2; exit 1; }
base="${src%.*}"
subs="${SUBS:-${base}.srt}"
zooms="${ZOOMS:-16.5:26.0:0.30:0.14 26.6:34.5:0.33:0.80}"
scale="${ZOOM_SCALE:-1.45}"   # how far in a zoomed beat sits
width="${GIF_WIDTH:-1200}"    # README width; the mp4 keeps the source size

command -v ffmpeg >/dev/null || { echo "ffmpeg is not on PATH (brew install ffmpeg)" >&2; exit 1; }

# A GIF carries a delay per frame, and trim= against those timestamps lands in
# the wrong places. Normalise to constant fps first; everything downstream then
# means what it says.
norm="${base}.norm.mp4"
ffmpeg -v error -y -i "$src" -vf "fps=${FPS:-25},scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -pix_fmt yuv420p -crf 18 "$norm"
src="$norm"

duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$src")
in_w=${size%x*}
in_h=${size#*x}
# h264 refuses odd dimensions, and a terminal capture is whatever size the font
# made it (1539x983 here), so everything is rendered to the even size below.
out_w=$(( ${in_w%.*} / 2 * 2 ))
out_h=$(( ${in_h%.*} / 2 * 2 ))
# even dimensions: h264 refuses odd ones
crop_w=$(( (${in_w%.*} * 100 / $(printf '%.0f' "$(echo "$scale * 100" | bc -l)") ) / 2 * 2 ))
crop_h=$(( (${in_h%.*} * 100 / $(printf '%.0f' "$(echo "$scale * 100" | bc -l)") ) / 2 * 2 ))

# Build one segment per stretch of time, wide or zoomed, then concatenate. A
# per-frame zoom expression would be shorter and much harder to reason about
# when a beat moves by half a second.
segments=()
filters=()
index=0
cursor=0

add_segment() { # start end mode cx cy
  local start=$1 end=$2 mode=$3 cx=${4:-0.5} cy=${5:-0.5}
  awk -v a="$start" -v b="$end" 'BEGIN{exit !(b - a > 0.05)}' || return 0
  local label="v${index}"
  if [ "$mode" = wide ]; then
    filters+=("[0:v]trim=start=${start}:end=${end},setpts=PTS-STARTPTS,scale=${out_w}:${out_h}[${label}]")
  else
    local x y
    x=$(awk -v c="$cx" -v w="${in_w%.*}" -v cw="$crop_w" 'BEGIN{v=c*w-cw/2; if(v<0)v=0; if(v>w-cw)v=w-cw; printf "%d", int(v/2)*2}')
    y=$(awk -v c="$cy" -v h="${in_h%.*}" -v ch="$crop_h" 'BEGIN{v=c*h-ch/2; if(v<0)v=0; if(v>h-ch)v=h-ch; printf "%d", int(v/2)*2}')
    filters+=("[0:v]trim=start=${start}:end=${end},setpts=PTS-STARTPTS,crop=${crop_w}:${crop_h}:${x}:${y},scale=${out_w}:${out_h}[${label}]")
  fi
  segments+=("[${label}]")
  index=$((index + 1))
}

for zoom in $zooms; do
  IFS=: read -r zs ze cx cy <<<"$zoom"
  add_segment "$cursor" "$zs" wide
  add_segment "$zs" "$ze" zoom "$cx" "$cy"
  cursor=$ze
done
add_segment "$cursor" "$duration" wide

chain=$(IFS=';'; echo "${filters[*]}")
concat="$(IFS=''; echo "${segments[*]}")concat=n=${index}:v=1:a=0[cut]"
last="[cut]"
caption_inputs=()
if [ -f "$subs" ]; then
  # This ffmpeg has no libass and no freetype, so subtitles= and drawtext= do
  # not exist. The captions are drawn as PNG strips and composited with plain
  # overlay filters, which every build has.
  caps_dir="${base}.captions"
  rm -rf "$caps_dir"
  caption_filter=$(python3 "$(dirname "$0")/captions.py" "$subs" "${out_w}" "${out_h}" "$caps_dir" 2> "${caps_dir}.list" || true)
  while IFS= read -r line; do
    [ "${line#input:}" != "$line" ] && caption_inputs+=("-i" "${line#input:}")
  done < "${caps_dir}.list"
  rm -f "${caps_dir}.list"
  concat="${concat};[cut]null[base];${caption_filter}"
  last="[captioned]"
else
  echo "no captions at $subs — rendering without them" >&2
fi

ffmpeg -v error -y -i "$src" "${caption_inputs[@]}" -filter_complex "${chain};${concat}" -map "$last" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "${base}.final.mp4"

ffmpeg -v error -y -i "${base}.final.mp4" \
  -vf "fps=12,scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  "${base}.final.gif"

printf '%s (%s KiB)\n' "${base}.final.mp4" "$(( $(stat -f%z "${base}.final.mp4") / 1024 ))"
printf '%s (%s KiB)\n' "${base}.final.gif" "$(( $(stat -f%z "${base}.final.gif") / 1024 ))"
