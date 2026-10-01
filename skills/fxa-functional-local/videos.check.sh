#!/usr/bin/env bash
# Offline check that run.sh posts a video with content and drops a blank one.
#   bash skills/fxa-functional-local/videos.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v ffmpeg >/dev/null || { echo "skip: needs ffmpeg"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^shows_something() {/,/^}/p' "$(dirname "$0")/run.sh")"
# A blank page (the grey of an unused Playwright page), and one with detail.
ffmpeg -v error -f lavfi -i "color=c=0xf4f4f5:s=320x180:d=2" -c:v libvpx -b:v 200k "$tmp/blank.webm" 2>/dev/null \
  || ffmpeg -v error -f lavfi -i "color=c=0xf4f4f5:s=320x180:d=2" "$tmp/blank.webm"
ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=2" -c:v libvpx -b:v 200k "$tmp/page.webm" 2>/dev/null \
  || ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=2" "$tmp/page.webm"
shows_something "$tmp/blank.webm"; check "a blank page is dropped" 1 $?
shows_something "$tmp/page.webm"; check "a page with content is kept" 0 $?
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
