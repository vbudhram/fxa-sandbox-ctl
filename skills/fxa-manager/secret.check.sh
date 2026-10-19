#!/usr/bin/env bash
# Offline check for vm.sh secret's cleaning of a pasted value.
#   bash skills/fxa-manager/secret.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
eval "$(sed -n '/^secret_clean() {/,/^}/p;/^secret_unit() {/,/^}/p' "$(dirname "$0")/vm.sh")"
check "a plain value is kept" "ATATT3xabc=" "$(printf 'ATATT3xabc=' | secret_clean)"
check "NAME= in front is dropped (the Jira paste)" "ATATT3xabc" "$(printf 'JIRA_TOKEN=ATATT3xabc' | secret_clean)"
check "spaces, quotes and a newline are dropped" "xoxb-1-2" "$(printf '  "xoxb-1-2"\n' | secret_clean)"
check "the right prefix passes" "xapp-9" "$(printf 'xapp-9' | secret_clean xapp-)"
check "the wrong prefix fails (a pasted command)" "1" "$(printf '! (umask 077; pbpaste > f)' | secret_clean xoxb- >/dev/null; echo $?)"
check "empty fails" "1" "$(printf '   ' | secret_clean >/dev/null; echo $?)"
check "the unit each secret restarts" "fxa-agent-bot|fxa-mcp-gateway|fxa-llm-proxy||" \
  "$(secret_unit fxa-slack-bot-token)|$(secret_unit fxa-sentry-token)|$(secret_unit fxa-anthropic-api-key)|$(secret_unit fxa-jira-token)|$(secret_unit fxa-dashboard-hmac)"
check "vm.sh secret runs fxa-secrets on the manager after it stores the value" "1" "$(grep -c "printf 'sudo /usr/local/sbin/fxa-secrets" "$(dirname "$0")/vm.sh")"
exit "$fail"
