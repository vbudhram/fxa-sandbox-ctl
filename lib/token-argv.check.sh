#!/usr/bin/env bash
# Offline check that the Jira login, the Sentry, CircleCI and App JWT tokens reach curl on stdin, never on its command line.
#   bash lib/token-argv.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/sentry.sh"
eval "$(sed -n '/^jira_sprint_add() {/,/^}/p' "$here/jira.sh")"
curl() { printf '%s\n' "$*" >> "$tmp/args"; case "$*" in *"-K -"*) cat >> "$tmp/stdin" ;; esac
  case "$*" in *shortids/*) echo '{"groupId":"42"}' ;; *issues/42/*) echo '{"id":"42","title":"t","count":"1","project":{"slug":"p"},"stats":{"24h":[]}}' ;; *sprint/*) printf 204 ;; esac; }
echo 'SENTRY_ACCESS_TOKEN=tok-sen-9z' > "$tmp/env"; : > "$tmp/args"; : > "$tmp/stdin"
FXA_SENTRY_TOKEN_FILE="$tmp/env" sentry_card FXA-AUTH-1 >/dev/null 2>&1
check "sentry_card: the token is on stdin as a header line, not on curl's command line" "0|2|2" \
  "$(grep -c tok-sen-9z "$tmp/args")|$(grep -cx 'header = "Authorization: Bearer tok-sen-9z"' "$tmp/stdin")|$(grep -c -- '-K -' "$tmp/args")"
: > "$tmp/args"; : > "$tmp/stdin"
pipeline_require() { :; }
PIPE_JIRA_BASIC='bot@example.com:jtok-9z' PIPE_JIRA_SITE=https://jira.example jira_sprint_add FXA-1 7 >/dev/null 2>&1
check "jira_sprint_add: the login is on stdin as a user line, not on curl's command line" "0|1|1" \
  "$(grep -c jtok-9z "$tmp/args")|$(grep -cx 'user = "bot@example.com:jtok-9z"' "$tmp/stdin")|$(grep -c -- '-K -' "$tmp/args")"
eval "$(sed -n '/^_circleci_get() {/p' "$here/circleci.sh")"
: > "$tmp/args"; : > "$tmp/stdin"; _circleci_get cci-tok-9z https://circleci.example/x >/dev/null 2>&1
check "_circleci_get: the CircleCI token is on stdin as a header line, not on curl's command line" "0|1|1" \
  "$(grep -c cci-tok-9z "$tmp/args")|$(grep -cx 'header = "Circle-Token: cci-tok-9z"' "$tmp/stdin")|$(grep -c -- '-K -' "$tmp/args")"
( eval "$(sed -n '/^_gh_jwt_conf() {/p;/^github_app_token() {/,/^}/p;/^github_read_token() {/,/^}/p;/^_gh_app_installation() {/,/^}/p;/^_gh_claimed() {/,/^}/p' "$here/github.sh")"
  export TMPDIR="$tmp/gh"; mkdir -p "$TMPDIR"; GITHUB_APP_INSTALLATION_ID=111 PIPE_REPO_SLUG=mozilla/fxa
  github_app_jwt() { echo eyJ-jwt-9z; }; _mtime() { echo 0; }
  curl() { printf '%s\n' "$*" >> "$tmp/args"; case "$*" in *"-K -"*) cat >> "$tmp/stdin" ;; esac
    case "$*" in */installation*) echo '{"id":222}' ;; */access_tokens*) echo '{"token":"t"}' ;; esac; }
  : > "$tmp/args"; : > "$tmp/stdin"
  _gh_app_installation mozilla/fxa >/dev/null; github_app_token fxa >/dev/null 2>&1; github_read_token mozilla/fxa >/dev/null
  k=$(grep -c -- '-K -' "$tmp/args"); h=$(grep -cx 'header = "Authorization: Bearer eyJ-jwt-9z"' "$tmp/stdin")
  check "the App JWT: on stdin as a header line for every lookup and mint, never on curl's command line" "0|yes|$(wc -l < "$tmp/args" | tr -d ' ')" \
    "$(grep -c eyJ-jwt-9z "$tmp/args")|$([ "$k" -ge 3 ] && [ "$k" = "$h" ] && echo yes)|$k" ) || fail=1
check "no curl in lib/ puts the App JWT in a -H argument" 0 "$(grep -c 'Bearer \$(github_app_jwt' "$here"/*.sh | awk -F: '{n+=$2} END{print n+0}')"
exit "$fail"
