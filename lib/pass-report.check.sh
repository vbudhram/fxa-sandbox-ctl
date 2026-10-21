#!/usr/bin/env bash
# Offline check of the pass report's fixed part: the counts, the PRs that wait on review, the runs in flight.
#   bash lib/pass-report.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
eval "$(sed -n '/^cmd_pass_report() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_NAME=fxa-ai-fixme
jira_queue_keys() { printf 'FXA-1\nFXA-2\nFXA-3\n'; }; jira_done_keys() { echo "FXA-4 FXA-5"; }; jira_inflight_keys() { echo FXA-6; }
gh_pr_state() { case "$1" in FXA-4) echo "FXA-4 41 OPEN ok=9";; *) return 1;; esac; }
pipeline_progress() { printf 'watching 120s\nmore\n'; }
out="$(set -e; cmd_pass_report)"
check "the header counts the queue and the runs in flight" "### fxa-ai-fixme: 3 queued, 1 in flight" "$(head -1 <<< "$out" | sed 's/   (.*//')"
check "each done key with its PR, and a failed PR read leaves the number empty" "  FXA-4  #41|  FXA-5  #" "$(sed -n '3p;4p' <<< "$out" | tr '\n' '|' | sed 's/|$//')"
check "each run in flight with the first line of its progress" "⏳ In flight:|  FXA-6  watching 120s" "$(sed -n '5,$p' <<< "$out" | tr '\n' '|' | sed 's/|$//')"
jira_done_keys() { :; }; jira_inflight_keys() { :; }
check "no done and no inflight keys: only the header" "1" "$(cmd_pass_report | wc -l | tr -d ' ')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
