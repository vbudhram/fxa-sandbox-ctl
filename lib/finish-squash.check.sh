#!/usr/bin/env bash
# Offline check: a round squashes on top of a person's commits on the PR, not over them.
#   bash lib/finish-squash.check.sh
set -euo pipefail
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
here="$(cd "$(dirname "$0")" && pwd -P)"
eval "$(sed -n '/^_finish_squash_base() {/,/^}/p' "$here/finish.sh")"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
g() { git -c init.defaultBranch=main -c user.email=t@example.com "$@"; }
g init -q "$tmp/r"; cd "$tmp/r"
echo a > a.txt; g -c user.name=dev add a.txt; g -c user.name=dev commit -qm base; base="$(git rev-parse HEAD)"
echo b > b.txt; git add b.txt; g -c 'user.name=fxa-agent[bot]' commit -qm agent; bot="$(git rev-parse HEAD)"

git update-ref refs/remotes/origin/fxa-1 "$bot"
check "only the App's commits: squash from the merge base" "$base" "$(_finish_squash_base "$tmp/r" fxa-1 "$base" "" 2>/dev/null)"
echo c > c.txt; git add c.txt; g -c user.name=Person commit -qm person; person="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/fxa-1 "$person"
check "a person's commit: squash on top of the PR head" "$person" "$(_finish_squash_base "$tmp/r" fxa-1 "$base" "" 2>/dev/null)"
check "a rebase round still squashes everything" "$base" "$(_finish_squash_base "$tmp/r" fxa-1 "$base" 1 2>/dev/null)"
check "no PR branch yet: the merge base" "$base" "$(_finish_squash_base "$tmp/r" fxa-2 "$base" "" 2>/dev/null)"
exit "$fail"
