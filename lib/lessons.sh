#!/bin/bash
# lessons.sh: what one session learned, for later sessions, once the operator approves it.
#
# Public API:
#   lessons_collect <key> <runner>   read the runner's /workspace/.fxa-lessons.json into the queue
#   lessons_approved_md              the approved lessons as a CLAUDE.md section, or nothing
#   cmd_lessons [--json] | approve <id> [--text <text>] | reject <id>
#
# An agent's lesson can carry text it read from Jira, a PR or the web, so it
# reaches no prompt until a person approves it on the dashboard or here.

[ -n "${_FXA_LESSONS_LOADED:-}" ] && return 0
_FXA_LESSONS_LOADED=1

LESSONS_FILE="${FXA_LESSONS_FILE:-${HOME}/.claude/state/fxa-ai-fixme/lessons.json}"
LESSONS_MAX=30   # approved lessons a runner gets; the newest win

_lessons_all() { [ -s "$LESSONS_FILE" ] && jq -c 'if type == "array" then . else [] end' "$LESSONS_FILE" 2>/dev/null || echo '[]'; }

# ponytail: no lock; a wrap-up and a dashboard tap at the same second can lose one write.
_lessons_save() {
  local t l; t="$(mktemp "${LESSONS_FILE}.XXXXXX")" || return 1
  cat > "$t" && mv "$t" "$LESSONS_FILE" || return 1
  declare -F db_ingest >/dev/null || return 0
  jq -c '.[]' "$LESSONS_FILE" 2>/dev/null | while IFS= read -r l; do db_ingest lessons "$l"; done
}

# _lessons_add <key> <json-array>   Queue each valid {lesson, why} as pending. Prints how many.
_lessons_add() {
  mkdir -p "$(dirname "$LESSONS_FILE")"
  local now new; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  new="$(jq -c --arg k "$1" --arg at "$now" '
    def clean: tostring | gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    [ (if type == "array" then .[:3] else [] end)[]
      | select(type == "object") | {text: (.lesson // "" | clean), why: (.why // "" | clean | .[:300])}
      | select((.text | length) >= 10 and (.text | length) <= 300)
      | . + {session: $k, at: $at, status: "pending"} ]' <<<"$2" 2>/dev/null)" || { echo 0; return 0; }
  local all item id n=0; all="$(_lessons_all)"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    id="$(jq -r .text <<<"$item" | shasum | cut -c1-8)"   # the same lesson twice is one row
    jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$all" >/dev/null && continue
    all="$(jq -c --arg id "$id" --argjson x "$item" '. + [$x + {id: $id}]' <<<"$all")"; n=$((n + 1))
  done < <(jq -c '.[]' <<<"$new")
  [ "$n" -gt 0 ] && printf '%s' "$all" | _lessons_save
  echo "$n"
}

lessons_collect() {
  local raw n
  raw="$(_session_sh "$2" 'head -c 8000 /workspace/.fxa-lessons.json 2>/dev/null; rm -f /workspace/.fxa-lessons.json' 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  n="$(_lessons_add "$1" "$raw")"
  [ "${n:-0}" -gt 0 ] && echo "Queued ${n} lesson(s) for review" >&2
  return 0
}

# _lessons_read   For readers: the store when it is up, else the file (writes go to the file, then the store).
_lessons_read() {
  if declare -F db_on >/dev/null && db_on; then
    db_json "SELECT text, why, session, at, status, id, decided_at FROM lessons ORDER BY rowid;" | jq -c 'map(with_entries(select(.value != null)))'
  else _lessons_all; fi
}

lessons_approved_md() {
  _lessons_read | jq -r --argjson max "$LESSONS_MAX" '
    [ .[] | select(.status == "approved") ] | .[-$max:]
    | if length == 0 then empty else
        "\n# Lessons from earlier sessions\n\nThe operator approved each one. Follow them unless the task says otherwise.\n", (.[] | "- \(.text)")
      end'
}

cmd_lessons() {
  case "${1:-list}" in
    list|--json)
      if [ "${1:-}" = --json ] || [ "${2:-}" = --json ]; then _lessons_read; return 0; fi
      _lessons_all | jq -r '.[] | "\(.id)  \(.status)\t\(.session)  \(.text)"' ;;
    approve|reject)
      local id="${2:-}" text="" status
      [[ "$id" =~ ^[0-9a-f]{8}$ ]] || { echo "usage: lessons $1 <id> [--text <text>]" >&2; return 1; }
      [ "${3:-}" = --text ] && text="$(printf '%s' "${4:-}" | tr -d '\000-\037' | cut -c1-300)"
      [ "$1" = approve ] && status=approved || status=rejected
      _lessons_all | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null || { echo "no lesson $id" >&2; return 1; }
      if [ -n "$text" ] && [ "${#text}" -lt 10 ]; then echo "a lesson needs at least 10 characters" >&2; return 1; fi
      _lessons_all | jq -c --arg id "$id" --arg s "$status" --arg t "$text" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        'map(if .id == $id then . + {status: $s, decided_at: $at} + (if $t != "" then {text: $t} else {} end) else . end)' | _lessons_save
      echo "$status $id" ;;
    *) echo "usage: fxa-sandbox-ctl lessons [--json] | approve <id> [--text <text>] | reject <id>" >&2; return 1 ;;
  esac
}
