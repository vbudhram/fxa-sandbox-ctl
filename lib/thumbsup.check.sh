#!/usr/bin/env bash
# Offline check that `feedback KEY thumbsup` reacts only to comments a push made outdated.
#   bash lib/thumbsup.check.sh
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
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG="mozilla/fxa"
# Comment 1 sits on lines a later push changed (position null); comment 2 does not.
gh() {
  case "$*" in
    *"--method POST"*) echo "$*" >>"$tmp/posts"; echo '{}' ;;
    *pulls/comments/1*) echo null ;;
    *pulls/comments/2*) echo 12 ;;
    *) return 1 ;;
  esac
}
printf '1\n2\ni3\n' >"$tmp/FXA-1.feedback-acted"

out="$(gh_feedback FXA-1 thumbsup 2>&1)"
check "reacts to the outdated comment only" "1" "$(wc -l <"$tmp/posts" | tr -d ' ')"
check "reacted on comment 1" "yes" "$(grep -q 'pulls/comments/1/reactions' "$tmp/posts" && echo yes)"
check "reports the unchanged inline comment" "yes" "$(grep -q 'not addressed.*2' <<<"$out" && echo yes)"
check "reports the conversation comment" "yes" "$(grep -q 'not addressed.*i3' <<<"$out" && echo yes)"
check "clears the acted file" "gone" "$([ -e "$tmp/FXA-1.feedback-acted" ] && echo present || echo gone)"

exit "$fail"
