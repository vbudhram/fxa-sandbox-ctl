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
printf '%s\n' "{\"at\":$now,\"queued\":5,\"awaiting\":2,\"inflight\":1,\"work\":true,\"merged\":1,\"woke\":{\"queue\":1,\"drain\":2}}" "{\"at\":$now,\"queued\":7,\"awaiting\":2,\"inflight\":3,\"work\":false,\"woke\":{\"drain\":1}}" > "$pd/passes.jsonl"
echo $(( now - 7200 )) > "$pd/FXA-1.queued-at"
echo "{\"issue\":\"FXA-1\",\"recorded_at\":\"$(date -u +%FT%TZ)\"}" > "$pd/runs.jsonl"
out="$(PIPE_STATE_DIR="$pd" PIPE_RUNS_FILE="$pd/runs.jsonl"; eval "$(sed -n '/^_stats_add_pipeline() {/,/^}/p' "$(dirname "$0")/snapshot.sh")"
  jq -nc --arg d "$(date -u +%F)" --arg pc "$(date -u -r $(( now - 3600 )) +%FT%TZ 2>/dev/null || date -u -d @$(( now - 3600 )) +%FT%TZ)" '{tickets: {"FXA-1": {attempts: 2}, "FXA-2": {attempts: 1}},
    rows: [{src: "pass", kind: "pass", at: ($d + "T01:00:00Z"), usd: 0.2}, {src: "pass", kind: "triage", at: ($d + "T01:00:00Z"), usd: 5}, {src: "pass", kind: "pass", at: ($d + "T02:00:00Z"), usd: 0.15}],
    prs: [{key: "FXA-1", created: $pc, merged: null}]}' | _stats_add_pipeline)"
check "pipeline: a day's passes, work, max queue, last in flight" "2|1|7|3" "$(jq -r '.pipeline.days[0] | "\(.passes)|\(.work)|\(.max_queued)|\(.inflight)"' <<< "$out")"
check "pipeline: queue wait and retries" "2|1|2" "$(jq -r '.pipeline | "\(.waits[0].hours | round)|\(.retried)|\(.tickets)"' <<< "$out")"
check "pipeline: what woke the passes, merges, and the passes' own spend" '{"drain":3,"queue":1}|1|0.35' "$(jq -r '.pipeline.days[0] | "\(.woke | tojson)|\(.merged)|\(.usd)"' <<< "$out")"
check "pipeline: queued to PR, and no merge yet" "1|null" "$(jq -r '.pipeline.waits[0] | "\(.pr_hours | round)|\(.merge_hours)"' <<< "$out")"
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
  db_json() { case "$1" in *"run LIKE 'ask-%'"*) echo '[{"run":"ask-bbb111","thread":"C1:1.000001"}]' ;; *) echo '[{"llm":"{}"}]' ;; esac; }
  printf '%s\n' '{"at":"2026-10-06T10:00:00Z","id":"ask-aaa222","secs":20,"cost_usd":0.12,"turns":3,"upgrade":false,"error":false,"thread":"C2:2.000002"}' \
    '{"at":"2026-10-05T10:00:00Z","id":"ask-bbb111","secs":30,"cost_usd":0.2,"turns":5,"upgrade":true,"error":false}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: an answer keeps its thread, an older one gets it from the LLM calls" "ask-aaa222 C2:2.000002 answered 3|ask-bbb111 C1:1.000001 upgraded 5" \
    "$(jq -r '[.rows[] | select(.src == "answer") | "\(.key) \(.thread) \(.kind) \(.turns)"] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# Test runs stay out of every total: an answer is priced by the proxy, and the LLM days and models
