#!/usr/bin/env bash
# Join pairing frames into one video: the Marionette authority on the left, the supplicant on
# the right, 3 s a step. Frames are NN-a-<label>.png (authority) and NN-s-<label>.png. See SKILL.md.
#   pair-video.sh <frames dir> <out.mp4>
set -euo pipefail
F="${1:?frames dir}" out="${2:?out.mp4}"
C="$(mktemp -d)"; trap 'rm -rf "$C"' EXIT
# Marionette and Playwright frames differ in size: fit each into the same box, or hstack fails.
fit='scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:760:(ow-iw)/2:40:white'
n=0
for a in "$F"/[0-9][0-9]-a-*.png; do
  [ -f "$a" ] || break
  i="$(basename "$a")"; i="${i%%-*}"
  s="$(ls "$F/$i"-s-*.png 2>/dev/null | head -1)"
  [ -n "$s" ] || { echo "pair-video: no supplicant frame for step $i" >&2; exit 1; }
  lbl="$(basename "$a" .png)"; lbl="${lbl#*-a-}"
  base="[0]${fit}[a];[1]${fit}[b];[a][b]hstack"
  # drawtext needs an ffmpeg with freetype; without one the step has no caption.
  ffmpeg -loglevel error -y -i "$a" -i "$s" -filter_complex \
      "${base},drawtext=text='Step ${i}  ${lbl}   (left\: authority, right\: supplicant)':x=20:y=10:fontsize=24:fontcolor=black" "$C/$i.png" 2>/dev/null \
    || ffmpeg -loglevel error -y -i "$a" -i "$s" -filter_complex "$base" "$C/$i.png"
  n=$(( n + 1 ))
done
[ "$n" -gt 0 ] || { echo "pair-video: no NN-a-*.png frames in $F" >&2; exit 1; }
ffmpeg -loglevel error -y -framerate 1/3 -pattern_type glob -i "$C/*.png" -vf "fps=25,format=yuv420p" -c:v libx264 "$out"
echo "video: $out ($n steps)"
