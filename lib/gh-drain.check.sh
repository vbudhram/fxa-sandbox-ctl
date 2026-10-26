#!/usr/bin/env bash
# Offline check of gh_drain: a done ticket whose PR is older than the 200 newest is read by its branch,
# and a fork PR from a branch with the key's name is not ours.
#   bash lib/gh-drain.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n "/^read -r -d '' _GH_ROLLUP_JQ/,/^JQ\$/p" "$here/github.sh")"
eval "$(sed -n '/^gh_drain() {/,/^}/p' "$here/github.sh")"
pipeline_require() { :; }; worktree_branch_for() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }; PIPE_REPO_SLUG=mozilla/fxa
pr() { printf '{"number":%s,"state":"%s","headRefName":"%s","statusCheckRollup":[],"mergeable":"MERGEABLE","headRefOid":"abc","isCrossRepository":%s}' "$@"; }
# The 200 newest: FXA-2's PR. FXA-1's merged PR is older: only --head finds it. FXA-3 has only a fork PR, which the branch read sees.
gh() { local q="" head=""; while [ $# -gt 0 ]; do case "$1" in -q) q="$2"; shift ;; --head) head="$2"; shift ;; esac; shift; done
  echo "$head" >> "$tmp/heads"
  case "$head" in
    "") j="[$(pr 2 MERGED fxa-2 false)]" ;;
    fxa-3) j="[$(pr 3 OPEN fxa-3 true)]" ;;
    fxa-1) j="[$(pr 1 MERGED fxa-1 false)]" ;;
    fxa-4) [ -z "${FAIL4:-}" ] || return 1; j="[]" ;;
    *) j="[]" ;;
  esac
  jq -r "$q" <<< "$j"; }
out="$(gh_drain $'FXA-1\nFXA-2\nFXA-3\nFXA-4' 2>/dev/null)"
check "an old PR is read by its branch; a newer one comes from the list" "FXA-1 1 MERGED|FXA-2 2 MERGED" "$(grep -E '^FXA-[12] ' <<< "$out" | paste -sd'|' -)"
check "a fork PR named after the key is not ours: none" "FXA-3 none -" "$(grep '^FXA-3 ' <<< "$out")"
check "a key with no PR anywhere: none, after one branch read" "FXA-4 none -|1" "$(grep '^FXA-4 ' <<< "$out")|$(grep -c '^fxa-4$' "$tmp/heads")"
check "a failed branch read reports nothing, not a false none" "" "$(FAIL4=1 gh_drain FXA-4 2>/dev/null)"
check "a key in the newest list costs no branch read" "0" "$(grep -c '^fxa-2$' "$tmp/heads")"
exit "$fail"
