#!/bin/bash
# errors.sh: one log of every failure the host sees, for finding and fixing bugs.
#
# Public API:
#   errors_record <source> <kind> <key> <where> <message> [log]   append one error
#   errors_err_trap <rc> <command>        the ERR trap: records a crash under set -e
#   cmd_errors [--json|--all] | show <sig> | resolve <sig> [note]
#
# The log is JSON lines in the pipeline state dir. Each write also copies it to
# GCS (errors/<host>.jsonl in the state bucket), so a triage later, or a
# controller in GCP, reads every host's errors. Nothing trims it. Each line has
# a signature, so the same bug in many sessions groups into one row.

[ -n "${_FXA_ERRORS_LOADED:-}" ] && return 0
_FXA_ERRORS_LOADED=1

ERRORS_FILE="${FXA_ERRORS_FILE:-${HOME}/.claude/state/fxa-ai-fixme/errors.jsonl}"
ERRORS_RESOLVED="${ERRORS_FILE%.jsonl}-resolved.json"
ERRORS_URI="${FXA_ERRORS_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/errors}}"

# errors_push   Copy this host's log to GCS. Whole file, one object per host:
# GCS has no append, and a host never overwrites another host's errors.
errors_push() {
  [ -n "$ERRORS_URI" ] && [ -s "$ERRORS_FILE" ] || return 0
  # At most once a minute: a runner that stops answering fails every 5 s poll.
  local stamp="${ERRORS_FILE}.pushed"
  if [ "${1:-}" != --now ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(_mtime "$stamp") )) -lt 60 ]; then return 0; fi
  touch "$stamp"
  gcloud storage cp -q "$ERRORS_FILE" "${ERRORS_URI}/$(hostname -s).jsonl" >/dev/null 2>&1
}

# errors_sig <where> <message>   Stable across sessions: line numbers, keys,
# tickets, paths, hashes and numbers are masked before hashing.
errors_sig() {
  local w m
  w="$(printf '%s' "$1" | sed -E 's/:[0-9]+//g')"
  m="$(printf '%s' "$2" | sed -E 's/agent-[a-z0-9]{4,12}/<key>/g; s/[Ff][Xx][Aa]-[0-9]+/<ticket>/g; s#(/[^ :]+)+#<path>#g; s/[0-9a-f]{7,40}/<hex>/g; s/[0-9]+/N/g' | cut -c1-200)"
  printf '%s|%s' "$w" "$m" | shasum | cut -c1-10
}

