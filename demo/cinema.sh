#!/usr/bin/env bash
# Turn a flat terminal capture into a shot: a tilted card that flattens as it
# comes in, on a backdrop, with the keys drawn as chips and the captions burned.
#
#   demo/cinema.sh demo/suggestion.gif
#   TILT=0 demo/cinema.sh demo/scenes/panel.gif     # no intro tilt for a middle scene
#
# A raw capture is the same size in every frame, so nothing tells the eye where
# to look and nobody can see which key did what. This adds, in order:
#
#   1. a backdrop, and the terminal as a card with rounded corners
#   2. an intro where the card sits at an angle and settles flat (TILT=1)
#   3. camera push-ins on the beats in ZOOMS
#   4. key chips from <take>.keys.json, captions from <take>.srt
#
# ffmpeg here has no libass and no freetype, so the text comes from Pillow
# (captions.py, keycast.py) and is composited with plain overlay.
set -euo pipefail

src="${1:?usage: demo/cinema.sh <take.gif|take.mp4>}"
[ -f "$src" ] || { echo "no such take: $src" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
base="${src%.*}"
fps="${FPS:-30}"
tilt="${TILT:-1}"
tilt_secs="${TILT_SECS:-1.6}"
zooms="${ZOOMS:-}"
scale="${ZOOM_SCALE:-1.4}"
pad="${PAD:-70}"                      # backdrop margin around the card
back_top="${BACK_TOP:-0x1b2233}"      # the backdrop is a vertical gradient
back_bottom="${BACK_BOTTOM:-0x0b0d14}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is not on PATH" >&2; exit 1; }

# Constant fps first: a GIF carries a delay per frame, and trim= against those
# timestamps lands in the wrong places.
norm="${base}.norm.mp4"
ffmpeg -v error -y -i "$src" -vf "fps=${fps},scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 "$norm"

size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$norm")
w=${size%x*}
h=${size#*x}
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$norm")
out_w=$(( (w + pad * 2) / 2 * 2 ))
out_h=$(( (h + pad * 2) / 2 * 2 ))
crop_w=$(awk -v w="$w" -v s="$scale" 'BEGIN{printf "%d", int(w/s/2)*2}')
crop_h=$(awk -v h="$h" -v s="$scale" 'BEGIN{printf "%d", int(h/s/2)*2}')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 1. the card: rounded corners, cut with geq's alpha ----------------------
radius="${RADIUS:-22}"
corner="if(lt(X,${radius})*lt(Y,${radius})*gt(pow(${radius}-X,2)+pow(${radius}-Y,2),pow(${radius},2))
 + gt(X,W-${radius})*lt(Y,${radius})*gt(pow(X-(W-${radius}),2)+pow(${radius}-Y,2),pow(${radius},2))
 + lt(X,${radius})*gt(Y,H-${radius})*gt(pow(${radius}-X,2)+pow(Y-(H-${radius}),2),pow(${radius},2))
 + gt(X,W-${radius})*gt(Y,H-${radius})*gt(pow(X-(W-${radius}),2)+pow(Y-(H-${radius}),2),pow(${radius},2)),0,255)"
