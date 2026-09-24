#!/usr/bin/env bash
# Offline check that gh_red_infra never caches a failed log fetch as "not infra".
#   bash lib/red-infra.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/github.sh"
pipeline_require() { :; }
worktree_branch_for() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG="mozilla/fxa" PIPE_INFRA_CHECKS="extract=Bad credentials"
gh() {
  case "$1 $2" in
    "pr list") echo '[{"number":1,"headRefOid":"abc","statusCheckRollup":[
                 {"name":"extract","conclusion":"FAILURE","detailsUrl":"https://github.com/x/actions/runs/11/job/22"}]}]' ;;
    "run view") [ "$(cat "$tmp/logmode")" = ok ] && echo "HTTP 401: Bad credentials" || return 1 ;;
  esac
}

echo fail >"$tmp/logmode"
gh_red_infra FXA-1 >/dev/null; rc=$?
check "failed fetch is not infra" "1" "$rc"
check "failed fetch is not cached" "absent" "$([ -e "$tmp/FXA-1.redinfra" ] && echo present || echo absent)"

echo ok >"$tmp/logmode"
check "next read matches" "extract(Bad credentials)" "$(gh_red_infra FXA-1)"
check "match is cached" "extract(Bad credentials)" "$(sed -n 2p "$tmp/FXA-1.redinfra" 2>/dev/null)"

exit "$fail"
