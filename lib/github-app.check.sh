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

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
