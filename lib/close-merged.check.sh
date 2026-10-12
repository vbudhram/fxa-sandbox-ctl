#!/usr/bin/env bash
# Offline check for the three selections jira_close_merged makes. No network.
#   bash lib/close-merged.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# 1. Approver: last human approval wins, bots never count.
approver() {
  jq -r '[ .[0].reviews[]?
           | select(.state == "APPROVED")
           | select(.author.login | test("\\[bot\\]$|copilot"; "i") | not)
           | .author.login ] | last // empty'
}
check "one approver" "vpomerleau" "$(echo '[{"reviews":[
  {"state":"APPROVED","author":{"login":"vpomerleau"}}]}]' | approver)"
# #21225: l10n approved the strings first, the code owner two hours later.
check "last of two wins" "vpomerleau" "$(echo '[{"reviews":[
  {"state":"APPROVED","author":{"login":"bcolsson"}},
  {"state":"APPROVED","author":{"login":"vpomerleau"}}]}]' | approver)"
check "bot ignored" "toufali" "$(echo '[{"reviews":[
  {"state":"APPROVED","author":{"login":"toufali"}},
  {"state":"APPROVED","author":{"login":"Copilot"}},
  {"state":"APPROVED","author":{"login":"some-app[bot]"}}]}]' | approver)"
check "comment is not approval" "" "$(echo '[{"reviews":[
  {"state":"COMMENTED","author":{"login":"nshirley"}}]}]' | approver)"
check "no reviews" "" "$(echo '[{"reviews":[]}]' | approver)"
check "no pr" "" "$(echo '[]' | approver)"

# 2. Sprint: exactly one match, or nothing. Board 225 runs FxA and SubPlat
#    sprints at the same time, so picking the first would file FxA work into
#    the SubPlat train.
sprint() {
  jq -r --arg re '^FxA Sprint ' \
    '[.sprints[]? | select(.name | test($re)) | .id] | if length == 1 then .[0] else empty end'
}
check "picks fxa over subplat" "26115" "$(echo '{"sprints":[
  {"id":26115,"name":"FxA Sprint 346"},{"id":26024,"name":"SubPlat Train 346"}]}' | sprint)"
check "two fxa sprints is ambiguous" "" "$(echo '{"sprints":[
  {"id":1,"name":"FxA Sprint 346"},{"id":2,"name":"FxA Sprint 347"}]}' | sprint)"
check "no fxa sprint" "" "$(echo '{"sprints":[{"id":26024,"name":"SubPlat Train 346"}]}' | sprint)"

# 3. reporters.tsv inverts login -> email, and never guesses.
map="$(mktemp)"; printf '# c\nAda Example\tada-example\tada@example.com\nBo Blank\tbo-blank\t\n' > "$map"
email() { awk -F'\t' -v l="$1" '$0 !~ /^#/ && $2 == l {print $3; exit}' "$map"; }
check "login to email" "ada@example.com" "$(email ada-example)"
check "blank column stays blank" "" "$(email bo-blank)"
check "unknown login" "" "$(email nobody)"
rm -f "$map"

[ "$fail" -eq 0 ] && echo "all ok" || echo "FAILURES"

# 4. After the close: the ticket's assignee and status, saved for the Stats PRs tab.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^jira_record_state() {/,/^}/p' "$(dirname "$0")/jira.sh")"
PIPE_STATE_DIR="$tmp"
acli() { echo '{"fields":{"assignee":{"displayName":"Pat Doe"},"status":{"name":"Done"}}}'; }
jira_record_state FXA-9
check "record: assignee and status after the close" "Pat Doe Done" "$(jq -r '"\(.assignee) \(.status)"' "$tmp/FXA-9.jira.json" 2>/dev/null)"
acli() { echo '{"fields":{"assignee":null,"status":{"name":"Done"}}}'; }
jira_record_state FXA-10
check "record: no assignee is null, not a crash" "null Done" "$(jq -r '"\(.assignee) \(.status)"' "$tmp/FXA-10.jira.json" 2>/dev/null)"
acli() { echo "unauthorized"; return 1; }
jira_record_state FXA-11
check "record: a failed Jira read writes no file" "no" "$([ -e "$tmp/FXA-11.jira.json" ] && echo yes || echo no)"

# 5. jira-state takes only ticket keys: a raw argument would become a state-file path.
eval "$(sed -n '/^cmd_jira_state() {/,/^}/p;/^_key() {/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^jira_normalize_key() {/,/^}/p' "$(dirname "$0")/jira.sh")"
jira_record_state() { echo "$1" >> "$tmp/recorded"; }
out="$(cmd_jira_state ../x FXA-12 -rf fxa-7 2>&1)"
check "jira-state: only ticket keys are recorded, upper-cased; the others are refused" "FXA-12 FXA-7|2" \
  "$(tr '\n' ' ' < "$tmp/recorded" | sed 's/ $//')|$(printf '%s\n' "$out" | grep -c 'not a ticket key')"

# 6. jira_close_merged itself saves the ticket's state after the close.
eval "$(sed -n '/^jira_close_merged() {/,/^}/p' "$(dirname "$0")/jira.sh")"
pipeline_require() { :; }; gh_pr_approver() { echo pat; }; jira_login_email() { echo pat@example.com; }
jira_active_sprint_id() { echo 7; }; jira_sprint_add() { :; }
eval "$(sed -n '/^jira_record_state() {/,/^}/p' "$(dirname "$0")/jira.sh")"
acli() { case "$*" in *"view FXA-20"*) echo '{"fields":{"assignee":{"displayName":"Pat Doe","accountId":"x"},"status":{"name":"Done"},"customfield_10020":[{"id":7}]}}' ;; esac; }
jira_close_merged FXA-20 2>/dev/null
check "close: jira_close_merged saves the ticket's assignee and status" "Pat Doe Done" "$(jq -r '"\(.assignee) \(.status)"' "$tmp/FXA-20.jira.json" 2>/dev/null)"
exit "$fail"
