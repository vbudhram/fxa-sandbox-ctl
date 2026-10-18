#!/usr/bin/env bash
# Offline check of the routine tick (epic i168, slice 3), on a fixed clock (FXA_ROUTINE_NOW).
#   bash lib/routines-tick.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR" "$FXA_LLM_PROXY_DIR/teams"; : > "$FXA_BOT_ENV"
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
_SESSIONS_PAUSE_URI=""
pipeline_folder_teams() { echo fxa; }
errors_record() { echo "$1|$2|$3|$5" >> "$tmp/errs"; }
_teams_actor() { printf '%s' "${FXA_TEAM_ACTOR:-}"; }
_teams_audit_note() { echo "$1|$2|$3" >> "$tmp/audit"; }
H1="1111111111111111111111111111111111111111"
_routine_head() { cat "$tmp/head" 2>/dev/null || echo "$H1"; }
_routine_team_paused() { return 1; }
_routine_free_slots() { cat "$tmp/free" 2>/dev/null || echo 5; }
T=1792414800   # Monday 2026-10-19 09:00 in New York
# mk <team> [schedule] [extra json]   A routine row (the validator's shape); prints its id.
mk() { local x="${3:-}"; [ -n "$x" ] || x='{}'
  db_value "INSERT INTO routines (team, data) VALUES ($(db_q "$1"), json($(db_q "$(jq -cn --arg s "${2:-daily 09:00}" --argjson x "$x" \
  '{name: "Code review", template: "code-review", prompt: "x", schedule: $s, zone: "America/New_York", repos: ["mozilla/fxa"], channel: "C0OWN00",
    mode: "report", max_usd: 5, skip_no_commits: true, env: "live"} + $x')"))); SELECT last_insert_rowid();"; }
tick() { FXA_ROUTINE_NOW="$1" routine_tick --env live; }
rows() { db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $1;"; }

# Two ticks at once, and one a minute later: one run, one row (D15).
r1="$(mk fxa)"
( tick $((T + 30)) > "$tmp/t1" ) & ( tick $((T + 30)) > "$tmp/t2" ) & wait
tick $((T + 90)) > "$tmp/t3"
check "two ticks at once and one a minute later answer one run, with one row" "1|1" \
  "$(cat "$tmp/t1" "$tmp/t2" "$tmp/t3" | jq -s '[.[].runs[]] | length')|$(rows "$r1")"
check "the heartbeat is the last tick's time" "$((T + 90))" "$(db_value "SELECT at FROM routine_tick;")"
check "the claimed run has the config snapshot and heads in slice 2's format" "claimed|x|$H1|null" \
  "$(db_value "SELECT state || '|' || json_extract(config, '$.prompt') || '|' || json_extract(heads, '$.\"mozilla/fxa\".head') || '|' || coalesce(json_extract(heads, '$.\"mozilla/fxa\".start'), 'null') FROM routine_runs WHERE routine_id = $r1;")"
# The second of two ticks read the period as free (a count read before the first one's INSERT): its INSERT OR
# IGNORE writes nothing, so it answers nothing.
check "a tick whose free read raced another's claim answers nothing for that routine, run or skip" "0|1" \
  "$(db_value() { case "$1" in ("SELECT count(*) FROM routine_runs WHERE routine_id = $r1 AND period"*) echo 0 ;; (*) _db -list "$1" ;; esac; }; tick $((T + 100)) | jq --argjson r "$r1" '[.runs[], .skips[] | select(.routine == $r)] | length')|$(rows "$r1")"
db_exec "UPDATE routine_runs SET state = 'ok';"

# A late period is missed, not run (D17).
r2="$(mk fxa "daily 07:59")"
check "a 61-min-old period answers no run and writes one missed row" "0|missed" \
  "$(tick $((T + 60)) | jq '.runs | length')|$(db_value "SELECT group_concat(state) FROM routine_runs WHERE routine_id = $r2;")"

# A routine of a team that is gone is never claimed and records nothing.
r3="$(mk ghost)"
check "a team with no record (and not a folder team) records nothing" "0" "$(tick $((T + 60)) >/dev/null; rows "$r3")"

# Gates skip with a reason and the next run time; a disabled team and a team at its daily cap.
echo '{"name":"drafty","status":"draft"}' > "$FXA_TEAMS_DIR/drafty.json"
echo '{"name":"spendy","status":"active"}' > "$FXA_TEAMS_DIR/spendy.json"
echo '{"day_usd": 10}' > "$FXA_LLM_PROXY_DIR/teams/spendy.json"
echo "{\"day\": \"2026-10-19\", \"day_usd\": 12, \"month\": \"2026-10\", \"month_usd\": 12}" > "$FXA_LLM_PROXY_DIR/teams/spendy.spend.json"
r4="$(mk drafty)"; r5="$(mk spendy)"
out="$(tick $((T + 60)))"
check "a disabled team and a team at its daily cap: skipped with the reason, the next run time, post true, and no run" \
  "the team is not active|true|1792501200|the team reached its daily spend cap|true|0" \
  "$(jq -r --argjson a "$r4" --argjson b "$r5" '[(.skips[] | select(.routine == $a) | .reason, .post, .next), (.skips[] | select(.routine == $b) | .reason, .post), (.runs | length)] | map(tostring) | join("|")' <<< "$out")"
echo 'not json' > "$FXA_LLM_PROXY_DIR/teams/spendy.spend.json"
check "a spend file that cannot be read skips (fail closed)" "the team's spend cannot be read" \
  "$(tick $((T + 86400 + 60)) | jq -r --argjson b "$r5" '.skips[] | select(.routine == $b) | .reason')"

# No new commits on three days: post on day 1; day 1's post is marked; days 2 and 3 stay quiet.
r6="$(mk fxa "daily 10:00")"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, started_at) VALUES ($r6, '2026-10-18', 'ok', json('{\"mozilla/fxa\": {\"start\": null, \"head\": \"$H1\"}}'), $((T - 86400)));"
d1="$(tick $((T + 3600 + 60)))"; s1="$(jq -r --argjson r "$r6" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)|\(.run)"' <<< "$d1")"
db_exec "UPDATE routine_runs SET posted = 1 WHERE id = ${s1##*|};"
d2="$(tick $((T + 86400 + 3600 + 60)))"; d3="$(tick $((T + 2 * 86400 + 3600 + 60)))"
check "no new commits: post true on day 1, false on day 2, false on day 3 (day 1 was posted)" \
  "no new commits since the last run|true|false|false" \
  "${s1%|*}|$(jq -r --argjson r "$r6" '.skips[] | select(.routine == $r) | .post' <<< "$d2")|$(jq -r --argjson r "$r6" '.skips[] | select(.routine == $r) | .post' <<< "$d3")"

# A routine an admin paused: skipped, and not posted.
r7="$(mk fxa "daily 11:00")"; db_exec "UPDATE routines SET paused = 1 WHERE id = $r7;"
check "a paused routine is skipped with post false" "the routine is paused|false" \
  "$(tick $((T + 7200 + 60)) | jq -r --argjson r "$r7" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)"')"
# A head that cannot be read: skipped, never run (fail closed).
r8="$(mk fxa "daily 12:00")"; _routine_head() { return 1; }
check "a head that cannot be read is skipped" "cannot read the branch head|0" \
  "$(tick $((T + 10800 + 60)) | jq -r --argjson r "$r8" '"\(.skips[] | select(.routine == $r) | .reason)|\(.runs | length)"')"
_routine_head() { cat "$tmp/head" 2>/dev/null || echo "$H1"; }

# A run waits for a slot: unclaimed for 20 min, then starts; another's slots stay full and it fails at 30 min (D16).
r9="$(mk fxa "daily 13:00")"; echo 1 > "$tmp/free"
check "a run with no free slot stays unclaimed at 20 min" "0|0" "$(tick $((T + 14400 + 1200)) | jq '.runs | length')|$(rows "$r9")"
echo 5 > "$tmp/free"
check "then starts when slots are free, and is not failed" "1|claimed" \
  "$(tick $((T + 14400 + 1260)) | jq --argjson r "$r9" '[.runs[] | select(.routine == $r)] | length')|$(db_value "SELECT state FROM routine_runs WHERE routine_id = $r9;")"
r10="$(mk fxa "daily 14:00")"; echo 1 > "$tmp/free"
tick $((T + 18000 + 1200)) >/dev/null
p10="$(tick $((T + 18000 + 1860)) | jq -r --argjson r "$r10" '.skips[] | select(.routine == $r) | .post')"
check "slots full for 31 min: failed 'no runner free', in the skips with post true" "failed|no runner free|true" \
  "$(db_value "SELECT state || '|' || reason FROM routine_runs WHERE routine_id = $r10;")|$p10"
echo 5 > "$tmp/free"

# DST: 01:30 and 02:30 daily run once each date; 02:30 on 2027-03-14 starts at 03:00, the first valid minute.
python3 -I - "$SANDBOX_ROOT/lib" <<'PY' > "$tmp/dst"
import sys; sys.path.insert(0, sys.argv[1]); import routine
for sched, start in (("daily 01:30", 1793505600), ("daily 02:30", 1793505600), ("daily 01:30", 1805000400), ("daily 02:30", 1805000400)):
    r = {"schedule": sched, "zone": "America/New_York"}
    seen = {}
    for now in range(start, start + 2 * 86400, 60):  # every minute for two days around the change
        d = routine.due(r, now)
        if d and now - d["at"] <= 3600:
            seen.setdefault(d["period"], set()).add(d["at"])
    print(sched, " ".join(f"{p}:{len(a)}" for p, a in sorted(seen.items())), routine.due(r, 1805011200 + 3600)["at"] if sched == "daily 02:30" and start == 1805000400 else "")
PY
check "the DST walk: one run time for each date, both ways" "2026-11-01:1 2026-11-02:1|2026-11-01:1 2026-11-02:1|2027-03-14:1 2027-03-15:1|2027-03-14:1 2027-03-15:1" \
  "$(sed -E 's/^daily [0-9:]+ //; s/ [0-9]*$//' "$tmp/dst" | paste -sd'|' -)"
check "the 02:30 run on 2027-03-14 is at 03:00 New York time, the first valid minute" "1805007600" "$(sed -n 4p "$tmp/dst" | awk '{print $NF}')"
r11="$(mk fxa "daily 01:30")"
tick 1793511060 >/dev/null; tick 1793514660 >/dev/null   # 01:31 EDT, then 01:31 EST: the same date
check "a tick in each 01:30 of the DST fold claims one run for the date" "1" "$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $r11 AND period = '2026-11-01';")"

