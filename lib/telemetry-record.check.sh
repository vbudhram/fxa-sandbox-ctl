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

# A relaunch reads the same transcript under a new launch time: no second row.
echo "Launched at: 1790000999" > "$(pipeline_launch_log FXA-1)"
telemetry_record FXA-1 >/dev/null 2>&1
check "the same run relaunched writes no second row" "1" "$(wc -l < "$PIPE_RUNS_FILE" | tr -d ' ')"

# 1-hour cache writes cost 2x input, model by model: 1M 1-hour tokens on opus-5-5 (input $4) are $8.
mkdir -p "$tmp/slot2"
echo '{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000}}}}' > "$tmp/slot2/.fxa-auto-session.jsonl"
_telemetry_worktree_for_key() { echo "$tmp/slot2"; }; echo "Run kind: fix" > "$(pipeline_launch_log FXA-2)"
telemetry_record FXA-2 >/dev/null 2>&1
check "a session transcript's 1-hour cache writes are priced at 2x input" "8" "$(jq -r 'select(.issue == "FXA-2") | .cost_usd' "$PIPE_RUNS_FILE")"
# A 1-hour count above the write count (a bad transcript) is clamped to it, as the proxy does: 1M writes, 2M "1-hour", still $8.
mkdir -p "$tmp/slot3"
echo '{"type":"assistant","message":{"id":"m3","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":2000000}}}}' > "$tmp/slot3/.fxa-auto-session.jsonl"
_telemetry_worktree_for_key() { echo "$tmp/slot3"; }; echo "Run kind: fix" > "$(pipeline_launch_log FXA-3)"
telemetry_record FXA-3 >/dev/null 2>&1
check "a 1-hour count above the write count is clamped to it" "8" "$(jq -r 'select(.issue == "FXA-3") | .cost_usd' "$PIPE_RUNS_FILE")"
# The single-rate path (a stream with no result event, so no per-model map) clamps the same way: still $8.
mkdir -p "$tmp/slot4"
echo '{"type":"assistant","message":{"id":"m4","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":2000000}}}}' > "$tmp/slot4/.fxa-auto-claude.jsonl"
_telemetry_worktree_for_key() { echo "$tmp/slot4"; }; echo "Run kind: fix" > "$(pipeline_launch_log FXA-4)"
telemetry_record FXA-4 >/dev/null 2>&1
check "the single-rate path clamps the 1-hour count too" "8" "$(jq -r 'select(.issue == "FXA-4") | .cost_usd' "$PIPE_RUNS_FILE")"
# The stream's result event: the 1-hour count comes from the assistant messages, per model.
printf '%s\n' '{"type":"assistant","message":{"id":"x1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":700}}}}' \
  '{"type":"assistant","message":{"id":"x1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":700}}}}' \
  '{"type":"result","num_turns":1,"modelUsage":{"claude-opus-5-5":{"inputTokens":0,"outputTokens":1,"cacheCreationInputTokens":900,"cacheReadInputTokens":0,"costUSD":1}}}' > "$tmp/stream.jsonl"
check "a result event keeps each model's 1-hour cache writes, once per message" "700|700|result" "$(jq -s "$_TELEMETRY_LOCAL" "$tmp/stream.jsonl" | jq -r '"\(.models["claude-opus-5-5"].cache_write_1h)|\(.cache_write_1h)|\(.source)"')"
check "prices: sonnet-5-5 cache reads are half of sonnet-5, haiku-5-5 has a row" "0.10|0.20|0.10 0.50 0.125 0.01" \
  "$(_telemetry_price_for claude-sonnet-5-5 | awk '{print $4}')|$(_telemetry_price_for claude-sonnet-5 | awk '{print $4}')|$(_telemetry_price_for claude-haiku-5-5 | tr -s ' ')"
exit "$fail"
