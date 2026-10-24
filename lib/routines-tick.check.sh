#!/usr/bin/env bash
# Offline check of the routine tick (epic i168, slice 3), on a fixed clock (FXA_ROUTINE_NOW).
#   bash lib/routines-tick.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR" "$FXA_LLM_PROXY_DIR/teams"; echo "PROFILE_CHANNELS=C0OWN00:fxa" > "$FXA_BOT_ENV"; echo '{"teams": {}}' > "$FXA_TEAMS_DIR/index.json"
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
# The team's profile as the validator reads it, for the tick's D8 check of the saved routine.
OPEN='{"private": false, "read_only": false, "repos": [{"slug": "mozilla/fxa", "role": "work"}]}'
PRIV='{"private": true, "read_only": false, "repos": [{"slug": "mozilla/fxa", "role": "work"}]}'
_routine_profile() { echo "$OPEN"; }
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
check "the heartbeat is the last tick's time" "$((T + 90))" "$(db_value "SELECT at FROM routine_tick_env WHERE env = 'live';")"
FXA_ROUTINE_NOW=$((T + 95)) routine_tick --env dev >/dev/null
check "a dev tick moves only the dev heartbeat" "$((T + 90))|$((T + 95))" "$(db_value "SELECT group_concat(at, '|') FROM (SELECT at FROM routine_tick_env ORDER BY env = 'dev');")"
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
r4="$(mk drafty "daily 09:00" '{"channel": "C0DRAFT"}')"; r5="$(mk spendy "daily 09:00" '{"channel": "C0SPEND"}')"
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
touch -t 202001010000 "$tmp/agent-prok01.json"   # ended long before N: the 10-min grace reads the record's mtime, a real clock
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
( db_json() { case "$1" in ("SELECT r.id AS id"*) echo "$stale" ;; (*) _db_ready && _db -json "$1" | sed 's/^$/[]/' ;; esac; }; routine_reconcile "$N" live )
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
check "History shows the held report and why it was held" "true|kept off Slack: it may hold personal data or a secret" \
  "$(routine_history fxa "$rr" | jq -r --argjson d "$d1" '.[] | select(.id == $d) | "\(.report | contains("ghp_abcdef"))|\(.reason)"')"
a2="$(FXA_ROUTINE_NOW=$((N + 9)) routine_done "$d1" --state failed --session agent-done01 --reason "late")"
check "a second done call changes nothing" "false|report|false|report|kept off Slack: it may hold personal data or a secret|$N" \
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
check "run-now queues a manual run, by that admin, with an audit row" "queued run ${qid}: it starts when a runner is free, within 60 min|queued|manual-${N}|admin@example.com|routine-run|fxa|routine ${rn}: run ${qid}" \
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
touch -t 202001010000 "$tmp/agent-stpd01.json"
routine_reconcile "$N" live
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
# Reconcile waits 10 min after a session ends, so a late done still lands; after that it fails the run.
NOWR="$(date +%s)"
echo '{"key":"agent-late01","state":"stopped"}' > "$tmp/agent-late01.json"; gl="$(st started agent-late01 $((NOWR - 60)))"
routine_reconcile "$NOWR" live
check "a session stopped just now keeps its run started" "started|" "$(s_of "$gl")"
check "and the bot's late done stores its report" "true|report|1" \
  "$(routine_done "$gl" --state report --session agent-late01 --report-file "$tmp/clean.md" | jq -r '"\(.changed)|\(.state)"')|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $gl AND report IS NOT NULL;")"
echo '{"key":"agent-late02","state":"stopped"}' > "$tmp/agent-late02.json"; gm="$(st started agent-late02 $((NOWR - 60)))"
# Its write time is NOWR, not the real clock: on a loaded host the write lands a second or more after NOWR.
perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$NOWR" "$tmp/agent-late02.json"
routine_reconcile $((NOWR + 601)) live
check "10 min after the session stopped, reconcile fails the run" "failed|the session stopped with no result" "$(s_of "$gm")"

# What the bot posts and checks comes with each run: name, mode, template, repos, branch, the team's private
# flag (true when the team does not load: fail closed), and the start of the last run with a result.
ri="$(mk fxa "daily 20:00" '{"branch": "main"}')"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, started_at) VALUES ($ri, '2026-10-18', 'ok', json('{\"mozilla/fxa\": {\"start\": null, \"head\": \"2222222222222222222222222222222222222222\"}}'), $((T - 3600)));"
check "a run carries name, mode, template, repos, branch, private and since" \
  '{"name":"Code review","mode":"report","template":"code-review","repos":["mozilla/fxa"],"branch":"main","private":false,"since":'"$((T - 3600))"'}' \
  "$(_routine_profile() { echo "$OPEN"; }; tick $((T + 11 * 3600 + 30)) | jq -c --argjson r "$ri" '.runs[] | select(.routine == $r) | {name, mode, template, repos, branch, private, since}')"
rj="$(mk fxa "daily 20:30")"
check "a team that stops loading after the D8 check marks the run private, and a first run has no since" "true|null" \
  "$(_routine_profile() { [ -e "$tmp/p1" ] && return 1; : > "$tmp/p1"; echo "$OPEN"; }; tick $((T + 11 * 3600 + 1830)) | jq -r --argjson r "$rj" '.runs[] | select(.routine == $r) | "\(.private)|\(.since)"')"
# A run the bot refused before any session (its channel check): done with no --session fails it; a run with a
# session still needs that session.
nc="$(db_value "SELECT id FROM routine_runs WHERE routine_id = $rj AND state = 'claimed';")"
check "done with no --session fails a claimed run that has no session" "true|failed|private channel" \
  "$(routine_done "$nc" --state failed --reason "private channel" | jq -r '"\(.changed)|\(.state)"')|$(db_value "SELECT reason FROM routine_runs WHERE id = $nc;")"
ns="$(st started agent-sess01 $((N - 60)))"
check "done with no --session is refused for a run with a session" "ERROR: routine run ${ns} is not session (none)'s|started" \
  "$(routine_done "$ns" --state failed --reason x 2>&1)|$(s_of "$ns" | cut -d'|' -f1)"

nc2="$(db_value "INSERT INTO routine_runs (routine_id, period, state, started_at) VALUES ($rj, 'x-claimed', 'claimed', $N); SELECT last_insert_rowid();")"
check "done with no --session takes only --state failed" "ERROR: done with no --session only fails a run|claimed" \
  "$(routine_done "$nc2" --state report --reason x 2>&1)|$(db_value "SELECT state FROM routine_runs WHERE id = $nc2;")"
ns2="$(db_value "INSERT INTO routine_runs (routine_id, period, state, started_at) VALUES ($rj, 'x-started', 'started', $N); SELECT last_insert_rowid();")"
check "done with no --session refuses a run that is not claimed or queued" "ERROR: routine run ${ns2} is started: done with no --session takes only a claimed or queued run|started" \
  "$(routine_done "$ns2" --state failed --reason x 2>&1)|$(db_value "SELECT state FROM routine_runs WHERE id = $ns2;")"
