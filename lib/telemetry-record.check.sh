#!/usr/bin/env bash
# Offline check that telemetry_record writes no row when no transcript exists.
#   bash lib/telemetry-record.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/telemetry.sh"
pipeline_require() { :; }
worktree_branch_for() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
_telemetry_worktree_for_key() { return 1; }         # no slot holds the branch
agent_ssh_exec() { return 1; }                       # the runner is gone
pipeline_launch_log() { printf '%s/%s.launch.log\n' "$tmp" "$1"; }
telemetry_costs() { :; }
PIPE_RUNS_FILE="$tmp/agent-runs.jsonl" PIPE_COSTS_FILE="$tmp/agent-costs.json" FXA_WORKTREE_BASE=main
echo "Run kind: fix" > "$(pipeline_launch_log FXA-1)"

telemetry_record FXA-1 >/dev/null 2>&1
check "no transcript returns 1" "1" "$?"
check "no transcript writes no row" "0" "$(cat "$PIPE_RUNS_FILE" 2>/dev/null | wc -l | tr -d ' ')"

# A slot transcript still records exactly one priced row.
mkdir -p "$tmp/slot"
echo '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0}}}' \
  > "$tmp/slot/.fxa-auto-session.jsonl"
_telemetry_worktree_for_key() { echo "$tmp/slot"; }
telemetry_record FXA-1 >/dev/null 2>&1
check "transcript writes one row" "1" "$(wc -l < "$PIPE_RUNS_FILE" | tr -d ' ')"
check "transcript row is priced" "5" "$(jq -r '.cost_usd' "$PIPE_RUNS_FILE")"

exit "$fail"