errors_record() {
  local src="$1" kind="$2" key="$3" where="$4" msg="${5:0:600}" log="${6:-}"
  mkdir -p "$(dirname "$ERRORS_FILE")" 2>/dev/null || return 0
  # One short line per write: an O_APPEND write this size lands whole, so
  # concurrent writers (the bot, jobs, polls) need no lock.
  local line; line="$(jq -nc --arg at "$(date -u +%FT%TZ)" --arg s "$src" --arg k "$kind" --arg key "$key" --arg w "$where" \
    --arg m "$msg" --arg l "$log" --arg sig "$(errors_sig "$where" "$msg")" \
    '{at: $at, source: $s, kind: $k, key: (if $key == "" then null else $key end), where: $w,
      message: $m, log: (if $l == "" then null else $l end), sig: $sig}' 2>/dev/null)" || return 0
  printf '%s\n' "$line" >> "$ERRORS_FILE" 2>/dev/null || true
  declare -F db_ingest >/dev/null && db_ingest errors "$line"
  # In the background: the caller may be about to exit, and must not wait on GCS.
  ( errors_push || true ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# errors_err_trap <rc> <command>
#   Under set -e an unexpected failure ends the process silently. Say where, on
#   stderr (so the job's own log shows it) and in the error log. Only the
#   top-level shell records: inside $(...) a failure is often expected, and a
#   failure in main itself is a command returning its error, already reported.
errors_err_trap() {
  local rc="$1" cmd="$2"
  [ "${BASH_SUBSHELL:-0}" = 0 ] || return 0
  [ "${FUNCNAME[1]:-main}" != main ] || return 0
  # One of our own functions returning its error, or a return: that code already
  # said what went wrong. A crash is a command such as grep, jq or ssh failing.
  [[ "$cmd" =~ ^return([[:space:]]|$) ]] && return 0
  # SIGPIPE: a reader such as `| head` closed the pipe early.
  [ "$rc" = 141 ] && return 0
  declare -F "${cmd%%[[:space:]]*}" >/dev/null 2>&1 && return 0
  # The same, assigned: x="$(own_function ...)", as key="$(_key "$1")" on a bad ticket key.
  [[ "$cmd" =~ ^(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\"?\$\(([A-Za-z_][A-Za-z0-9_]*) ]] \
    && declare -F "${BASH_REMATCH[2]}" >/dev/null 2>&1 && return 0
  local where="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]} ${FUNCNAME[1]}" kind=crash
  cmd="$(printf '%s' "$cmd" | tr -s ' \t\n' ' ' | cut -c1-300)"
  # ssh exits 255 when it cannot connect: a network or runner hiccup, not a bug here.
  [ "$rc" = 255 ] && [[ "$cmd" =~ ^(ssh|scp|vm_exec|_gce|gcloud) ]] && kind=ssh
  local stack; stack="$(printf '%s < ' "${FUNCNAME[@]:1}")"
  echo "fxa-sandbox-ctl: unexpected failure (exit ${rc}) at ${where}: ${cmd}" >&2
  local key; key="$(grep -oE 'agent-[a-z0-9]{4,12}|FXA-[0-9]+' <<< "${_ERR_CONTEXT:-}" | head -1 || true)"
  errors_record ctl "$kind" "$key" "$where" "exit ${rc}: ${cmd} (in ${stack% < })" ""
}

# cmd_errors   Grouped by signature: count, first and last seen, sessions.
#   errors            open signatures (new, or seen again after a resolve)
#   errors --all      every signature
#   errors --json     every signature, for the dashboard
#   errors show SIG   every occurrence of one signature
#   errors resolve SIG [note]   mark it fixed; it reopens if it happens again
#   errors push       copy this host's log to GCS now (the bot uses this)
# _errors_rows   One row per signature, newest first: from the store when it is up, else the file.
_errors_rows() {
  if declare -F db_on >/dev/null && db_on; then
    # The first occurrence names the source and kind; the last gives where, message and log.
    db_json 'WITH g AS (SELECT sig, count(*) AS count, min(at) AS first, max(at) AS last, min(id) AS fid, max(id) AS lid FROM errors GROUP BY sig)
      SELECT g.sig, f.source, f.kind, l."where" AS "where", l.message, g.count, g.first, g.last, l.log,
        (SELECT json_group_array(key) FROM (SELECT DISTINCT key FROM errors WHERE sig = g.sig AND key IS NOT NULL ORDER BY key DESC LIMIT 5)) AS keys,
        r.at AS rat, r.note AS rnote
      FROM g JOIN errors f ON f.id = g.fid JOIN errors l ON l.id = g.lid LEFT JOIN error_resolutions r ON r.sig = g.sig' \
    | jq -c 'map({sig, source, kind, where, message, count, first, last, keys: (.keys | fromjson | sort), log,
        resolved: (if .rat then {at: .rat, note: .rnote} else null end)}
      | .status = (if .resolved == null then "open" elif .last > .resolved.at then "reopened" else "resolved" end))
      | sort_by(.last) | reverse'
    return
  fi
  [ -s "$ERRORS_FILE" ] || { echo '[]'; return 0; }
  local resolved='{}'; [ -s "$ERRORS_RESOLVED" ] && resolved="$(cat "$ERRORS_RESOLVED")"
  jq -s -c --argjson r "$resolved" '
    group_by(.sig) | map({sig: .[0].sig, source: .[0].source, kind: .[0].kind, where: (last | .where),
      message: (last | .message), count: length, first: (map(.at) | min), last: (map(.at) | max),
      keys: ([.[].key | select(. != null)] | unique | .[-5:]), log: (last | .log),
      resolved: $r[.[0].sig]}
    | .status = (if .resolved == null then "open" elif .last > .resolved.at then "reopened" else "resolved" end))
    | sort_by(.last) | reverse' "$ERRORS_FILE"
}

cmd_errors() {
  [ "${1:-}" = push ] && { errors_push "${2:-}" && echo "pushed to ${ERRORS_URI}/$(hostname -s).jsonl"; return; }
  local resolved='{}'; [ -s "$ERRORS_RESOLVED" ] && resolved="$(cat "$ERRORS_RESOLVED")"
  case "${1:-}" in
    show)
      local sig="${2:?errors show needs a signature}"
      if declare -F db_on >/dev/null && db_on; then
        db_json "SELECT at, source, kind, key, \"where\", message, log, sig FROM errors WHERE sig = $(db_q "$sig") ORDER BY id;" | jq -c '.[]'
      else jq -c --arg s "$sig" 'select(.sig == $s)' "$ERRORS_FILE" 2>/dev/null; fi ;;
    resolve)
      local sig="${2:?errors resolve needs a signature}" note="${3:-}"
      [ "$(_errors_rows | jq --arg s "$sig" 'any(.[]; .sig == $s)')" = true ] || { echo "ERROR: no error has signature ${sig}" >&2; return 1; }
      local at; at="$(date -u +%FT%TZ)"
      jq --arg s "$sig" --arg at "$at" --arg n "$note" '.[$s] = {at: $at, note: $n}' <<< "$resolved" > "${ERRORS_RESOLVED}.tmp" \
        && mv "${ERRORS_RESOLVED}.tmp" "$ERRORS_RESOLVED" && echo "resolved ${sig}" || return 1
      declare -F db_ingest >/dev/null && db_ingest error_resolutions "$(jq -nc --arg s "$sig" --arg at "$at" --arg n "$note" '{sig: $s, at: $at, note: $n}')"
      return 0 ;;
    ""|--all|--json)
      local rows; rows="$(_errors_rows)"
      if [ "${1:-}" = --json ]; then printf '%s\n' "$rows"; return 0; fi
      [ "$rows" != "[]" ] || { echo "No errors recorded."; return 0; }
      [ "${1:-}" = --all ] || rows="$(jq -c 'map(select(.status != "resolved"))' <<< "$rows")"
      [ "$(jq length <<< "$rows")" -gt 0 ] || { echo "No open errors."; return 0; }
      jq -r '.[] | "\(.sig)  \(.status | ascii_upcase)  x\(.count)  last \(.last)  \(.source)/\(.kind)  \(.where)\n    \(.message | .[0:160])\(if (.keys | length) > 0 then "\n    sessions: " + (.keys | join(", ")) else "" end)"' <<< "$rows" ;;
    *) echo "Usage: fxa-sandbox-ctl errors [--all|--json] | show <sig> | resolve <sig> [note]" >&2; return 1 ;;
  esac
}
