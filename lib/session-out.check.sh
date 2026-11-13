#!/usr/bin/env bash
# Offline check for session tail and session log --grep: secrets are masked, the word stays data,
# and a stopped session's archive is streamed with no runner call and nothing unpacked to disk.
#   bash lib/session-out.check.sh
source "$(dirname "$0")/session-check-head.sh"
ws="$tmp/ws"; mkdir -p "$ws/.fxa-functional-job"
SECRET="hunter2-team-secret"; TOK="ghp_abcdefghijklmnop1234"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }
# The runner, here: the script runs on this host, with /workspace pointed at a scratch folder.
_session_sh_in() { echo called >> "$tmp/sh"; bash -c "${4//\/workspace/$ws}" | head -c "$3"; }
res() { jq -nc --arg t "$1" '{type: "user", message: {content: [{type: "tool_result", content: $t}]}}'; }
{ res "PASS one"; res "password is $SECRET and token $TOK"; res "literal \$(touch pwned)'x here"; } > "$ws/.fxa-auto-claude.jsonl"
echo "bg line 1" > "$ws/.fxa-functional-job/log"
echo '{"key":"agent-out1","state":"active","runtime":"claude"}' > "$SESSION_DIR/agent-out1.json"

out="$(session_tail agent-out1 5 U123ABC)"
check "tail shows the tool output and the background run" "yes|yes" \
  "$(grep -q 'PASS one' <<< "$out" && echo yes)|$(grep -q 'bg line 1' <<< "$out" && echo yes)"
check "tail masks the runtime secret and the token" "0|0|2" \
  "$(grep -c "$SECRET" <<< "$out")|$(grep -c "$TOK" <<< "$out")|$(grep -o '<masked>' <<< "$out" | wc -l | tr -d ' ')"
check "a post writes one history line with the person" "1|yes" \
  "$(wc -l < "$SESSION_DIR/agent-out1.history.jsonl" | tr -d ' ')|$(jq -r .text "$SESSION_DIR/agent-out1.history.jsonl" | grep -q 'bytes of output (tail) to U123ABC' && echo yes)"
check "a bad line count is refused" "2" "$(session_tail agent-out1 '5; id' >/dev/null 2>&1; echo $?)"
_session_secret_values() { echo false; }
out="$(session_tail agent-out1 5)"
check "tail shows nothing of the output when a secret read failed" "0|0|1" \
  "$(grep -c "$SECRET" <<< "$out")|$(grep -c 'PASS one' <<< "$out")|$(grep -c 'not shown: the host could not read' <<< "$out")"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }

w="\$(touch pwned)'x"
check "the word is a literal, and nothing ran from it" "literal \$(touch pwned)'x here|no" \
  "$(printf '%s\n' "$w" | (cd "$ws" && session_log_grep agent-out1))|$([ -e "$ws/pwned" ] || [ -e pwned ] && echo yes || echo no)"
check "a search masks the secret" "0" "$(printf 'password\n' | session_log_grep agent-out1 | grep -c "$SECRET")"
check "an empty word is refused" "2" "$(printf '\n' | session_log_grep agent-out1 >/dev/null 2>&1; echo $?)"

# Stopped: the saved archive, read with no runner and nothing written to the temp folder.
mkdir -p "$tmp/home/.claude/projects/p"; res "saved FAIL $SECRET" > "$tmp/home/.claude/projects/p/s.jsonl"
(cd "$tmp/home" && tar -czf "$SESSION_DIR/agent-out1.claude.tgz" .claude/projects)
session_set agent-out1 state paused; rm -f "$tmp/sh"; mkdir "$tmp/t"
out="$(printf 'FAIL\n' | TMPDIR="$tmp/t" session_log_grep agent-out1)"
check "a paused session is searched from its archive, masked" "saved FAIL <masked>" "$out"
check "no runner call, and nothing unpacked" "no|0" "$([ -e "$tmp/sh" ] && echo yes || echo no)|$(ls -A "$tmp/t" | wc -l | tr -d ' ')"
check "tail of a paused session reads nothing" "agent-out1 not running|no" "$(session_tail agent-out1)|$([ -e "$tmp/sh" ] && echo yes || echo no)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