db_exec "UPDATE routine_runs SET state = 'ok' WHERE id IN ($nc2, $ns2);"
# A manual run carries the same fields as a scheduled one; a skip names its routine, template and private flag.
rm_="$(mk fxa "daily 23:00" '{"name": "Perf look", "template": "perf-review"}')"
db_exec "UPDATE routine_runs SET state = 'ok' WHERE state IN ('queued','claimed','started');"
FXA_ROUTINE_NOW=$((T + 12 * 3600)) routine_runnow fxa "$rm_" >/dev/null
check "a manual run carries name, mode, template, private and since" '{"trigger":"manual","name":"Perf look","mode":"report","template":"perf-review","private":true,"since":null}' \
  "$(_routine_profile() { echo "$PRIV"; }; tick $((T + 12 * 3600 + 30)) | jq -c --argjson r "$rm_" '.runs[] | select(.routine == $r) | {trigger, name, mode, template, private, since}')"
echo '{"name":"drafty2","status":"draft"}' > "$FXA_TEAMS_DIR/drafty2.json"
rk="$(mk drafty2 "daily 23:30" '{"name": "Sec look", "template": "security-review"}')"
check "a skip carries the routine's name, template and private flag" '{"name":"Sec look","template":"security-review","private":false}' \
  "$(_routine_profile() { echo "$OPEN"; }; tick $((T + 14 * 3600 + 1830)) | jq -c --argjson r "$rk" '.skips[] | select(.routine == $r) | {name, template, private}')"

# D8 again at run time: a team that turned private after the save, or that does not load, does not run, and the skip
# does not post in a channel its results may no longer go to.
rb="$(mk fxa "daily 23:40" '{"name": "Bound look", "channel": "C0OTHER"}')"
check "a team that turned private skips a routine whose channel it does not bind, with no claim and no post" \
  "skipped|the routine no longer passes its checks: channel: A team with a private repo posts only to one of this team's channels|false|0" \
  "$(_routine_profile() { echo "$PRIV"; }; tick $((T + 14 * 3600 + 2430)) | jq -r --argjson r "$rb" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)"' | sed 's/^/skipped|/')|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rb AND state = 'claimed';")"
rd="$(mk fxa "daily 23:50")"
check "a team that does not load skips the routine, with no claim" "the team does not load|0" \
  "$(_routine_profile() { return 1; }; tick $((T + 14 * 3600 + 3030)) | jq -r --argjson r "$rd" '.skips[] | select(.routine == $r) | .reason')|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rd AND state = 'claimed';")"
check "run-now refuses a routine whose channel the private team does not bind" \
  "ERROR: routine ${rb} cannot run now: the routine no longer passes its checks: channel: A team with a private repo posts only to one of this team's channels|0" \
  "$(_routine_profile() { echo "$PRIV"; }; FXA_ROUTINE_NOW=$((T + 15 * 3600)) routine_runnow fxa "$rb" 2>&1)|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rb AND state = 'queued';")"

# A queued Run now meets the same D8 check when the tick hands it on; only a channel refusal stays out of Slack.
rq="$(mk fxa "daily 03:00" '{"name": "Queued look", "channel": "C0OTHER"}')"
FXA_ROUTINE_NOW=$((T + 16 * 3600)) routine_runnow fxa "$rq" >/dev/null
check "a queued run of a team that turned private is skipped, not claimed, and its channel refusal does not post" \
  "the routine no longer passes its checks: channel: A team with a private repo posts only to one of this team's channels|false|skipped" \
  "$(_routine_profile() { echo "$PRIV"; }; tick $((T + 16 * 3600 + 30)) | jq -r --argjson r "$rq" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)"')|$(db_value "SELECT state FROM routine_runs WHERE routine_id = $rq AND trigger = 'manual';")"
rr="$(mk fxa "daily 21:10" '{"name": "Repo look"}')"
check "a recheck refusal that is not the channel posts once (D23)" "repos|true" \
  "$(_routine_profile() { echo '{"private": false, "read_only": false, "repos": [{"slug": "mozilla/other", "role": "work"}]}'; }; tick $((T + 12 * 3600 + 10 * 60 + 30)) | jq -r --argjson r "$rr" '.skips[] | select(.routine == $r) | "\(.reason | ltrimstr("the routine no longer passes its checks: ") | split(":")[0])|\(.post)"')"

# A refusal on the repos and on the channel names the channel and stays out of Slack, scheduled or queued.
BOTH='{"private": true, "read_only": false, "repos": [{"slug": "mozilla/other", "role": "work"}]}'
rx="$(mk fxa "daily 21:20" '{"name": "Two look", "channel": "C0OTHER"}')"
check "a refusal on repos and channel gives the channel line and does not post" "channel|false" \
  "$(_routine_profile() { echo "$BOTH"; }; tick $((T + 12 * 3600 + 20 * 60 + 30)) | jq -r --argjson r "$rx" '.skips[] | select(.routine == $r) | "\(.reason | ltrimstr("the routine no longer passes its checks: ") | split(":")[0])|\(.post)"')"
ry="$(mk fxa "daily 04:00" '{"name": "Two queued", "channel": "C0OTHER"}')"
FXA_ROUTINE_NOW=$((T + 17 * 3600)) routine_runnow fxa "$ry" >/dev/null
check "a queued run refused on repos and channel gives the channel line and does not post" "channel|false" \
  "$(_routine_profile() { echo "$BOTH"; }; tick $((T + 17 * 3600 + 30)) | jq -r --argjson r "$ry" '.skips[] | select(.routine == $r) | "\(.reason | ltrimstr("the routine no longer passes its checks: ") | split(":")[0])|\(.post)"')"

# Each env's tick reconciles only its own runs: the dev bot has its own session records (D5).
rv="$(mk fxa "weekly sun 04:00")"; db_exec "UPDATE routines SET env = 'dev' WHERE id = $rv;"
gv="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rv, 'manual-9', 'started', 'agent-devr01', $((NOWR - 60))); SELECT last_insert_rowid();")"
FXA_ROUTINE_NOW=$((NOWR + 601)) routine_tick --env live >/dev/null
check "the live tick leaves a dev run with no live session record alone" "started|" "$(s_of "$gv")"
FXA_ROUTINE_NOW=$((NOWR + 602)) routine_tick --env dev >/dev/null
check "the dev tick fails its own run with no session record" "failed|the run's session is gone" "$(s_of "$gv")"
# A run whose routine row is gone (routines_clear_name) is still the live tick's to end.
ro="$(mk fxa "weekly sun 03:00")"
go="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($ro, 'manual-10', 'started', 'agent-orph01', $((NOWR - 60))); SELECT last_insert_rowid();")"
db_exec "DELETE FROM routines WHERE id = $ro;"
FXA_ROUTINE_NOW=$((NOWR + 603)) routine_tick --env live >/dev/null
check "the live tick ends a run whose routine row is gone" "failed|the run's session is gone" "$(s_of "$go")"
# A run belongs to the env it was claimed under, even after an edit moves its routine to the other env.
re_="$(mk fxa "weekly sun 02:00")"
ge="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($re_, 'manual-11', 'started', 'agent-envx01', $((NOWR - 60)), json('{\"env\": \"live\"}')); SELECT last_insert_rowid();")"
db_exec "UPDATE routines SET env = 'dev' WHERE id = $re_;"
FXA_ROUTINE_NOW=$((NOWR + 604)) routine_tick --env dev >/dev/null
check "a run claimed under live stays the live tick's after its routine moves to dev" "started|" "$(s_of "$ge")"

