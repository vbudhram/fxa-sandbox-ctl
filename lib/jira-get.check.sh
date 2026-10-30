#!/usr/bin/env bash
# jira_get: only a /rest/ path reaches the GET, and a failed GET names itself.
set -uo pipefail
eval "$(sed -n '/^jira_get() {/,/^}/p' "$(dirname "$0")/jira.sh")"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
_jira_rest_get() { [ "$1" = /rest/api/3/fail ] && return 22; echo "{\"p\":\"$1\"}"; }
[ "$(jira_get '/rest/api/3/mypermissions?projectKey=PAY&permissions=EDIT_ISSUES,TRANSITION_ISSUES')" = '{"p":"/rest/api/3/mypermissions?projectKey=PAY&permissions=EDIT_ISSUES,TRANSITION_ISSUES"}' ] && ok "a /rest/ path is fetched" || bad "a /rest/ path is fetched"
for p in '' 'rest/api/3/issue' '/browse/PAY-1' '/rest/api/3/issue PAY-1' '/rest/x@evil.com'; do
  jira_get "$p" >/dev/null 2>&1 && bad "rejects '$p'" || ok "rejects '$p'"
done
err="$(jira_get /rest/api/3/fail 2>&1 >/dev/null)"; [ $? -ne 0 ] && [[ "$err" == *'Jira GET /rest/api/3/fail failed'* ]] && ok "a failed GET says so" || bad "a failed GET says so"
exit $fail
