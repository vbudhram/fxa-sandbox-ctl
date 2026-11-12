#!/usr/bin/env bash
# Offline check that a PR behind its base is rebuilt as one App commit on the base, not merged.
#   bash lib/gh-update-branch.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^gh_update_branch() {/,/^}/p' "$(dirname "$0")/github.sh")"
_retry() { "$@"; }
github_app_enabled() { :; }
PIPE_REPO_SLUG=o/r PIPE_REPO="$tmp/clone"
g() { git -C "$tmp/$1" -c user.email=b@example.com -c user.name="${A:-fxa-agent[bot]}" -c core.hooksPath=/dev/null "${@:2}"; }
git init -q -b main "$tmp/up" && echo a > "$tmp/up/a" && echo b > "$tmp/up/b" && g up add . && g up commit -qm base
g up checkout -qb fix && echo fix > "$tmp/up/b" && g up commit -qam "fix(x): the change" && g up checkout -q main
echo a2 > "$tmp/up/a" && g up commit -qam m1 && g up checkout -q fix && g up merge -q --no-edit main && g up checkout -q main
echo a3 > "$tmp/up/a" && g up commit -qam m2
git clone -q "$tmp/up" "$tmp/clone"
gh() { echo "fix $(git -C "$tmp/up" rev-parse fix) main false"; }
_gh_app_api() { echo "$*" >> "$tmp/api"; }
github_app_commit() { echo "$3|$(git -C "$1" write-tree)|$(head -1 <<< "$4")|${_GH_APP_REBUILT:-}" > "$tmp/commit"; }
want="$(g up rev-parse main)|$(g up merge-tree --write-tree main fix)|fix(x): the change|1"
gh_update_branch 7; rc=$?
check "a bot PR behind main: one App commit on main with both changes, and no merge" "0|$want|" "$rc|$(cat "$tmp/commit")|$(cat "$tmp/api" 2>/dev/null)"
rm -f "$tmp/commit"; g up checkout -q fix && A=Person g up commit -q --allow-empty -m "person" && g up checkout -q main
gh_update_branch 7
check "a person's commit on the branch: GitHub's update-branch merges, and nothing is rebuilt" "PUT pulls/7/update-branch|" "$(cat "$tmp/api")|$(cat "$tmp/commit" 2>/dev/null)"
rm -f "$tmp/api"; g up checkout -q fix && g up reset -q --hard HEAD~1 && g up checkout -q main
echo conflict > "$tmp/up/b" && g up commit -qam m3
gh_update_branch 7 2>/dev/null; rc=$?
check "a conflict with main: fails, and nothing is pushed" "1||" "$rc|$(cat "$tmp/commit" 2>/dev/null)|$(cat "$tmp/api" 2>/dev/null)"
check "no worktree is left behind" "1" "$(git -C "$tmp/clone" worktree list | wc -l | tr -d ' ')"
exit "$fail"
