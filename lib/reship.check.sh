#!/usr/bin/env bash
# Offline check for the reship of a saved tooling ship (epic i519): the strict PR read, the
# reship on a temporary repo with an origin, and the fallback. No network.
#   bash lib/reship.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

# ── gh_pr_none: 0 no PR, 1 a PR, 2 gh failed; gh_pr_state still says none on a failure ──
eval "$(sed -n '/^gh_pr_none() {/,/^}/p;/^gh_pr_state() {/,/^}/p' "$here/github.sh")"
pipeline_require() { :; }; _retry() { "$@"; }; worktree_branch_for() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }
PIPE_REPO_SLUG=mozilla/fxa _GH_ROLLUP_JQ='{ok: 0, fail: 0, run: 0}'
gh() { case "${GH:-}" in none) echo '[]' ;; one) echo '[{"number":9,"state":"CLOSED"}]' ;; *) return 1 ;; esac; }
none_rc() { GH="$1" gh_pr_none FXA-7 >/dev/null 2>&1; echo $?; }
check "gh_pr_none: no PR 0, a PR 1, a failed gh 2" "0 1 2" "$(none_rc none) $(none_rc one) $(none_rc fail)"
check "gh_pr_state still prints none when gh fails" "FXA-7 none - -" "$(GH=fail gh_pr_state FXA-7)"

exit "$fail"
