#!/usr/bin/env bash
# Offline check of cmd_task --source routine (epic i168, slice 2): ctl trusts the claimed run row, not the caller.
#   bash lib/routines-task.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
nohup() { :; }
export FXA_VM_BACKEND=gce FXA_SESSION_MAX=20
A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
cfg() { jq -cn --arg t "${1:-code-review}" '{name: "Code review", template: $t, prompt: "ADMIN-TEXT: review the commits.", schedule: "weekdays 09:00",
  zone: "America/New_York", repos: ["mozilla/PyFxA"], branch: "release-1", channel: "C0OWN00", mode: "report", max_usd: 7, skip_no_commits: true, env: "live"}'; }
heads() { jq -cn --arg s "${1:-$A}" --arg h "${2:-$B}" '{"mozilla/PyFxA": {start: $s, head: $h}}'; }
# run <team> <state> [template] [heads]   A routine and one run row; prints the run id.
run() {
  local rid; rid="$(db_value "INSERT INTO routines (team, data) VALUES ($(db_q "$1"), '{}'); SELECT last_insert_rowid();")"
  db_value "INSERT INTO routine_runs (routine_id, period, state, config, heads) VALUES ($rid, 'p$RANDOM$RANDOM', $(db_q "$2"), $(db_q "$(cfg "${3:-code-review}")"), $(db_q "${4:-$(heads)}")); SELECT last_insert_rowid();"
}
task() { PIPE_PROFILE="$1" PIPE_REPO_SLUG=mozilla/PyFxA cmd_task --source routine --id "$2" "${@:3}"; }
none() { [ -f "$tmp/$1.json" ] && echo "session $1" || echo none; }

r1="$(run pyfxa claimed)"
check "a routine run needs --routine-run, with no session" "ERROR: --source routine needs --routine-run|none" "$(task pyfxa agent-rt01 2>&1)|$(none agent-rt01)"
check "--routine-run needs --source routine" "ERROR: --routine-run needs --source routine" \
  "$(PIPE_PROFILE=pyfxa cmd_task --source slack --id agent-rt02 --owner U1 --prompt-file /dev/null --routine-run "$r1" 2>&1)"
check "a run of another team (--pipeline fxa) is refused, with no session, and the run stays claimed" "ERROR: routine run ${r1} is not a run of team fxa|none|claimed" \
  "$(task fxa agent-rt03 --routine-run "$r1" 2>&1)|$(none agent-rt03)|$(db_value "SELECT state FROM routine_runs WHERE id = $r1;")"
printf 'mine\n' > "$tmp/caller.md"
check "the caller cannot pass the prompt, the owner or the repos" "ERROR: a routine run takes its owner, prompt, repos and connectors from its row, not from options|none" \
  "$(task pyfxa agent-rt04 --routine-run "$r1" --prompt-file "$tmp/caller.md" 2>&1)|$(none agent-rt04)"
r2="$(run pyfxa started)"
check "a run that is not claimed is refused, with no session" "ERROR: routine run ${r2} is not claimed|none" "$(task pyfxa agent-rt05 --routine-run "$r2" 2>&1)|$(none agent-rt05)"
r3="$(run pyfxa claimed code-review '{"mozilla/PyFxA": {"start": null, "head": "$(rm -rf /)"}}')"
check "a run whose head is not a hex SHA is refused, with no session, and stays claimed" "ERROR: routine run ${r3} cannot start: its row is not valid|none|claimed" \
  "$(task pyfxa agent-rt06 --routine-run "$r3" 2>/dev/null; task pyfxa agent-rt06 --routine-run "$r3" 2>&1 | tail -1)|$(none agent-rt06)|$(db_value "SELECT state FROM routine_runs WHERE id = $r3;")"
check "no such run" "ERROR: no routine run 999" "$(task pyfxa agent-rt07 --routine-run 999 2>&1)"