# A bot that restarts between the claim and the start (--resume on its first tick): a claimed run with no
# session, in its 10 min, starts again; an old one is left to reconcile, and the other env's run is not touched.
NC=$((NOWR + 2000)); rcl="$(mk fxa "weekly sun 01:00")"
gc="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at) VALUES ($rcl, 'manual-12', 'schedule', 'claimed', $((NC - 120))); SELECT last_insert_rowid();")"
check "a tick with no --resume does not answer a claimed run again" "0" "$(FXA_ROUTINE_NOW=$NC routine_tick --env live | jq --argjson g "$gc" '[.runs[] | select(.run == $g)] | length')"
check "--resume answers it once, with its trigger and channel" "1|schedule|C0OWN00|claimed" \
  "$(FXA_ROUTINE_NOW=$((NC + 5)) routine_tick --env live --resume | jq -r --argjson g "$gc" '[.runs[] | select(.run == $g)] | "\(length)|\(.[0].trigger)|\(.[0].channel)"')|$(db_value "SELECT state FROM routine_runs WHERE id = $gc;")"
rcd="$(mk fxa "weekly sun 01:30")"; db_exec "UPDATE routines SET env = 'dev' WHERE id = $rcd;"
gd="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at) VALUES ($rcd, 'manual-13', 'schedule', 'claimed', $((NC - 60))); SELECT last_insert_rowid();")"
check "--resume on live leaves a dev run alone, and one past 10 min fails" "0|failed|no session started within 10 min" \
  "$(FXA_ROUTINE_NOW=$((NC + 500)) routine_tick --env live --resume | jq --argjson g "$gd" '[.runs[] | select(.run == $g)] | length')|$(db_value "SELECT state || '|' || reason FROM routine_runs WHERE id = $gc;")"
rq="$(mk fxa "weekly sun 03:00")"
gq="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at) VALUES ($rq, 'manual-14', 'manual', 'queued', $((NC + 400))); SELECT last_insert_rowid();")"
check "--resume lists a queued run that this tick claims once, not again as an orphan" "1|claimed" \
  "$(FXA_ROUTINE_NOW=$((NC + 510)) routine_tick --env live --resume | jq --argjson g "$gq" '[.runs[] | select(.run == $g)] | length')|$(db_value "SELECT state FROM routine_runs WHERE id = $gq;")"
check "a bad flag after --env is refused" "1" "$(FXA_ROUTINE_NOW=$NC routine_tick --env live --bogus >/dev/null 2>&1; echo $?)"

# A paused team that turned private: its skip does not post to a channel it does not bind.
rh="$(mk fxa "daily 05:00" '{"name": "Held look", "channel": "C0OTHER"}')"
# A routine with no channel (D32): its skip is recorded but never posts, and a public channel would post it.
rnc="$(mk fxa "daily 05:00" '{"name": "Quiet look"}')"; db_exec "UPDATE routines SET data = json_remove(data, '$.channel') WHERE id = $rnc;"
rpub="$(mk fxa "daily 05:00" '{"name": "Loud look"}')"
out="$(_routine_profile() { echo "$PRIV"; }; _routine_team_paused() { echo held; return 0; }; tick $((T + 20 * 3600 + 30)))"
check "a team-paused skip of a team that turned private does not post to an unbound channel" "the team is paused: held|false" \
  "$(jq -r --argjson r "$rh" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)"' <<< "$out")"
check "a skip of a routine with no channel is recorded and does not post" "the team is paused: held|false|skipped" \
  "$(jq -r --argjson r "$rnc" '.skips[] | select(.routine == $r) | "\(.reason)|\(.post)"' <<< "$out")|$(db_value "SELECT state FROM routine_runs WHERE routine_id = $rnc;")"
check "the same skip on the team's own channel posts" "true" "$(jq -r --argjson r "$rpub" '.skips[] | select(.routine == $r) | .post' <<< "$out")"
# done for a routine with no channel: post false, the row keeps the report, and no held reason.
gn="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rnc, 'manual-13', 'started', 'agent-noch01', $((T - 60))); SELECT last_insert_rowid();")"
printf 'No issue found in 2 commits.\n' > "$tmp/quiet.md"
check "done for a routine with no channel answers post false and keeps the report with no reason" "true|false|No issue found in 2 commits.|" \
  "$(FXA_ROUTINE_NOW=$T routine_done "$gn" --state report --session agent-noch01 --report-file "$tmp/quiet.md" | jq -r '"\(.changed)|\(.post)"')|$(db_value "SELECT trim(report, char(10)) || '|' || coalesce(reason, '') FROM routine_runs WHERE id = $gn;")"
gh_="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rnc, 'manual-14', 'started', 'agent-noch02', $((T - 60))); SELECT last_insert_rowid();")"
check "a report the guard flags, of a routine with no channel, gets no held reason" "false|" \
  "$(FXA_ROUTINE_NOW=$T routine_done "$gh_" --state report --session agent-noch02 --report-file "$tmp/report.md" | jq -r .post)|$(db_value "SELECT coalesce(reason, '') FROM routine_runs WHERE id = $gh_;")"
# The run's config snapshot decides, not the routine as it is now.
gc1="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rpub, 'manual-15', 'started', 'agent-noch03', $((T - 60)), json('{}')); SELECT last_insert_rowid();")"
gc2="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rnc, 'manual-16', 'started', 'agent-noch04', $((T - 60)), json('{\"channel\": \"C0OWN00\"}')); SELECT last_insert_rowid();")"
check "done follows the channel the run started with" "false|true" \
  "$(FXA_ROUTINE_NOW=$T routine_done "$gc1" --state report --session agent-noch03 --report-file "$tmp/quiet.md" | jq -r .post)|$(FXA_ROUTINE_NOW=$T routine_done "$gc2" --state report --session agent-noch04 --report-file "$tmp/quiet.md" | jq -r .post)"
# A queued Run now of a routine with no channel that the recheck refuses: recorded, never posted.
rqn="$(mk fxa "weekly sun 01:00" '{"name": "Quiet queue"}')"; db_exec "UPDATE routines SET data = json_remove(data, '$.channel') WHERE id = $rqn;"
FXA_ROUTINE_NOW=$((T + 21 * 3600)) routine_runnow fxa "$rqn" >/dev/null
check "a refused queued run of a routine with no channel does not post" "false" \
  "$(_routine_profile() { echo "$BOTH"; }; tick $((T + 21 * 3600 + 30)) | jq -r --argjson r "$rqn" '.skips[] | select(.routine == $r) | .post')"

