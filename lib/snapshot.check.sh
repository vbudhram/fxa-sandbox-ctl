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

# The pipeline block: passes by day, and the wait from queued to the first run.
pd="$(mktemp -d)"; now=$(date +%s)
printf '%s\n' "{\"at\":$now,\"queued\":5,\"awaiting\":2,\"inflight\":1,\"work\":true}" "{\"at\":$now,\"queued\":7,\"awaiting\":2,\"inflight\":3,\"work\":false}" > "$pd/passes.jsonl"
echo $(( now - 7200 )) > "$pd/FXA-1.queued-at"
echo "{\"issue\":\"FXA-1\",\"recorded_at\":\"$(date -u +%FT%TZ)\"}" > "$pd/runs.jsonl"
out="$(PIPE_STATE_DIR="$pd" PIPE_RUNS_FILE="$pd/runs.jsonl"; eval "$(sed -n '/^_stats_add_pipeline() {/,/^}/p' "$(dirname "$0")/snapshot.sh")"
  echo '{"tickets":{"FXA-1":{"attempts":2},"FXA-2":{"attempts":1}}}' | _stats_add_pipeline)"
check "pipeline: a day's passes, work, max queue, last in flight" "2|1|7|3" "$(jq -r '.pipeline.days[0] | "\(.passes)|\(.work)|\(.max_queued)|\(.inflight)"' <<< "$out")"
check "pipeline: queue wait and retries" "2|1|2" "$(jq -r '.pipeline | "\(.waits[0].hours | round)|\(.retried)|\(.tickets)"' <<< "$out")"
rm -rf "$pd"

# Load: the most Slack sessions live at once each day, waits at the cap, and drops.
( _session_cap() { echo 2; }; db_on() { false; }; export ERRORS_FILE="$tmp/load-errors.jsonl"
  printf '%s\n' '{"at":"2026-10-01T15:00:00Z","kind":"queue_dropped","key":"agent-ld09"}' '{"at":"2026-10-01T15:00:00Z","kind":"crash","key":null}' > "$ERRORS_FILE"
  d1=$(date -u -d 2026-10-01T10:00:00Z +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-10-01T10:00:00Z +%s)
  rows="$(jq -nc --argjson t "$d1" '{rows: [
    {src: "slack", at: "2026-10-01T10:00:00Z", t0: $t, end: ($t + 3600), live: false},
    {src: "slack", at: "2026-10-01T10:30:00Z", t0: ($t + 1800), end: ($t + 5400), live: false, queued_s: 90},
    {src: "slack", at: "2026-10-01T11:00:00Z", t0: ($t + 3600), end: ($t + 7200), live: false, queued_s: 400},
    {src: "slack", at: "2026-10-01T09:00:00Z", t0: ($t - 3600), end: null, live: false},
    {src: "pipeline", at: "2026-10-01T10:00:00Z", t0: $t, end: ($t + 9999)}]}')"
  out="$(echo "$rows" | _stats_add_load | jq -c '.load')"
  check "load: a stop at the same second as a start does not count both" '{"cap":2,"days":[{"day":"2026-10-01","peak":2,"queued":2,"wait_max_s":400,"dropped":1}]}' "$out"
  live="$(jq -nc '{rows: [{src: "slack", at: "2026-10-02T10:00:00Z", t0: 1790935200, end: null, live: true}]}' | _stats_add_load | jq -c '.load.days[-1].peak')"
  check "load: a live session counts until now" "1" "$live"
  exit "$fail" ) || fail=1

exit "$fail"