# The good run: what it runs comes from the row.
rid1="$(db_value "SELECT routine_id FROM routine_runs WHERE id = $r1;")"
task pyfxa agent-rt10 --routine-run "$r1" --thread C0OWN00:1790000000.000100 >/dev/null 2>&1
check "the session is a routine session: owner routine:<team>/<id>, untrusted, the routine branch as base, the run and the cap" \
  "routine:pyfxa/${rid1}|routine|1|release-1|${r1}|7|report" \
  "$(jq -r '[.owner, .source, .untrusted, .base, .routine_run, .cap_usd, .routine_mode] | map(tostring) | join("|")' "$tmp/agent-rt10.json")"
check "the run is started by that session" "started|agent-rt10" "$(db_value "SELECT state || '|' || session FROM routine_runs WHERE id = $r1;")"
p="$tmp/agent-rt10.prompt.md"
open="$(grep -o '^<routine-[0-9a-f]\{12\}>$' "$p")"; close="$(grep -o '^</routine-[0-9a-f]\{12\}>$' "$p")"
check "the admin text is inside one nonce fence" "1|1|yes|ADMIN-TEXT: review the commits." \
  "$(grep -c '^<routine-' "$p")|$(grep -c '^</routine-' "$p")|$([ "${close#</}" = "${open#<}" ] && echo yes)|$(sed -n "/^${open}\$/,/^<\\/routine-/p" "$p" | sed -n 2p)"
check "the only commit text is the run's hex SHAs" "- mozilla/PyFxA, branch release-1: ${A}..${B}|0" \
  "$(grep '^- mozilla/PyFxA' "$p")|$(grep -oE '[0-9a-f]{40}' "$p" | grep -cvE "^(${A}|${B})\$")"
check "a code review keeps the team's watch rule and memory" "|" "$(jq -r '"\(.watch_narrow // "")|\(.memory // "")"' "$tmp/agent-rt10.json")"
check "a second caller with the same run is refused, with no session" "ERROR: routine run ${r1} is not claimed|none" \
  "$(task pyfxa agent-rt11 --routine-run "$r1" 2>&1)|$(none agent-rt11)"
# Two callers at once: both read the run while it is claimed; only the guarded UPDATE decides.
r6="$(run pyfxa claimed)"; seen="$(routine_run_read "$r6" pyfxa)"
task pyfxa agent-rt14 --routine-run "$r6" >/dev/null 2>&1
check "two callers at once: the second, whose read saw the run claimed, is refused by the claim, with no session" "ERROR: routine run ${r6} is not claimed|none|agent-rt14" \
  "$(routine_run_read() { printf '%s\n' "$seen"; }; task pyfxa agent-rt15 --routine-run "$r6" 2>&1)|$(none agent-rt15)|$(db_value "SELECT session FROM routine_runs WHERE id = $r6;")"
r4="$(run pyfxa claimed security-review)"
task pyfxa agent-rt12 --routine-run "$r4" >/dev/null 2>&1
check "a security review is narrowed: watch_narrow 1 and memory off" "1|off" "$(jq -r '"\(.watch_narrow)|\(.memory)"' "$tmp/agent-rt12.json")"
r5="$(run pyfxa claimed)"
check "a session that cannot start ends its run failed" "failed|the session could not start|none" \
  "$(task pyfxa agent-rt13 --routine-run "$r5" --runtime nope >/dev/null 2>&1; db_value "SELECT state || '|' || reason FROM routine_runs WHERE id = $r5;")|$(none agent-rt13)"

# The cap: the run's own, at most the host's (D21); a bad one fails.
echo '{"cap_usd": 7}' > "$tmp/agent-cap1.json"; echo '{"cap_usd": 70}' > "$tmp/agent-cap2.json"; echo '{}' > "$tmp/agent-cap3.json"; echo '{"cap_usd": "x"}' > "$tmp/agent-cap4.json"
check "the run cap is min(the run's, the host's), the host's when none, and a bad one fails" "7|50|50|1" \
  "$(_session_run_cap agent-cap1)|$(_session_run_cap agent-cap2)|$(_session_run_cap agent-cap3)|$(_session_run_cap agent-cap4 >/dev/null 2>&1; echo $?)"

exit "$fail"