# Reconcile (D14): runs the bot never reported on still end, from their session records.
: > "$tmp/errs"
# It reads stdin, as GCE ssh does: reconcile must not let it eat the rows still to read.
session_stop() { cat >/dev/null 2>&1 || true; echo "$1" >> "$tmp/stopped"; session_set "$1" state stopped; }; : > "$tmp/stopped"
rr="$(mk fxa "weekly sun 03:00")"
st() { db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rr, 'r$RANDOM$RANDOM', $(db_q "$1"), $( [ -n "$2" ] && db_q "$2" || echo NULL ), $3); SELECT last_insert_rowid();"; }
N=$((T + 50000))
g1="$(st started agent-gone01 $((N - 60)))"
echo '{"key":"agent-paus01","state":"paused"}' > "$tmp/agent-paus01.json"; g2="$(st started agent-paus01 $((N - 60)))"
echo '{"key":"agent-prok01","state":"pr_open","pr_url":"https://github.com/mozilla/fxa/pull/7"}' > "$tmp/agent-prok01.json"; g3="$(st started agent-prok01 $((N - 60)))"
echo '{"key":"agent-long01","state":"active"}' > "$tmp/agent-long01.json"; g4="$(st started agent-long01 $((N - 7300)))"
echo '{"key":"agent-fine01","state":"active"}' > "$tmp/agent-fine01.json"; g5="$(st started agent-fine01 $((N - 60)))"
g6="$(st claimed "" $((N - 660)))"; g7="$(st claimed "" $((N - 540)))"
echo 'not json' > "$tmp/agent-junk01.json"; g8="$(st started agent-junk01 $((N - 60)))"
tick "$N" >/dev/null; tick $((N + 30)) >/dev/null
s_of() { db_value "SELECT state || '|' || coalesce(reason, pr_url, '') FROM routine_runs WHERE id = $1;"; }
check "a started run whose session is gone fails, with one error row" "failed|the run's session is gone|1" \
  "$(s_of "$g1")|$(grep -c "routine run ${g1}: " "$tmp/errs")"
