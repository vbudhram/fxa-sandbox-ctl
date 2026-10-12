#!/usr/bin/env bash
# Offline check that a done PR's red check wakes one pass, not every pass: the pass can only
# report it, so the same red again is quiet until its head or its failures change.
#   bash lib/precheck-red.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp" PIPE_NAME=test
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_reap() { :; }; cmd_label() { :; }
jira_done_keys() { echo FXA-7; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }; jira_keys_in_state() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
jira_login_ok() { :; }
gh_feedback() { echo '{}'; }
# The red is not known infra; gh_red_infra caches the head sha it read, as the real one does.
gh_red_infra() { printf '%s\n\n' "$(cat "$tmp/sha")" > "$tmp/FXA-7.redinfra"; return 1; }
cmd_drain() { echo "FXA-7 70 RED ok=9 fail=$(cat "$tmp/fails") running=$(cat "$tmp/running")"; }
echo aaa > "$tmp/sha"; echo 1 > "$tmp/fails"; echo 0 > "$tmp/running"
q() { cmd_precheck 2>&1 | head -1 | cut -c1-6; }
check "the first time a done PR is red: the pass wakes" "drain:" "$(q)"
check "the same red on the next pass: quiet" "quiet:" "$(q)"
echo 2 > "$tmp/running"
check "only the running count moved: still quiet" "quiet:" "$(q)"
echo 2 > "$tmp/fails"
check "another check fails on the same head: the pass wakes" "drain:" "$(q)"
echo bbb > "$tmp/sha"
check "a new push that is red again: the pass wakes" "drain:" "$(q)"
cmd_drain() { :; }; q >/dev/null
cmd_drain() { echo "FXA-7 70 RED ok=9 fail=$(cat "$tmp/fails") running=0"; }
check "red, then green, then the same red again: the pass wakes" "drain:" "$(q)"
exit "$fail"
