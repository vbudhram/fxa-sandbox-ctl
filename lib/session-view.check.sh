#!/usr/bin/env bash
# Offline check for the watch page's events: tool calls, clipped results, diffs, todos, subagents, masking.
#   bash lib/session-view.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
eval "$(sed -n "/^_SESSION_MASK_JQ='/,/^  else empty end'\$/p" "$(dirname "$0")/session.sh")"
v() { printf '%s\n' "$1" | jq -R -c --slurpfile vals <(printf '"%s"\n' "${VALS[@]}") "$_SESSION_VIEW_JQ"; }
VALS=(hunter2-not-prefixed)

check "text, with a key masked" '{"t":"text","text":"key sk-ant-api03-<masked> and fxl_<masked>","sub":false}' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"text","text":"key sk-ant-api03-ABCDEFGHIJKL and fxl_abcdefghijklmnop"}]}}')"
check "a team secret with no known prefix, in a tool result" '"login with <masked> now"' \
  "$(v '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"login with hunter2-not-prefixed now"}]}}' | jq -c .out)"
check "a JWT in a command" '"curl -H x:<masked>"' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"curl -H x:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.sig"}}]}}' | jq -c .arg)"
eval "$(sed -n '/^_session_secret_values() {/,/^}/p' "$(dirname "$0")/session.sh")"
gcloud() { printf 'short\n-----BEGIN KEY-----\nAAAABBBBCCCCDDDD\n'; }
check "secret values: the whole value and each long line, never a short one" \
  '"short\n-----BEGIN KEY-----\nAAAABBBBCCCCDDDD"|"-----BEGIN KEY-----"|"AAAABBBBCCCCDDDD"' \
  "$(PIPE_RUNTIME_SECRETS='fxa-team-x=/home/agent/a/b' _session_secret_values | paste -sd'|' -)"
check "secret values: none without runtime secrets" "" "$(PIPE_RUNTIME_SECRETS='' _session_secret_values)"
gcloud() { return 1; }
check "secret values: a failed read gives false" "false" "$(PIPE_RUNTIME_SECRETS='fxa-team-x=/home/agent/a/b' _session_secret_values)"
check "the mask shows nothing when a secret read failed" "|5" \
  "$(printf 'pw hunter2-not-prefixed\n' | jq -R -r --slurpfile vals <(echo false) "${_SESSION_MASK_JQ} mask" 2>/dev/null)|$(echo x | jq -R --slurpfile vals <(echo false) "${_SESSION_MASK_JQ} mask" >/dev/null 2>&1; echo $?)"
check "an OpenAI-style key, and sk-ant- masked once" '"a sk-proj-<masked> b sk-<masked> c sk-ant-api03-<masked>"' \
  "$(v '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a sk-proj-AAAAbbbbCCCCddddEEEEffff b sk-AAAAbbbbCCCCddddEEEEffff c sk-ant-api03-ABCDEFGHIJKL"}]}}' | jq -c .out)"
check "a word that holds sk- is not a key" '"risk-assessment-for-the-new-thing"' \
  "$(v '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"risk-assessment-for-the-new-thing"}]}}' | jq -c .out)"
check "a tool call, its path relative" '{"t":"tool","id":"t1","name":"Read","sub":false,"arg":"src/a.ts"}' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/workspace/src/a.ts"}}]}}')"
check "a result: 8 lines and a count" '{"out":"1\n2\n3\n4\n5\n6\n7\n8","more":2,"t":"done","id":"t1","ok":true,"sub":false}' \
  "$(v '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"}]}}')"
check "a failed result" '{"out":"no match","more":0,"t":"done","id":"t2","ok":false,"sub":false}' \
  "$(v '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"no match"}]}]}}')"
check "an edit as a diff" '["- a","- b","+ c"]' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/workspace/a.ts","old_string":"a\nb","new_string":"c"}}]}}' | jq -c .diff)"
check "a subagent's call" "true" \
  "$(v '{"type":"assistant","parent_tool_use_id":"t9","message":{"content":[{"type":"tool_use","id":"t4","name":"Grep","input":{"pattern":"x"}}]}}' | jq .sub)"
check "todos" '[{"content":"measure","status":"in_progress"}]' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"TodoWrite","input":{"todos":[{"content":"measure","status":"in_progress","activeForm":"x"}]}}]}}' | jq -c .items)"
check "the reply as it is written" '{"t":"delta","text":"Hel"}' \
  "$(v '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}')"
check "a subagent's deltas stay out" "" \
  "$(v '{"type":"stream_event","parent_tool_use_id":"t9","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}')"
check "the turn's end" '{"t":"turn_end","secs":65,"cost":0.42,"error":false}' "$(v '{"type":"result","duration_ms":65000,"total_cost_usd":0.42}')"
check "a line that is not JSON" "" "$(v 'not json')"

exit "$fail"
