#!/usr/bin/env bash
# Offline check that a declined review comment gets one short reply, and that the reply
# never reads as new feedback.
#   bash lib/feedback-decline.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/github.sh"
pipeline_require() { :; }
worktree_branch_for() { echo fxa-1; }
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG="mozilla/fxa"
# Each POST goes to a file, one line per call, so a second reply shows.
gh() {
  case "$*" in
    "pr list"*) echo 7 ;;
    *"--method POST"*) [ -n "${POST_FAILS:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; return 1; }; printf '%s\n' "$*" >> "$tmp/posts" ;;
    *issues/comments/55*) echo https://github.com/mozilla/fxa/pull/7#issuecomment-55 ;;
    *pulls/7/comments*) echo '[{"id":1,"user":{"login":"Copilot","type":"Bot"},"author_association":"CONTRIBUTOR","path":"a.ts","line":3,"body":"no lint target"},
      {"id":2,"in_reply_to_id":1,"user":{"login":"fxa-bot[bot]","type":"Bot"},"author_association":"NONE","path":"a.ts","line":3,"body":"Not changed: the plugin adds it"}]' ;;
    *graphql*) echo '[]' ;;
    *pulls/7/reviews*|*issues/7/comments*) echo '[]' ;;
    *) return 1 ;;
  esac
}
posts() { cat "$tmp/posts" 2>/dev/null; }
errors_record() { echo "$*" >> "$tmp/errs"; }

check "a decline replies on the inline thread" "1|yes" \
  "$(gh_feedback FXA-1 decline 1 "the eslint plugin adds the lint target" >/dev/null; posts | grep -c 'pulls/7/comments/1/replies')|$(posts | grep -q 'body=Not changed: the eslint plugin adds the lint target' && echo yes)"
check "it marks the comment seen, and our own reply is not feedback" "0" "$(gh_feedback FXA-1 | jq '.comments | length')"
check "a second decline on the same id posts nothing" "1" "$(gh_feedback FXA-1 decline 1 again >/dev/null; posts | wc -l | tr -d ' ')"
check "a conversation comment gets a PR comment that links it" "yes" \
  "$(gh_feedback FXA-1 decline i55 "out of scope" >/dev/null; posts | grep -q 'issues/7/comments.*Not changed: out of scope (https://github.com/mozilla/fxa/pull/7#issuecomment-55)' && echo yes)"
check "a long reason is cut to one line of 300 characters" "yes" \
  "$(gh_feedback FXA-1 decline 3 "$(printf 'x%.0s' $(seq 400))"$'\nmore' >/dev/null; [ "$(posts | tail -1 | grep -o 'x*' | awk '{ if (length > m) m = length } END { print m }')" = 300 ] && echo yes)"
check "no reason, or a bad id, is refused" "1|1" \
  "$(gh_feedback FXA-1 decline 4 "" >/dev/null 2>&1; echo $?)|$(gh_feedback FXA-1 decline 'x;y' why >/dev/null 2>&1; echo $?)"
check "a failed post records nothing, so the next pass can reply" "1|no" \
  "$(POST_FAILS=1 gh_feedback FXA-1 decline 5 why >/dev/null 2>&1; echo $?)|$(grep -qx 5 "$tmp/FXA-1.feedback-declined" && echo yes || echo no)"
check "a failed post says why, and goes to the error store" "1|1" \
  "$(POST_FAILS=1 gh_feedback FXA-1 decline 6 why 2>&1 >/dev/null | grep -c 'could not reply on 6: HTTP 403: Resource not accessible')|$(grep -c '^github decline_failed FXA-1 feedback decline could not reply on 6: HTTP 403' "$tmp/errs")"
exit "$fail"