# leave out dev and dry-run sessions, dev answers and hand-run CLI asks (no ask-<6 hex> id).
( export SESSION_DIR="$tmp/tr" PIPE_STATE_DIR="$tmp/trps" FXA_LLM_PROXY_DIR="$tmp/trp"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR" "$FXA_LLM_PROXY_DIR"
  _session_records() { printf '%s\n' '{"key":"agent-dev001","owner":"U1","env":"dev","created":1}' '{"key":"agent-try001","owner":"U-DRYRUN","created":1}' '{"key":"agent-abc001","owner":"U1","created":1}'; }
  db_on() { false; }
  printf '%s\n' '{"at":"2026-10-14T10:00:00Z","id":"ask-abc123","secs":9,"cost_usd":0.5}' '{"at":"2026-10-14T10:00:00Z","id":"ask-def456","env":"dev","cost_usd":0.4}' \
    '{"at":"2026-10-14T10:00:00Z","id":"timing1","cost_usd":0.3}' > "$PIPE_STATE_DIR/answers.jsonl"
  { for r in agent-dev001 agent-try001 ask-def456 timing1; do printf '{"at":"2026-10-14T10:00:00Z","run":"%s","model":"m","usd":10}\n' "$r"; done
    printf '%s\n' '{"at":"2026-10-14T10:00:00Z","run":"agent-abc001","model":"m","usd":1}' '{"at":"2026-10-14T10:00:00Z","run":"ask-abc123","model":"m","usd":0.2}' \
      '{"at":"2026-10-14T10:00:00Z","run":null,"model":"m","usd":0.05}'; } > "$FXA_LLM_PROXY_DIR/usage.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: one answer row, at the proxy's price" "ask-abc123 0.2" "$(jq -r '[.rows[] | select(.src == "answer") | "\(.key) \(.usd)"] | join("|")' <<< "$out")"
  check "stats: the LLM days and models leave out test runs" "1.25|1.25" "$(jq -r '"\(.llm.days | map(.usd) | add)|\(.llm.models | map(.usd) | add)"' <<< "$out")"
  exit "$fail" ) || fail=1

# llm.hour_usd: the proxy spend of the last hour, test runs left out, on the jsonl and the store paths.
( export SESSION_DIR="$tmp/hr" PIPE_STATE_DIR="$tmp/hrps" FXA_LLM_PROXY_DIR="$tmp/hrp" FXA_DB="$tmp/hr.db"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR" "$FXA_LLM_PROXY_DIR"
  _session_records() { printf '%s\n' '{"key":"agent-dev002","owner":"U1","env":"dev","created":1}'; }
  ago() { date -u -r $(( $(date +%s) - $1 )) +%FT%TZ 2>/dev/null || date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
  printf '%s\n' "{\"at\":\"$(ago 600)\",\"run\":\"agent-x\",\"usd\":0.3}" "{\"at\":\"$(ago 1200)\",\"run\":null,\"usd\":0.12}" \
    "{\"at\":\"$(ago 900)\",\"run\":\"agent-dev002\",\"usd\":5}" "{\"at\":\"$(ago 7200)\",\"run\":\"agent-x\",\"usd\":9}" > "$FXA_LLM_PROXY_DIR/usage.jsonl"
  db_on() { false; }
  check "stats: hour_usd sums the last hour, with the test session left out (usage.jsonl)" "0.42" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r .llm.hour_usd)"
  printf '%s\n' "{\"at\":\"$(ago 7200)\",\"run\":\"agent-x\",\"usd\":9}" > "$FXA_LLM_PROXY_DIR/usage.jsonl"
  check "stats: hour_usd is 0 when the last hour was quiet (usage.jsonl)" "0" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r .llm.hour_usd)"
  if command -v sqlite3 >/dev/null; then
    unset -f db_on; source "$(dirname "$0")/db.sh"; db_init >/dev/null
    sqlite3 "$FXA_DB" "INSERT INTO llm_calls (at, run, usd) VALUES ('$(ago 600)','agent-x',0.3),('$(ago 1200)',NULL,0.12),('$(ago 900)','agent-dev002',5),('$(ago 7200)','agent-x',9);"
    check "stats: hour_usd from the store, the test session left out" "0.42" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r .llm.hour_usd)"
    sqlite3 "$FXA_DB" "DELETE FROM llm_calls WHERE usd < 9;"
    check "stats: hour_usd from the store is 0 when quiet" "0" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r .llm.hour_usd)"
  fi
  exit "$fail" ) || fail=1

