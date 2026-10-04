#!/usr/bin/env bash
# Offline check for _jira_ready_comment: one Jira comment per PR when a ticket turns done.
#   bash lib/ready-comment.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_jira_ready_comment() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG=mozilla/fxa
PRN=21358; gh_pr_state() { echo "FXA-1 $PRN OPEN"; }
jira_comment() { printf '%s|%s\n' "$1" "$2" >> "$tmp/comments"; }
_jira_ready_comment FXA-1; _jira_ready_comment FXA-1
check "one comment for a PR, however often it turns done" "1" "$(wc -l < "$tmp/comments" | tr -d ' ')"
check "it leads with the robot and links the PR" "FXA-1|🤖 PR ready for review: https://github.com/mozilla/fxa/pull/21358 (CI is green)." "$(head -1 "$tmp/comments")"
PRN=21400; _jira_ready_comment FXA-1
check "a new PR on the ticket gets its own comment" "2" "$(wc -l < "$tmp/comments" | tr -d ' ')"
PRN=none; _jira_ready_comment FXA-1
check "no PR, no comment" "2" "$(wc -l < "$tmp/comments" | tr -d ' ')"
jira_comment() { return 1; }; PRN=21500; _jira_ready_comment FXA-1 2>/dev/null
check "a failed post is tried again next time" "21400" "$(cat "$tmp/FXA-1.ready-noted")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
