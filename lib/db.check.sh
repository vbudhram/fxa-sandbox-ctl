#!/usr/bin/env bash
# Offline check for the SQLite store: migrations, quoting, concurrent writers, triggers, backup.
#   bash lib/db.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
here="$(cd "$(dirname "$0")" && pwd)"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
source "$here/db.sh"

check "init applies the migrations" "applied 001-init.sql applied 002-ingest.sql" "$(db_init | tr '\n' ' ' | sed 's/ $//')"
check "init again changes nothing" "" "$(db_init)"
check "schema version and WAL" "2|wal" "$(_db "PRAGMA user_version;")|$(_db "PRAGMA journal_mode;")"

# Every hostile string comes back unchanged.
db_exec "CREATE TABLE t (v TEXT);"
n=0
for v in "it's" "'; DROP TABLE t; --" 'back\slash' "two
lines" '"double"' '$(rm -rf /)' "émoji 🦊" "''" ""; do
  db_exec "DELETE FROM t; INSERT INTO t VALUES ($(db_q "$v"));"
  [ "$(db_value "SELECT v FROM t;")" = "$v" ] || { echo "FAIL quoting: [$v]"; fail=1; }; n=$((n + 1))
done
check "quoting: hostile strings round-trip" "1" "$(db_value "SELECT count(*) FROM sqlite_master WHERE name = 't';")"

check "json: rows" '[{"v":"x"}]' "$(db_exec "DELETE FROM t; INSERT INTO t VALUES ('x');"; db_json "SELECT v FROM t;" | tr -d ' \n')"
check "json: no rows is []" "[]" "$(db_json "SELECT v FROM t WHERE 0;")"
check "a leading -- comment stays SQL" "1" "$(db_value "-- a comment
SELECT 1;")"

# Two writers at once: the busy timeout serializes them, nothing is lost.
w() { for i in $(seq 150); do db_exec "INSERT INTO sessions (key, data) VALUES ($(db_q "agent-$1$i"), json_object('state', 'paused', 'created', $i));" || echo ERR; done; }
w a > "$tmp/a" & w b > "$tmp/b" & wait
check "concurrent writers: every row lands" "300|0" "$(db_value "SELECT count(*) FROM sessions;")|$(cat "$tmp/a" "$tmp/b" | grep -c ERR)"

# Generated columns and the change log.
db_exec "UPDATE sessions SET data = json_set(data, '$.state', 'active') WHERE key = 'agent-a1';"
check "generated column follows the JSON" "active" "$(db_value "SELECT state FROM sessions WHERE key = 'agent-a1';")"
check "every write lands in changes" "301" "$(db_value "SELECT count(*) FROM changes WHERE tbl = 'sessions';")"
check "the state index is used" "1" "$(db_value "EXPLAIN QUERY PLAN SELECT key FROM sessions WHERE state = 'active';" | grep -c sessions_state)"

# The daily rollup is kept on insert.
for j in '{"at":"2026-10-02T10:00:00Z","run":"agent-x","model":"opus","usd":0.5,"usd_cache_write":0.2,"input_tokens":3}' '{"at":"2026-10-02T11:00:00Z","run":"agent-y","model":"opus","usd":0.25,"usd_cache_write":0.1}' '{"at":"2026-10-03T09:00:00Z","run":"agent-x","model":"opus","usd":1,"usd_cache_write":0}'; do db_ingest llm_calls "$j"; done
# A running session's cost is the proxy's total so far (agent-x: 0.5 + 1), subagents included.
eval "$(sed -n '/^_session_proxy_cost() {/,/^}/p' "$here/session.sh")"
check "session cost: the proxy's total replaces the transcript's" '{"cost":1.5,"tokens":10}' "$(_session_proxy_cost agent-x '{"cost":0.4,"tokens":10}')"
check "session cost: a live card's cost_so_far too" '{"turns":3,"cost_so_far":1.5}' "$(_session_proxy_cost agent-x '{"turns":3,"cost_so_far":0.4}')"
check "session cost: unchanged when the proxy never saw it" '{"cost":0.4}' "$(_session_proxy_cost agent-none '{"cost":0.4}')"
check "session cost: the proxy's even with no transcript price" '{"cost":1.5}' "$(_session_proxy_cost agent-x '')"
check "llm_daily: calls and spend per day" "2026-10-02|2|0.75|2026-10-03|1|1.0" "$(db_value "SELECT group_concat(day || '|' || calls || '|' || usd, '|') FROM (SELECT * FROM llm_daily ORDER BY day);")"

