#!/usr/bin/env bash
# Offline check for the GitHub App commit path. The API is stubbed.
#   bash lib/github-app.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"
eval "$(sed -n '/^github_app_commit() {/,/^}/p' "$here/github.sh")"
# Stub: log each call, answer like GitHub. REMOTE_SHA plays the branch's current head.
_gh_app_api() {
  local body; body="$(cat)"; printf '%s %s %s\n' "$1" "$2" "$body" >> "$tmp/calls"
  case "$1 $2" in
    "POST git/blobs") echo '{"sha":"blob'"$(wc -l < "$tmp/calls" | tr -d ' ')"'"}' ;;
    "POST git/trees") echo '{"sha":"tree1"}' ;;
    "POST git/commits") echo '{"sha":"commit1"}' ;;
    GET*) [ -n "${REMOTE_SHA:-}" ] && echo '{"object":{"sha":"'"$REMOTE_SHA"'"}}' || return 22 ;;
    *) echo '{}' ;;
  esac
}
g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.com "$@"; }
g init -q "$tmp/r"; cd "$tmp/r"
echo a > a.txt; echo c > c.txt; printf '#!/bin/sh\n' > run.sh; g add . && g commit -qm base
base="$(git rev-parse HEAD)"
echo a2 > a.txt; git rm -q c.txt; echo d > d.txt; chmod +x run.sh; git add a.txt d.txt run.sh

out="$(github_app_commit "$tmp/r" fxa-1 "$base" "fix(x): y" 2>/dev/null)"
check "prints the new commit" "commit1" "$out"
tree="$(grep '^POST git/trees' "$tmp/calls" | cut -d' ' -f3-)"
check "tree sits on the parent's tree" "$(git rev-parse "${base}^{tree}")" "$(jq -r .base_tree <<< "$tree")"
check "tree entries" "a.txt:100644:blob,c.txt:100644:null,d.txt:100644:blob,run.sh:100755:blob" \
  "$(jq -r '[.tree[] | "\(.path):\(.mode):\(if .sha == null then "null" else "blob" end)"] | join(",")' <<< "$tree")"
check "blob holds the staged content" "a2" "$(grep '^POST git/blobs' "$tmp/calls" | head -1 | cut -d' ' -f3- | jq -r .content | base64 -d)"
check "commit has one parent and the message" "$base|fix(x): y" \
  "$(grep '^POST git/commits' "$tmp/calls" | cut -d' ' -f3- | jq -r '"\(.parents | join(","))|\(.message)"')"
check "a new branch is created" "refs/heads/fxa-1" "$(grep '^POST git/refs' "$tmp/calls" | cut -d' ' -f3- | jq -r .ref)"

# An existing branch that moved since our fetch is never overwritten.
: > "$tmp/calls"; git update-ref refs/remotes/origin/fxa-1 "$base"
REMOTE_SHA=0123456789abcdef github_app_commit "$tmp/r" fxa-1 "$base" "m" >/dev/null 2>&1
check "moved branch refused" "0" "$(grep -c '^PATCH' "$tmp/calls")"
: > "$tmp/calls"
REMOTE_SHA="$base" github_app_commit "$tmp/r" fxa-1 "$base" "m" >/dev/null 2>&1
check "expected branch is moved" "true" "$(grep '^PATCH git/refs/heads/fxa-1' "$tmp/calls" | cut -d' ' -f3- | jq -r .force)"

# Media goes to the bucket: references rewritten in place, the rest appended.
eval "$(sed -n '/^_finish_media_to_bucket() {/,/^}/p' "$here/finish.sh")"
eval "$(sed -n '/^slot_write() /p' "$here/worktree.sh")"
gcloud() { printf '%s\n' "$*" >> "$tmp/gcloud"; }
FXA_MEDIA_BUCKET=b branch=fxa-1
mkdir -p "$tmp/m"; : > "$tmp/m/shot.png"; : > "$tmp/m/other.png"; : > "$tmp/m/run.mp4"
printf 'Before ![x](./shot.png) after\n' > "$tmp/body.md"
arr=(--attach "$tmp/m/shot.png" --attach "$tmp/m/other.png" --attach "$tmp/m/run.mp4")
md="$(_finish_media_to_bucket "$tmp/body.md" arr)"
check "three uploads" "3" "$(grep -c '^storage cp' "$tmp/gcloud")"
check "reference rewritten in place" "1" "$(grep -cE '^Before !\[x\]\(https://storage.googleapis.com/b/fxa-1/[0-9a-f]{16}/1/shot.png\) after$' "$tmp/body.md")"
check "unreferenced image appended" "1" "$(grep -cE '^!\[other.png\]\(https://storage.googleapis.com/b/.*/2/other.png\)$' "$tmp/body.md")"
check "video appended as a link" "1" "$(grep -cE '^\[run.mp4\]\(https://.*/3/run.mp4\)$' "$tmp/body.md")"
check "markdown lists all three" "3" "$(printf '%s\n' "$md" | grep -c 'storage.googleapis.com')"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
