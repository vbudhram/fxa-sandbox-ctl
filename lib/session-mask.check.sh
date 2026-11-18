#!/usr/bin/env bash
# Offline check that a team's runtime secret values are masked in what goes to Slack: the poll's events (and the
# wrap-up reply, from the same parse), the live watch's text, and the last-step line.
#   bash lib/session-mask.check.sh
source "$(dirname "$0")/session-check-head.sh"
SECRET="s3cr3t-value-123"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }
export PIPE_RUNTIME_SECRETS="fxa-team-x=/home/agent/a/b"
res="$(jq -nc --arg t "key is $SECRET" '{type: "result", result: $t}')"
delta="$(jq -nc --arg t "it is $SECRET" '{type: "stream_event", parent_tool_use_id: null, event: {type: "content_block_delta", delta: {type: "text_delta", text: $t}}}')"
cmd="$(jq -nc --arg c "echo $SECRET" '{type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: $c}}]}}')"
out="$(printf '%s\n' "$res" | _session_parse)"
check "poll: the turn's reply has the value masked" "0|1" "$(grep -c "$SECRET" <<< "$out")|$(grep -c '<masked>' <<< "$out")"
_session_sh() { printf '%s\n' "$delta"; }; session_get() { :; }
out="$(_session_watch agent-m1)"
check "watch: the live text has the value masked" "0|1" "$(grep -c "$SECRET" <<< "$out")|$(grep -c '<masked>' <<< "$out")"
out="$(printf '%s\n' "$cmd" | _session_activity)"
check "the last step has the value masked" "0|1" "$(grep -c "$SECRET" <<< "$out")|$(grep -c '<masked>' <<< "$out")"
_session_secret_values() { echo false; }
check "a failed secret read gives no events" "" "$(printf '%s\n' "$res" | _session_parse)"
check "no runtime secrets: the reply passes as it is, with no secret read" "key is $SECRET" \
  "$(printf '%s\n' "$res" | PIPE_RUNTIME_SECRETS="" _session_parse | jq -r .text)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