# Team memory: saves by result and the learnings they moved in the last 30 days, and the last digest.
( export FXA_MEMORY_LOG="$tmp/mem.jsonl"
  printf '%s\n' "{\"at\":\"$(date -u +%FT%TZ)\",\"run\":\"agent-a\",\"result\":\"saved\",\"added\":1,\"inbox\":2,\"dropped\":1}" \
    "{\"at\":\"$(date -u +%FT%TZ)\",\"run\":\"agent-b\",\"result\":\"pii_blocked\",\"added\":0,\"inbox\":0,\"dropped\":0}" \
    '{"at":"2020-01-01T00:00:00Z","run":"agent-old","result":"saved","added":9,"inbox":9,"dropped":9}' \
    "{\"at\":\"$(date -u +%FT%TZ)\",\"run\":\"digest\",\"result\":\"opened\",\"added\":3,\"inbox\":1,\"dropped\":0}" > "$FXA_MEMORY_LOG"
  check "stats: memory saves and learnings in 30 days, and the last digest" '{"pii_blocked":1,"saved":1}|1|2|1|opened' \
    "$(echo '{}' | _stats_add_memory | jq -r '.memory | "\(.saves | tojson)|\(.added)|\(.inbox)|\(.dropped)|\(.last_digest.result)"')"
  exit "$fail" ) || fail=1

# Every team's runs and passes: rows tagged with their team, and each team's passes in 7 days.
( export HOME="$tmp/th" FXA_PROFILES_DIR="$tmp/tp" PIPE_PROFILE=fxa PIPE_STATE_DIR="$tmp/th/.claude/state/fxa-ai-fixme"
  mkdir -p "$FXA_PROFILES_DIR/fxa" "$FXA_PROFILES_DIR/sync-storage" "$FXA_PROFILES_DIR/monitor" "$HOME/.claude/state/sync-storage" "$PIPE_STATE_DIR"
  touch "$FXA_PROFILES_DIR"/{fxa,sync-storage,monitor}/profile.conf
  echo '{"recorded_at":"2026-10-14T10:00:00Z","issue":"STOR-1","kind":"fix","cost_usd":2.5,"cost_source":"proxy"}' > "$HOME/.claude/state/sync-storage/agent-runs.jsonl"
  echo '{"at":"2026-10-14T10:00:00Z","job":"pass","run":"pass-s1","cost_usd":0.9}' > "$HOME/.claude/state/sync-storage/job-costs.jsonl"
  printf '%s\n' "{\"at\":$(date +%s),\"work\":true}" "{\"at\":$(date +%s),\"work\":false}" '{"at":1,"work":true}' > "$HOME/.claude/state/sync-storage/passes.jsonl"
  out="$(echo '{"rows":[{"src":"pipeline","key":"FXA-1","usd":1},{"src":"slack","key":"agent-a","usd":1,"profile":"monitor"}],"llm":{"runs":{"pass-s1":0.4}}}' | _stats_add_teams)"
  check "teams: each row has its team, and another team's run and pass join at the proxy's price" "FXA-1 fxa 1|agent-a monitor 1|STOR-1 sync-storage 2.5|pass sync-storage 0.4" \
    "$(jq -r '[.rows[] | "\(.key) \(.profile) \(.usd)"] | join("|")' <<< "$out")"
  check "teams: a team's passes in 7 days, and one with no state folder is left out" '{"sync-storage":{"passes":2,"work":1}}' \
    "$(jq -c '.team_passes | map_values(del(.last))' <<< "$out")"
  exit "$fail" ) || fail=1

# A resume chain is one conversation: each row names the chain's first session.
( export SESSION_DIR="$tmp/cv" PIPE_STATE_DIR="$tmp/cvps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"; db_on() { false; }
  _session_records() { printf '%s\n' '{"key":"agent-c1","owner":"U1","created":1}' '{"key":"agent-c2","owner":"U1","created":2,"resume_from":"agent-c1"}' \
    '{"key":"agent-c3","owner":"U1","created":3,"resume_from":"agent-c2"}' '{"key":"agent-c4","owner":"U1","created":4}' '{"key":"agent-c5","owner":"U1","created":5,"resume_from":"agent-c5"}'; }
  check "stats: a resume chain is one conversation" "agent-c1 agent-c1|agent-c2 agent-c1|agent-c3 agent-c1|agent-c4 agent-c4|agent-c5 agent-c5" \
    "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r '[.rows[] | "\(.key) \(.conv)"] | join("|")')"
  exit "$fail" ) || fail=1

