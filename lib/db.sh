#!/bin/bash
# db.sh: the controller's SQLite store. See ai/docs/design-docs/2026-10-02-sqlite-state-design.md.
#
# Public API:
#   db_q <text>          the text as one SQL string literal: the only way text reaches SQL
#   db_exec <sql>        run statements; returns non-zero on any error
#   db_json <sql>        rows of one SELECT as a JSON array ([] for none)
#   db_value <sql>       the value of a query that returns one row and one column, or nothing
#   db_ingest <tbl> <json>  one log record (errors, llm_calls, mcp_calls, runs, job_costs,
#                        passes, lessons, error_resolutions); never fails its caller
#   db_init              create the file and apply the migrations in lib/db/ (PRAGMA user_version)
#   db_backup [--now]    copy it with SQLite's backup API to the state bucket, at most hourly
#   db_session <key> <file>  mirror one session record (or drop its row when the file is gone)
#   db_on                true when the store is usable: the readers' switch while the files remain
#   cmd_db status | init | backup | import | parity | query <sql>
#
# WAL mode and a 5 s busy timeout on every connection, so the dashboard reads
# while the controller, the bot, the proxy and the gateway write.

[ -n "${_FXA_DB_LOADED:-}" ] && return 0
_FXA_DB_LOADED=1

FXA_DB="${FXA_DB:-${HOME}/.claude/state/fxa.db}"
FXA_DB_BACKUP_URI="${FXA_DB_BACKUP_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/db}}"
_DB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db"

# _db [-json|-list|...] [sql]   The SQL goes on stdin: sqlite3 reads an argument
# that starts with "-" (a "--" comment) as an option, and stdin has no length limit.
_db() {
  local o=(); while [ $# -gt 0 ]; do case "$1" in -json|-list|-box|-csv|-line|-readonly) o+=("$1"); shift ;; *) break ;; esac; done
  if [ $# -gt 0 ]; then printf '%s\n' "$1" | sqlite3 -bail -batch ${o[@]+"${o[@]}"} -cmd ".timeout 5000" "$FXA_DB"
  else sqlite3 -bail -batch ${o[@]+"${o[@]}"} -cmd ".timeout 5000" "$FXA_DB"; fi
}

db_q() { local q="'"; printf "'%s'" "${1//$q/$q$q}"; }

# Migrate once per process, before the first statement.
_db_ready() { [ -n "${_FXA_DB_READY:-}" ] || db_init >/dev/null || return 1; _FXA_DB_READY=1; }

db_exec() { _db_ready || return 1; _db "$1"; }
db_value() { _db_ready || return 1; _db -list "$1"; }
db_json() {
  _db_ready || return 1
  local out; out="$(_db -json "$1")" || return 1
  printf '%s\n' "${out:-[]}"
}

# The writers keep their files while the store proves itself, so a failed insert must not fail them.
db_ingest() { [ -s "$FXA_DB" ] || return 0; { _db_ready && _db "INSERT INTO ingest (tbl, j) VALUES ($(db_q "$1"), $(db_q "$2"));"; } >/dev/null 2>&1 || true; }

db_session() {
  [ -s "$FXA_DB" ] || return 0
  if [ -f "$2" ]; then db_exec "INSERT INTO sessions (key, data) VALUES ($(db_q "$1"), json($(db_q "$(cat "$2")"))) ON CONFLICT (key) DO UPDATE SET data = excluded.data;"
  else db_exec "DELETE FROM sessions WHERE key = $(db_q "$1");"; fi >/dev/null 2>&1 || true
}

db_on() { declare -F db_json >/dev/null && command -v sqlite3 >/dev/null && [ -s "$FXA_DB" ] && _db_ready 2>/dev/null; }

# _db_log_files   table, path and kind of every log the store mirrors.
_db_log_files() {
  local ps="${PIPE_STATE_DIR:-$HOME/.claude/state/fxa-ai-fixme}"
  printf '%s\t%s\t%s\n' errors "${ERRORS_FILE:-$ps/errors.jsonl}" jsonl \
    error_resolutions "${ERRORS_RESOLVED:-$ps/errors-resolved.json}" object \
    llm_calls "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/usage.jsonl" jsonl \
    mcp_calls "${FXA_MCP_GATEWAY_DIR:-$HOME/.claude/state/mcp-gateway}/calls.jsonl" jsonl \
    runs "${PIPE_RUNS_FILE:-$ps/agent-runs.jsonl}" jsonl \
    job_costs "$ps/job-costs.jsonl" jsonl \
    passes "$ps/passes.jsonl" jsonl \
    lessons "${LESSONS_FILE:-$ps/lessons.json}" array \
    sessions "${SESSION_DIR:-${FXA_SESSION_DIR:-$HOME/.claude/state/agent-sessions}}" dir
}

# db_import   Rebuild the log tables from their files (exact: every writer appends to its file first).
# ponytail: a writer that appends during the rebuild can land twice; db parity shows it, and a rerun fixes it.
db_import() {
  _db_ready || return 1
  _db_log_files | python3 -c '
import json, os, sys
sys.path.insert(0, sys.argv[1]); import fxadb
files = [tuple(l.rstrip("\n").split("\t")) for l in sys.stdin if l.strip()]
for t, n in fxadb.import_files(fxadb.connect(sys.argv[2]), files).items(): print(f"{t:18} {n} records")
' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$FXA_DB"
}

# db_parity   Each mirrored log against its table: records and, where it has money, the total.
db_parity() {
  _db_ready || return 1
  local tbl path kind n m bad=0
  while IFS=$'\t' read -r tbl path kind; do
    [ -e "$path" ] || { printf '%-18s no file\n' "$tbl"; continue; }
    case "$kind" in jsonl) n="$(grep -c . "$path" || true)" ;; array) n="$(jq length "$path")" ;; object) n="$(jq 'keys | length' "$path")" ;;
      dir) n="$(find "$path" -maxdepth 1 -name 'agent-*.json' | wc -l | tr -d ' ')" ;; esac
    m="$(db_value "SELECT count(*) FROM ${tbl};")"
    local extra=""
    case "$tbl" in
      llm_calls) extra=" usd file $(jq -s 'map(.usd // 0) | add // 0 | . * 100 | round / 100' "$path") db $(db_value "SELECT round(coalesce(sum(usd), 0), 2) FROM llm_calls;") daily $(db_value "SELECT round(coalesce(sum(usd), 0), 2) FROM llm_daily;")" ;;
      sessions) extra=" differ $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fxadb; print(fxadb.sessions_differ(fxadb.connect(sys.argv[2], readonly=True), sys.argv[3]))' \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$FXA_DB" "$path")"
        [ "${extra##* }" = 0 ] || bad=1 ;;
      runs) extra=" usd file $(jq -s 'map(.cost_usd // 0) | add // 0 | . * 100 | round / 100' "$path") db $(db_value "SELECT round(coalesce(sum(cost_usd), 0), 2) FROM runs;")" ;;
    esac
    [ "$n" = "$m" ] && printf '%-18s ok   %s%s\n' "$tbl" "$n" "$extra" || { printf '%-18s DIFF file %s, db %s%s\n' "$tbl" "$n" "$m" "$extra"; bad=1; }
  done < <(_db_log_files)
  return "$bad"
}

