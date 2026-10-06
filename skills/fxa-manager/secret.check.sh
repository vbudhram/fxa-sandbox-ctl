#!/usr/bin/env bash
# Offline check for vm.sh secret's cleaning of a pasted value.
#   bash skills/fxa-manager/secret.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
eval "$(sed -n '/^secret_clean() {/,/^}/p' "$(dirname "$0")/vm.sh")"
check "a plain value is kept" "ATATT3xabc=" "$(printf 'ATATT3xabc=' | secret_clean)"
check "NAME= in front is dropped (the Jira paste)" "ATATT3xabc" "$(printf 'JIRA_TOKEN=ATATT3xabc' | secret_clean)"
check "spaces, quotes and a newline are dropped" "xoxb-1-2" "$(printf '  "xoxb-1-2"\n' | secret_clean)"
check "the right prefix passes" "xapp-9" "$(printf 'xapp-9' | secret_clean xapp-)"
check "the wrong prefix fails (a pasted command)" "1" "$(printf '! (umask 077; pbpaste > f)' | secret_clean xoxb- >/dev/null; echo $?)"
check "empty fails" "1" "$(printf '   ' | secret_clean >/dev/null; echo $?)"
exit "$fail"