check "a started run whose session paused is stopped and fails, with one error row" "failed|the session paused with no result|agent-paus01|1" \
  "$(s_of "$g2")|$(cat "$tmp/stopped" | grep -x agent-paus01)|$(grep -c "routine run ${g2}: " "$tmp/errs")"
check "a session at pr_open with a pr_url: the run is ok with that PR, and no error" "ok|https://github.com/mozilla/fxa/pull/7|0" \
  "$(s_of "$g3")|$(grep -c "routine run ${g3}: " "$tmp/errs")"
check "a started run past 120 min is stopped and fails" "failed|the run took over 120 min|agent-long01" "$(s_of "$g4")|$(grep -x agent-long01 "$tmp/stopped")"
check "a recent active run is left alone" "started|" "$(s_of "$g5")"
check "a claimed run with no session after 11 min fails; one after 9 min waits" "failed|no session started within 10 min|claimed|" "$(s_of "$g6")|$(s_of "$g7")"
check "a session record that cannot be read fails the run (fail closed)" "failed|the run's session record cannot be read" "$(s_of "$g8")"

# A done call that lands between reconcile's read and its UPDATE wins: the run stays ok, with no error row.
g9="$(st ok agent-gone02 $((N - 60)))"; n0="$(wc -l < "$tmp/errs" | tr -d ' ')"
stale="[{\"id\": $g9, \"state\": \"started\", \"session\": \"agent-gone02\", \"since\": $((N - 60))}]"
( db_json() { case "$1" in ("SELECT id, state, coalesce(session"*) echo "$stale" ;; (*) _db_ready && _db -json "$1" | sed 's/^$/[]/' ;; esac; }; routine_reconcile "$N" )
check "reconcile does not undo a done call that raced it" "ok||$n0" "$(s_of "$g9")|$(wc -l < "$tmp/errs" | tr -d ' ')"

