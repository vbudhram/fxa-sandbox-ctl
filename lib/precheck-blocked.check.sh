#!/usr/bin/env bash
# Offline check that precheck moves a blocked ticket whose PR a person merged or closed.
#   bash lib/precheck-blocked.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp"
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }
jira_done_keys() { :; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
jira_keys_in_state() { [ "$1" = blocked ] && printf 'FXA-1\nFXA-2\nFXA-3\n'; }
gh_pr_state() { case "$1" in FXA-1) echo "FXA-1 11 MERGED ok=1";; FXA-2) echo "FXA-2 12 CLOSED ok=1";; *) echo "FXA-3 13 OPEN ok=1";; esac; }
cmd_label() { echo "$1 $2" >> "$tmp/labels"; }
out="$(cmd_precheck 2>&1)"
check "a merged PR moves the ticket to merged, a closed one to rejected, an open one stays" "FXA-1 merged|FXA-2 rejected" "$(paste -sd'|' "$tmp/labels")"
check "the quiet line counts them" "yes" "$(grep -q '1 merged, 1 rejected' <<<"$out" && echo yes)"
exit "$fail"
