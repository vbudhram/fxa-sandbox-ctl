#!/usr/bin/env bash
# Offline check that a feedback round posts its summary on the PR and updates only the
# body's questions section.
#   bash lib/feedback-pr.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "skip: needs jq and python3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_feedback_pr() {/,/^}/p' "$(dirname "$0")/finish.sh")"
printf '%s' '**Summary**
Copy change.

**Questions for the reviewer:**

1. Old question one?
2. Old question two?

**Testing**
- PASS' > "$tmp/body"
gh() {
  case "$*" in
    *"-X POST"*comments*) printf '%s' "${@: -1}" | sed 's/^body=//' > "$tmp/comment" ;;
    *"-X PATCH"*) cat > "$tmp/newbody" ;;
    *pulls/7*) cat "$tmp/body" ;;
  esac
}
jq -n '{feedback_summary: ["Fixed: the email is kept. <link>", "Not fixed: the colour, it matches the design."], open_questions: ["Old question two?"]}' > "$tmp/done.json"
_finish_feedback_pr https://github.com/mozilla/fxa/pull/7 "$tmp/done.json" 2>/dev/null
check "the summary is posted on the PR" "yes" "$(grep -q 'review round' "$tmp/comment" && grep -q '^- Fixed: the email is kept' "$tmp/comment" && echo yes)"
check "only the questions section changes" "**Summary**|Copy change.|1. Old question two?|**Testing**|- PASS" \
  "$(grep -v '^$' "$tmp/newbody" | grep -v '^\*\*Questions' | paste -sd'|' -)"
rm -f "$tmp/newbody"; jq -n '{feedback_summary: ["Fixed: x"], open_questions: []}' > "$tmp/done.json"
_finish_feedback_pr https://github.com/mozilla/fxa/pull/7 "$tmp/done.json" 2>/dev/null
check "no open questions says so" "yes" "$(grep -q 'None left open.' "$tmp/newbody" && echo yes)"
rm -f "$tmp/newbody"; jq -n '{feedback_summary: ["Fixed: x"]}' > "$tmp/done.json"
_finish_feedback_pr https://github.com/mozilla/fxa/pull/7 "$tmp/done.json" 2>/dev/null
check "without open_questions the body is left alone" "no" "$([ -f "$tmp/newbody" ] && echo yes || echo no)"

# A markdown heading after the questions ends the section too, and CRLF from a web edit is fine.
printf '%s' $'**Questions for the reviewer:**\r\n\r\n1. Old?\r\n2. Kept?\r\n\r\n## Screenshots\r\n![x](y)\r\n\r\nCloses: FXA-1' > "$tmp/body"
rm -f "$tmp/newbody"; jq -n '{open_questions: ["Kept?"]}' > "$tmp/done.json"
_finish_feedback_pr https://github.com/mozilla/fxa/pull/7 "$tmp/done.json" 2>/dev/null
check "a ## heading ends the section, CRLF bodies match, the rest stays" "1. Kept?|## Screenshots|![x](y)|Closes: FXA-1" \
  "$(grep -v '^$' "$tmp/newbody" 2>/dev/null | grep -v '^\*\*Questions' | paste -sd'|' -)"
exit "$fail"