# Every log goes in through ingest, as the writers' JSON lines.
db_ingest errors '{"at":"2026-10-02T10:00:00Z","source":"bot","kind":"stream","key":null,"where":"stream","message":"it'"'"'s broken","log":null,"sig":"abc"}'
db_ingest mcp_calls '{"at":"2026-10-02T10:00:00Z","run":"agent-x","connector":"jira","tool":"getJiraIssue","outcome":"ok","ms":120,"bytes":900,"args":"{}"}'
db_ingest runs '{"recorded_at":"2026-10-02T10:00:00Z","issue":"FXA-1","kind":"fix","model":"opus","cost_usd":1.5,"wall_seconds":600,"pr":"21300"}'
db_ingest job_costs '{"at":"2026-10-02T10:00:00Z","job":"pass","cost_usd":0.35,"turns":10,"duration_ms":1000,"is_error":false}'
db_ingest passes '{"at":1790969732,"queued":26,"awaiting":7,"inflight":2,"work":true}'
db_ingest lessons '{"id":"l1","at":"x","session":"agent-x","text":"one","status":"pending"}'
db_ingest lessons '{"id":"l1","at":"x","session":"agent-x","text":"one, edited","status":"approved","decided_at":"y"}'
db_ingest error_resolutions '{"sig":"abc","at":"z","note":"fixed"}'
db_ingest nosuch '{"a":1}'; db_ingest errors 'not json'
check "ingest: each table maps its fields" "it's broken|jira|FXA-1|21300|0.35|0|26|1|one, edited|approved|fixed" \
  "$(db_value "SELECT (SELECT message FROM errors) || '|' || (SELECT connector FROM mcp_calls) || '|' || (SELECT issue FROM runs) || '|' || (SELECT data->>'pr' FROM runs) || '|' || (SELECT cost_usd FROM job_costs) || '|' || (SELECT is_error FROM job_costs) || '|' || (SELECT queued FROM passes) || '|' || (SELECT count(*) FROM lessons) || '|' || (SELECT text FROM lessons) || '|' || (SELECT status FROM lessons) || '|' || (SELECT note FROM error_resolutions);")"
check "ingest: an unknown table or bad JSON is dropped, quietly" "1|0" "$(db_value "SELECT count(*) FROM errors;")|$(db_ingest errors 'not json'; echo $?)"

# Import rebuilds each table from its file; parity then matches; a second import changes nothing.
export PIPE_STATE_DIR="$tmp/ps" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_MCP_GATEWAY_DIR="$tmp/gw"; mkdir -p "$PIPE_STATE_DIR" "$FXA_LLM_PROXY_DIR" "$FXA_MCP_GATEWAY_DIR"
printf '%s\n' '{"at":"2026-10-01T10:00:00Z","source":"ctl","kind":"crash","key":null,"where":"x","message":"m1","log":null,"sig":"s1"}' '{"at":"2026-10-02T10:00:00Z","source":"ctl","kind":"crash","key":"agent-a","where":"x","message":"m2","log":null,"sig":"s1"}' > "$PIPE_STATE_DIR/errors.jsonl"
echo '{"s1":{"at":"2026-10-01T12:00:00Z","note":"fixed"}}' > "$PIPE_STATE_DIR/errors-resolved.json"
printf '%s\n' '{"at":"2026-10-01T10:00:00Z","run":"agent-a","model":"m","usd":1.25,"usd_cache_write":0.5,"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":20}' '{"at":"2026-10-01T10:09:00Z","run":"agent-a","model":"m","usd":0.75,"usd_cache_write":0.25,"cache_read_input_tokens":500,"output_tokens":5}' '{"at":"2026-10-01T10:10:00Z","run":"agent-a","model":"h","usd":0.1,"cache_read_input_tokens":50,"output_tokens":7}' > "$FXA_LLM_PROXY_DIR/usage.jsonl"
printf '%s\n' '{"recorded_at":"2026-10-01T10:00:00Z","issue":"FXA-1","cost_usd":2.5}' > "$PIPE_STATE_DIR/agent-runs.jsonl"
echo '[{"id":"l9","at":"x","session":"agent-a","text":"t","status":"pending"}]' > "$PIPE_STATE_DIR/lessons.json"
db_import >/dev/null
check "import: tables match their files" "0" "$(db_parity >/dev/null; echo $?)"
check "import: the daily rollup is rebuilt" "2026-10-01|m|2|2.0" "$(db_value "SELECT day || '|' || model || '|' || calls || '|' || usd FROM llm_daily WHERE model = 'm';")"
db_import >/dev/null
( export FXA_SESSION_DIR="$tmp/ss" SESSION_DIR="$tmp/ss"; mkdir -p "$SESSION_DIR"; echo '{"key":"agent-a","owner":"U1","created":1}' > "$SESSION_DIR/agent-a.json"
  source "$here/session.sh"; source "$here/snapshot.sh"; a="$(echo '{}' | _stats_add_rows | jq -c '.llm | .. |= (if type == "number" then . + 0 else . end)')"
  db_on() { false; }; b="$(echo '{}' | _stats_add_rows | jq -c .llm)"
  check "stats: the store's LLM rollup equals the file's" "$b" "$a"; exit "$fail" ) || fail=1