# routine done: idempotent, the cost from the run's token, and the PII guard on a report (D10).
mkdir -p "$FXA_LLM_PROXY_DIR/runs" "$FXA_LLM_PROXY_DIR/tokens"
TOK="fxl_$(printf 'a%.0s' $(seq 32))"
echo "$TOK" > "$FXA_LLM_PROXY_DIR/runs/$(worktree_branch_for agent-done01)"; echo '{"spent_usd": 1.25}' > "$FXA_LLM_PROXY_DIR/tokens/$TOK.json"
d1="$(st started agent-done01 $((N - 60)))"
printf 'Finding: the handler logs user@example.com and ghp_abcdefghijklmnop1234 in plain text.\n' > "$tmp/report.md"
a1="$(FXA_ROUTINE_NOW=$N routine_done "$d1" --state report --session agent-done01 --report-file "$tmp/report.md")"
check "a report with an email and a token: post false, and the row keeps the report and the cost" "true|report|false|1|1.25" \
  "$(jq -r '"\(.changed)|\(.state)|\(.post)"' <<< "$a1")|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $d1 AND report LIKE '%ghp_abcdef%';")|$(db_value "SELECT cost_usd FROM routine_runs WHERE id = $d1;")"
a2="$(FXA_ROUTINE_NOW=$((N + 9)) routine_done "$d1" --state failed --session agent-done01 --reason "late")"
check "a second done call changes nothing" "false|report|false|report||$N" \
  "$(jq -r '"\(.changed)|\(.state)|\(.post)"' <<< "$a2")|$(db_value "SELECT state || '|' || coalesce(reason, '') || '|' || ended_at FROM routine_runs WHERE id = $d1;")"
d2="$(st started agent-done02 $((N - 60)))"; printf 'No issue found in 6 commits.\n' > "$tmp/clean.md"
check "a clean report posts" "true" "$(FXA_ROUTINE_NOW=$N routine_done "$d2" --state report --session agent-done02 --report-file "$tmp/clean.md" | jq -r .post)"
d3="$(st started agent-done03 $((N - 60)))"
check "done for another session's run is refused, and the run stays started" "ERROR: routine run ${d3} is not session agent-other1's|started" \
  "$(routine_done "$d3" --state ok --session agent-other1 2>&1)|$(db_value "SELECT state FROM routine_runs WHERE id = $d3;")"
