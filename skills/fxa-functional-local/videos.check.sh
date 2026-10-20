#!/usr/bin/env bash
# Offline check that run.sh posts a video with content and drops a blank one,
# and posts nothing from a failed run.
#   bash skills/fxa-functional-local/videos.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v ffmpeg >/dev/null || { echo "skip: needs ffmpeg"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^shows_something() {/,/^}/p; /^post_videos() {/,/^}/p' "$(dirname "$0")/run.sh")"
# A blank page (the grey of an unused Playwright page), and one with detail.
ffmpeg -v error -f lavfi -i "color=c=0xf4f4f5:s=320x180:d=2" -c:v libvpx -b:v 200k "$tmp/blank.webm" 2>/dev/null \
  || ffmpeg -v error -f lavfi -i "color=c=0xf4f4f5:s=320x180:d=2" "$tmp/blank.webm"
ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=2" -c:v libvpx -b:v 200k "$tmp/page.webm" 2>/dev/null \
  || ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=2" "$tmp/page.webm"
shows_something "$tmp/blank.webm"; check "a blank page is dropped" 1 $?
shows_something "$tmp/page.webm"; check "a page with content is kept" 0 $?
# post_videos reads $out, $media and $rc from run.sh.
out="$tmp/out"; mkdir -p "$out/test-page" "$out/test-blank"
cp "$tmp/page.webm" "$out/test-page/video.webm"; cp "$tmp/blank.webm" "$out/test-blank/video.webm"
media="$tmp/pass"; mkdir -p "$media"; rc=0; got="$(post_videos)"
check "a pass posts the video" "test-page.webm" "$(ls "$media")"
check "a pass prints a check line" 1 "$(grep -c "^check: .*frames $media/test-page.webm\$" <<< "$got")"
media="$tmp/fail"; mkdir -p "$media"; rc=1; got="$(post_videos)"
check "a failure posts no video" "" "$(ls "$media")"
check "a failure names the video it kept back" 1 "$(grep -c "^video (not posted): $out/test-page/video.webm\$" <<< "$got")"
check "a failure prints a check line" 1 "$(grep -c "^check: .*frames $out/test-page/video.webm\$" <<< "$got")"
check "a failure still drops a blank video" 1 "$(grep -c '^no video: test-blank' <<< "$got")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
