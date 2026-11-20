#!/usr/bin/env bash
# Offline check of the investigation sweep (inv_sweep in lib/routines.sh): a team admin's label on a public ticket queues
# one run, a non-admin's or a twice-failed one gets one comment, and the tick hands the run to the bot. Jira is stubbed.
#   bash lib/routines-investigate.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR" "$FXA_LLM_PROXY_DIR/teams"; echo "PROFILE_CHANNELS=C0OWN00:fxa" > "$FXA_BOT_ENV"; echo '{"teams": {}}' > "$FXA_TEAMS_DIR/index.json"
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
_SESSIONS_PAUSE_URI=""
pipeline_folder_teams() { echo fxa; }
errors_record() { :; }; _teams_actor() { :; }; _teams_audit_note() { :; }
_routine_team_paused() { return 1; }
_routine_profile() { echo '{"private": false, "secret": false, "read_only": false, "repos": [{"slug": "mozilla/fxa", "role": "work"}]}'; }
_routine_free_slots() { echo 5; }
github_app_enabled() { return 1; }
pipeline_load() { PIPE_PROFILE="$1" PIPE_JIRA_SITE=https://jira.example.net; }
pipeline_jira_scope() { echo 'project = FXA AND level IS EMPTY'; }
_jira_sa() { return 0; }
# Jira: the search lists $tmp/keys; FXA-2 got the label from a non-admin, every other key from acc-a1; each write is logged
# with the run rows the store holds at that moment.
_jira_keys_for_jql() { echo "jql $1" >> "$tmp/log"; cat "$tmp/keys"; }
_jira_rest() { echo "rest $2" >> "$tmp/log"; local who=acc-a1; case "$2" in */FXA-2\?*) who=acc-p9 ;; esac
  jq -nc --arg w "$who" '{changelog: {histories: [{created: "2026-11-15T09:00:00.000+0000", author: {accountId: "acc-old"}, items: [{field: "labels", fromString: "", toString: "ai-investigate"}]},
    {created: "2026-11-15T10:00:00.000+0000", author: {accountId: $w}, items: [{field: "labels", fromString: "bug", toString: "bug ai-investigate"}]}]}}'; }
jira_admin_ids() { printf 'acc-a1\nacc-a2\n'; }
acli() { echo "unlabel $* rows=$(db_value "SELECT count(*) FROM routine_runs;")" >> "$tmp/log"; }
jira_comment() { printf 'comment %s %s\n' "$1" "$(printf '%s' "$2" | paste -sd' ' -)" >> "$tmp/log"; }
N=1794000000
rid="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', json($(db_q "$(jq -cn '{name: "Investigate", on: "jira-label", template: "investigate", mode: "report",
  repos: ["mozilla/fxa"], channel: "C0OWN00", max_usd: 10, env: "live", jira: {label: "ai-investigate", sweep_min: 5}}')"))); SELECT last_insert_rowid();")"
sweep() { db_exec "UPDATE routines SET swept_at = NULL WHERE id = $rid;"; : > "$tmp/log"; inv_sweep live "${1:-$N}" >>"$tmp/out" 2>>"$tmp/err"; }
rows() { db_value "SELECT json_extract(heads, '$.investigate.key') || ' ' || state || ' ' || trigger || ' ' || actor FROM routine_runs WHERE routine_id = $rid ORDER BY id;" | paste -sd, -; }

echo FXA-1 > "$tmp/keys"; sweep
check "the search is the team's public scope with the label, not done, oldest first" \
  'jql project = FXA AND level IS EMPTY AND labels = "ai-investigate" AND statusCategory != Done ORDER BY created ASC' "$(grep '^jql' "$tmp/log")"
check "an admin's label (the newest add) is removed before the one queued run" "FXA-1 queued jira-label acc-a1|unlabel jira workitem edit -k FXA-1 --remove-labels ai-investigate -y rows=0|0" \
  "$(rows)|$(grep '^unlabel' "$tmp/log")|$(grep -c '^comment' "$tmp/log")"
check "heads.investigate holds the key, the adder and the browse link" '{"key":"FXA-1","by":"acc-a1","url":"https://jira.example.net/browse/FXA-1"}' \
  "$(db_value "SELECT json(json_extract(heads, '$.investigate')) FROM routine_runs WHERE routine_id = $rid;")"
check "the full sweep sets swept_at; a sweep inside sweep_min reads nothing" "$N|0" \
  "$(db_value "SELECT swept_at FROM routines WHERE id = $rid;")|$(: > "$tmp/log"; inv_sweep live $((N + 60)) >/dev/null 2>&1; grep -c . "$tmp/log")"