# A queued run with no free runner for 60 min fails with that reason, not one that blames the tick.
rw="$(mk fxa "weekly sun 05:00")"
qn="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at) VALUES ($rw, 'manual-8', 'manual', 'queued', $((T - 3660))); SELECT last_insert_rowid();")"
echo 1 > "$tmp/free"; tick "$T" >/dev/null; echo 5 > "$tmp/free"
check "a queued run with no free runner after 60 min fails as no runner free" "failed|no runner free within 60 min" "$(s_of "$qn")"
qf="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at) VALUES ($rw, 'manual-12', 'manual', 'queued', $((T - 3660))); SELECT last_insert_rowid();")"
FXA_ROUTINE_NOW=$T routine_reconcile "$T" live
check "a queued run that waited 60 min with free runners does not blame the runners" "failed|no tick started it within 60 min" "$(s_of "$qf")"

# A pr-label routine runs on request only: the tick never claims it on a schedule, even with a schedule saved.
rpl="$(mk fxa "daily 09:00" '{"on": "pr-label", "mode": "pr", "pr": {"repo": "mozilla/fxa", "authors": ["dependabot[bot]"]}}')"
check "a pr-label routine is not claimed or skipped on a schedule, and gets no row" "0|0" \
  "$(tick $((T + 30)) | jq --argjson r "$rpl" '[.runs[], .skips[] | select(.routine == $r)] | length')|$(rows "$rpl")"

# _prfix_set writes heads.fix of a live fix row only; _with_timeout stops a slow command.
fx1="$(db_value "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rpl, 'pr-1-aa', 'queued', json('{\"fix\":{\"pr\":1}}')); SELECT last_insert_rowid();")"
fx2="$(db_value "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rpl, 'pr-2-bb', 'ok', json('{\"fix\":{\"pr\":2}}')); SELECT last_insert_rowid();")"
check "_prfix_set: a live fix row takes the filter with its --arg; an ended row is not written" "0|{\"pr\":1,\"wait\":\"it's busy\"}|1|{\"pr\":2}" \
  "$(_prfix_set "$fx1" '.wait = $w' --arg w "it's busy"; echo $?)|$(db_value "SELECT heads->'fix' FROM routine_runs WHERE id = $fx1;")|$(_prfix_set "$fx2" '.wait = "x"'; echo $?)|$(db_value "SELECT heads->'fix' FROM routine_runs WHERE id = $fx2;")"
s0="$(date +%s)"; _with_timeout 1 sleep 5; rc=$?
check "_with_timeout stops sleep 5 at 1 s with 124; a quick command keeps its status and output" "124|1|hi|3" \
  "$rc|$([ $(( $(date +%s) - s0 )) -le 3 ] && echo 1)|$(_with_timeout 5 echo hi)|$(_with_timeout 5 sh -c 'exit 3'; echo $?)"

# Stop with several fix rows: no --run takes the started row, not the newer queued one; --run takes that row;
# a row whose fix is being pushed is not stopped. The list's live is the started row, and lives has every row.
rst="$(mk fxa "weekly sun 05:00")"
fa="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, heads) VALUES ($rst, 'pr-10-aa', 'started', 'agent-fixa01', json('{\"fix\":{\"pr\":10}}')); SELECT last_insert_rowid();")"
fb="$(db_value "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rst, 'pr-11-bb', 'queued', json('{\"fix\":{\"pr\":11}}')); SELECT last_insert_rowid();")"
echo '{"key":"agent-fixa01","state":"active"}' > "$tmp/agent-fixa01.json"; : > "$tmp/stopped"
check "routine list: live is the started row; lives has both, started first, each with its fix" "$fa|$fa,$fb|10,11" \
  "$(routine_list fxa | jq -r --argjson r "$rst" '.[] | select(.id == $r) | "\(.live.id)|\([.lives[].id] | join(","))|\([.lives[].fix.pr] | join(","))"')"
check "stop with no --run ends the started row and its session; the queued row stays" "stopped run $fa|stopped|agent-fixa01|queued" \
  "$(cmd_routine stop fxa "$rst")|$(db_value "SELECT state FROM routine_runs WHERE id = $fa;")|$(cat "$tmp/stopped")|$(db_value "SELECT state FROM routine_runs WHERE id = $fb;")"
check "stop --run ends that row" "stopped run $fb|stopped" "$(cmd_routine stop fxa "$rst" --run "$fb")|$(db_value "SELECT state FROM routine_runs WHERE id = $fb;")"
fc="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, heads) VALUES ($rst, 'pr-12-cc', 'started', 'agent-fixc01', json('{\"fix\":{\"pr\":12,\"pushing\":1792414800}}')); SELECT last_insert_rowid();")"
check "a row whose fix is being pushed is not stopped" "ERROR: The fix is being pushed. Try again after it ends.|started" \
  "$(cmd_routine stop fxa "$rst" --run "$fc" 2>&1)|$(db_value "SELECT state FROM routine_runs WHERE id = $fc;")"
check "stop --run of a run that is not live, and a bad option, are refused" "ERROR: run $fa of routine $rst is not in progress|usage: routine stop <team> <id> [--run <run>]" \
  "$(cmd_routine stop fxa "$rst" --run "$fa" 2>&1)|$(cmd_routine stop fxa "$rst" --now 2>&1)"
db_exec "UPDATE routine_runs SET state = 'ok' WHERE id = $fc;"

# _prfix_claim_push: one claim of a started fix row, with the commit it pushes; a stop then waits for the push.
S1="2222222222222222222222222222222222222222"
fd="$(db_value "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rst, 'pr-13-dd', 'started', json('{\"fix\":{\"pr\":13}}')); SELECT last_insert_rowid();")"
check "the claim sets pushing and pending_sha once; a second claim, an ended row and a bad sha are refused" "0|$((T + 7))|$S1|1|1|1" \
  "$(FXA_ROUTINE_NOW=$((T + 7)) _prfix_claim_push "$fd" "$S1"; echo $?)|$(db_value "SELECT json_extract(heads, '$.fix.pushing') || '|' || json_extract(heads, '$.fix.pending_sha') FROM routine_runs WHERE id = $fd;")|$(_prfix_claim_push "$fd" "$S1"; echo $?)|$(_prfix_claim_push "$fb" "$S1"; echo $?)|$(db_exec "UPDATE routine_runs SET state = 'started' WHERE id = $fb;"; _prfix_claim_push "$fb" "x'); --"; echo $?)"
check "a stop of the claimed row says the fix is being pushed" "ERROR: The fix is being pushed. Try again after it ends." "$(cmd_routine stop fxa "$rst" --run "$fd" 2>&1)"
db_exec "UPDATE routine_runs SET state = 'ok' WHERE id IN ($fd, $fb);"

