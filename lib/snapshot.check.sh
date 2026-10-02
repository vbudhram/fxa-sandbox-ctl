#!/usr/bin/env bash
# Offline check for the runner transcript parser.
#   bash lib/snapshot.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/telemetry.sh"
source "$(dirname "$0")/snapshot.sh"

# One message in two lines (text, then a tool call), each with the same usage,
# then a second message: the usage counts once per message.
u='{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100}'
printf '%s\n' \
  "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-5-5\",\"usage\":$u,\"content\":[{\"type\":\"text\",\"text\":\"Looking.\"}]}}" \
  "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-5-5\",\"usage\":$u,\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}" \
  "{\"type\":\"assistant\",\"message\":{\"id\":\"m2\",\"model\":\"claude-opus-5-5\",\"usage\":$u,\"content\":[{\"type\":\"text\",\"text\":\"Done.\"}]}}" > "$tmp/t.jsonl"
out="$(_snapshot_agent_json "$tmp/t.jsonl" "$(date +%s)")"
check "usage counts once per message" "2 20 2000 200" "$(jq -r '.tokens | "\(.in) \(.out) \(.cache_read) \(.cache_write)"' <<< "$out")"
check "the last tool and text still come from every line" "Bash ls|Done." "$(jq -r '"\(.last_tool)|\(.last_text)"' <<< "$out")"

# Every kept session is listed: a paused one from last week too, newest first.
sd="$(mktemp -d)"; now=$(date +%s)
echo "{\"key\":\"agent-old1\",\"state\":\"paused\",\"created\":1,\"last_activity\":$(( now - 9 * 86400 ))}" > "$sd/agent-old1.json"
echo "{\"key\":\"agent-new1\",\"state\":\"stopped\",\"created\":2,\"last_activity\":$now}" > "$sd/agent-new1.json"
check "old paused sessions stay listed" '["agent-new1","agent-old1"]' "$(
  SESSION_DIR="$sd"; session_live() { return 1; }; worktree_branch_for() { echo "$1"; }
  eval "$(sed -n '/^_snapshot_sessions() {/,/^}/p;/^_snapshot_session_row() {/,/^}/p' "$(dirname "$0")/snapshot.sh")"
  _snapshot_sessions "$now" | jq -c 'map(.key)')"
rm -rf "$sd"

exit "$fail"
