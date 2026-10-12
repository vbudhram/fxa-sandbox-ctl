#!/usr/bin/env bash
# Offline check that a refused Jira login stops the pass before it reads Jira: one clear error
# for the operator (the bot DMs a new one) and a "paused:" line, so no model turn and no jq crash.
#   bash lib/precheck-jira.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^jira_login_ok() {/,/^}/p' "$(dirname "$0")/jira.sh")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp" PIPE_NAME=test
pipeline_lock() { :; }; pipeline_unlock() { echo unlocked >> "$tmp/unlock"; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }; cmd_label() { :; }
jira_keys_in_state() { :; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }
jira_done_keys() { echo "read" >> "$tmp/reads"; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
errors_record() { echo "$1/$2 $5" >> "$tmp/errors"; }
acli() { [ "$*" = "jira auth status" ] && printf '%s\n' "$(cat "$tmp/auth")"; }

echo "✗ Error: unauthorized: use 'acli jira auth login' to authenticate" > "$tmp/auth"
out="$(cmd_precheck 2>&1)"
check "a refused login: the pass stops as paused, before any Jira read" "paused:|0" "$(printf '%s' "$out" | head -1 | cut -c1-7)|$(cat "$tmp/reads" 2>/dev/null | wc -l | tr -d ' ')"
check "it records one jira/login error that names the fix, and releases the lock" "jira/login|yes|1" \
  "$(cut -d' ' -f1 "$tmp/errors")|$(grep -q 'vm.sh secret fxa-jira-token' "$tmp/errors" && echo yes)|$(wc -l < "$tmp/unlock" | tr -d ' ')"
printf '✓ Authenticated\n  Site: example.atlassian.net\n' > "$tmp/auth"
out="$(cmd_precheck 2>&1)"
check "a good login: precheck reads Jira as before" "quiet:|1" "$(printf '%s' "$out" | head -1 | cut -c1-6)|$(cat "$tmp/reads" | wc -l | tr -d ' ')"
exit "$fail"
