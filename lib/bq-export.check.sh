#!/usr/bin/env bash
# Offline check for the BigQuery export: the rows from a fixture store and Stats feed, and no private field.
#   bash lib/bq-export.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_DB="$tmp/fxa.db" PIPE_STATE_DIR="$tmp/state" PIPE_REPO_SLUG=mozilla/fxa PIPE_PROFILE=fxa
mkdir -p "$PIPE_STATE_DIR"
source "$(dirname "$0")/db.sh"
source "$(dirname "$0")/bq-export.sh"
db_init >/dev/null || { echo "FAIL db_init"; exit 1; }

# A routine session with a PR (fix head: depfix), a routine run with no session, a run of a deleted routine,
# and a plain Slack session. The private values all contain SECRET.
_db "INSERT INTO routines (id, team, data, env) VALUES (1, 'sync-storage', '{\"name\":\"RUSTSEC Patches\",\"mode\":\"pr\",\"prompt\":\"SECRET prompt\"}', 'live'),
  (2, 'fxa', '{\"name\":\"Dev one\",\"mode\":\"report\"}', 'dev');
INSERT INTO routine_runs (id, routine_id, period, trigger, actor, state, reason, session, thread, pr_url, cost_usd, heads, report, started_at, ended_at) VALUES
  (1, 1, '2026-11-01', 'schedule', 'U-SECRET', 'ok', 'SECRET reason', 'agent-aaaaaa', 'SECRET thread', 'https://github.com/mozilla/syncstorage-rs/pull/7', 1.5, '{\"fix\":\"x\"}', 'SECRET report', 1761998400, 1761998700),
  (2, 1, '2026-11-02', 'schedule', NULL, 'failed', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1762084800, NULL),
  (3, 9, '2026-11-03', 'manual', NULL, 'report', NULL, NULL, NULL, NULL, 0.25, NULL, NULL, 1762171200, 1762171300),
  (4, 2, '2026-11-04', 'manual', NULL, 'report', NULL, 'agent-dddddd', NULL, NULL, 0.1, NULL, NULL, 1762257600, 1762257700);
INSERT INTO sessions (key, data) VALUES
  ('agent-aaaaaa', '{\"key\":\"agent-aaaaaa\",\"owner\":\"U-SECRET\",\"owner_name\":\"SECRET name\",\"profile\":\"sync-storage\",\"source\":\"routine\",\"state\":\"stopped\",\"created\":1761998400,\"stopped_at\":1761998700,\"busy_s\":\"60\",\"turns\":3,\"summary\":\"{\\\"text\\\":\\\"SECRET summary\\\"}\",\"pr_url\":\"https://github.com/mozilla/syncstorage-rs/pull/7\",\"routine_run\":1}'),
  ('agent-bbbbbb', '{\"key\":\"agent-bbbbbb\",\"owner\":\"U-DRYRUN\",\"state\":\"active\",\"created\":1762000000,\"thread\":\"SECRET thread\"}');
INSERT INTO runs (recorded_at, issue, kind, model, cost_usd, wall_seconds, data) VALUES
  ('2026-11-01T10:00:00Z', 'FXA-1', 'fix', 'claude-opus-5', 2.4, 600, '{\"pr\":\"https://github.com/mozilla/fxa/pull/100\",\"files_changed\":3,\"prompt\":\"SECRET prompt\"}');
INSERT INTO job_costs (at, job, cost_usd, turns, duration_ms, is_error) VALUES ('2026-11-01T11:00:00Z', 'pass', 0.5, 9, 60000, 1);
INSERT INTO llm_daily (day, model, calls, usd, usd_cache_write) VALUES ('2026-11-01', 'claude-opus-5', 10, 3.2, 0.4);" >/dev/null
printf '%s\n' '{"at":"2026-11-01T12:00:00Z","id":"ask-abcdef","q":"SECRET question","thread":"SECRET thread","cost_usd":0.12,"secs":20,"turns":4,"error":"SECRET error text"}' > "$PIPE_STATE_DIR/answers.jsonl"

# The Stats feed: a pipeline run and a rebase on one merged PR, a Slack session that continues it, the routine's
# session, and an answer. who, q and thread are private fields of the feed.
cat > "$tmp/stats.json" <<'JSON'
{"rows":[
 {"at":"2026-11-01T10:00:00Z","src":"pipeline","key":"FXA-1","kind":"fix","usd":2.4,"min":10,"model":"claude-opus-5","pr":true,"prn":100,"prr":"mozilla/fxa","profile":"fxa"},
 {"at":"2026-11-02T10:00:00Z","src":"pipeline","key":"FXA-1","kind":"rebase","usd":0.3,"min":2,"model":"claude-opus-5","pr":true,"prn":100,"prr":"mozilla/fxa","profile":"fxa"},
 {"at":"2026-11-02T11:00:00Z","src":"slack","key":"agent-cccccc","kind":"session","usd":1.45,"min":30,"model":"claude-opus-5","pr":true,"prn":100,"prr":"mozilla/fxa","who":"SECRET name","stop":"idle","profile":"fxa"},
 {"at":"2026-11-01T10:00:00Z","src":"slack","key":"agent-aaaaaa","kind":"session","usd":1.5,"min":5,"model":"claude-opus-5","pr":true,"prn":7,"prr":"mozilla/syncstorage-rs","who":"SECRET name","profile":"sync-storage"},
 {"at":"2026-11-01T12:00:00Z","src":"answer","key":"ask-abcdef","kind":"answered","usd":0.12,"min":0,"model":"","pr":false,"q":"SECRET question","thread":"SECRET thread","profile":"fxa"}],
 "prs":[{"n":100,"title":"SECRET title","state":"MERGED","created":"2026-11-01T10:30:00Z","merged":"2026-11-03T09:00:00Z","closed":"2026-11-03T09:00:00Z","by":"SECRET-login","src":"pipeline","key":"FXA-1","jira":{"assignee":"SECRET assignee"}},
  {"n":7,"title":"SECRET title","state":"OPEN","created":"2026-11-01T10:10:00Z","merged":null,"closed":null,"by":null,"src":"slack","key":"agent-aaaaaa","repo":"mozilla/syncstorage-rs","team":"sync-storage"}],
 "tickets":{"FXA-1":{"attempts":1,"feedback_rounds":2,"admin_rounds":0}}}
