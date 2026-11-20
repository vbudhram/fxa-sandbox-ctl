#!/usr/bin/env bash
# Offline check that a pr_ticket routine's PR gets one Jira ticket when its run ends ok, from the bot or the tick.
#   bash lib/routine-pr-ticket.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR"; echo '{"teams": {}}' > "$FXA_TEAMS_DIR/index.json"
source "$here/db.sh"; source "$here/routines.sh"
db_init >/dev/null
errors_record() { echo "$1|$2|$5" >> "$tmp/errs"; }
session_create_jira() { echo "${PIPE_PROFILE:-}|$*" >> "$tmp/sj"; [ -z "${CREATE_FAILS:-}" ] || { echo "could not create a Jira ticket" >&2; return 1; }; echo FXA-77; }
pipeline_load() { PIPE_PROFILE="$1"; }
export PIPE_PROFILE=fxa-private
PR=https://github.com/mozilla/fxa-private/pull/5
cfg='{"name": "Nightly", "template": "code-review", "prompt": "look", "mode": "pr", "pr_ticket": true, "repos": ["mozilla/fxa-private"]}'
rr="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa-private', json($(db_q "$cfg"))); SELECT last_insert_rowid();")"
run() { # run <session> [cfg override]   a started run of the routine
  local o="${2:-}"; [ -n "$o" ] || o='{}'
  db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rr, 'p$RANDOM$RANDOM', 'started', $(db_q "$1"), 1, json($(db_q "$(jq -c ". + $o" <<< "$cfg")"))); SELECT last_insert_rowid();"; }
calls() { grep -c . "$tmp/sj" 2>/dev/null || true; }

r1="$(run agent-prt001)"
check "an ok run with a PR files one ticket for the session, with the routine's name" "ok|fxa-private|agent-prt001 --routine Nightly" \
  "$(routine_done "$r1" --state ok --session agent-prt001 --pr "$PR" | jq -r .state)|$(cat "$tmp/sj")"
check "a second done files nothing" "1" "$(routine_done "$r1" --state ok --session agent-prt001 --pr "$PR" >/dev/null; calls)"
r2="$(run agent-prt002 '{pr_ticket: false}')"
check "a routine without pr_ticket files nothing" "1" "$(routine_done "$r2" --state ok --session agent-prt002 --pr "$PR" >/dev/null; calls)"
r3="$(run agent-prt003)"
check "an ok run with no PR files nothing" "1" "$(routine_done "$r3" --state ok --session agent-prt003 >/dev/null; calls)"
r4="$(run agent-prt004 '{mode: "report"}')"
check "a report-mode run files nothing" "1" "$(routine_done "$r4" --state ok --session agent-prt004 --pr "$PR" >/dev/null; calls)"
r5="$(run agent-prt005)"
check "a failed create keeps the run ok and records the error" "ok|routine|jira_create_failed|no ticket for the PR: could not create a Jira ticket" \
  "$(CREATE_FAILS=1 routine_done "$r5" --state ok --session agent-prt005 --pr "$PR" | jq -r .state)|$(cat "$tmp/errs")"
r6="$(run agent-prt006)"
check "another team's run loads that team first" "other" \
  "$(db_exec "UPDATE routines SET team = 'other' WHERE id = $rr;"; routine_done "$r6" --state ok --session agent-prt006 --pr "$PR" >/dev/null; tail -1 "$tmp/sj" | cut -d'|' -f1)"
db_exec "UPDATE routines SET team = 'fxa-private' WHERE id = $rr;"

# The tick ends a run the bot missed: its session record has the PR and ended over 10 min ago.
session_live() { return 1; }
r7="$(run agent-prt007)"
jq -n --arg p "$PR" '{state: "pr_open", pr_url: $p}' > "$SESSION_DIR/agent-prt007.json"; touch -t 202601010000 "$SESSION_DIR/agent-prt007.json"
out="$(routine_reconcile "$(date +%s)" live)"
check "the tick's end files the ticket too, and prints nothing more" "ok|fxa-private|agent-prt007 --routine Nightly|" \
  "$(db_value "SELECT state FROM routine_runs WHERE id = $r7;")|$(tail -1 "$tmp/sj")|$out"
exit "$fail"
