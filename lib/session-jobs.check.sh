#!/usr/bin/env bash
# Offline check for the background job registry: a job the host saw run that ends gives a job_done event and a
# masked, fenced host note whose turn has no admin, at most twice for each human message; on Linux the runner
# script counts only a live pid of this uid with the recorded start time.
#   bash lib/session-jobs.check.sh
source "$(dirname "$0")/session-check-head.sh"
ws="$tmp/ws"; mkdir -p "$ws/.fxa-jobs"
SECRET="hunter2-team-secret"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }
_session_sh_in() { bash -c "${4//\/workspace/$ws}" | head -c "$3"; }
echo "1234 1000 $ws/log" > "$ws/.fxa-jobs/functional"
printf 'PASS one\npassword %s\n' "$SECRET" > "$ws/log"
k=agent-job1; echo "{\"key\":\"$k\",\"state\":\"active\",\"runtime\":\"claude\",\"turn_open\":\"0\"}" > "$SESSION_DIR/$k.json"
q="$SESSION_DIR/$k.queue"

check "a running job: no event, the host keeps it" "[]|functional:1234:1000" \
  "$(_session_jobs $k '@@job functional 1234 1000 1')|$(session_get $k jobs_seen)"
check "a job never seen running gives nothing" "[]" "$(_session_jobs $k '@@job functional 1234 1000 1
@@job other 77 1000 0')"
out="$(_session_jobs $k '@@job functional 1234 1000 0')"
check "the job ends: one job_done event that starts a turn" "job_done|functional|true" "$(jq -r '.[] | "\(.type)|\(.name)|\(.turn)"' <<< "$out")"
check "the note has the log tail, masked and fenced" "1|0|1|2" \
  "$(grep -c 'PASS one' "$q")|$(grep -c "$SECRET" "$q")|$(grep -c '<masked>' "$q")|$(grep -cE '^<<</?JOB-[0-9a-f]+>>>$' "$q")"
check "the note's turn has no admin" "0|host" "$(session_get $k q_admin)|$(session_get $k q_asker)"
check "the history says it ended, and the host forgets it" "Background job functional ended|" \
  "$(jq -r 'select(.role == "action") | .text' "$SESSION_DIR/$k.history.jsonl")|$(session_get $k jobs_seen)"

again() { _session_jobs $k "@@job functional $1 1000 1" >/dev/null; _session_jobs $k "@@job functional $1 1000 0"; }
check "a second ended job starts a second turn" "true" "$(again 1235 | jq -r '.[0].turn')"
n="$(wc -l < "$q" | tr -d " ")"
check "a third gives only the event: no turn until a person writes" "false|$n" "$(again 1236 | jq -r '.[0].turn')|$(wc -l < "$q" | tr -d ' ')"
_session_turn() { :; }
echo "go on" > "$tmp/msg"; cmd_steer $k --message-file "$tmp/msg" >/dev/null
check "a person's message starts the count again" "0|true" "$(session_get $k job_notes)|$(again 1237 | jq -r '.[0].turn')"

_session_jobs $k '@@job functional 1238 1000 1' >/dev/null; session_set $k turn_open 1
n="$(wc -l < "$q" | tr -d " ")"
check "a job that ends in an open turn (run.sh wait reads it): no event, no note" "[]|$n" \
  "$(_session_jobs $k '@@job functional 1238 1000 0')|$(wc -l < "$q" | tr -d ' ')"
session_set $k turn_open 0
_session_jobs $k '@@job functional 1238 1000 1' >/dev/null
check "a job past 2 h is dropped with no notice" "[]|" "$(_session_jobs $k '@@job functional 1238 1000 2')|$(session_get $k jobs_seen)"
check "a bad line is ignored" "[]|" "$(_session_jobs $k '@@job ../x 1 1 1
@@job f 0 1 1
@@run 1')|$(session_get $k jobs_seen)"

# cmd_events: the job lines come before the count line and are not transcript lines.
_session_jobs $k '@@job functional 1239 1000 1' >/dev/null
vm_exec_as_agent() { printf '@@job functional 1239 1000 0\n@@run 0\n{"type":"system","subtype":"init","session_id":"s1-abcdefgh"}\n'; }
_session_end_facts() { printf '\t\n'; }
out="$(cmd_events $k --since 0)"
check "events carries the job_done event, and the cursor counts only the transcript" "job_done|1" \
  "$(jq -r '[.events[] | select(.type == "job_done")][0].type' <<< "$out")|$(jq .cursor <<< "$out")"

if [ -d /proc/self/fd ] && command -v pgrep >/dev/null; then
  sleep 300 & live=$!; sleep 0.1 & dead=$!; wait "$dead"; sleep 1
  st=$(( $(date +%s) - $(ps -o etimes= -p "$live" | tr -d ' ') ))
  rm -f "$ws/.fxa-jobs"/*
  echo "$live $st $ws/log" > "$ws/.fxa-jobs/a"; echo "$live $(( st - 600 )) $ws/log" > "$ws/.fxa-jobs/b"
  echo "$dead $st $ws/log" > "$ws/.fxa-jobs/c"; echo "$live $st" > "$ws/.fxa-jobs/d"
  jobs_as() { bash -c "$(sed -e "s#/workspace#$ws#g" -e "s#-u agent#-u $1#" <<< "$_SESSION_JOBS")" | awk '{print $2, $5}' | paste -sd'|' -; }
  check "only a live pid with its recorded start counts, and at most 3 jobs" "a 1|b 0|c 0" "$(jobs_as "$(id -un)")"
  check "a pid of another uid never counts" "a 0|b 0|c 0" "$(jobs_as nobody)"
  kill "$live" 2>/dev/null
else
  echo "skip the runner script check: it needs Linux /proc"
fi
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