check "done after the tick failed the run changes nothing" "false|failed" "$(routine_done "$g1" --state ok --session agent-gone01 | jq -r '"\(.changed)|\(.state)"')"
check "a bad --state is refused" "ERROR: --state must be ok, report, nochange, failed or stopped" "$(routine_done "$d3" --state merged --session agent-done03 2>&1)"
got="$(db_value() { case "$1" in (UPDATE*) return 1 ;; (*) _db -list "$1" ;; esac; }; routine_done "$d3" --state ok --session agent-done03 2>&1)"
check "a store error in done is the store line" "ERROR: the routine store did not answer (busy or failed); nothing changed, try again|started" "$got|$(db_value "SELECT state FROM routine_runs WHERE id = $d3;")"
# routine posted: only a skip or a failure.
sk="$(db_value "SELECT id FROM routine_runs WHERE state = 'skipped' AND posted = 0 LIMIT 1;")"
check "posted marks a skip; a started run is refused" "posted ${sk}|1|ERROR: routine run ${d3} is not a skip or a failure" \
  "$(routine_posted "$sk")|$(db_value "SELECT posted FROM routine_runs WHERE id = $sk;")|$(routine_posted "$d3" 2>&1)"

# Run now and Stop: a queued manual run that the next tick hands out once; Stop stops the row, then the session.
: > "$tmp/audit"; rn="$(mk fxa "weekly sat 23:00")"
q1="$(FXA_ROUTINE_NOW=$N FXA_TEAM_ACTOR=admin@example.com routine_runnow fxa "$rn")"
qid="$(db_value "SELECT id FROM routine_runs WHERE routine_id = $rn;")"
check "run-now queues a manual run, by that admin, with an audit row" "queued run ${qid}: it starts within a minute|queued|manual-${N}|admin@example.com|routine-run|fxa|routine ${rn}: run ${qid}" \
  "$q1|$(db_value "SELECT state || '|' || period || '|' || actor FROM routine_runs WHERE id = $qid;")|$(tail -1 "$tmp/audit")"
check "run-now with a run already live is refused" "ERROR: a run of routine ${rn} is in progress" "$(FXA_ROUTINE_NOW=$((N + 60)) routine_runnow fxa "$rn" 2>&1)"
check "run-now of another team's routine is refused" "ERROR: team drafty has no routine ${rn}" "$(routine_runnow drafty "$rn" 2>&1)"
( tick $((N + 20)) > "$tmp/m1" ) & ( tick $((N + 20)) > "$tmp/m2" ) & wait
check "two ticks hand the queued run to the bot once, as claimed" "1|claimed" \
  "$(cat "$tmp/m1" "$tmp/m2" | jq -s --argjson q "$qid" '[.[].runs[] | select(.run == $q)] | length')|$(db_value "SELECT state FROM routine_runs WHERE id = $qid;")"
: > "$tmp/stopped"
db_exec "UPDATE routine_runs SET state = 'started', session = 'agent-stop01' WHERE id = $qid;"; echo '{"key":"agent-stop01","state":"active"}' > "$tmp/agent-stop01.json"
check "stop records stopped with an audit row, then stops the session" "stopped run ${qid}|stopped|stopped by a team admin|routine-stop|agent-stop01" \
  "$(FXA_ROUTINE_NOW=$((N + 120)) routine_stop fxa "$rn")|$(db_value "SELECT state || '|' || reason FROM routine_runs WHERE id = $qid;")|$(tail -1 "$tmp/audit" | cut -d'|' -f1)|$(cat "$tmp/stopped")"