sweep $((N + 1))
check "a ticket with a live run waits: no read, no label change, no second run" "1|0|0" \
  "$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rid;")|$(grep -c '^rest' "$tmp/log")|$(grep -c '^unlabel' "$tmp/log")"

echo FXA-2 > "$tmp/keys"; sweep
check "a non-admin's label: removed, one comment that says who can, no run" "1|1|0" \
  "$(grep -c '^unlabel .*-k FXA-2' "$tmp/log")|$(grep -c '^comment FXA-2 ::warning Only a team admin can start an investigation. Ask one to add ai-investigate.$' "$tmp/log")|$(db_value "SELECT count(*) FROM routine_runs WHERE json_extract(heads, '$.investigate.key') = 'FXA-2';")"

( _jira_rest() { echo '{"changelog": {"histories": []}}'; }; echo FXA-11 > "$tmp/keys"; sweep )
check "a ticket created with the label (no add in its changelog): the label goes, one comment, no run" "1|1|0" \
  "$(grep -c '^unlabel .*-k FXA-11' "$tmp/log")|$(grep -c '^comment FXA-11 ::warning I cannot tell who added ai-investigate' "$tmp/log")|$(db_value "SELECT count(*) FROM routine_runs WHERE json_extract(heads, '$.investigate.key') = 'FXA-11';")"
echo FXA-2 > "$tmp/keys"
( jira_admin_ids() { return 1; }; sweep )
check "an admin lookup that fails keeps the label: no comment, no run" "0|0|0" \
  "$(grep -c '^unlabel' "$tmp/log")|$(grep -c '^comment' "$tmp/log")|$(db_value "SELECT count(*) FROM routine_runs WHERE json_extract(heads, '$.investigate.key') = 'FXA-2';")"

db_exec "UPDATE routine_runs SET state = 'failed', ended_at = $N WHERE routine_id = $rid;"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, started_at, ended_at) VALUES ($rid, 'jira-FXA-1-x', 'failed', '{\"investigate\":{\"key\":\"FXA-1\"}}', $N, $((N + 10)));"
echo FXA-1 > "$tmp/keys"; sweep $((N + 100))
check "two failures in 24 h: the label goes, one comment, no run" "1|1|2" \
  "$(grep -c '^unlabel .*-k FXA-1' "$tmp/log")|$(grep -c '^comment FXA-1 ::warning The investigation of this ticket failed twice in 24 hours' "$tmp/log")|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rid;")"
sweep $((N + 86500))
check "a day later it starts again" "FXA-1 queued" "$(db_value "SELECT json_extract(heads, '$.investigate.key') || ' ' || state FROM routine_runs WHERE routine_id = $rid ORDER BY id DESC LIMIT 1;")"
db_exec "DELETE FROM routine_runs;"

printf 'FXA-3\nFXA-4\nbad key\nFXA-5\nFXA-6\n' > "$tmp/keys"; sweep
check "at most 3 keys a sweep, and a key that is not a key is skipped" "FXA-3,FXA-4" \
  "$(db_value "SELECT json_extract(heads, '$.investigate.key') FROM routine_runs ORDER BY id;" | paste -sd, -)"
db_exec "DELETE FROM routine_runs;"
acli() { return 1; }; echo FXA-7 > "$tmp/keys"; sweep
check "a label that Jira does not remove starts nothing" "0" "$(db_value "SELECT count(*) FROM routine_runs;")"
acli() { :; }
( PIPE_SECRET_TICKETS=1; echo FXA-8 > "$tmp/keys"; pipeline_load() { PIPE_PROFILE="$1"; PIPE_SECRET_TICKETS=1; }; sweep )
check "a secret team reads and starts nothing" "0|0" "$(db_value "SELECT count(*) FROM routine_runs;")|$(grep -c . "$tmp/log")"

# The tick claims the queued run as any run, and tells the bot it is an investigation.
echo FXA-9 > "$tmp/keys"; sweep
out="$(FXA_ROUTINE_NOW=$((N + 400)) routine_tick --env live 2>>"$tmp/err")"
check "the tick claims it: trigger jira-label, the key and its link" "jira-label|FXA-9|https://jira.example.net/browse/FXA-9|report|claimed" \
  "$(jq -r '.runs[0] | "\(.trigger)|\(.investigate.key)|\(.investigate.url)|\(.mode)"' <<< "$out")|$(db_value "SELECT state FROM routine_runs WHERE json_extract(heads, '$.investigate.key') = 'FXA-9';")"
check "run-now refuses a jira-label routine" "ERROR: routine ${rid} runs when a team admin adds its label to a Jira ticket; add the label to start it" \
  "$(routine_runnow fxa "$rid" 2>&1)"

