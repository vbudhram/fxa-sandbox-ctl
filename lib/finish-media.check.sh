#!/usr/bin/env bash
# Offline check that a PR's media is attached from the worktree, on macOS and Linux.
#   bash lib/finish-media.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_copy_media() {/,/^}/p; /^finish_media_args() {/,/^}/p' "$(dirname "$0")/finish.sh")"
wt="$tmp/wt"; mkdir -p "$wt/.fxa-auto-media"
printf 'png' > "$wt/.fxa-auto-media/shot.png"
printf 'secret' > "$tmp/outside.png"; ln -s "$tmp/outside.png" "$wt/.fxa-auto-media/link.png"
printf '{"media_paths":["/workspace/.fxa-auto-media/shot.png",".fxa-auto-media/link.png","../outside.png"]}' > "$tmp/done.json"
args=()
log="$(finish_media_args "$wt" "$tmp/done.json" args 2>&1)"
finish_media_args "$wt" "$tmp/done.json" args 2>/dev/null
check "the screenshot is attached" "3 listed, 1 attached" "$(grep -oE '[0-9]+ listed, [0-9]+ attached' <<< "$log")"
check "its copy holds the file" "png" "$(cat "${args[1]}" 2>/dev/null)"
check "a symlink and a path outside are refused" "2" "$(grep -cE 'not found inside|refused' <<< "$log")"
# The same recording twice (a WebM and its MP4, or a rerun): only the newest one goes on the PR.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
printf 'old' > "$wt/.fxa-auto-media/run.webm"; printf 'new' > "$wt/.fxa-auto-media/run.mp4"
touch -t 202601010000 "$wt/.fxa-auto-media/run.webm"; touch -t 202601020000 "$wt/.fxa-auto-media/run.mp4"
printf '{"media_paths":[".fxa-auto-media/run.webm",".fxa-auto-media/shot.png",".fxa-auto-media/run.mp4"]}' > "$tmp/dup.json"
args=(); log="$(finish_media_args "$wt" "$tmp/dup.json" args 2>&1)"; args=(); finish_media_args "$wt" "$tmp/dup.json" args 2>/dev/null
check "a duplicate recording is dropped and the newest kept" "3 listed, 2 attached (1 duplicate dropped)|shot.png run.mp4" \
  "$(grep -oE '[0-9]+ listed, [0-9]+ attached[^;]*' <<< "$log")|$(for a in "${args[@]}"; do [ "$a" = --attach ] || basename "$a"; done | paste -sd' ' -)"

# The body rewrite, with gcloud stubbed: local links to the file become the bucket URL.
eval "$(sed -n '/^media_mp4() {/,/^}/p; /^_finish_bucket_cp() {/,/^}/p; /^_finish_play_frame() {/,/^}/p; /^_finish_media_to_bucket() {/,/^}/p' "$(dirname "$0")/finish.sh")"
slot_write() { rm -f -- "$1" && (set -C; cat > "$1"); }
gcloud() { :; }
FXA_MEDIA_BUCKET=bkt; branch=fxa-1
printf '![a](./.fxa-auto-media/shot.png)\n![b](shot.png)\n![c](other-shot.png)\n![d](https://x.test/shot.png)\n' > "$tmp/body.md"
media=("$wt/.fxa-auto-media/shot.png")
_finish_media_to_bucket "$tmp/body.md" media > /dev/null
check "local links are rewritten, another file and a URL are not" "2|1|1|0" \
  "$(grep -c 'storage.googleapis.com/bkt/fxa-1/' "$tmp/body.md")|$(grep -c '(other-shot.png)' "$tmp/body.md")|$(grep -c '(https://x.test/shot.png)' "$tmp/body.md")|$(grep -c 'fxa-auto-media' "$tmp/body.md")"
check "a screenshot shows 480 px wide and links to the full size" "2" \
  "$(grep -cE '^<a href="https://storage.googleapis.com/bkt/fxa-1/[0-9a-f]{16}/1/shot.png"><img src="https://storage.googleapis.com/bkt/fxa-1/[0-9a-f]{16}/1/shot.png" width="480" alt="shot.png"></a>$' "$tmp/body.md")"
