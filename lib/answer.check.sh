#!/usr/bin/env bash
# Offline check for quick answers: the script the runner runs, the upgrade line, slots, and failures.
#   bash lib/answer.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
export PIPE_STATE_DIR="$tmp/ps" FXA_LLM_PROXY_URL="http://10.0.0.2:8788"; mkdir -p "$PIPE_STATE_DIR"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
FXA_SESSION_DIR="$tmp/sess" source "$here/session.sh"   # _SESSION_FIN_JQ: questions parse as a turn does
source "$here/answer.sh"
export LOG_DIR="$tmp/logs"; mkdir -p "$LOG_DIR"; echo us-central1-b > "$LOG_DIR/fxa-answer.zone"
_claude_auth_line() { printf 'export ANTHROPIC_BASE_URL=%s\nexport ANTHROPIC_API_KEY=fxl_test%s\n' "$FXA_LLM_PROXY_URL" "$1"; }
llm_token_revoke() { echo "llm $1" >> "$tmp/revoked"; }
mcp_token_revoke() { echo "mcp $1" >> "$tmp/revoked"; }
errors_record() { echo "$2" >> "$tmp/errors"; }
gh() { echo '{"number":7,"title":"Fix it"}'; }

# The runner side, run here: /workspace is a scratch dir, and claude echoes what it got.
mkdir -p "$tmp/ws/.git" "$tmp/bin"
cat > "$tmp/bin/claude" <<'EOF'
#!/bin/bash
p="$(cat)"; args="$*"
case "$p" in *UPGRADE-ME*) r=$'It needs the stack.\n@@upgrade {"reason": "needs the stack", "findings": "see auth.ts:12"}' ;; *) r="answer to: ${p%%$'\n'*}" ;; esac
echo '{"type":"system","subtype":"init"}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Grep","input":{"pattern":"changePassword"}},{"type":"tool_use","name":"Read","input":{"file_path":"/workspace/packages/a/password.ts"}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"\"type\":\"result\" inside a file is not the result"}]}}'
jq -nc --arg r "$r" --arg a "$args" '{type: "result", result: $r, total_cost_usd: 0.21, num_turns: 3, is_error: false, args: $a}'
EOF
chmod +x "$tmp/bin/claude"
for c in git flock timeout; do printf '#!/bin/bash\n%s\n' "$( [ $c = timeout ] && echo 'shift; exec "$@"' || echo 'exit 0')" > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
FIREWALL=1
_gce_ssh() { [ "$FIREWALL" = 1 ] || exit 9; sed "s#/workspace#$tmp/ws#g; s#/home/agent#$tmp#g" | PATH="$tmp/bin:$PATH" bash -s; }

printf "%s\n" "Where is the 'password' check? \$(touch $tmp/pwned) EOF" > "$tmp/q1"
script="$(_answer_script ask-t001 "$tmp/q1" "")"
check "script: the question travels only as base64" "0" "$(grep -c 'password' <<< "$script")"
check "script: the proxy token, never the API key" "1|0" "$(grep -c 'ANTHROPIC_BASE_URL=http://10.0.0.2:8788' <<< "$script")|$(grep -c 'sk-ant' <<< "$script")"
check "script: no edit tools" "1" "$(grep -c -- '--disallowedTools Edit Write' <<< "$script")"
check "script: git only through the wrapper; plain git denied, which wins over auto-approval" "0|1|1" "$(grep -c "'Bash(git [a-z]" <<< "$script")|$(grep -c "'Bash(fxa-git-ro:\*)'" <<< "$script")|$(grep -c "'Bash(git:\*)'" <<< "$script")"
check "script: no reads of /proc, tokens or other answers" "1|1|1" "$(grep -c "'Read(//proc/\*\*)'" <<< "$script")|$(grep -c "'Read(//home/agent/.fxa-mcp-\*)'" <<< "$script")|$(grep -c "'Read(//home/agent/.claude/projects/\*\*)'" <<< "$script")"

