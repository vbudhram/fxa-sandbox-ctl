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

# More than 128 KB of sessions: one jq argument stops there (exit 126), so they go as files.
( export SESSION_DIR="$tmp/big" PIPE_STATE_DIR="$tmp/bigps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"; db_on() { false; }; _session_records() { for f in "$SESSION_DIR"/agent-*.json; do cat "$f"; done; }
  big="$(head -c 3000 /dev/zero | tr '\0' x)"
  for n in $(seq 100 160); do printf '{"key":"agent-b%s","owner":"U1","created":%s,"summary":"{\\"note\\":\\"%s\\"}"}\n' "$n" "$n" "$big" > "$SESSION_DIR/agent-b$n.json"; done
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>&1)"
  check "stats: more than 128 KB of sessions still builds" "61" "$(jq '[.rows[] | select(.src == "slack")] | length' <<< "$out" 2>/dev/null)"
  exit "$fail" ) || fail=1

# Quick answers carry their Slack thread: their own field, else the one the LLM calls name.
( export SESSION_DIR="$tmp/ans" PIPE_STATE_DIR="$tmp/ansps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { :; }; db_on() { true; }
  db_json() { case "$1" in *"run LIKE 'ask-%'"*) echo '[{"run":"ask-old111","thread":"C1:1.000001"}]' ;; *) echo '[{"llm":"{}"}]' ;; esac; }
  printf '%s\n' '{"at":"2026-10-06T10:00:00Z","id":"ask-new222","secs":20,"cost_usd":0.12,"turns":3,"upgrade":false,"error":false,"thread":"C2:2.000002"}' \
    '{"at":"2026-10-05T10:00:00Z","id":"ask-old111","secs":30,"cost_usd":0.2,"turns":5,"upgrade":true,"error":false}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: an answer keeps its thread, an older one gets it from the LLM calls" "ask-new222 C2:2.000002 answered 3|ask-old111 C1:1.000001 upgraded 5" \
    "$(jq -r '[.rows[] | select(.src == "answer") | "\(.key) \(.thread) \(.kind) \(.turns)"] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# Spend by model: a session counts at its main model, an answer by the proxy's models.
( export SESSION_DIR="$tmp/mod" PIPE_STATE_DIR="$tmp/modps" FXA_AGENT_MODEL=claude-opus-5-5; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { echo '{"key":"agent-m1","owner":"U1","created":1,"runtime":"claude","summary":"{\"cost\":2.5}"}'; }
  db_on() { true; }
  db_json() { case "$1" in *"run LIKE 'ask-%'"*) echo '[]' ;; *) echo '[{"llm":"{\"run_models\":{\"ask-m2\":{\"claude-sonnet-5-5\":0.2}}}"}]' ;; esac; }
  echo '{"at":"2026-10-07T10:00:00Z","id":"ask-m2","secs":9,"cost_usd":0.2,"turns":2}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: a session has its main model, an answer the proxy's models" 'agent-m1 claude-opus-5-5 null true|ask-m2  {"claude-sonnet-5-5":0.2} false' \
    "$(jq -r '[.rows[] | "\(.key) \(.model) \(.models | tojson) \(.main_only // false)"] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# The stats are production's: a session or an answer from the dev bot (env "dev") is left out.
( export SESSION_DIR="$tmp/env" PIPE_STATE_DIR="$tmp/envps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { echo '{"key":"agent-p1","owner":"U1","created":1}'; echo '{"key":"agent-d1","owner":"U1","created":2,"env":"dev"}'; }
  db_on() { false; }
  printf '%s\n' '{"at":"2026-10-07T10:00:00Z","id":"ask-p2","secs":9,"cost_usd":0.2,"turns":2}' \
    '{"at":"2026-10-07T11:00:00Z","id":"ask-d2","secs":9,"cost_usd":0.2,"turns":2,"env":"dev"}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: the dev bot's sessions and answers are left out" "agent-p1 ask-p2" "$(jq -r '[.rows[].key] | sort | join(" ")' <<< "$out")"
  exit "$fail" ) || fail=1

# Agent PRs for the PRs tab: the source and key come from the branch, a session row
# names its PR, and a failed read keeps the last list.
( export SESSION_DIR="$tmp/prs" PIPE_STATE_DIR="$tmp/prsps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  gh() { echo '[{"number":7,"title":"t7","headRefName":"fxa-12","state":"MERGED","createdAt":"2026-10-01T10:00:00Z","mergedAt":"2026-10-02T10:00:00Z","closedAt":"2026-10-02T10:00:00Z","mergedBy":{"login":"rev1"},"additions":5,"deletions":2},
    {"number":8,"title":"t8","headRefName":"agent-ab12","state":"OPEN","createdAt":"2026-10-03T10:00:00Z","mergedAt":null,"closedAt":null,"mergedBy":null,"additions":1,"deletions":0}]'; }
  out="$(echo '{}' | _stats_add_prs)"
  check "prs: source, key and outcome from the branch" "7 pipeline FXA-12 MERGED rev1|8 slack agent-ab12 OPEN null" \
    "$(jq -r '[.prs[] | "\(.n) \(.src) \(.key) \(.state) \(.by)"] | join("|")' <<< "$out")"
  gh() { return 1; }; touch -t 202001010000 "$PIPE_STATE_DIR/prs.json"
  check "prs: a failed read keeps the last list" "2" "$(echo '{}' | _stats_add_prs | jq '.prs | length')"
  _session_records() { echo '{"key":"agent-q1","owner":"U1","created":1,"pr_url":"https://github.com/mozilla/fxa/pull/8"}'; }
  db_on() { false; }
  check "prs: a session row names its PR" "8" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq '.rows[0].prn')"
  _session_records() { echo '{"key":"agent-q2","owner":"U1","created":1,"profile":"monitor"}'; echo '{"key":"agent-q3","owner":"U1","created":2}'; }
  check "stats: a session row names its team; an old record is fxa" "monitor fxa" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r '[.rows[].profile] | join(" ")')"
  exit "$fail" ) || fail=1

exit "$fail"
