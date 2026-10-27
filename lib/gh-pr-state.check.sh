#!/usr/bin/env bash
# Offline check for gh_pr_state: a fork PR is not ours, and a failed gh still says none. No network.
#   bash lib/gh-pr-state.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^gh_pr_state() {/,/^}/p' "$here/github.sh")"
pipeline_require() { :; }; _retry() { "$@"; }; worktree_branch_for() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }
PIPE_REPO_SLUG=mozilla/fxa _GH_ROLLUP_JQ='{ok: 0, fail: 0, run: 0}'
gh() { case "${GH:-}" in fork) echo '[{"number":9,"state":"MERGED","isCrossRepository":true}]' ;;
  both) echo '[{"number":9,"state":"MERGED","isCrossRepository":true},{"number":8,"state":"OPEN","isCrossRepository":false}]' ;; *) return 1 ;; esac; }
check "a fork PR from a branch with the key's name is not ours: none, then our own PR" \
  "FXA-7 none - -|FXA-7 8 OPEN" "$(GH=fork gh_pr_state FXA-7)|$(GH=both gh_pr_state FXA-7 | cut -d' ' -f1-3)"
check "gh_pr_state still prints none when gh fails" "FXA-7 none - -" "$(GH=fail gh_pr_state FXA-7)"
[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