check "usage by model: tokens and cost per model, costliest first" '[{"model":"m","calls":2,"input":3,"cache_read":1500,"cache_write":200,"output":25,"usd":2.0},{"model":"h","calls":1,"input":0,"cache_read":50,"cache_write":0,"output":7,"usd":0.1}]' \
  "$(python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import fxadb; print(json.dumps(fxadb.usage_by_model(fxadb.connect(sys.argv[2], readonly=True), "agent-a"), separators=(",", ":")))' "$here" "$FXA_DB")"

# Sessions: each write mirrors to the store, import and parity cover the directory, and the readers agree.
( export FXA_SESSION_DIR="$tmp/ss2" SESSION_DIR="$tmp/ss2"; mkdir -p "$SESSION_DIR"
  source "$here/session.sh"; source "$here/snapshot.sh"
  [ "$SESSION_DIR" = "$tmp/ss2" ] || { echo "FAIL sessions: SESSION_DIR is not the scratch folder"; exit 1; }
  echo '{"key":"agent-b","owner":"U1","state":"stopped","created":1790000000.5,"last_activity":1}' > "$SESSION_DIR/agent-b.json"
  echo '{"key":"agent-c","owner":"U2","state":"paused","created":1790000001}' > "$SESSION_DIR/agent-c.json"
  echo 'a request' > "$SESSION_DIR/agent-c.prompt.md"
  db_import >/dev/null
  check "sessions: import fills the table" "2" "$(db_value 'SELECT count(*) FROM sessions;')"
  session_set agent-b pr_url "https://example.com/pr/1" summary '{"cost":1.5}'
  check "sessions: a write mirrors to the store" "https://example.com/pr/1" "$(db_value "SELECT json_extract(data, '\$.pr_url') FROM sessions WHERE key = 'agent-b';")"
  check "sessions: parity finds no difference" "0|differ 0" "$(db_parity >/dev/null; echo $?)|$(db_parity | grep '^sessions ' | grep -o 'differ.*')"
  a="$(_snapshot_quiet_rows "$FXA_DB" | jq -sc 'sort_by(.key)')"; b="$(_snapshot_quiet_rows "" | jq -sc 'sort_by(.key)')"
  check "sessions: the page's rows from the store equal the files'" "$b" "$a"
  a="$(_session_records | jq -sc .)"; b="$(db_on() { false; }; _session_records | jq -sc .)"
  check "sessions: the records from the store equal the files'" "$b" "$a"
  echo '{"key":"agent-b","state":"edited"}' > "$SESSION_DIR/agent-b.json"
  check "parity: a record changed outside the store shows" "1|differ 1" "$(db_parity >/dev/null; echo $?)|$(db_parity | grep '^sessions ' | grep -o 'differ.*')"
  rm -f "$SESSION_DIR/agent-b.json"; _session_db_sync agent-b
  check "sessions: a removed record leaves the store" "agent-c" "$(db_value 'SELECT key FROM sessions;')"
  # The page's quick path: only what changed since its cursor, and a removed one as deleted.
  since() { python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import fxadb
c = fxadb.connect(sys.argv[2], readonly=True); print(json.dumps(fxadb.sessions_since(c, None if sys.argv[3] == "-" else int(sys.argv[3]), sys.argv[4])))' "$here" "$FXA_DB" "$1" "$SESSION_DIR"; }
  cur="$(since - | jq .cursor)"
  check "since: the first call is only a cursor" "[]" "$(since - | jq -c .rows)"
  session_set agent-c state stopped
  check "since: a changed session, with its request" "agent-c|stopped|a request" "$(since "$cur" | jq -r '.rows[] | "\(.key)|\(.state)|\(.request)"')"
  next="$(since "$cur" | jq .cursor)"
  check "since: nothing new after the new cursor" "[]" "$(since "$next" | jq -c .rows)"
  rm -f "$SESSION_DIR/agent-c.json"; _session_db_sync agent-c
  check "since: a removed session is marked deleted" "agent-c|true" "$(since "$next" | jq -r '.rows[] | "\(.key)|\(.deleted)"')"
  db_on() { false; }; rm -rf "$SESSION_DIR"/*
  check "sessions: no records is one empty list" "[]" "$(_session_records | jq -sc .)"
  exit "$fail" ) || fail=1
db_import >/dev/null
check "import twice: still one copy" "2|3|1" "$(db_value "SELECT (SELECT count(*) FROM errors) || '|' || (SELECT count(*) FROM llm_calls) || '|' || (SELECT count(*) FROM runs);")"
echo '{"at":"2026-10-03T10:00:00Z","source":"ctl","kind":"crash","key":null,"where":"x","message":"m3","log":null,"sig":"s2"}' >> "$PIPE_STATE_DIR/errors.jsonl"
check "parity: a row only in the file shows as a difference" "1|DIFF" "$(db_parity >/dev/null; echo $?)|$(db_parity | grep '^errors ' | awk '{print $2}')"

# Prune keeps the store to the files' windows: MCP calls 30 days, LLM calls 90; llm_daily keeps its totals.
( export FXA_SESSION_DIR="$tmp/pr" SESSION_DIR="$tmp/pr" FXA_MCP_GATEWAY_DIR="$tmp/pr/mcp" FXA_LLM_PROXY_DIR="$tmp/pr/llm"; mkdir -p "$SESSION_DIR"
  source "$here/session.sh"
  [ "$SESSION_DIR" = "$tmp/pr" ] || { echo "FAIL prune: SESSION_DIR is not the scratch folder"; exit 1; }
  iso() { jq -rn --argjson t "$(( $(date +%s) - $1 * 86400 ))" '$t | todate'; }
  for d in 40 1; do db_ingest mcp_calls "{\"at\":\"$(iso $d)\",\"run\":\"r\",\"connector\":\"jira\",\"tool\":\"t\",\"outcome\":\"ok\",\"args\":\"day $d\"}"; done
  for d in 100 40; do db_ingest llm_calls "{\"at\":\"$(iso $d)\",\"run\":\"r\",\"model\":\"m\",\"usd\":1}"; done
  daily="$(db_value "SELECT round(sum(usd), 2) FROM llm_daily;")"
  session_prune >/dev/null 2>&1
  check "prune: MCP calls past 30 days leave the store" "day 1" "$(db_value "SELECT args FROM mcp_calls WHERE run = 'r';")"
  check "prune: LLM calls past 90 days leave it; the daily totals stay" "1|$daily" "$(db_value "SELECT count(*) FROM llm_calls WHERE run = 'r';")|$(db_value "SELECT round(sum(usd), 2) FROM llm_daily;")"
  exit "$fail" ) || fail=1

# A backup is a whole, valid database.
_db ".backup '$tmp/copy.db'"
check "backup passes the integrity check" "ok|$(db_value 'SELECT count(*) FROM sessions;')" "$(sqlite3 "$tmp/copy.db" "PRAGMA integrity_check;")|$(sqlite3 "$tmp/copy.db" "SELECT count(*) FROM sessions;")"
# The Python helper reads what bash wrote, and writes with bound parameters.
check "python: reads and writes the same file" "$(db_value 'SELECT count(*) FROM sessions;')|it's" "$(python3 -c "
import sys; sys.path.insert(0, '$here'); import fxadb
con = fxadb.connect(); con.execute('DELETE FROM t'); con.execute('INSERT INTO t VALUES (?)', (\"it's\",))
print(str(con.execute('SELECT count(*) FROM sessions').fetchone()[0]) + '|' + fxadb.rows(con, 'SELECT v FROM t')[0]['v'])")"
check "python: a read-only connection cannot write" "readonly" "$(python3 -c "
import sys, sqlite3; sys.path.insert(0, '$here'); import fxadb
try: fxadb.connect(readonly=True).execute('DELETE FROM t'); print('wrote')
except sqlite3.OperationalError as e: print('readonly' if 'readonly' in str(e) else e)")"
# A pipeline run's cost from the proxy: its ticket (any case), inside its own window, by model.
eval "$(sed -n '/^_telemetry_proxy_cost() {/,/^}/p' "$here/telemetry.sh")"
for j in '{"at":"2026-10-02T10:05:00Z","run":"fxa-1","model":"claude-opus-5-5","usd":0.5}' \
         '{"at":"2026-10-02T10:40:00Z","run":"fxa-1","model":"claude-sonnet-5-5","usd":0.25}' \
         '{"at":"2026-10-02T15:00:00Z","run":"fxa-1","model":"claude-opus-5-5","usd":9}' \
         '{"at":"2026-10-02T10:10:00Z","run":"fxa-2","model":"claude-opus-5-5","usd":1}'; do db_ingest llm_calls "$j"; done
check "proxy cost: this run's window and ticket only, by model" \
  '{"usd":0.75,"models":{"claude-opus-5-5":0.5,"claude-sonnet-5-5":0.25}}' "$(_telemetry_proxy_cost FXA-1 1790935200 1790938800)"
check "proxy cost: nothing for a run the proxy never saw" "" "$(_telemetry_proxy_cost FXA-3 1790935200 1790938800)"
check "proxy cost: no window, no answer" "" "$(_telemetry_proxy_cost FXA-1 0x 1790938800)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
