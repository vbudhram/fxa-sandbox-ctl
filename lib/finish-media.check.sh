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
exit "$fail"