# The queued claim loop for a fix row (a pr-label routine): every gate keeps it queued with heads.fix.wait, and the
# target check against the fake gh (lib/testdata/prfix) skips a PR with a new commit before any claim.
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE state IN ('queued','claimed','started');"
PA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
rpf="$(mk fxa "daily 09:00" '{"name": "Dep fix", "on": "pr-label", "mode": "pr", "pr": {"repo": "mozilla/fxa", "authors": ["dependabot[bot]"]}}')"
fq() { # fq <head sha> [trigger]   A queued fix row on PR 90001; prints its id.
  db_value "INSERT INTO routine_runs (routine_id, period, trigger, actor, state, heads, started_at) VALUES ($rpf, 'pr-90001-$1', '${2:-label}', 'example-writer', 'queued',
    json('{\"fix\":{\"pr\":90001,\"url\":\"https://github.com/mozilla/fxa/pull/90001\",\"head_sha\":\"$1\",\"packages\":[\"example-pkg\"]}}'), $T); SELECT last_insert_rowid();"; }
q1="$(fq "$PA")"
out="$(PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; _routine_team_paused() { echo held; return 0; }; tick $((T + 30)))"
check "A7: a queued fix row on a paused team stays queued with the gate text in heads.fix.wait, and no run starts" "queued|the team is paused|0" \
  "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.wait') FROM routine_runs WHERE id = $q1;")|$(jq --argjson q "$q1" '[.runs[], .skips[] | select(.run == $q)] | length' <<< "$out")"
out="$(PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; db_exec "UPDATE routines SET paused = 1 WHERE id = $rpf;"; tick $((T + 60)))"
check "a paused routine holds a label run, not a manual one" "queued|the routine is paused" "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.wait') FROM routine_runs WHERE id = $q1;")"
db_exec "UPDATE routine_runs SET trigger = 'manual' WHERE id = $q1;"
out="$(PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; tick $((T + 90)))"; db_exec "UPDATE routines SET paused = 0 WHERE id = $rpf;"
check "a queued fix row that passes the gates and the target check is claimed: wait cleared, its trigger, actor and fix on runs" \
  "claimed||manual|example-writer|90001|https://github.com/mozilla/fxa/pull/90001|example-writer|example-pkg" \
  "$(db_value "SELECT state || '|' || coalesce(json_extract(heads, '$.fix.wait'), '') FROM routine_runs WHERE id = $q1;")|$(jq -r --argjson q "$q1" '.runs[] | select(.run == $q) | [.trigger, .actor, .fix.pr, .fix.url, .fix.actor, .fix.package] | map(tostring) | join("|")' <<< "$out")"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $q1;"
q2="$(fq "$H1")"
out="$(PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; tick $((T + 120)))"
check "A8: a PR with a new commit: not claimed, skipped with why new-commit, on skips with fix, not on runs, and its head freed" \
  "skipped|new-commit|new-commit|90001|true|0|pr-90001-$H1-x$q2" \
  "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.why') FROM routine_runs WHERE id = $q2;")|$(jq -r --argjson q "$q2" '.skips[] | select(.run == $q) | [.fix.why, .fix.pr, .post] | map(tostring) | join("|")' <<< "$out")|$(jq --argjson q "$q2" '[.runs[] | select(.run == $q)] | length' <<< "$out")|$(db_value "SELECT period FROM routine_runs WHERE id = $q2;")"
q3="$(fq "$PA")"
out="$(PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH" export PRFIX_DIR="$tmp/nofx"; tick $((T + 150)))"
check "a PR read that fails keeps the row queued with a wait, not a skip" "queued|GitHub did not answer" "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.wait') FROM routine_runs WHERE id = $q3;")"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $q3;"

# A39 run-now --pr: with two queued rows and a started run, a fork PR and a head with a result are refused with their
# fixed texts, and a good PR queues a manual row with heads.fix at its head.
PB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
db_exec "INSERT INTO routine_runs (routine_id, period, trigger, state, heads) VALUES ($rpf, 'pr-90003-c', 'label', 'queued', json('{\"fix\":{\"pr\":90003}}')),
  ($rpf, 'pr-90005-e', 'label', 'queued', json('{\"fix\":{\"pr\":90005}}')), ($rpf, 'pr-90004-d', 'label', 'started', json('{\"fix\":{\"pr\":90004}}')),
  ($rpf, 'pr-90002-$PB', 'label', 'ok', json('{\"fix\":{\"pr\":90002}}'));"
