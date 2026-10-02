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

check "init applies the migrations" "applied 001-init.sql" "$(db_init)"
check "init again changes nothing" "" "$(db_init)"
check "schema version and WAL" "1|wal" "$(_db "PRAGMA user_version;")|$(_db "PRAGMA journal_mode;")"

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
db_exec "INSERT INTO llm_calls (at, run, model, usd, usd_cache_write) VALUES ('2026-10-02T10:00:00Z', 'agent-x', 'opus', 0.5, 0.2), ('2026-10-02T11:00:00Z', 'agent-y', 'opus', 0.25, 0.1), ('2026-10-03T09:00:00Z', 'agent-x', 'opus', 1, 0);"
check "llm_daily: calls and spend per day" "2026-10-02|2|0.75|2026-10-03|1|1.0" "$(db_value "SELECT group_concat(day || '|' || calls || '|' || usd, '|') FROM (SELECT * FROM llm_daily ORDER BY day);")"

# A backup is a whole, valid database.
_db ".backup '$tmp/copy.db'"
check "backup passes the integrity check" "ok|300" "$(sqlite3 "$tmp/copy.db" "PRAGMA integrity_check;")|$(sqlite3 "$tmp/copy.db" "SELECT count(*) FROM sessions;")"
# The Python helper reads what bash wrote, and writes with bound parameters.
check "python: reads and writes the same file" "300|it's" "$(python3 -c "
import sys; sys.path.insert(0, '$here'); import fxadb
con = fxadb.connect(); con.execute('DELETE FROM t'); con.execute('INSERT INTO t VALUES (?)', (\"it's\",))
print(str(con.execute('SELECT count(*) FROM sessions').fetchone()[0]) + '|' + fxadb.rows(con, 'SELECT v FROM t')[0]['v'])")"
check "python: a read-only connection cannot write" "readonly" "$(python3 -c "
import sys, sqlite3; sys.path.insert(0, '$here'); import fxadb
try: fxadb.connect(readonly=True).execute('DELETE FROM t'); print('wrote')
except sqlite3.OperationalError as e: print('readonly' if 'readonly' in str(e) else e)")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