out="$(answer_ask ask-t001 "$tmp/q1")"
check "ask: the answer comes back" "answer to: Where is the 'password' check? \$(touch $tmp/pwned) EOF" "$(jq -r .answer <<< "$out")"
check "ask: a hostile question runs nothing" "no" "$([ -e "$tmp/pwned" ] && echo yes || echo no)"
check "ask: cost and turns, no upgrade" "0.21|3|null" "$(jq -r '"\(.cost_usd)|\(.turns)|\(.upgrade)"' <<< "$out")"
check "ask: tokens revoked and slot freed" "llm ask-t001,mcp ask-t001|0" "$(paste -sd, "$tmp/revoked")|$(ls "$PIPE_STATE_DIR/answer-slots" | wc -l | tr -d ' ')"
check "ask: one line in the answers log" "1" "$(wc -l < "$PIPE_STATE_DIR/answers.jsonl" | tr -d ' ')"

echo "UPGRADE-ME please fix https://github.com/mozilla/fxa/pull/7" > "$tmp/q2"
out="$(answer_ask ask-t002 "$tmp/q2")"
check "upgrade: the line is split off the answer" "It needs the stack." "$(jq -r .answer <<< "$out")"
check "upgrade: reason and findings" "needs the stack|see auth.ts:12" "$(jq -r '"\(.upgrade.reason)|\(.upgrade.findings)"' <<< "$out")"
check "upgrade: a bad JSON line still upgrades" "the agent asked for a sandbox" \
  "$(_answer_result ask-t003 1 '{"result":"x\n@@upgrade not json"}' | jq -r .upgrade.reason)"
check "result: no JSON is an error, not a crash" "true" "$(_answer_result ask-t004 1 'Connection refused' | jq -r .error)"

mkdir -p "$PIPE_STATE_DIR/answer-slots"; for n in 1 2; do mkdir "$PIPE_STATE_DIR/answer-slots/$n"; done
check "busy: no free slot returns 3" "3" "$(FXA_ANSWER_MAX=2 answer_ask ask-t005 "$tmp/q1" 2>/dev/null; echo $?)"
rmdir "$PIPE_STATE_DIR/answer-slots"/*

FIREWALL=0; : > "$tmp/errors"
check "firewall: missing refuses the answer" "1|no_firewall" "$(answer_ask ask-t006 "$tmp/q1" >/dev/null 2>&1; echo $?)|$(cat "$tmp/errors")"
FIREWALL=1
check "no proxy: refused, never the API key" "1" "$(FXA_LLM_PROXY_URL= answer_ask ask-t007 "$tmp/q1" >/dev/null 2>&1; echo $?)"
check "id: must look like ask-xxxx" "1" "$(answer_ask agent-1234 "$tmp/q1" >/dev/null 2>&1; echo $?)"
check "prs: a linked PR comes as fenced data" "1|2" "$(_answer_prs "$tmp/q2" | grep -c '"title":"Fix it"')|$(_answer_prs "$tmp/q2" | grep -cE '^</?pr-')"
s="$(answer_ask ask-t008 "$tmp/q1" "" 1)"
check "stream: one step per tool, then the answer" 'Searching for `changePassword`|Reading `password.ts`|answer' "$(jq -r 'if .type == "step" then .text else .type end' <<< "$s" | paste -sd'|' -)"
check "stream: a tool result that quotes a result line is not the result" "0.21" "$(tail -1 <<< "$s" | jq -r .cost_usd)"
q='{"type":"result","result":"I found the heading at `en.ftl:3`.\nQUESTION: What should the heading say?\nOPTION: Sign in or sign up (recommended)\nOPTION: Enter your email to continue\nQUESTION: Update the two tests too?\nOPTION: Yes (recommended)\nOPTION: No"}'
r="$(_answer_result ask-t009 2 "$q")"
check "question: the text without the control lines" "I found the heading at \`en.ftl:3\`." "$(jq -r .answer <<< "$r")"
check "question: two groups, as a turn parses them" "2|What should the heading say?|Sign in or sign up (recommended)" "$(jq -r '"\(.question.questions | length)|\(.question.questions[0].q)|\(.question.questions[0].options[0])"' <<< "$r")"
check "no question: null" "null" "$(_answer_result ask-t010 1 '{"type":"result","result":"Just an answer."}' | jq -c .question)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