rn() { ( export PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH" FXA_TEAM_ACTOR=admin@example.com FXA_ROUTINE_NOW=$((T + 200)); cmd_routine run-now fxa "$rpf" "$@" 2>&1 ); }
check "run-now --pr on a fork PR is refused with its text" "ERROR: PR #90006 is from a fork. The fix pushes to the PR branch, so use a PR from a branch of mozilla/fxa." \
  "$(rn --pr https://github.com/mozilla/fxa/pull/90006)"
check "run-now --pr on a head with a result gives the D4 text" "ERROR: A run on bbbbbbb already ended. A new commit allows a new run." \
  "$(rn --pr https://github.com/mozilla/fxa/pull/90002)"
check "run-now --pr on a PR of another repo, and run-now of a pr-label routine with no --pr, are refused" \
  "ERROR: https://github.com/mozilla/other/pull/1 is not a PR of mozilla/fxa. Use a PR link of mozilla/fxa.|ERROR: routine $rpf runs on a dependency PR: pass --pr <url>" \
  "$(rn --pr https://github.com/mozilla/other/pull/1)|$(rn)"
got="$(rn --pr https://github.com/mozilla/fxa/pull/90001)"; qn="$(sed -nE 's/^queued run ([0-9]+):.*/\1/p' <<< "$got")"
check "a third good PR queues a manual row with heads.fix, beside two queued rows and a started run" \
  "queued run $qn: Queued for #90001. The PR comment shows its state.|queued|manual|admin@example.com|pr-90001-$PA|90001|$PA|dependabot/npm_and_yarn/example-pkg-1.3.0|main|example-pkg|https://github.com/mozilla/fxa/actions/runs/1000/job/1" \
  "$got|$(db_value "SELECT state || '|' || trigger || '|' || actor || '|' || period FROM routine_runs WHERE id = ${qn:-0};")|$(db_value "SELECT heads->'fix' FROM routine_runs WHERE id = ${qn:-0};" | jq -r '[.pr, .head_sha, .head_ref, .base_ref, (.packages | join(",")), (.check_urls | join(","))] | map(tostring) | join("|")')"
check "the same PR head again, while that run is queued" "ERROR: A run on #90001 at aaaaaaa is already queued or in progress. The PR comment shows its state." \
  "$(rn --pr https://github.com/mozilla/fxa/pull/90001)"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE routine_id = $rpf AND state IN ('queued','claimed','started');"

# A16 prfix_report: the PR comment of a fix row is one fixed text with its next step, for each state and why. The
# comment and the label are stubbed here (lib/github-app.check.sh checks them on the fixture).
prfix_comment() { printf 'comment %s %s %s\n' "$1" "$2" "$3" >> "$tmp/pc"; [ -z "${PC_FAILS:-}" ]; }
prfix_label() { echo "label $*" >> "$tmp/pc"; }
P7="9999999999999999999999999999999999999999"
fr() { # fr <state> [fix keys json]   A fix row of the pr-label routine on PR 90001 at head PA; prints its id.
  local x="${2:-}"; [ -n "$x" ] || x='{}'
  db_value "INSERT INTO routine_runs (routine_id, period, state, reason, heads) VALUES ($rpf, 'pr-90001-$RANDOM$RANDOM', '$1', 'agent says: see https://internal.example/x',
    json($(db_q "$(jq -cn --argjson x "$x" --arg h "$PA" '{fix: ({pr: 90001, url: "https://github.com/mozilla/fxa/pull/90001", head_sha: $h} + $x)}')"))); SELECT last_insert_rowid();"; }
rep() { local id; id="$(fr "$@")"; : > "$tmp/pc"; prfix_report "$id" >/dev/null 2>&1; sed "s/^comment mozilla\/fxa 90001 //" "$tmp/pc" | paste -sd'#' -; db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $id AND state IN ('queued','claimed','started');"; }
L="label mozilla/fxa 90001 remove agent-help"
check "queued: Queued" "Queued: the fix starts when a runner is free." "$(rep queued)"
check "queued with a gate: Waiting and the gate text" "Waiting: the team budget is used. I try again each minute." "$(rep queued '{"wait": "the team budget is used"}')"
fs="$(fr started '{"pr": 90003}')"
check "queued behind a live run on another PR: In line" "In line behind #90003. The fix starts after that run ends." "$(rep queued '{"wait": "another run of this routine is in progress"}')"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $fs;"
check "claimed and started: Working, with the short head" "Working: the agent is fixing the failing checks on aaaaaaa.|Working: the agent is fixing the failing checks on aaaaaaa." "$(rep claimed)|$(rep started)"
check "ok: Pushed and the next step, and the label is removed" "Pushed 9999999. Next: review the fix commit, then approve the functional tests gate.#$L" "$(rep ok "{\"new_sha\": \"$P7\"}")"
check "nochange and a report with no why" "No fix found on aaaaaaa. A new commit allows a new run.#$L|No fix found on aaaaaaa. A new commit allows a new run.#$L" "$(rep nochange)|$(rep report)"
check "report: the branch moved" "The branch moved, so nothing was pushed. Add agent-help again to retry.#$L" "$(rep report '{"why": "moved"}')"
check "report: each guard" "Nothing was pushed: the fix changes yarn.lock entries, which I do not push. Fix it by hand.#$L|Nothing was pushed: the fix changes Yarn tooling files, which I do not push. Fix it by hand.#$L|Nothing was pushed: the fix changes protected files, which I do not push. Fix it by hand.#$L|Nothing was pushed: the fix may hold personal data or a secret, so I do not push it. Fix it by hand.#$L" \
  "$(rep report '{"why": "guard:lock"}')|$(rep report '{"why": "guard:tooling"}')|$(rep report '{"why": "guard:frozen"}')|$(rep report '{"why": "guard:pii"}')"
check "failed, and a boot failure" "The fix failed, and nothing was pushed. Add agent-help again to retry.#$L|Not started: the sandbox did not start. Add agent-help again to retry.#$L" "$(rep failed)|$(rep failed '{"why": "boot"}')"
check "stopped: label, closed, merged, admin" "Stopped: the agent-help label was removed. Nothing was pushed.#$L|Stopped: the PR was closed. Nothing was pushed. Reopen it and add agent-help again to retry.#$L|Stopped: the PR was merged. Nothing was pushed.#$L|Stopped by a team admin. Nothing was pushed. Add agent-help again to retry.#$L" \
  "$(rep stopped '{"why": "label"}')|$(rep stopped '{"why": "closed"}')|$(rep stopped '{"why": "merged"}')|$(rep stopped)"
check "skipped: each not-started why" "Not started: the PR has a new commit. Add agent-help again to fix the new head.#$L|Not started: it waited 24 h. Add agent-help again to retry.#$L|Not started: CI passes on aaaaaaa. Add agent-help again if CI fails.#$L|Not started: a run on aaaaaaa already ended. A new commit allows a new run.#$L|Not started: the label needs a person with write access. Ask a person with write access to add agent-help.#$L" \
  "$(rep skipped '{"why": "new-commit"}')|$(rep skipped '{"why": "expired"}')|$(rep skipped '{"why": "not-red"}')|$(rep skipped '{"why": "used"}')|$(rep skipped '{"why": "no-write"}')"
check "skipped: fork, base, closed, merged, target, and an unknown why" "Not started: the PR is from a fork. Fix it by hand.#$L|Not started: the PR branch is a base or release branch. Fix it by hand.#$L|Not started: the PR is closed. Reopen it and add agent-help again.#$L|Not started: the PR is merged. No step is needed.#$L|Not started: the PR no longer matches the routine's repo, author or branch rules. Fix it by hand.#$L|Not started: the run could not start. Add agent-help again to retry.#$L" \
  "$(rep skipped '{"why": "fork"}')|$(rep skipped '{"why": "base"}')|$(rep skipped '{"why": "closed"}')|$(rep skipped '{"why": "merged"}')|$(rep skipped '{"why": "target"}')|$(rep skipped '{"why": "<b>odd</b>"}')"
# The text is kept in heads.fix.comment: the same text again makes no call, a new state edits, and a failed edit keeps the old text.
fe="$(fr queued)"; : > "$tmp/pc"; prfix_report "$fe"; prfix_report "$fe"
check "the same text twice: one comment call, and the text is kept" "1|Queued: the fix starts when a runner is free." "$(grep -c '^comment' "$tmp/pc")|$(db_value "SELECT json_extract(heads, '$.fix.comment') FROM routine_runs WHERE id = $fe;")"
db_exec "UPDATE routine_runs SET state = 'started' WHERE id = $fe;"; : > "$tmp/pc"; PC_FAILS=1 prfix_report "$fe"; rc=$?
check "a failed edit exits 1 and keeps the old text, so the next call tries again" "1|Queued: the fix starts when a runner is free.|2" \
  "$rc|$(db_value "SELECT json_extract(heads, '$.fix.comment') FROM routine_runs WHERE id = $fe;")|$(prfix_report "$fe"; grep -c '^comment' "$tmp/pc")"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $fe;"
check "a row with no fix makes no call" "0" "$(: > "$tmp/pc"; prfix_report "$r1"; prfix_report "$(db_value "SELECT id FROM routine_runs WHERE routine_id = $r1 LIMIT 1;")"; grep -c . "$tmp/pc")"
check "no text holds the row's reason or a link" "0" "$(cat "$tmp/pc" | grep -c 'http\|agent says')"

# The end of a fix row comes from heads.fix, not from the bot's state or the session's pr_url (checkout sets it at boot).
fx() { # fx <state> <session> [fix keys json] [started_at]   A fix row with a session record; prints its id.
  local x="${3:-}"; [ -n "$x" ] || x='{}'
  db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, heads) VALUES ($rpf, 'pr-90001-$RANDOM$RANDOM', '$1', $(db_q "$2"), ${4:-$((N - 60))},
    json($(db_q "$(jq -cn --argjson x "$x" --arg h "$PA" '{fix: ({pr: 90001, url: "https://github.com/mozilla/fxa/pull/90001", head_sha: $h} + $x)}')"))); SELECT last_insert_rowid();"; }
rec() { echo "{\"key\":\"$1\",\"state\":\"$2\",\"pr_url\":\"https://github.com/mozilla/fxa/pull/90001\"}" > "$tmp/$1.json"; [ "$2" = active ] || touch -t 202001010000 "$tmp/$1.json"; }
dn() { ( export PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; FXA_ROUTINE_NOW=$N routine_done "$@" | jq -c '[.changed, .state, .fix.pr, .fix.sha, .fix.why]' ); }
rec agent-fxd001 active; e1="$(fx started agent-fxd001 "{\"new_sha\": \"$P7\"}")"
check "done: a bot failed after the push (new_sha) records ok, and answers the fix" "[true,\"ok\",90001,\"$P7\",null]|ok" "$(dn "$e1" --state failed --session agent-fxd001)|$(s_of "$e1" | cut -d'|' -f1)"
rec agent-fxd002 active; e2="$(fx started agent-fxd002)"
check "done: ok with no new_sha records failed, with why it failed" "[true,\"failed\",90001,null,null]|failed|the fix was not pushed" "$(dn "$e2" --state ok --session agent-fxd002)|$(s_of "$e2")"
rec agent-fxd003 active; e3="$(fx started agent-fxd003 '{"why": "guard:lock"}')"
check "done: a guard refusal is report, whatever the bot says" "[true,\"report\",90001,null,\"guard:lock\"]" "$(dn "$e3" --state nochange --session agent-fxd003)"
rec agent-fxd004 active; e4="$(fx stopped agent-fxd004 '{"why": "label"}')"; e5="$(fx skipped agent-fxd005 '{"why": "new-commit"}')"
check "done on a row ctl ended first answers its state and why: stopped, and skipped" "[false,\"stopped\",90001,null,\"label\"]|[false,\"skipped\",90001,null,\"new-commit\"]" \
  "$(dn "$e4" --state stopped --session agent-fxd004)|$(dn "$e5" --state failed --session agent-fxd005)"
rec agent-fxd006 active; e6="$(fx started agent-fxd006 "{\"pushing\": $((N - 30)), \"pending_sha\": \"$PA\"}")"
check "done: a push claim with no new_sha, and the PR at pending_sha, is ok with new_sha" "[true,\"ok\",90001,\"$PA\",null]" "$(dn "$e6" --state failed --session agent-fxd006)"
# Reconcile, on the fake gh: PR 90001 is at PA.
rec agent-fxr001 stopped; r1f="$(fx started agent-fxr001)"
rec agent-fxr002 active; r2f="$(fx started agent-fxr002 "{\"pushing\": $((N - 601)), \"pending_sha\": \"$PA\"}")"
rec agent-fxr003 active; r3f="$(fx started agent-fxr003 "{\"pushing\": $((N - 60)), \"pending_sha\": \"$PA\"}")"
rec agent-fxr004 active; r4f="$(fx started agent-fxr004 "{\"pushing\": $((N - 601)), \"pending_sha\": \"$P7\"}")"
rec agent-fxr005 stopped; r5f="$(fx started agent-fxr005 '{"why": "moved"}')"
rec agent-fxr006 stopped; r6f="$(fx started agent-fxr006 "{\"new_sha\": \"$P7\"}")"
: > "$tmp/errs"; ( export PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"; routine_reconcile "$N" live )
check "reconcile: a stopped session with the checkout's pr_url and no new_sha fails, not ok" "failed|the session stopped with no result" "$(s_of "$r1f")"
check "A26b: a kill after the PATCH: 10 min after the claim, the PR at pending_sha ends ok with new_sha" "ok|$PA" \
  "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.new_sha') FROM routine_runs WHERE id = $r2f;")"
check "a claim under 10 min old waits; one whose PR is not at pending_sha fails" "started|failed" "$(s_of "$r3f" | cut -d'|' -f1)|$(s_of "$r4f" | cut -d'|' -f1)"
check "a moved branch is report, a pushed one ok, and only the real failures are operator errors" "report|ok|2" \
  "$(s_of "$r5f" | cut -d'|' -f1)|$(s_of "$r6f" | cut -d'|' -f1)|$(grep -c . "$tmp/errs")"

# A18: a queued fix row waits up to 24 h, not 60 min: then it ends skipped with why expired, posts once on the skips
# list, records no operator error, and its head is free for a new request.
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE state IN ('queued','claimed','started');"
x1="$(db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, started_at, heads) VALUES ($rpf, 'pr-90001-$PA', 'label', 'queued', $((N - 7200)),
  json('{\"fix\":{\"pr\":90001,\"url\":\"https://github.com/mozilla/fxa/pull/90001\",\"head_sha\":\"$PA\",\"wait\":\"the team is paused\"}}')); SELECT last_insert_rowid();")"
: > "$tmp/errs"; ( _routine_team_paused() { echo held; return 0; }; tick "$N" >/dev/null )
check "a fix row queued 2 h stays queued" "queued" "$(s_of "$x1" | cut -d'|' -f1)"
out="$(_routine_team_paused() { echo held; return 0; }; tick $((N + 86400 - 7200 + 60)))"
check "after 24 h: skipped with why expired, on skips with post true and the fix, no error, the head freed" \
  "skipped|expired|it waited 24 h|true|90001|expired|0|pr-90001-$PA-x$x1" \
  "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.why') || '|' || reason FROM routine_runs WHERE id = $x1;")|$(jq -r --argjson q "$x1" '.skips[] | select(.run == $q) | [.post, .fix.pr, .fix.why] | map(tostring) | join("|")' <<< "$out")|$(grep -c . "$tmp/errs")|$(db_value "SELECT period FROM routine_runs WHERE id = $x1;")"
check "the next tick does not post it again, and a new request on the same head inserts" "0|1" \
  "$(tick $((N + 86400)) | jq --argjson q "$x1" '[.skips[] | select(.run == $q)] | length')|$(db_value "INSERT INTO routine_runs (routine_id, period, state) VALUES ($rpf, 'pr-90001-$PA', 'stopped'); SELECT changes();")"

# A15, A17, A19: each state change edits the App's one comment, through the real prfix_comment on a copy of the fixture
# (the stub API writes there, as in lib/github-app.check.sh). The tick repairs the comment of each fix row.
( eval "$(sed -n '/^_prfix_comment_id() {/,/^}/p;/^prfix_comment() {/,/^}/p;/^prfix_label() {/,/^}/p;/^PRFIX_MARK=/p' "$SANDBOX_ROOT/lib/github.sh")"
  cp -R "$SANDBOX_ROOT/lib/testdata/prfix" "$tmp/pf"; export PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH" PRFIX_DIR="$tmp/pf" GITHUB_APP_ID=123456
  echo '[]' > "$tmp/pf/api/repos/mozilla/fxa/issues/90003/comments.json"; echo '[]' > "$tmp/pf/api/repos/mozilla/fxa/issues/90004/comments.json"
  github_app_enabled() { true; }
  _gh_app_api() {
    local body f; body="$(cat)"; echo "$1 $2 $(jq -r '.body // "" | split("\n")[1] // ""' <<< "${body:-{\}}" 2>/dev/null)" >> "$tmp/app"
    case "$1 $2" in
      "POST issues/"*/comments) f="$tmp/pf/api/repos/$PIPE_REPO_SLUG/$2.json"
        jq --argjson b "$body" '. + [{id: (9100 + length), user: {login: "example-fxa-app[bot]", type: "Bot"}, performed_via_github_app: {id: 123456}, body: $b.body}]' "$f" > "$f.n" && mv "$f.n" "$f"
        [ -z "${POST_LOST:-}" ] || return 22; echo '{}' ;;
      "PATCH issues/comments/"*) for f in "$tmp"/pf/api/repos/"$PIPE_REPO_SLUG"/issues/*/comments.json; do
          jq --argjson b "$body" --argjson id "${2##*/}" 'map(if .id == $id then .body = $b.body else . end)' "$f" > "$f.n" && mv "$f.n" "$f"; done; echo '{}' ;;
      *) echo '{}' ;;
    esac
  }
  mine() { jq -r '[.[] | select(.user.type == "Bot" and .performed_via_github_app.id == 123456)] | "\(length)|\(map(.body | split("\n")[1]) | join(","))"' "$tmp/pf/api/repos/mozilla/fxa/issues/$1/comments.json"; }
  M=$((T + 3000))
  # Only this block's rows are new enough for the tick's repair of each PR's comment.
  db_exec "UPDATE routine_runs SET state = 'stopped' WHERE state IN ('queued','claimed','started'); UPDATE routine_runs SET ended_at = 0 WHERE ended_at IS NOT NULL;"
  echo '{"day_usd": 1}' > "$FXA_LLM_PROXY_DIR/teams/fxa.json"; echo '{"day": "2026-10-19", "day_usd": 2, "month": "2026-10", "month_usd": 2}' > "$FXA_LLM_PROXY_DIR/teams/fxa.spend.json"
  : > "$tmp/app"
  got="$(export FXA_TEAM_ACTOR=admin@example.com FXA_ROUTINE_NOW=$M; rm "$FXA_LLM_PROXY_DIR/teams/fxa.json"; POST_LOST=1 cmd_routine run-now fxa "$rpf" --pr https://github.com/mozilla/fxa/pull/90003 2>&1; echo '{"day_usd": 1}' > "$FXA_LLM_PROXY_DIR/teams/fxa.json")"
  w1="$(sed -nE 's/^queued run ([0-9]+):.*/\1/p' <<< "$got")"
  check "run-now writes the Queued comment; the create reply is lost, and the comment is still one" "1|Queued: the fix starts when a runner is free." "$(mine 90003)"
  tick "$M" >/dev/null
  check "A17: a used budget keeps the row queued, and the comment says Waiting" "queued|1|Waiting: the team budget is used. I try again each minute." "$(s_of "${w1:-0}" | cut -d'|' -f1)|$(mine 90003)"
  rm -f "$FXA_LLM_PROXY_DIR/teams/fxa.json" "$FXA_LLM_PROXY_DIR/teams/fxa.spend.json"
  o1="$(tick $((M + 60)))"; o2="$(tick $((M + 120)))"
  check "the budget frees: the row is claimed once, and the comment says Working" "claimed|1|0|1|Working: the agent is fixing the failing checks on ccccccc." \
    "$(s_of "${w1:-0}" | cut -d'|' -f1)|$(jq --argjson q "${w1:-0}" '[.runs[] | select(.run == $q)] | length' <<< "$o1")|$(jq --argjson q "${w1:-0}" '[.runs[] | select(.run == $q)] | length' <<< "$o2")|$(mine 90003)"
  routine_run_start "$w1" agent-fxw001; _prfix_set "$w1" '.new_sha = $s' --arg s "$P7"
  FXA_ROUTINE_NOW=$((M + 180)) routine_done "$w1" --state ok --session agent-fxw001 >/dev/null
  check "A15: done ok edits the same comment to Pushed, and the label is removed: one comment, edited at each step" \
    "1|Pushed 9999999. Next: review the fix commit, then approve the functional tests gate.|POST,PATCH,PATCH,PATCH,DELETE|Queued: the fix starts when a runner is free.,Waiting: the team budget is used. I try again each minute.,Working: the agent is fixing the failing checks on ccccccc.,Pushed 9999999. Next: review the fix commit, then approve the functional tests gate." \
    "$(mine 90003)|$(cut -d' ' -f1 "$tmp/app" | paste -sd, -)|$(grep -E '^(POST|PATCH) ' "$tmp/app" | cut -d' ' -f3- | paste -sd, -)"
  check "a tick after the end edits nothing more" "0" "$(: > "$tmp/app"; tick $((M + 240)) >/dev/null; grep -c . "$tmp/app")"
  # A19: a run whose runner does not boot frees its head: the comment says so, and a new request on that head runs.
  got="$(export FXA_TEAM_ACTOR=admin@example.com FXA_ROUTINE_NOW=$((M + 300)); cmd_routine run-now fxa "$rpf" --pr https://github.com/mozilla/fxa/pull/90004 2>&1)"; w2="$(sed -nE 's/^queued run ([0-9]+):.*/\1/p' <<< "$got")"
  tick $((M + 300)) >/dev/null; routine_run_start "$w2" agent-fxw002; _prfix_set "$w2" '.why = "boot"'; routine_run_fail "$w2" "the session could not start"
  tick $((M + 360)) >/dev/null
  check "A19: a boot failure says Not started on the PR, and frees the head" "1|Not started: the sandbox did not start. Add agent-help again to retry.|pr-90004-dddddddddddddddddddddddddddddddddddddddd-x$w2" \
    "$(mine 90004)|$(db_value "SELECT period FROM routine_runs WHERE id = ${w2:-0};")"
  got="$(export FXA_TEAM_ACTOR=admin@example.com FXA_ROUTINE_NOW=$((M + 400)); cmd_routine run-now fxa "$rpf" --pr https://github.com/mozilla/fxa/pull/90004 2>&1)"; w3="$(sed -nE 's/^queued run ([0-9]+):.*/\1/p' <<< "$got")"
  o3="$(tick $((M + 420)))"
  check "a new request on that head queues, starts, and the one comment says Working" "1|1|Working: the agent is fixing the failing checks on ddddddd." \
    "$(jq --argjson q "${w3:-0}" '[.runs[] | select(.run == $q)] | length' <<< "$o3")|$(mine 90004)"
  db_exec "UPDATE routine_runs SET state = 'stopped' WHERE state IN ('queued','claimed','started');"
  exit "$fail" ) || fail=1

# A store error is no answer, not a domain error.
got="$(db_exec() { return 1; }; tick $T 2>"$tmp/err")"; rc=$?
check "a store error: exit 1, the store line, and no answer" "1|ERROR: the routine store did not answer (busy or failed); nothing changed, try again|" "$rc|$(cat "$tmp/err")|$got"

exit "$fail"
