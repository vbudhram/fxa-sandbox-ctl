#!/usr/bin/env bash
# Offline check for record.sh argument handling, and the blank-video hint on stop.
# Needs no X; the stop check needs ffmpeg.
#   bash skills/fxa-page-shot/record.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp" FXA_WORKSPACE="$tmp/ws"
R="$(cd "$(dirname "$0")" && pwd)/record.sh"
bash "$R" start >/dev/null 2>&1; check "start needs a name" 2 $?
bash "$R" start '../x' >/dev/null 2>&1; check "start refuses a path in the name" 2 $?
bash "$R" stop >/dev/null 2>&1; check "stop with nothing recording fails" 1 $?
bash "$R" stop --speed 0 >/dev/null 2>&1; check "stop refuses a speed of 0" 2 $?
bash "$R" bogus >/dev/null 2>&1; check "an unknown command fails" 2 $?
if command -v ffmpeg >/dev/null; then
  # A sleep stands in for the ffmpeg recorder; stop sends it SIGINT.
  ffmpeg -v error -f lavfi -i "color=c=black:s=320x180:d=2" -pix_fmt yuv420p "$tmp/blank.mp4"
  # A background job of a script ignores SIGINT; the stand-in takes the default back, as ffmpeg handles it.
  (trap - INT; exec sleep 20) & echo $! > "$tmp/fxa-record.pid"; echo "$tmp/blank.mp4" > "$tmp/fxa-record.out"
  got="$(bash "$R" stop 2>&1)"; check "stop fails on a blank video" 1 $?
  check "stop gives the blank-video hint" 1 "$(grep -c 'gfx.webrender.software=true.*env -u MOZ_HEADLESS' <<< "$got")"
  check "the blank video leaves the media name, so the wrap-up does not post it" "no|yes" "$([ -e "$tmp/blank.mp4" ] && echo yes || echo no)|$([ -e "$tmp/blank.mp4.blank" ] && echo yes || echo no)"
fi
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
