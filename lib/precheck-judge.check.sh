#!/usr/bin/env bash
# Offline check that an in-flight ticket's judgment line (a red PR, a stall) wakes one pass, then
# one an hour while it stays, not every pass; and that each pass records what woke it.
#   bash lib/precheck-judge.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp" PIPE_NAME=test
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_drain() { :; }; cmd_reap() { :; }; cmd_label() { :; }
jira_done_keys() { :; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }; jira_keys_in_state() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }; jira_login_ok() { :; }
gh_feedback() { echo '{}'; }
cmd_reconcile() { [ -s "$tmp/line" ] && cat "$tmp/line"; }
q() { cmd_precheck 2>&1 | head -1 | cut -c1-10; }
echo "FXA-9 pr #90 RED ok=3 fail=1 running=5" > "$tmp/line"
check "an in-flight PR goes red: the pass wakes" "reconcile:" "$(q)"
echo "FXA-9 pr #90 RED ok=6 fail=1 running=2" > "$tmp/line"
check "the same red, only ok and running moved: quiet" "quiet: 0 q" "$(q)"
check "the pass records what woke it, and that the quiet one woke nothing" '{"reconcile":1}|{}' \
  "$(jq -c .woke "$tmp/passes.jsonl" | sed -n 1p)|$(jq -c .woke "$tmp/passes.jsonl" | sed -n 2p)"
echo "FXA-9 pr #90 RED ok=6 fail=2 running=0" > "$tmp/line"
check "another check fails: the pass wakes" "reconcile:" "$(q)"
check "an hour on, the same line wakes one more pass (a retry)" "reconcile:" "$(FXA_PASS_REJUDGE_S=0 q)"
: > "$tmp/line"; q >/dev/null
echo "FXA-9 pr #90 RED ok=6 fail=2 running=0" > "$tmp/line"
check "red, gone, then the same red again: the pass wakes" "reconcile:" "$(q)"
echo "FXA-9 pr #90 ok=12 fail=0 running=3" > "$tmp/line"
check "a line that needs no judgment never wakes it" "quiet: 0 q" "$(q)"
exit "$fail"