if command -v ffmpeg >/dev/null 2>&1; then
  gcloud() { [ "$1 $2" = "storage cp" ] && printf '%s\n' "$5" >> "$tmp/up"; }
  ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=1" -c:v libvpx "$wt/run.webm" 2>/dev/null || ffmpeg -v error -f lavfi -i "testsrc=s=320x180:d=1" "$wt/run.webm"
  printf 'body\n' > "$tmp/body.md"; media=("$wt/run.webm")
  _finish_media_to_bucket "$tmp/body.md" media > /dev/null
  check "a WebM goes up as an MP4 and a still frame, and the frame links to the MP4" "1|2" \
    "$(grep -cE '^<a href="https://storage.googleapis.com/bkt/fxa-1/[0-9a-f]{16}/1/run.mp4"><img src="https://storage.googleapis.com/bkt/fxa-1/[0-9a-f]{16}/1/run.png" width="480" alt="run.mp4 \(video: click to play\)"></a>$' "$tmp/body.md")|$(grep -cE '/1/run\.(mp4|png)$' "$tmp/up")"
  # At most 2 videos show as frames; the rest are links in a closed "More recordings" list. A caption shows under its picture.
  for v in a b c; do ffmpeg -v error -y -f lavfi -i "testsrc=s=320x180:d=1" -c:v libx264 -pix_fmt yuv420p "$wt/$v.mp4"; done
  printf '{"media_captions":{"a.mp4":"Sign-in with a <new> code","shot.png":"The code screen"}}' > "$tmp/cap.json"
  printf 'body\n' > "$tmp/body.md"; : > "$tmp/up"; media=("$wt/a.mp4" "$wt/b.mp4" "$wt/c.mp4" "$wt/.fxa-auto-media/shot.png")
  _finish_media_to_bucket "$tmp/body.md" media "$tmp/cap.json" > /dev/null
  check "two videos show as frames, the third is a link under More recordings, and every file is uploaded" "2|1|1|6" \
    "$(grep -c '(video: click to play)' "$tmp/body.md")|$(grep -c '<details><summary>More recordings (1)</summary>' "$tmp/body.md")|$(grep -cE '^- \[c.mp4\]\(https://storage.googleapis.com/bkt/fxa-1/[0-9a-f]{16}/3/c.mp4\)$' "$tmp/body.md")|$(grep -c . "$tmp/up")"
  check "a caption shows under its picture, escaped, and in the alt text" "1|1" \
    "$(grep -c '<br><em>Sign-in with a &lt;new&gt; code</em>$' "$tmp/body.md")|$(grep -c 'alt="shot.png: The code screen"' "$tmp/body.md")"
  # The frame is 480 px wide, with a white play triangle on a dark disc in its center: a reader sees a video.
  px() { ffmpeg -v error -i "$wt/run.png" -vf "crop=1:1:$1:$2" -f rawvideo -pix_fmt gray - | od -An -tu1 | tr -d ' '; }
  check "the still frame is 480 px wide, with a play button in the middle" "480|1|1" \
    "$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$wt/run.png")|$([ "$(px 'iw/2' 'ih/2')" -gt 230 ] && echo 1)|$([ "$(px 'iw/2-30' 'ih/2')" -lt 110 ] && echo 1)"
else echo "skip the video check: no ffmpeg"; fi
# The host's backstop: an FxA PR that changes what a person sees, with nothing attached and no reason, says so in
# its body. A test-only change, an attached file, a reason, or a repo that is not FxA adds no line.
eval "$(sed -n '/^_finish_media_note() {/,/^}/p' "$(dirname "$0")/finish.sh")"
fx="$tmp/fx"; mkdir -p "$fx/packages/fxa-settings/src" && cd "$fx" && git init -q && echo a > packages/fxa-settings/src/Page.tsx && echo a > packages/fxa-settings/src/Page.test.tsx \
  && git -c user.email=t@example.com -c user.name=t add . && git -c user.email=t@example.com -c user.name=t commit -qm base && b="$(git rev-parse HEAD)"
c() { git -c user.email=t@example.com -c user.name=t commit -qam "$1"; }
echo b > packages/fxa-settings/src/Page.test.tsx; c test
check "a test-only change adds no line" "" "$(_finish_media_note "$fx" "$b" 0)"
echo b > packages/fxa-settings/src/Page.tsx; c page
check "a visible change with nothing attached names its file" 1 "$(_finish_media_note "$fx" "$b" 0 | grep -c 'No screenshot or video is attached, though this PR changes what a person sees (`packages/fxa-settings/src/Page.tsx`)')"
check "an attached file adds no line" "" "$(_finish_media_note "$fx" "$b" 1)"
echo 'behind a WebAuthn prompt' > .fxa-auto-media-skipped.txt; check "a reason adds no line" "" "$(_finish_media_note "$fx" "$b" 0)"; rm .fxa-auto-media-skipped.txt
check "a repo that is not FxA adds no line" "" "$(mv packages/fxa-settings packages/other && _finish_media_note "$fx" "$b" 0; mv packages/other packages/fxa-settings)"
cd "$tmp"
exit "$fail"
