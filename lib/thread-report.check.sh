#!/usr/bin/env bash
# Offline check that a thread resolves from any handle and its report sums every session.
#   bash lib/thread-report.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$(dirname "$0")/session.sh"

T="C0AB12CD3:1791135361.015169"
echo '{"thread":"'"$T"'","request":"make it faster","sessions":"agent-aaaaaa agent-bbbbbb"}' > "$tmp/thread-C0AB12CD3-1791135361.015169.json"
echo '{"key":"agent-aaaaaa","state":"stopped","created":1791135400,"thread":"'"$T"'","turns":3,"compute_usd":"0.40"}' > "$tmp/agent-aaaaaa.json"
echo '{"key":"agent-bbbbbb","state":"active","created":1791158233.4,"thread":"'"$T"'","turns":1,"compute_usd":"0.10","pr_url":"https://example.com/pr/1"}' > "$tmp/agent-bbbbbb.json"

check "key" "$T" "$(session_thread_id agent-bbbbbb)"
check "thread ID" "$T" "$(session_thread_id "$T")"
check "bare ts" "$T" "$(session_thread_id 1791135361.015169)"
check "message link" "$T" "$(session_thread_id https://example.slack.com/archives/C0AB12CD3/p1791135361015169)"
check "reply link" "$T" "$(session_thread_id 'https://example.slack.com/archives/C0AB12CD3/p1791135999000100?thread_ts=1791135361.015169&cid=C0AB12CD3')"
check "unknown ts" "" "$(session_thread_id 1700000000.000001)"
check "an unknown ts is not an error under set -e" "ok" "$(set -e; t="$(session_thread_id 1700000000.000001)"; echo ok)"

db_on() { return 0; }
db_q() { printf "'%s'" "$1"; }
db_json() { echo '[{"run":"agent-aaaaaa","usd":2.5},{"run":"ask-aaaaaa","usd":0.25},{"run":"agent-bbbbbb","usd":5.6}]'; }
out="$(_thread_summary "$T")"
check "one line per session" "2" "$(grep -c '^  agent-' <<<"$out")"
check "quick answer counts to its session" "yes" "$(grep -q 'agent-aaaaaa stopped .* llm \$2.75 ' <<<"$out" && echo yes)"
check "thread total" "  total: 2 sessions, llm \$8.35, compute \$0.5" "$(tail -1 <<<"$out")"

printf '%s\n' '{"turn":1,"secs":2124}' > "$tmp/agent-aaaaaa.turns.jsonl"
printf '%s\n' '{"turn":1,"secs":76}' '{"turn":2,"secs":5740}' > "$tmp/agent-bbbbbb.turns.jsonl"
check "thread usage: sessions, turns, minutes, no dollars" '{"sessions":2,"turns":3,"minutes":132}' "$(_thread_usage agent-bbbbbb)"
echo '{"key":"agent-cccccc","state":"active"}' > "$tmp/agent-cccccc.json"
check "no thread: null" "null" "$(_thread_usage agent-cccccc)"
rm -f "$tmp/agent-aaaaaa.turns.jsonl"
# The bot reads a non-zero exit as a failure and drops the thread line.
check "a session with no finished turn yet still counts, under pipefail" '{"sessions":2,"turns":2,"minutes":96} rc=0' "$( (set -o pipefail; _thread_usage agent-bbbbbb; echo "rc=$?") | paste -sd" " -)"

exit "$fail"
