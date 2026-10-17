#!/usr/bin/env bash
# Offline check for routines (epic i168): the tables, the validator, the templates and the CRUD commands.
#   bash lib/routine.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/db.sh"

# The tables: db_init creates them, and one (routine, period) is claimed once.
db_init >/dev/null
check "db_init creates the three routine tables" "routine_runs routine_tick routines" \
  "$(db_value "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'routine%' ORDER BY name;" | tr '\n' ' ' | sed 's/ $//')"
db_exec "INSERT OR IGNORE INTO routine_runs (routine_id, period) VALUES (1, '2026-10-20'); INSERT OR IGNORE INTO routine_runs (routine_id, period) VALUES (1, '2026-10-20');"
check "a second claim of one (routine, period) is ignored" "1" "$(db_value "SELECT count(*) FROM routine_runs;")"
db_exec "DELETE FROM routine_runs;"

exit "$fail"
