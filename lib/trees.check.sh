#!/usr/bin/env bash
# Offline check for trees.sh and the tree routing in session_get/session_set.
#   bash lib/trees.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
SESSION_DIR="$tmp"; HOME="$tmp/home"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
_session_db_sync() { :; }
eval "$(grep '^_TREE_FIELDS=' "$here/session.sh")"
eval "$(grep '^_session_file()' "$here/session.sh")"
eval "$(grep '^_tree_field()' "$here/session.sh")"
eval "$(sed -n '/^session_get() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^session_set() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^_session_write() {/,/^}/p' "$here/session.sh")"
# shellcheck disable=SC1091
source "$here/trees.sh"

k=agent-ab12
echo '{"key":"agent-ab12","branch":"agent-ab12","pr_url":""}' > "$tmp/$k.json"
check "a one-repo session has no trees" "1" "$(trees_on "$k"; echo $?)"

PIPE_PROFILE=team PIPE_REPO_SLUG=mozilla/PyFxA PIPE_REPO="$tmp/home/Desktop/working2/PyFxA" PIPE_BASE_BRANCH=main PIPE_PR_OPEN=1
PIPE_WORK_ROWS=("mozilla/PyFxA /home/agent/pyfxa" "mozilla/fxa /home/agent/fxa")
_profile_app_repos() { echo mozilla/fxa; }
check "a repo off the profile's list is refused" "1" "$(trees_init "$k" mozilla/other 2>/dev/null; echo $?)"
trees_init "$k" mozilla/fxa,mozilla/FXA; check "a repo picked twice is added once" "1" "$(jq ".trees | length" "$tmp/$k.json")"; echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
trees_init "$k" mozilla/fxa,mozilla/pyfxa
check "trees in the order picked, pr only where the App is" "0	fxa	mozilla/fxa	/home/agent/fxa	pr|1	pyfxa	mozilla/PyFxA	/home/agent/pyfxa	diff" \
  "$(trees_rows "$k" | paste -sd '|' -)"
trees_init "$k" mozilla/pyfxa
check "a later pick adds only the new repo" "fxa pyfxa" "$(jq -r '[.trees[].name] | join(" ")' "$tmp/$k.json")"
echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
PIPE_PR_OPEN=0 trees_init "$k" mozilla/fxa
check "a read-only profile gives diff even with the App" "diff" "$(jq -r '.trees[0].out' "$tmp/$k.json")"
echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
trees_init "$k" mozilla/fxa,mozilla/pyfxa

session_set "$k" pr_url top
( _tree_enter "$k" 1 && session_set "$k" pr_url https://github.com/mozilla/PyFxA/pull/7 branch b1 state active )
check "a tree field goes to the selected tree" "https://github.com/mozilla/PyFxA/pull/7|b1" "$(jq -r '.trees[1].pr_url + "|" + .trees[1].branch' "$tmp/$k.json")"
check "other fields stay at the top" "top|active" "$(jq -r '.pr_url + "|" + .state' "$tmp/$k.json")"
check "session_get reads the selected tree" "https://github.com/mozilla/PyFxA/pull/7" "$( _tree_enter "$k" 1 && session_get "$k" pr_url)"
check "session_get without a tree reads the top" "top" "$(session_get "$k" pr_url)"
check "the tree's repo and host clone" "mozilla/PyFxA|$tmp/home/Desktop/working2/PyFxA|/home/agent/pyfxa" \
  "$( _tree_enter "$k" 1 && echo "$PIPE_REPO_SLUG|$FXA_REPO|$FXA_TREE_PATH")"
check "a bad index is refused" "1" "$( _tree_enter "$k" 'x;rm' 2>/dev/null; echo $?)"
check "trees_each runs every tree, fails when one fails" "fxa pyfxa |1" \
  "$(trees_each "$k" bash -c 'printf "%s " "$FXA_TREE_NAME"; [ "$FXA_TREE_NAME" = fxa ]'; echo "|$?")"
check "trees_each leaves the caller's repo alone" "mozilla/PyFxA|" "$(trees_each "$k" true; echo "$PIPE_REPO_SLUG|${_TREE_IDX:-}")"
echo '{"key":"agent-cd34"}' > "$tmp/agent-cd34.json"
trees_carry "$k" agent-cd34
check "a resume carries the repos, each on the new branch" "fxa:agent-cd34:pr pyfxa:agent-cd34:diff|" \
  "$(jq -r '[.trees[] | "\(.name):\(.branch):\(.out)"] | join(" ")' "$tmp/agent-cd34.json")|$(jq -r '.trees[1].pr_url // ""' "$tmp/agent-cd34.json")"
# A one-repo session resumed as a stack keeps its fields at the top; only FxA's tree takes them.
echo '{"key":"agent-one1","branch":"b-one","pr_url":"https://github.com/mozilla/fxa/pull/5","base_sha":"abc"}' > "$tmp/agent-one1.json"
check "a one-repo resume gives its PR and base to FxA's tree only" "https://github.com/mozilla/fxa/pull/5|abc|" \
  "$( _tree_enter "$k" 0 && trees_from_get agent-one1 pr_url)|$( _tree_enter "$k" 0 && trees_from_get agent-one1 base_sha)|$( _tree_enter "$k" 1 && trees_from_get agent-one1 pr_url)"
check "a stack resume reads each tree's own field" "https://github.com/mozilla/PyFxA/pull/7" "$( _tree_enter "$k" 1 && trees_from_get "$k" pr_url)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
