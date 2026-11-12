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
check "the summary is posted on the ticket, one bullet per comment" "FXA-1|::info
**Review feedback round** · [PR #7](${url})
- Fixed: null guard, confirmed on main (https://github.com/mozilla/fxa/pull/7#discussion_r1)
- Not fixed: rename, a design preference (https://github.com/mozilla/fxa/pull/7#issuecomment-2)" "$(cat "$tmp/posted")"

rm -f "$tmp/posted"; printf '{"pr_body":"x"}' > "$tmp/done.json"
_finish_feedback_comment FXA-1 "$tmp/done.json" "$url"
check "a run without a summary or acted comments posts nothing" "no" "$([ -e "$tmp/posted" ] && echo yes || echo no)"
printf '41\ni5\n' > "$tmp/FXA-1.feedback-acted"
check "a feedback round with no summary says so and names its comments" "FXA-1|::warning
**Review feedback round: no summary** · [PR #7](${url})
- The round pushed a commit but did not say which comments it fixed. A person should check: [41](${url}#discussion_r41), i5.|1" \
  "$(PIPE_STATE_DIR="$tmp" _finish_feedback_comment FXA-1 "$tmp/done.json" "$url" 2>"$tmp/err"; cat "$tmp/posted"; echo "|$(grep -c 'WARN: needs you' "$tmp/err")")"
rm -f "$tmp/FXA-1.feedback-acted" "$tmp/posted"

printf '{"feedback_summary":"Fixed: one\\n\\nNot fixed: two"}' > "$tmp/done.json"
_finish_feedback_comment FXA-1 "$tmp/done.json" "$url"
check "a string summary gives one bullet per line" "- Fixed: one|- Not fixed: two" "$(tail -2 "$tmp/posted" | paste -sd'|' -)"
printf '{"feedback_summary":["- Fixed: one\\n* Not fixed: two"]}' > "$tmp/done.json"; rm -f "$tmp/posted"
_finish_feedback_comment FXA-1 "$tmp/done.json" "$url"
check "the agent's own list marks and line breaks give clean bullets" "- Fixed: one|- Not fixed: two" "$(tail -2 "$tmp/posted" | paste -sd'|' -)"
rm -f "$tmp/posted"
_finish_feedback_comment agent-x1 "$tmp/done.json" "$url"
check "a session key is not a Jira ticket" "no" "$([ -e "$tmp/posted" ] && echo yes || echo no)"

# A round that fixed none of its comments, all from bots, gives its review round back; a person's comment keeps it.
eval "$(sed -n '/^_finish_feedback_free() {/,/^}/p' "$(dirname "$0")/finish.sh")"
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG=mozilla/fxa
gh() { case "$*" in *comments/11*|*comments/12*) echo Bot ;; *) echo User ;; esac; }
free() { echo 2 > "$tmp/FXA-2.feedback-rounds"; printf '%s\n' "$@" > "$tmp/FXA-2.feedback-acted"; _finish_feedback_free FXA-2 "$tmp/done.json" 2>/dev/null; cat "$tmp/FXA-2.feedback-rounds"; }
printf '{"feedback_summary":["Not fixed: a, wrong on main (u1)","- Not fixed: b, out of scope (u2)"]}' > "$tmp/done.json"
check "all not fixed, all bot comments: the round does not count" "1" "$(free 11 12)"
check "a person's inline comment in the round: it counts" "2" "$(free 11 13)"
check "a conversation comment is a person's: it counts" "2" "$(free 11 i5)"
printf '{"feedback_summary":["Not fixed: a (u1)","Fixed: b (u2)"]}' > "$tmp/done.json"
check "one comment fixed: it counts" "2" "$(free 11 12)"
printf '{"pr_body":"x"}' > "$tmp/done.json"
check "no summary: it counts" "2" "$(free 11 12)"
printf '{"feedback_summary":["Fixed: one"]}' > "$tmp/done.json"
jira_comment() { return 1; }
check "a failed post warns and does not fail" "0 1" "$(_finish_feedback_comment FXA-1 "$tmp/done.json" "$url" 2>"$tmp/err"; echo "$? $(grep -c WARN "$tmp/err")")"
exit "$fail"
