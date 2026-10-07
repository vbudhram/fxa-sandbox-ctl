#!/usr/bin/env bash
# Offline check that pair-video.sh joins authority and supplicant frames of any size into one video.
#   bash skills/fxa-functional-local/pair-video.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v ffmpeg >/dev/null && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264 || { echo "skip: needs ffmpeg with libx264"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
S="$(dirname "$0")/pair-video.sh"
mkdir "$tmp/f"
# Frame sizes differ, as a Marionette screenshot and a Playwright page do.
ffmpeg -v error -f lavfi -i "testsrc=s=1366x768:d=1" -frames:v 1 "$tmp/f/01-a-totp-form.png"
ffmpeg -v error -f lavfi -i "testsrc=s=1280x720:d=1" -frames:v 1 "$tmp/f/01-s-totp-form.png"
ffmpeg -v error -f lavfi -i "testsrc=s=800x1200:d=1" -frames:v 1 "$tmp/f/02-a-paired.png"
ffmpeg -v error -f lavfi -i "testsrc=s=640x480:d=1" -frames:v 1 "$tmp/f/02-s-paired.png"
bash "$S" "$tmp/f" "$tmp/out.mp4" >/dev/null; check "two steps make a video" 0 $?
check "authority and supplicant side by side" "2560x760" \
  "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$tmp/out.mp4")"
check "three seconds a step" "6" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/out.mp4" | cut -d. -f1)"
rm "$tmp/f/02-s-paired.png"
bash "$S" "$tmp/f" "$tmp/out2.mp4" 2>/dev/null; check "a step with no supplicant frame fails" 1 $?
bash "$S" "$tmp/empty-$$" "$tmp/out3.mp4" 2>/dev/null; check "no frames fails" 1 $?
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
