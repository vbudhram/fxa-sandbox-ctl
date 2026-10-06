#!/usr/bin/env bash
# Offline check that a feedback round's summary is posted on the Jira ticket.
#   bash lib/feedback-comment.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_feedback_comment() {/,/^}/p' "$(dirname "$0")/finish.sh")"
jira_comment() { printf '%s|%s' "$1" "$2" > "$tmp/posted"; }
url=https://github.com/mozilla/fxa/pull/7

printf '{"feedback_summary":["Fixed: null guard, confirmed on main (https://github.com/mozilla/fxa/pull/7#discussion_r1)","Not fixed: rename, a design preference (https://github.com/mozilla/fxa/pull/7#issuecomment-2)"]}' > "$tmp/done.json"
_finish_feedback_comment FXA-1 "$tmp/done.json" "$url"
check "the summary is posted on the ticket" "FXA-1|🤖 Review feedback on ${url}:
Fixed: null guard, confirmed on main (https://github.com/mozilla/fxa/pull/7#discussion_r1)
Not fixed: rename, a design preference (https://github.com/mozilla/fxa/pull/7#issuecomment-2)" "$(cat "$tmp/posted")"

rm -f "$tmp/posted"; printf '{"pr_body":"x"}' > "$tmp/done.json"
_finish_feedback_comment FXA-1 "$tmp/done.json" "$url"
check "a round without a summary posts nothing" "no" "$([ -e "$tmp/posted" ] && echo yes || echo no)"

printf '{"feedback_summary":"Fixed: one line"}' > "$tmp/done.json"
_finish_feedback_comment agent-x1 "$tmp/done.json" "$url"
check "a session key is not a Jira ticket" "no" "$([ -e "$tmp/posted" ] && echo yes || echo no)"

jira_comment() { return 1; }
check "a failed post warns and does not fail" "0 1" "$(_finish_feedback_comment FXA-1 "$tmp/done.json" "$url" 2>"$tmp/err"; echo "$? $(grep -c WARN "$tmp/err")")"
exit "$fail"
