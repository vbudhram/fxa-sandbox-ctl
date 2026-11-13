#!/usr/bin/env bash
# Offline check for jira_admin_asked: only a team admin's comment after the queue label, which asks for a CI config change, allows it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^read -r -d .. _JIRA_TEXT_JQ <</,/^JQ$/p' "$here/jira.sh")"
eval "$(sed -n '/^jira_admin_asked() {/,/^}/p' "$here/jira.sh")"
pipeline_label_for() { echo ai-fixme; }
export FXA_TEAMS_DIR="$tmp" PIPE_PROFILE=demo
echo '{"admins":[{"slack":"UA1","email":"admin1@example.com"}],"people":[{"slack":"UP1","email":"pat@example.com"},{"slack":"UA2","email":"admin2@example.com","admin":true}]}' > "$tmp/demo.json"
# The queue label went on at 10:00 UTC (05:00 -0500). A comment is {author, created, text}.
queued='{"histories":[{"created":"2026-11-13T05:00:00.000-0500","items":[{"field":"labels","fromString":"bug","toString":"bug ai-fixme"}]}]}'
c() { jq -nc --arg a "$1" --arg t "$2" --arg x "$3" '{author: {accountId: $a}, created: $t, body: {type: "doc", content: [{type: "paragraph", content: [{type: "text", text: $x}]}]}}'; }
issue() { local cl="$1"; shift; printf '{"changelog":%s,"fields":{"reporter":{"accountId":"acc-a1"},"comment":{"comments":[%s]}}}' "$cl" "$(IFS=,; echo "$*")"; }
after=2026-11-13T11:00:00.000+0000 before=2026-11-13T09:00:00.000+0000
ask='Please update .circleci/config.yml to use node 22.'
_jira_rest() {
  case "$2" in
    /rest/api/3/user/search) case "$*" in *admin1@*) echo '[{"accountId":"acc-a1"}]' ;; *admin2@*) echo '[{"accountId":"acc-a2"}]' ;; *) echo '[]' ;; esac ;;
    */issue/X-1*) issue "$queued" ;;                                              # an admin reporter, no comment
    */issue/X-2*) issue "$queued" "$(c acc-a2 "$after" "$ask")" ;;
    */issue/X-3*) issue "$queued" "$(c acc-p "$after" "$ask")" ;;                 # not an admin
    */issue/X-4*) issue "$queued" "$(c acc-a2 "$before" "$ask")" ;;               # before the queue label
    */issue/X-5*) issue "$queued" "$(c acc-a2 "$after" 'thanks, looks good')" ;;
    */issue/X-6*) issue "$queued" "$(c acc-a2 "$after" 'Do not update .circleci/config.yml')" ;;
    */issue/X-7*) issue "$queued" "$(c acc-a2 "$after" "🤖 $ask")" ;;            # the bot, under a person's login
    */issue/X-8*) issue '{"histories":[]}' "$(c acc-a2 "$after" "$ask")" ;;       # no queue label event
    */issue/X-10*) issue "$queued" "$(c acc-a2 "$after" 'The job reads .circleci/config.yml.')" ;;  # no verb
    *) return 22 ;;
  esac
}
yes_no() { jira_admin_asked "$1" && echo yes || echo no; }
check "an admin reporter with no CI comment does not allow it" no "$(yes_no X-1)"
check "an admin's comment after the queue label that asks for a .circleci/ change allows it" yes "$(yes_no X-2)"
check "a non-admin's comment does not" no "$(yes_no X-3)"
check "an admin's comment from before the queue label does not" no "$(yes_no X-4)"
check "an admin's thanks does not" no "$(yes_no X-5)"
check "a negation does not" no "$(yes_no X-6)"
check "a 🤖 comment does not" no "$(yes_no X-7)"
check "no queue label event does not (fail closed)" no "$(yes_no X-8)"
check "a mention of the path with no change verb does not" no "$(yes_no X-10)"
check "a ticket Jira does not return does not" no "$(yes_no X-9)"
check "a team with no record does not" no "$(PIPE_PROFILE=other yes_no X-2)"
exit "$fail"
