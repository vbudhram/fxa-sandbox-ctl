#!/usr/bin/env bash
# Offline check that session create-jira makes one FXA task from a session PR with no ticket.
#   bash lib/create-jira.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^session_create_jira() {/,/^}/p;/^_session_pr_parts() {/,/^}/p' "$(dirname "$0")/session.sh")"
session_get() { case "$2" in pr_url) echo https://github.com/mozilla/fxa/pull/9 ;; slack_url) echo https://example.slack.com/archives/C1/p1 ;; esac; }
session_set() { echo "$1 $2 $3" > "$tmp/set"; }
_session_history_add() { :; }
BODY='Short summary of the change.
More of the first paragraph.

## Testing
- ok'
gh() {
  case "$*" in
    "pr view"*) jq -n --arg b "$BODY" --arg t "${TITLE:-fix(settings): keep the email}" '{title: $t, body: $b, headRefName: "agent-abc123"}' ;;
    *"-X PATCH"*) cat > "$tmp/patched" ;;
  esac
}
acli() { cat "$(sed -n 's/.*--description-file \([^ ]*\).*/\1/p' <<< "$*")" > "$tmp/desc"; echo "$*" > "$tmp/acli"; echo '{"key":"FXA-777"}'; }
check "it prints the new key and records it" "FXA-777|agent-x1 jira FXA-777" "$(session_create_jira agent-x1)|$(cat "$tmp/set")"
check "the task: FXA, Task, label, title without the type prefix" "yes" \
  "$(grep -q -- '--project FXA --type Task --summary keep the email' "$tmp/acli" && grep -q -- '--label agent-session' "$tmp/acli" && echo yes)"
check "the description: the first paragraph and both links" "Short summary of the change.|More of the first paragraph.|Pull request: https://github.com/mozilla/fxa/pull/9|Slack thread: https://example.slack.com/archives/C1/p1|Created by fxa-agent from an agent session." \
  "$(grep -v '^$' "$tmp/desc" | paste -sd'|' -)"
check "the PR body names the ticket" "yes" "$(tail -1 "$tmp/patched" | grep -q '^Jira: https://mozilla-hub.atlassian.net/browse/FXA-777$' && grep -q '## Testing' "$tmp/patched" && echo yes)"
rm -f "$tmp/acli"; TITLE='fix(settings): FXA-12 keep the email'
check "a PR that names a ticket creates nothing" "FXA-12|no" "$(session_create_jira agent-x1)|$([ -e "$tmp/acli" ] && echo yes || echo no)"
exit "$fail"