check "stop with no live run is refused" "ERROR: no run of routine ${rn} is in progress" "$(routine_stop fxa "$rn" 2>&1)"
# Two admins stop at once: the second's read saw the run live, but its guarded UPDATE stops nothing.
FXA_ROUTINE_NOW=$((N + 180)) routine_runnow fxa "$rn" >/dev/null; q2="$(db_value "SELECT max(id) FROM routine_runs WHERE routine_id = $rn;")"
seen="$(db_json "SELECT id, state, coalesce(session, '') AS session FROM routine_runs WHERE id = $q2;")"; routine_stop fxa "$rn" >/dev/null; : > "$tmp/stopped"
got="$(db_json() { case "$1" in ("SELECT id, state, coalesce(session"*) echo "$seen" ;; (*) _db_ready && _db -json "$1" | sed 's/^$/[]/' ;; esac; }; routine_stop fxa "$rn" 2>&1)"
check "two admins stop at once: the second stops nothing and audits nothing (two real stops, two rows)" "ERROR: no run of routine ${rn} is in progress|2" "$got|$(grep -c '^routine-stop' "$tmp/audit")"
check "run-now on a team at its cap is refused, with no row" "ERROR: routine ${r5} cannot run now: the team's spend cannot be read|0" \
  "$(routine_runnow spendy "$r5" 2>&1)|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $r5 AND trigger = 'manual';")"

# Stop then Run now in the same minute: no period clash (epoch seconds).
FXA_ROUTINE_NOW=$((N + 300)) routine_runnow fxa "$rn" >/dev/null; FXA_ROUTINE_NOW=$((N + 301)) routine_stop fxa "$rn" >/dev/null
check "stop then run now in the same minute queues a new run" "queued" \
  "$(FXA_ROUTINE_NOW=$((N + 330)) routine_runnow fxa "$rn" >/dev/null; db_value "SELECT state FROM routine_runs WHERE routine_id = $rn ORDER BY id DESC LIMIT 1;")"
FXA_ROUTINE_NOW=$((N + 340)) routine_stop fxa "$rn" >/dev/null
check "a run now in the same second as the last one says try again, not in progress" "ERROR: routine ${rn} ran in this same second; try again in a second" \
  "$(FXA_ROUTINE_NOW=$((N + 330)) routine_runnow fxa "$rn" 2>&1)"
# A queued run waits for a slot too, and takes one.
FXA_ROUTINE_NOW=$((N + 400)) routine_runnow fxa "$rn" >/dev/null; qw="$(db_value "SELECT max(id) FROM routine_runs WHERE routine_id = $rn;")"
echo 1 > "$tmp/free"
check "a queued run waits while slots are full" "queued" "$(tick $((N + 420)) >/dev/null; db_value "SELECT state FROM routine_runs WHERE id = $qw;")"
echo 5 > "$tmp/free"; tick $((N + 480)) >/dev/null; routine_stop fxa "$rn" >/dev/null
# 'queued' is live for delete, the team drop and routine_run_fail.
FXA_ROUTINE_NOW=$((N + 500)) routine_runnow fxa "$rn" >/dev/null; qd="$(db_value "SELECT max(id) FROM routine_runs WHERE routine_id = $rn;")"
check "delete is refused while a queued run waits" "ERROR: a run of routine ${rn} is in progress; stop it first" "$(routine_state fxa "$rn" delete 2>&1)"
check "the team drop is refused while a queued run waits" "ERROR: team fxa has a routine run in progress; stop it first" "$(routines_drop_team fxa 2>&1)"
routine_run_fail "$qd" "x"
check "routine_run_fail ends a queued run" "failed|x" "$(db_value "SELECT state || '|' || reason FROM routine_runs WHERE id = $qd;")"
# Reconcile: a live session with a pr_url is still the bot's (it calls done); a stopped one with no result fails.
echo '{"key":"agent-prlv01","state":"active","pr_url":"https://github.com/mozilla/fxa/pull/8"}' > "$tmp/agent-prlv01.json"; g10="$(st started agent-prlv01 $((N - 60)))"
echo '{"key":"agent-stpd01","state":"stopped"}' > "$tmp/agent-stpd01.json"; g11="$(st started agent-stpd01 $((N - 60)))"
routine_reconcile "$N"
check "a live session with a PR stays started for the bot's done call; a stopped one with no result fails" "started||failed|the session stopped with no result" \
  "$(s_of "$g10")|$(s_of "$g11")"
check "the bot's done call then stores its report and cost on that run" "true|report|1" \
  "$(routine_done "$g10" --state report --session agent-prlv01 --report-file "$tmp/clean.md" | jq -r '"\(.changed)|\(.state)"')|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $g10 AND report IS NOT NULL;")"
