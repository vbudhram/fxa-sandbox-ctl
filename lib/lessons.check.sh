#!/usr/bin/env bash
# Offline check for the lessons queue.
#   bash lib/lessons.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_LESSONS_FILE="$tmp/state/lessons.json"
source "$(dirname "$0")/lessons.sh"

check "no lessons: no guide section" "" "$(lessons_approved_md)"
long="$(printf 'x%.0s' $(seq 301))"
in='[{"lesson":"Run stack.sh wait before a functional test.","why":"the auth server takes 90 s"},
 {"lesson":"Use  PLAYWRIGHT_WORKERS=2\u0007 on the runner.","why":"memory"},{"lesson":"short"},
 {"lesson":"a fourth one is cut off by the cap"}]'
check "a lesson over 300 characters is dropped" "0" "$(_lessons_add agent-ab12 '[{"lesson":"'"$long"'"},"junk"]')"
check "valid ones only, the first 3 read" "2" "$(_lessons_add agent-ab12 "$in")"
check "control characters and spaces cleaned" "Use PLAYWRIGHT_WORKERS=2 on the runner." "$(cmd_lessons --json | jq -r '.[1].text')"
check "queued as pending, with the session" "pending|agent-ab12" "$(cmd_lessons --json | jq -r '.[0] | "\(.status)|\(.session)"')"
check "the same lesson again is not queued" "0" "$(_lessons_add agent-cd34 "$in")"
check "not JSON adds nothing" "0" "$(_lessons_add agent-cd34 'nope')"
check "pending ones stay out of the guide" "" "$(lessons_approved_md)"

id="$(cmd_lessons --json | jq -r '.[0].id')"; id2="$(cmd_lessons --json | jq -r '.[1].id')"
check "approve" "approved $id" "$(cmd_lessons approve "$id")"
check "reject" "rejected $id2" "$(cmd_lessons reject "$id2")"
check "approved ones reach the guide" "- Run stack.sh wait before a functional test." "$(lessons_approved_md | grep '^- ')"
cmd_lessons approve "$id" --text "Run stack.sh wait auth before any functional test." >/dev/null
check "approve with edited text" "- Run stack.sh wait auth before any functional test." "$(lessons_approved_md | grep '^- ')"
check "an unknown id is refused" "1" "$(cmd_lessons approve deadbeef 2>/dev/null; echo $?)"
check "a bad id is refused" "1" "$(cmd_lessons approve '../x' 2>/dev/null; echo $?)"
check "too short an edit is refused" "1" "$(cmd_lessons approve "$id" --text "no" 2>/dev/null; echo $?)"

# The runner's file is read once and removed.
_session_sh() { echo "$2" > "$tmp/script"; echo '[{"lesson":"Fetch main by sha when the ref is missing."}]'; }
lessons_collect agent-ef56 runner 2>/dev/null
check "collect queues the runner's lessons" "agent-ef56" "$(cmd_lessons --json | jq -r '.[-1].session')"
check "collect removes the file on the runner" "1" "$(grep -c 'rm -f /workspace/.fxa-lessons.json' "$tmp/script")"
_session_sh() { return 255; }
check "an unreachable runner is not an error" "0" "$(lessons_collect agent-ef56 runner; echo $?)"

# The store gives the same lessons and the same guide section as the file.
if command -v sqlite3 >/dev/null; then
  export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
  _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
  source "$(dirname "$0")/db.sh"; db_init >/dev/null
  _lessons_add agent-db01 '[{"lesson":"Use stack.sh wait before a test, it'"'"'s faster.","why":"x"}]' >/dev/null
  id="$(cmd_lessons --json | jq -r '.[-1].id')"; cmd_lessons approve "$id" >/dev/null
  from_db="$(cmd_lessons --json | jq -S 'map(del(.decided_at))')"; md_db="$(lessons_approved_md)"
  db_on() { return 1; }
  check "lessons: the store equals the file" "$(cmd_lessons --json | jq -S 'map(del(.decided_at))')" "$from_db"
  check "lessons: the same guide section" "$(lessons_approved_md)" "$md_db"
fi
exit $fail
