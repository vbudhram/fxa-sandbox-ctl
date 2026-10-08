#!/usr/bin/env bash
# Offline check of sentry_card: a bad reference, no token, and an email in a title.
#   bash lib/sentry.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/sentry.sh"
check "a bad reference is refused" "1" "$(sentry_card 'x; rm -rf /' >/dev/null 2>&1; echo $?)"
check "no token: null" "null" "$(FXA_SENTRY_TOKEN_FILE="$tmp/none" sentry_card FXA-AUTH-1)"
echo 'SENTRY_ACCESS_TOKEN=t' > "$tmp/env"
curl() { case "$*" in *shortids/FXA-AUTH-1/*) echo '{"groupId":"42"}' ;;
  *issues/42/*) echo '{"id":"42","shortId":"FXA-AUTH-1","title":"account jane@gmail.com not found","culprit":"POST /x","status":"unresolved","level":"error","project":{"slug":"fxa-auth"},"count":"7","userCount":2,"stats":{"24h":[[1,0],[2,3]]},"lastRelease":{"version":"1.0"}}' ;; esac; }
got="$(FXA_SENTRY_TOKEN_FILE="$tmp/env" sentry_card FXA-AUTH-1)"
check "a short id resolves to the issue, emails become [email], counts are numbers" \
  "42|account [email] not found|7|fxa-auth|0,3|1.0" "$(jq -r '"\(.id)|\(.title)|\(.count)|\(.project)|\(.hourly|join(","))|\(.release)"' <<< "$got")"
exit "$fail"