JSON

all=""
for t in work prs runs sessions routine_runs job_costs answers llm_daily; do
  eval "out_$t=\"\$(_bq_rows $t \"\$tmp/stats.json\")\""
  all="$all$(eval "printf '%s\n' \"\$out_$t\"")"$'\n'
done

check "work: one row per Stats row and per routine run with no session" 7 "$(printf '%s\n' "$out_work" | grep -c .)"
check "work: the routine session is depfix with the routine name and its team PR's state" "depfix|sync-storage|RUSTSEC Patches|mozilla/syncstorage-rs|7|open" \
  "$(printf '%s\n' "$out_work" | jq -r 'select(.key == "agent-aaaaaa") | "\(.src)|\(.team)|\(.kind)|\(.pr_repo)|\(.pr_number)|\(.outcome)"')"
check "work: a routine run with no session gets a row with its state" "routine|failed|0" \
  "$(printf '%s\n' "$out_work" | jq -r 'select(.key == "routine-2") | "\(.src)|\(.outcome)|\(.usd)"')"
check "work: a deleted routine's run counts, as team unknown" "unknown|report" \
  "$(printf '%s\n' "$out_work" | jq -r 'select(.key == "routine-3") | "\(.team)|\(.outcome)"')"
check "work: a dev routine's run is left out" "" "$(printf '%s\n' "$out_work" | jq -r 'select(.key == "routine-4" or .key == "agent-dddddd") | .key')"
check "work: a PR in the PR list gets its state" "merged merged merged" "$(printf '%s\n' "$out_work" | jq -r 'select(.pr_number == 100) | .outcome' | xargs)"
check "work: an answer keeps its kind as outcome" "answer|answered|0.12" "$(printf '%s\n' "$out_work" | jq -r 'select(.src == "answer") | "\(.src)|\(.outcome)|\(.usd)"')"
check "work: the columns are the allowlist" "key,kind,minutes,model,outcome,pr_number,pr_repo,src,team,ts,usd" \
  "$(printf '%s\n' "$out_work" | jq -sr 'map(keys) | add | unique | join(",")')"
check "prs: a session on a pipeline PR leaves it pipeline, with the rounds and rebases" "pipeline|merged|2|1|fxa|mozilla/fxa" \
  "$(printf '%s\n' "$out_prs" | jq -r 'select(.number == 100) | "\(.src)|\(.state)|\(.feedback_rounds)|\(.rebases)|\(.team)|\(.repo)"')"
check "prs: a team's PR keeps its repo and team" "mozilla/syncstorage-rs|sync-storage" \
  "$(printf '%s\n' "$out_prs" | jq -r 'select(.number == 7) | "\(.repo)|\(.team)"')"
check "routine_runs: all four runs, the fix as a boolean" "4 true" "$(printf '%s\n' "$out_routine_runs" | grep -c .) $(printf '%s\n' "$out_routine_runs" | jq -r 'select(.id == 1) | .fix')"
check "sessions: both rows, a dry run marked, busy_s a number" "2|true|60" \
  "$(printf '%s\n' "$out_sessions" | jq -sr '"\(length)|\(map(select(.key == "agent-bbbbbb"))[0].dryrun)|\(map(select(.key == "agent-aaaaaa"))[0].busy_s | floor)"')"
check "sessions: times are UTC ISO" "2025-11-01T12:00:00Z" "$(printf '%s\n' "$out_sessions" | jq -r 'select(.key == "agent-aaaaaa") | .created')"
check "job_costs: is_error is a boolean" "true" "$(printf '%s\n' "$out_job_costs" | jq -r '.is_error')"
check "answers: error is a boolean, no question" "true|false" "$(printf '%s\n' "$out_answers" | jq -r '"\(.error)|\(.upgraded)"')"
check "runs and llm_daily: one row each" "1 1" "$(printf '%s\n' "$out_runs" | grep -c .) $(printf '%s\n' "$out_llm_daily" | grep -c .)"
check "no private value in any table" "" "$(printf '%s' "$all" | grep -o 'SECRET[^"]*' | sort -u | xargs)"
check "no private field name in any table" "" "$(printf '%s' "$all" | grep -oE '"(owner|owner_name|who|q|thread|email|summary|prompt|title|reason|report|actor|jira|by)":' | sort -u | xargs)"
# Every table's rows have exactly the columns of its schema, so bq load cannot reject or drop a field.
while IFS= read -r line; do
  t="${line%%|*}" want="$(printf '%s' "${line#*|}" | tr ',' '\n' | cut -d: -f1 | sort | xargs)"
  got="$(eval "printf '%s\n' \"\$out_$t\"" | jq -sr 'map(keys) | add | unique | .[]' | sort | xargs)"
  check "schema matches the rows: $t" "$want" "$got"
done <<< "$_BQ_TABLES"
exit $fail
