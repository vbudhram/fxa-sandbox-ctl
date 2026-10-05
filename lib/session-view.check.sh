#!/usr/bin/env bash
# Offline check for the watch page's events: tool calls, clipped results, diffs, todos, subagents, masking.
#   bash lib/session-view.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
eval "$(sed -n "/^_SESSION_VIEW_JQ='/,/^  else empty end'\$/p" "$(dirname "$0")/session.sh")"
v() { printf '%s\n' "$1" | jq -R -c "$_SESSION_VIEW_JQ"; }

check "text, with a key masked" '{"t":"text","text":"key sk-ant-api03-<masked> and fxl_<masked>","sub":false}' \
  "$(v '{"type":"assistant","message":{"content":[{"type":"text","text":"key sk-ant-api03-ABCDEFGHIJKL and fxl_abcdefghijklmnop"}]}}')"
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
