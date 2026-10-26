#!/usr/bin/env bash
# Offline check that precheck wakes a model for a queued ticket only when a slot is free to launch it.
#   bash lib/precheck-queue.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp" PIPE_NAME=fxa-ai-fixme
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }
jira_done_keys() { :; }; jira_inflight_keys() { :; }; jira_keys_in_state() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }; jira_login_ok() { :; }
jira_queue_keys() { echo FXA-9; }
# skip-changed runs as a child of the controller: here each key is new, as with no .skipped record.
xargs() { while IFS= read -r k; do echo "$k new"; done; }
cmd_freeslots() { echo x >> "$tmp/reads"; case "${SLOTS:-}" in fail) return 1 ;; none) ;; *) echo fxa-auto-1 ;; esac; }
row() { tail -1 "$tmp/passes.jsonl" 2>/dev/null | jq -r .work; }
out="$(SLOTS=one cmd_precheck 2>&1)"
check "a free slot: the queued ticket wakes the pass" "1" "$(grep -c '^queue: FXA-9 new (run: ground FXA-9)' <<< "$out")"
out="$(SLOTS=none cmd_precheck 2>&1)"
check "no free slot: no work line, so the pass stays quiet and no model wakes" "0|1" "$(grep -c '(run: ground' <<< "$out")|$(grep -c '^quiet:' <<< "$out")"
out="$(SLOTS=fail cmd_precheck 2>&1)"
check "a failed slot read still wakes the pass" "1" "$(grep -c '^queue: FXA-9 new (run: ground FXA-9)' <<< "$out")"
: > "$tmp/reads"; jira_queue_keys() { :; }; cmd_precheck >/dev/null 2>&1
check "an empty queue reads no slots" "0" "$(grep -c . "$tmp/reads")"
exit "$fail"
