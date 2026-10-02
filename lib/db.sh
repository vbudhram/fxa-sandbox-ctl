#!/bin/bash
# db.sh: the controller's SQLite store. See ai/docs/design-docs/2026-10-02-sqlite-state-design.md.
#
# Public API:
#   db_q <text>          the text as one SQL string literal: the only way text reaches SQL
#   db_exec <sql>        run statements; returns non-zero on any error
#   db_json <sql>        rows of one SELECT as a JSON array ([] for none)
#   db_value <sql>       the value of a query that returns one row and one column, or nothing
#   db_init              create the file and apply the migrations in lib/db/ (PRAGMA user_version)
#   db_backup [--now]    copy it with SQLite's backup API to the state bucket, at most hourly
#   cmd_db status | init | backup | query <sql>
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
    query) [ -n "${2:-}" ] || { echo "usage: fxa-sandbox-ctl db query '<sql>'" >&2; return 1; }
      _db_ready && _db -readonly -box "$2" ;;
    status)
      [ -f "$FXA_DB" ] || { echo "no database at ${FXA_DB} (run: fxa-sandbox-ctl db init)"; return 0; }
      echo "database: ${FXA_DB} ($(du -h "$FXA_DB" | cut -f1), schema $(_db "PRAGMA user_version;"), journal $(_db "PRAGMA journal_mode;"))"
      _db -list "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;" | while read -r t; do
        printf '  %-18s %s rows\n' "$t" "$(_db "SELECT count(*) FROM \"$t\";")"; done ;;
    *) echo "usage: fxa-sandbox-ctl db [status | init | backup | query '<sql>']" >&2; return 1 ;;
  esac
}