# A session's PR keeps its repo, so the PR list matches its number only in that repo.
( export SESSION_DIR="$tmp/pr" PIPE_STATE_DIR="$tmp/prps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"; db_on() { false; }
  _session_records() { echo '{"key":"agent-p1","owner":"U1","created":1,"pr_url":"https://github.com/mozilla/PyFxA/pull/12"}'; }
  check "stats: a session PR has its number and its repo" "12|mozilla/PyFxA" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r '.rows[0] | "\(.prn)|\(.prr)"')"
  exit "$fail" ) || fail=1

# A pass row has the main model the job recorded (Haiku runs Claude Code's small steps); an old row has none.
( export SESSION_DIR="$tmp/pm" PIPE_STATE_DIR="$tmp/pmps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { :; }; db_on() { false; }
  printf '%s\n' '{"at":"2026-10-12T15:00:00Z","job":"pass","cost_usd":0.2,"models":["claude-haiku-4-5","claude-sonnet-5-5"]}' \
    '{"at":"2026-10-12T14:00:00Z","job":"pass","cost_usd":0.47}' > "$PIPE_STATE_DIR/job-costs.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: a pass row has its recorded main model; an old one has none" "claude-sonnet-5-5|" \
    "$(jq -r '[.rows[] | select(.src == "pass") | .model] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# A pass that went through the proxy is priced from the proxy's log; one that did not keeps the CLI's figure.
( export SESSION_DIR="$tmp/pp" PIPE_STATE_DIR="$tmp/ppps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { :; }; db_on() { true; }
  db_json() { case "$1" in *"run LIKE 'ask-%'"*) echo '[]' ;; *) echo '[{"llm":"{\"runs\":{\"pass-123\":0.31}}"}]' ;; esac; }
  printf '%s\n' '{"at":"2026-10-12T15:00:00Z","job":"pass","run":"pass-123","cost_usd":0.5}' '{"at":"2026-10-12T14:00:00Z","job":"pass","cost_usd":0.47}' > "$PIPE_STATE_DIR/job-costs.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: a pass through the proxy has the proxy's cost; an older pass the CLI's" "0.31|0.47" \
    "$(jq -r '[.rows[] | select(.src == "pass") | .usd] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# Spend by model: a session counts at its main model, an answer by the proxy's models.
( export SESSION_DIR="$tmp/mod" PIPE_STATE_DIR="$tmp/modps" FXA_AGENT_MODEL=claude-opus-5-5; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { echo '{"key":"agent-m1","owner":"U1","created":1,"runtime":"claude","summary":"{\"cost\":2.5}"}'; }
  db_on() { true; }
  db_json() { case "$1" in *"run LIKE 'ask-%'"*) echo '[]' ;; *) echo '[{"llm":"{\"run_models\":{\"ask-ccc002\":{\"claude-sonnet-5-5\":0.2}}}"}]' ;; esac; }
  echo '{"at":"2026-10-07T10:00:00Z","id":"ask-ccc002","secs":9,"cost_usd":0.2,"turns":2}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: a session has its main model, an answer the proxy's models" 'agent-m1 claude-opus-5-5 null true|ask-ccc002  {"claude-sonnet-5-5":0.2} false' \
    "$(jq -r '[.rows[] | "\(.key) \(.model) \(.models | tojson) \(.main_only // false)"] | join("|")' <<< "$out")"
  exit "$fail" ) || fail=1

# The stats are production's: a session or an answer from the dev bot (env "dev") is left out.
( export SESSION_DIR="$tmp/env" PIPE_STATE_DIR="$tmp/envps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { echo '{"key":"agent-p1","owner":"U1","created":1}'; echo '{"key":"agent-d1","owner":"U1","created":2,"env":"dev"}'; }
  db_on() { false; }
  printf '%s\n' '{"at":"2026-10-07T10:00:00Z","id":"ask-ddd002","secs":9,"cost_usd":0.2,"turns":2}' \
    '{"at":"2026-10-07T11:00:00Z","id":"ask-d2","secs":9,"cost_usd":0.2,"turns":2,"env":"dev"}' > "$PIPE_STATE_DIR/answers.jsonl"
  out="$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null)"
  check "stats: the dev bot's sessions and answers are left out" "agent-p1 ask-ddd002" "$(jq -r '[.rows[].key] | sort | join(" ")' <<< "$out")"
  exit "$fail" ) || fail=1