db_init() {
  command -v sqlite3 >/dev/null || { echo "ERROR: sqlite3 is not installed" >&2; return 1; }
  mkdir -p "$(dirname "$FXA_DB")" || return 1
  _db "PRAGMA journal_mode = WAL;" >/dev/null || return 1
  local cur f n; cur="$(_db "PRAGMA user_version;")"
  for f in "$_DB_DIR"/[0-9][0-9][0-9]-*.sql; do
    [ -f "$f" ] || continue
    n="$(basename "$f" | cut -c1-3)"; n=$((10#$n))
    [ "$n" -gt "${cur:-0}" ] || continue
    # One transaction per migration, with its version: a failed one leaves the last good schema.
    { echo "BEGIN;"; cat "$f"; echo "PRAGMA user_version = ${n};"; echo "COMMIT;"; } | _db || { echo "ERROR: migration $(basename "$f") failed" >&2; return 1; }
    echo "applied $(basename "$f")"
  done
  _FXA_DB_READY=1
}

db_backup() {
  [ -n "$FXA_DB_BACKUP_URI" ] && [ -f "$FXA_DB" ] || return 0
  local stamp="${FXA_DB}.backed-up"
  if [ "${1:-}" != --now ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(_mtime "$stamp") )) -lt 3600 ]; then return 0; fi
  touch "$stamp"
  local t; t="$(mktemp "${FXA_DB}.bak.XXXXXX")" || return 1
  # The backup API copies a consistent snapshot while writers keep writing; a file copy would not.
  _db ".backup '${t}'" && gzip -f "$t" \
    && gcloud storage cp -q "${t}.gz" "${FXA_DB_BACKUP_URI}/$(hostname -s).db.gz" >/dev/null 2>&1
  local rc=$?; rm -f "$t" "${t}.gz"; return "$rc"
}

cmd_db() {
  case "${1:-status}" in
    init) db_init ;;
    backup) db_backup --now && echo "backed up to ${FXA_DB_BACKUP_URI:-nowhere (no bucket set)}" ;;
    import) db_import ;;
    parity) db_parity ;;
    query) [ -n "${2:-}" ] || { echo "usage: fxa-sandbox-ctl db query '<sql>'" >&2; return 1; }
      _db_ready && _db -readonly -box "$2" ;;
    status)
      [ -f "$FXA_DB" ] || { echo "no database at ${FXA_DB} (run: fxa-sandbox-ctl db init)"; return 0; }
      echo "database: ${FXA_DB} ($(du -h "$FXA_DB" | cut -f1), schema $(_db "PRAGMA user_version;"), journal $(_db "PRAGMA journal_mode;"))"
      _db -list "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;" | while read -r t; do
        printf '  %-18s %s rows\n' "$t" "$(_db "SELECT count(*) FROM \"$t\";")"; done ;;
    *) echo "usage: fxa-sandbox-ctl db [status | init | backup | import | parity | query '<sql>']" >&2; return 1 ;;
  esac
}
