#!/usr/bin/env bash
# Offline check that jira-card hides tickets Slack must not show.
#   bash lib/jira-card.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
eval "$(sed -n '/^jira_card() {/,/^}/p;/^jira_normalize_key() {/,/^}/p' "$(dirname "$0")/jira.sh")"
acli() { case "$4" in
  FXA-1) echo '{"key":"FXA-1","fields":{"summary":"Fix it","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"assignee":{"displayName":"Dev One"},"labels":["ai-fixme"],"security":null,"issuetype":{"name":"Bug"},"priority":{"name":"P2"}}}' ;;
  FXA-2) echo '{"key":"FXA-2","fields":{"summary":"x","labels":[],"security":{"name":"Embargoed"}}}' ;;
  FXA-3) echo '{"key":"FXA-3","fields":{"summary":"x","labels":["HackerOne"],"security":null}}' ;;
  FXA-4) echo '{"key":"FXA-4","fields":{"summary":"x","labels":["security"],"security":null}}' ;;
  SEC-5) echo '{"key":"SEC-5","fields":{"summary":"x","labels":[],"security":null}}' ;;
  *) return 1 ;; esac; }
check "a normal ticket" '{"key":"FXA-1","summary":"Fix it","status":"In Progress","category":"indeterminate","assignee":"Dev One","type":"Bug","priority":"P2"}' "$(jira_card fxa-1)"
for k in FXA-2 FXA-3 FXA-4 SEC-5 FXA-9; do check "$k is hidden" "null" "$(jira_card $k)"; done
check "a bad key fails" "1" "$(jira_card 'x; rm' >/dev/null 2>&1; echo $?)"
exit "$fail"