# A run that waits behind another investigation of the routine waits up to 24 h, not 60 min, then posts one skip.
echo FXA-10 > "$tmp/keys"; db_exec "UPDATE routines SET swept_at = 0;"; sweep
q10="$(db_value "SELECT id FROM routine_runs WHERE json_extract(heads, '$.investigate.key') = 'FXA-10';")"
db_exec "UPDATE routine_runs SET state = 'started', session = 'agent-busy1', started_at = $((N + 500)) WHERE json_extract(heads, '$.investigate.key') = 'FXA-9';"
_mtime() { echo $((N + 9000)); }; session_live() { return 0; }; echo '{"state": "running"}' > "$SESSION_DIR/agent-busy1.json"
routine_reconcile $((N + 4000)) live >/dev/null
check "a queued investigation is still queued after 60 min" "queued" "$(db_value "SELECT state FROM routine_runs WHERE id = $q10;")"
out="$(FXA_ROUTINE_NOW=$((N + 90000)) routine_tick --env live 2>>"$tmp/err")"
check "after 24 h it is skipped, not failed, with no fix, and posts once on the skips list" "skipped|it waited 24 h||true|null" \
  "$(db_value "SELECT state || '|' || reason || '|' || coalesce(json_extract(heads, '$.fix'), '') FROM routine_runs WHERE id = $q10;")|$(jq -r --argjson q "$q10" '.skips[] | select(.run == $q) | "\(.post)|\(.fix)"' <<< "$out")"

# A Slack session's 'host: investigate <KEY>' (inv_ask; lib/asks.sh gates the team admin): a run with no label.
db_exec "DELETE FROM routine_runs;"; PIPE_PROFILE=fxa PIPE_JIRA_SITE=https://jira.example.net; : > "$tmp/log"
pipeline_key_in_scope() { [ "$1" != FXA-99 ]; }
check "routines off on the host, a bad key, a ticket out of scope, a secret team: refused, nothing queued" "1|1|1|1|0" \
  "$(ROUTINES_ENV= inv_ask FXA-20 agent-ab12 Ana | grep -c '^refused: routines are off')|$(ROUTINES_ENV=live inv_ask 'FXA-1;x' agent-ab12 Ana | grep -c '^refused: .* is not a Jira key')|$(ROUTINES_ENV=live inv_ask FXA-99 agent-ab12 Ana | grep -c "^refused: FXA-99 is not in team fxa's public Jira scope")|$(PIPE_SECRET_TICKETS=1 ROUTINES_ENV=live inv_ask FXA-20 agent-ab12 Ana | grep -c '^refused: team fxa takes secret tickets')|$(db_value "SELECT count(*) FROM routine_runs;")"
check "a dev host finds no live routine" "1" "$(ROUTINES_ENV=dev inv_ask FXA-20 agent-ab12 Ana | grep -c '^refused: team fxa has no active investigate routine')"
check "--check names the ticket and queues nothing" "Jira ticket FXA-20|0" "$(ROUTINES_ENV=live inv_ask FXA-20 - '' --check)|$(db_value "SELECT count(*) FROM routine_runs;")"
check "an ask queues one run with the asker and the session, and touches no Jira label" \
  "done: queued an investigation of FXA-20. Its result goes on the ticket as a comment, and this thread gets a line when it posts.|FXA-20 queued jira-label slack:Ana|agent-ab12|0" \
  "$(ROUTINES_ENV=live inv_ask FXA-20 agent-ab12 Ana)|$(rows)|$(db_value "SELECT json_extract(heads, '$.investigate.from') FROM routine_runs;")|$(grep -c . "$tmp/log")"
check "a second ask while it runs is refused" "refused: an investigation of FXA-20 already runs." "$(ROUTINES_ENV=live inv_ask FXA-20 agent-ab12 Ana)"
out="$(FXA_ROUTINE_NOW=$((N + 100000)) routine_tick --env live 2>>"$tmp/err")"
check "the tick hands the session to the bot" "FXA-20|agent-ab12" "$(jq -r '.runs[] | select(.investigate.key == "FXA-20") | "\(.investigate.key)|\(.investigate.from)"' <<< "$out")"
db_exec "UPDATE routine_runs SET state = 'failed', ended_at = $((N + 100000));"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, started_at, ended_at) VALUES ($rid, 'jira-FXA-20-y', 'failed', '{\"investigate\":{\"key\":\"FXA-20\"}}', $N, $((N + 100010)));"
check "two failures in 24 h refuse the ask" "1" "$(FXA_ROUTINE_NOW=$((N + 100100)) ROUTINES_ENV=live inv_ask FXA-20 agent-ab12 Ana | grep -c '^refused: the investigation of FXA-20 failed twice in 24 h')"
exit "$fail"