# budget: any wrong shape fails closed.
for bad in 'null' '[1]' '{"day_usd": "ten"}' '{"day_usd": true}'; do
  echo "$bad" > "$tmp/caps.json"; echo '{}' > "$tmp/spend.json"
  check "budget: caps $bad cannot be read" "the team's spend cannot be read" "$(python3 -I "$SANDBOX_ROOT/lib/routine.py" budget "$tmp/caps.json" "$tmp/spend.json" "$N")"
done
echo '{"day_usd": 10}' > "$tmp/caps.json"; echo '{"day": "2026-10-20", "day_usd": "x"}' > "$tmp/spend.json"
check "budget: a spend that is not a number cannot be read" "the team's spend cannot be read" "$(python3 -I "$SANDBOX_ROOT/lib/routine.py" budget "$tmp/caps.json" "$tmp/spend.json" 1792501200)"
# A routine saved after today's time runs at the next one, with no missed row for a period before it.
rs="$(mk fxa "daily 06:00")"; db_exec "UPDATE routines SET saved_at = $((T + 60)) WHERE id = $rs;"
check "a routine saved after today's time records nothing today" "0|0" "$(tick $((T + 120)) | jq --argjson r "$rs" '[.runs[], .skips[] | select(.routine == $r)] | length')|$(rows "$rs")"
check "and runs at the next day's time" "1" "$(tick $((T + 86400 - 3 * 3600 + 30)) | jq --argjson r "$rs" '[.runs[] | select(.routine == $r)] | length')"

# done: a report that cannot be written for the PII guard is not scanned, so it is not posted.
d9="$(st started agent-jqf001 $((N - 60)))"
check "a report the guard cannot read is not posted" "true|false" \
  "$(jq() { case "$*" in (*'{report: $t}'*) return 1 ;; (*) command jq "$@" ;; esac; }; routine_done "$d9" --state report --session agent-jqf001 --report-file "$tmp/clean.md" | command jq -r '"\(.changed)|\(.post)"')"
# The claim checks for a live run in the same statement: a gate read that raced a run-now claims nothing.
echo '{"key":"agent-live01","state":"active"}' > "$tmp/agent-live01.json"
rl="$(mk fxa "daily 15:00")"; db_exec "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rl, 'manual-1', 'started', 'agent-live01', $((T + 21600)));"
got="$(db_value() { case "$1" in ("SELECT count(*) FROM routine_runs WHERE routine_id = $rl AND state IN"*) echo 0 ;; (*) _db -list "$1" ;; esac; }; tick $((T + 21600 + 60)) | jq --argjson r "$rl" '[.runs[] | select(.routine == $r)] | length')"
check "a scheduled claim with a run of the routine live claims nothing" "0|0" "$got|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rl AND state = 'claimed';")"
db_exec "INSERT INTO routine_runs (routine_id, period, state, started_at) VALUES ($rl, 'manual-2', 'queued', $((T + 21600)));"
check "a queued run is not handed out while another run of the routine is live" "queued" \
  "$(tick $((T + 21600 + 120)) >/dev/null; db_value "SELECT state FROM routine_runs WHERE routine_id = $rl AND period = 'manual-2';")"
# The start comes only from a run with a result: a stopped run does not make the next run skip.
rp="$(mk fxa "daily 16:00")"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, started_at) VALUES ($rp, '2026-10-18', 'stopped', json('{\"mozilla/fxa\": {\"start\": null, \"head\": \"$H1\"}}'), $((T - 86400)));"
check "after a stopped run with the same head, the next run still runs, from no start" "1|null" \
  "$(tick $((T + 25200 + 60)) | jq --argjson r "$rp" '[.runs[] | select(.routine == $r)] | length')|$(db_value "SELECT coalesce(json_extract(heads, '$.\"mozilla/fxa\".start'), 'null') FROM routine_runs WHERE routine_id = $rp AND state = 'claimed';")"
# A store error is no answer, not a domain error.
got="$(db_exec() { return 1; }; tick $T 2>"$tmp/err")"; rc=$?
check "a store error: exit 1, the store line, and no answer" "1|ERROR: the routine store did not answer (busy or failed); nothing changed, try again|" "$rc|$(cat "$tmp/err")|$got"

exit "$fail"