# With no answers file yet, the dev bot's sessions still leave the LLM totals (under the ctl's pipefail).
( set -o pipefail; export SESSION_DIR="$tmp/noans" PIPE_STATE_DIR="$tmp/noansps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  _session_records() { echo '{"key":"agent-d9","owner":"U1","created":2,"env":"dev"}'; }
  db_on() { true; }; db_json() { printf '%s\n' "$1" >> "$tmp/noans.sql"; echo '[]'; }
  echo '{"rows":[]}' | _stats_add_rows >/dev/null 2>&1
  check "stats: with no answers file, a dev session is still left out of the LLM totals" "yes" "$(grep -q 'agent-d9' "$tmp/noans.sql" && echo yes || echo no)"
  : > "$tmp/noans.sql"; echo '{bad' > "$PIPE_STATE_DIR/answers.jsonl"; echo '{"rows":[]}' | _stats_add_rows >/dev/null 2>&1
  check "stats: nor with a malformed answers line" "yes" "$(grep -q 'agent-d9' "$tmp/noans.sql" && echo yes || echo no)"
  exit "$fail" ) || fail=1

# Agent PRs for the PRs tab: the source and key come from the branch, a session row
# names its PR, and a failed read keeps the last list.
( export SESSION_DIR="$tmp/prs" PIPE_STATE_DIR="$tmp/prsps"; mkdir -p "$SESSION_DIR" "$PIPE_STATE_DIR"
  gh() { echo '[{"number":7,"title":"t7","headRefName":"fxa-12","state":"MERGED","createdAt":"2026-10-01T10:00:00Z","mergedAt":"2026-10-02T10:00:00Z","closedAt":"2026-10-02T10:00:00Z","mergedBy":{"login":"rev1"},"additions":5,"deletions":2},
    {"number":8,"title":"t8","headRefName":"agent-ab12","state":"OPEN","createdAt":"2026-10-03T10:00:00Z","mergedAt":null,"closedAt":null,"mergedBy":null,"additions":1,"deletions":0}]'; }
  out="$(echo '{}' | _stats_add_prs)"
  check "prs: source, key and outcome from the branch" "7 pipeline FXA-12 MERGED rev1|8 slack agent-ab12 OPEN null" \
    "$(jq -r '[.prs[] | "\(.n) \(.src) \(.key) \(.state) \(.by)"] | join("|")' <<< "$out")"
  echo '{"assignee":"Pat Doe","status":"Done","at":"2026-10-02T10:15:00Z"}' > "$PIPE_STATE_DIR/FXA-12.jira.json"
  check "prs: a merged PR carries its ticket's state; a PR with none gets null" "Pat Doe Done|null" \
    "$(echo '{}' | _stats_add_prs | jq -r '[(.prs[0].jira | "\(.assignee) \(.status)"), (.prs[1].jira | tostring)] | join("|")')"
  gh() { return 1; }; touch -t 202001011200 "$PIPE_STATE_DIR/prs.json"
  check "prs: a failed read keeps the last list, with its time" "2 1577836800" "$(echo '{}' | _stats_add_prs | TZ=UTC jq -r '"\(.prs | length) \(.prs_at - (.prs_at % 86400))"')"
  rm -f "$PIPE_STATE_DIR/prs.json"
  check "prs: a list never read is null, not empty, and has no time" "null null" "$(echo '{}' | _stats_add_prs | jq -r '"\(.prs) \(.prs_at)"')"
  _session_records() { echo '{"key":"agent-q1","owner":"U1","created":1,"pr_url":"https://github.com/mozilla/fxa/pull/8"}'; }
  db_on() { false; }
  check "prs: a session row names its PR" "8" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq '.rows[0].prn')"
  _session_records() { echo '{"key":"agent-q2","owner":"U1","created":1,"profile":"monitor"}'; echo '{"key":"agent-q3","owner":"U1","created":2}'; }
  check "stats: a session row names its team; an old record is fxa" "monitor fxa" "$(echo '{"rows":[]}' | _stats_add_rows 2>/dev/null | jq -r '[.rows[].profile] | join(" ")')"
  exit "$fail" ) || fail=1

exit "$fail"
