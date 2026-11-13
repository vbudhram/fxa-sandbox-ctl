#!/usr/bin/env bash
# Offline check for session interrupt --tool: Codex is refused, and on Linux the runner script stops
# only the foreground Bash call's group, never a run_in_background job, an MCP server or Claude.
#   bash lib/session-stop-tool.check.sh
source "$(dirname "$0")/session-check-head.sh"
echo '{"key":"agent-st01","state":"active","runtime":"codex","turn_open":"1"}' > "$SESSION_DIR/agent-st01.json"
_session_sh() { echo called >> "$tmp/sh"; printf '%s\n' "$2" > "$tmp/script"; echo "${STUB_OUT:-none}"; }
check "a Codex session is refused before the runner is reached" "2|no" \
  "$(session_interrupt_tool agent-st01 2>/dev/null; echo "$?|$([ -e "$tmp/sh" ] && echo yes || echo no)")"
session_set agent-st01 runtime claude turn_open 0
check "an idle session has nothing to stop" "agent-st01 idle|no" "$(session_interrupt_tool agent-st01)|$([ -e "$tmp/sh" ] && echo yes || echo no)"
session_set agent-st01 turn_open 1
check "no foreground command: nothing is logged" "agent-st01 no command|0" \
  "$(session_interrupt_tool agent-st01)|$(cat "$SESSION_DIR/agent-st01.history.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
check "a stopped command: the turn stays open, and the history says so" "agent-st01 command stopped|1|Stopped the running command; the turn goes on" \
  "$(STUB_OUT='stopped 42' session_interrupt_tool agent-st01)|$(session_get agent-st01 turn_open)|$(jq -r .text "$SESSION_DIR/agent-st01.history.jsonl")"
check "the runner script gets the agent pattern" "1" "$(grep -c "^pat=" "$tmp/script")"

if [ -d /proc/self/fd ] && command -v pgrep >/dev/null; then
  # A stand-in claude with a unique name, so a real claude on this host is never matched.
  pat="^claude -p fxa-stop-check-$$"; h="$tmp/home"; snap="$tmp/shell-snapshots/snapshot-bash-1.sh"
  mkdir -p "$h/.claude/projects/p" "$tmp/tasks" "${snap%/*}"; : > "$snap"
  echo '{"content":"Command running in background with ID: bgjob1. Output is being written to: /tmp/x/tasks/bgjob1.output"}' > "$h/.claude/projects/p/s.jsonl"
  # set -m: each Bash call is its own group, as Claude spawns it; the MCP stand-in stays in Claude's group.
  ( exec -a "claude -p fxa-stop-check-$$" bash -c 'set -m
    bash -c "source $1; sleep 300; true" > "$2/tasks/fgjob1.output" 2>&1 & echo $! > "$2/fg"
    bash -c "source $1; sleep 300; true" > "$2/tasks/bgjob1.output" 2>&1 & echo $! > "$2/bg"
    set +m; sleep 300 & echo $! > "$2/mcp"
    wait' _ "$snap" "$tmp" ) &
  fake=$!; disown "$fake"
  for i in $(seq 50); do [ -s "$tmp/mcp" ] && break; sleep 0.1; done
  out="$(bash -c "pat=$(printf '%q' "$pat"); ${_SESSION_TOOL_STOP//\/home\/agent/$h}")"
  alive() { kill -0 "$(cat "$tmp/$1")" 2>/dev/null && echo up || echo gone; }
  check "only the foreground Bash call is stopped" "stopped $(cat "$tmp/fg")|gone|up|up|up" \
    "$out|$(alive fg)|$(alive bg)|$(alive mcp)|$(kill -0 "$fake" 2>/dev/null && echo up || echo gone)"
  kill -KILL -- "-$(cat "$tmp/bg")" "$(cat "$tmp/mcp")" "$fake" 2>/dev/null
  check "with no foreground call, nothing is signalled" "none" "$(bash -c "pat=$(printf '%q' "$pat"); ${_SESSION_TOOL_STOP//\/home\/agent/$h}")"
else
  echo "skip the process check: it needs Linux /proc"
fi
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
