#!/usr/bin/env bash
# Offline check that the Jira login and the Sentry token reach curl on stdin, never on its command line.
#   bash lib/token-argv.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/sentry.sh"
eval "$(sed -n '/^jira_sprint_add() {/,/^}/p' "$here/jira.sh")"
curl() { printf '%s\n' "$*" >> "$tmp/args"; cat >> "$tmp/stdin" 2>/dev/null || true
  case "$*" in *shortids/*) echo '{"groupId":"42"}' ;; *issues/42/*) echo '{"id":"42","title":"t","count":"1","project":{"slug":"p"},"stats":{"24h":[]}}' ;; *sprint/*) printf 204 ;; esac; }
echo 'SENTRY_ACCESS_TOKEN=tok-sen-9z' > "$tmp/env"; : > "$tmp/args"; : > "$tmp/stdin"
FXA_SENTRY_TOKEN_FILE="$tmp/env" sentry_card FXA-AUTH-1 >/dev/null 2>&1
check "sentry_card: the token is on stdin, not on curl's command line" "0|2" "$(grep -c tok-sen-9z "$tmp/args")|$(grep -c tok-sen-9z "$tmp/stdin")"
: > "$tmp/args"; : > "$tmp/stdin"
pipeline_require() { :; }
PIPE_JIRA_BASIC='bot@example.com:jtok-9z' PIPE_JIRA_SITE=https://jira.example jira_sprint_add FXA-1 7 >/dev/null 2>&1
check "jira_sprint_add: the login is on stdin, not on curl's command line" "0|1" "$(grep -c jtok-9z "$tmp/args")|$(grep -c jtok-9z "$tmp/stdin")"
exit "$fail"
