#!/usr/bin/env bash
# Offline check for jira_admin_asked: a team admin's ticket or comment allows CI config; nobody else's does.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^jira_admin_asked() {/,/^}/p' "$here/jira.sh")"
export FXA_TEAMS_DIR="$tmp" PIPE_PROFILE=demo
echo '{"admins":[{"slack":"UA1","email":"admin1@example.com"}],"people":[{"slack":"UP1","email":"pat@example.com"},{"slack":"UA2","email":"admin2@example.com","admin":true}]}' > "$tmp/demo.json"
# Jira, stubbed: admin1 and admin2 have one account each; pat is not an admin.
_jira_rest() {
  case "$2" in
    /rest/api/3/user/search) case "$*" in *admin1@*) echo '[{"accountId":"acc-a1"}]' ;; *admin2@*) echo '[{"accountId":"acc-a2"}]' ;; *) echo '[]' ;; esac ;;
    */issue/X-1*) echo '{"fields":{"reporter":{"accountId":"acc-a1"},"comment":{"comments":[]}}}' ;;
    */issue/X-2*) echo '{"fields":{"reporter":{"accountId":"acc-p"},"comment":{"comments":[{"author":{"accountId":"acc-p"}},{"author":{"accountId":"acc-a2"}}]}}}' ;;
    */issue/X-3*) echo '{"fields":{"reporter":{"accountId":"acc-p","displayName":"Admin One"},"comment":{"comments":[{"author":{"accountId":"acc-p","displayName":"Admin One"}}]}}}' ;;
    *) return 22 ;;
  esac
}
yes_no() { jira_admin_asked "$1" && echo yes || echo no; }
check "an admin's ticket allows CI config" yes "$(yes_no X-1)"
check "an admin's comment on another person's ticket allows it" yes "$(yes_no X-2)"
check "a display name that copies an admin's does not" no "$(yes_no X-3)"
check "a ticket Jira does not return does not" no "$(yes_no X-9)"
check "a team with no record does not" no "$(PIPE_PROFILE=other yes_no X-1)"
exit "$fail"