corner=${corner//$'\n'/}

ffmpeg -v error -y -i "$norm" -vf "format=rgba,geq=lum='p(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='${corner}'" \
  -c:v qtrle "${work}/card.mov"

# --- 2. the backdrop ---------------------------------------------------------
ffmpeg -v error -y -f lavfi -i "gradients=s=${out_w}x${out_h}:c0=${back_top}:c1=${back_bottom}:x0=0:y0=0:x1=0:y1=${out_h}:d=${duration}:r=${fps}" \
  -t "$duration" -c:v libx264 -pix_fmt yuv420p "${work}/back.mp4"

# --- 3. the tilt: stages concatenated, not cross-faded -----------------------
# perspective= takes fixed corners, so the lean is animated by rendering a
# stage per step and joining them. Cross-fading them instead ghosts: two
# different perspectives blended read as a double exposure, not as motion.
card="${work}/card.mov"
if [ "$tilt" = 1 ]; then
  steps="${TILT_STEPS:-12}"
  seg=$(awk -v t="$tilt_secs" -v n="$steps" 'BEGIN{printf "%.3f", t/n}')
  : > "${work}/tilt.list"
  for ((step = 0; step < steps; step++)); do
    # ease out: most of the lean is gone by the halfway point
    lean=$(awk -v s="$step" -v n="$steps" -v w="$w" 'BEGIN{p=1-s/(n-1); printf "%d", w*0.18*p*p}')
    drop=$(awk -v s="$step" -v n="$steps" -v h="$h" 'BEGIN{p=1-s/(n-1); printf "%d", h*0.12*p*p}')
    start=$(awk -v s="$step" -v g="$seg" 'BEGIN{printf "%.3f", s*g}')
    ffmpeg -v error -y -ss "$start" -t "$seg" -i "$card" \
      -vf "perspective=x0=${lean}:y0=${drop}:x1=W-${lean}:y1=0:x2=0:y2=H:x3=W:y3=H-${drop}:sense=destination,format=rgba,setsar=1" \
      -c:v qtrle "${work}/tilt${step}.mov"
    printf "file '%s'\n" "${work}/tilt${step}.mov" >> "${work}/tilt.list"
  done
  rest=$(awk -v t="$tilt_secs" 'BEGIN{printf "%.3f", t}')
  ffmpeg -v error -y -ss "$rest" -i "$card" -c:v qtrle "${work}/flat.mov"
  printf "file '%s'\n" "${work}/flat.mov" >> "${work}/tilt.list"
  ffmpeg -v error -y -f concat -safe 0 -i "${work}/tilt.list" -c:v qtrle "${work}/carded.mov"
  card="${work}/carded.mov"
fi

# --- 4. card on backdrop, with a shadow --------------------------------------
ffmpeg -v error -y -i "${work}/back.mp4" -i "$card" -filter_complex \
  "[1:v]split[shadow][top];[shadow]format=rgba,colorchannelmixer=rr=0:gg=0:bb=0:aa=0.55,gblur=sigma=18[sh];\
[0:v][sh]overlay=x=${pad}:y=$((pad + 10))[bg];[bg][top]overlay=x=${pad}:y=${pad}:format=auto[out]" \
  -map "[out]" -t "$duration" -c:v libx264 -pix_fmt yuv420p -crf 18 "${work}/staged.mp4"

# --- 5. camera: wide, then a push on each beat -------------------------------
stage_src="${work}/staged.mp4"
if [ -n "$zooms" ]; then
  filters=(); labels=(); index=0; cursor=0
  add() { # start end mode cx cy
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(b-a > 0.05)}' || return 0
    local label="c${index}"
    if [ "$3" = wide ]; then
      filters+=("[0:v]trim=start=$1:end=$2,setpts=PTS-STARTPTS,setsar=1[${label}]")
    else
      local cw ch x y
      cw=$(awk -v w="$out_w" -v s="$scale" 'BEGIN{printf "%d", int(w/s/2)*2}')
      ch=$(awk -v h="$out_h" -v s="$scale" 'BEGIN{printf "%d", int(h/s/2)*2}')
      x=$(awk -v c="$4" -v w="$out_w" -v cw="$cw" 'BEGIN{v=c*w-cw/2; if(v<0)v=0; if(v>w-cw)v=w-cw; printf "%d", int(v/2)*2}')
      y=$(awk -v c="$5" -v h="$out_h" -v ch="$ch" 'BEGIN{v=c*h-ch/2; if(v<0)v=0; if(v>h-ch)v=h-ch; printf "%d", int(v/2)*2}')
      filters+=("[0:v]trim=start=$1:end=$2,setpts=PTS-STARTPTS,crop=${cw}:${ch}:${x}:${y},scale=${out_w}:${out_h},setsar=1[${label}]")
    fi
    labels+=("[${label}]"); index=$((index + 1))
  }
  for zoom in $zooms; do
    IFS=: read -r zs ze cx cy <<<"$zoom"
    add "$cursor" "$zs" wide; add "$zs" "$ze" push "$cx" "$cy"; cursor=$ze
  done
  add "$cursor" "$duration" wide
  ffmpeg -v error -y -i "${work}/staged.mp4" -filter_complex \
    "$(IFS=';'; echo "${filters[*]}");$(IFS=''; echo "${labels[*]}")concat=n=${index}:v=1:a=0[cam]" \
    -map "[cam]" -c:v libx264 -pix_fmt yuv420p -crf 18 "${work}/camera.mp4"
  stage_src="${work}/camera.mp4"
fi

# --- 6. the text: key chips, then captions -----------------------------------
inputs=(); chain=""; label="[0:v]"
next_input=1
overlay_pass() { # script arg_file out_label
  local script=$1 arg=$2 out=$3 filter list
  list="${work}/$(basename "$script").list"
  [ -f "$arg" ] || return 1
  filter=$(python3 "${here}/${script}" "$arg" "$out_w" "$out_h" "${work}/$(basename "$script" .py)" 2> "$list") || return 1
  local count=0
  while IFS= read -r line; do
    [ "${line#input:}" != "$line" ] || continue
    inputs+=("-i" "${line#input:}"); count=$((count + 1))
  done < "$list"
  [ "$count" -gt 0 ] || return 1
  # captions.py and keycast.py number their inputs from 1; shift them along
  local shifted=$filter i
  for ((i = count; i >= 1; i--)); do
    shifted=${shifted//\[$i:v\]/[$((i + next_input - 1)):v]}
  done
  next_input=$((next_input + count))
  chain="${chain}${chain:+;}${label}null[base];${shifted}"
  label="[${out}]"
  return 0
}
overlay_pass keycast.py "${base}.keys.json" keyed || true
overlay_pass captions.py "${base}.srt" captioned || true

if [ -n "$chain" ]; then
  ffmpeg -v error -y -i "$stage_src" "${inputs[@]}" -filter_complex "$chain" -map "$label" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "${base}.shot.mp4"
else
  cp "$stage_src" "${base}.shot.mp4"
fi

ffmpeg -v error -y -i "${base}.shot.mp4" \
  -vf "fps=12,scale=${GIF_WIDTH:-1100}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  "${base}.shot.gif"

printf '%s (%s KiB)\n' "${base}.shot.mp4" "$(( $(stat -f%z "${base}.shot.mp4") / 1024 ))"
printf '%s (%s KiB)\n' "${base}.shot.gif" "$(( $(stat -f%z "${base}.shot.gif") / 1024 ))"
