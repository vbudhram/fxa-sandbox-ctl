#!/usr/bin/env bash
# Routines (epic i168, design ai/docs/design-docs/2026-10-17-routines.md): a team's scheduled prompts, in the
# store (lib/db/006-routines.sql). lib/routine.py is the one validator. Each write checks the version (a stale
# one exits 2) and writes a team_audit row that names the routine and the changed fields, never the prompt.
#
#   routine list <team> | get <id> | history <team> <id> | templates
#   routine set <team> <file> [--id <id> --version <v>]   create, or replace one at that version
#   routine pause | resume | delete | run-now | stop <team> <id>
#   routine tick --env live|dev                            the bot's 60 s pass: gates, claims, reconcile
#   routine done <run> --state <s> [--session <key>] [...] | posted <run>   the bot's results
# A command that names a team refuses a routine of another team.

_ROUTINE_PY() { python3 -I "${SANDBOX_ROOT}/lib/routine.py" "$@"; }
# The states of a run that is not over: Run now's queued, the tick's claimed, cmd_task's started.
_ROUTINE_LIVE_STATES="'queued','claimed','started'"
_ROUTINE_STALE="Someone changed this routine since you opened it. Load it again to see their change."
_ROUTINE_STORE="ERROR: the routine store did not answer (busy or failed); nothing changed, try again"

# _routine_profile <team>   The team's profile show (repos, private, read_only), in its own shell.
_routine_profile() { ( pipeline_load "$1" >/dev/null 2>&1 && pipeline_profile_json ); }

# No leading zero: bash reads 08 as octal, and $((08 + 1)) fails.
_ROUTINE_NUM='^(0|[1-9][0-9]{0,8})$'
# _routine_branch_ok <name>   The validator's branch rule (lib/routine.py BRANCH), for the host paths that read it back.
_routine_branch_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,59}$ ]] && [[ "$1" != *..* ]]; }
_routine_id() { [[ "${1:-}" =~ $_ROUTINE_NUM ]] || { echo "ERROR: bad routine id" >&2; return 1; }; }
_routine_row() { local j; j="$(db_json "SELECT id, team, env, paused, version, data FROM routines WHERE id = $1;")" || return 1; jq -c '.[0] // empty' <<< "$j"; }
# _routine_of <team> <id>   The row, only when it belongs to that team.
_routine_of() {
  _routine_id "$2" || return 1
  local r; r="$(_routine_row "$2")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  [ -n "$r" ] && [ "$(jq -r .team <<< "$r")" = "$1" ] || { echo "ERROR: team $1 has no routine $2" >&2; return 1; }
  printf '%s
' "$r"
}

# routine_list <team>   The team's routines, each with its config, next three run times, its live run and last
# result, and the scheduler's last tick (the dashboard warns when it is old).
routine_list() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: bad team name" >&2; return 1; }
  local rows r f out="[]" runs tick; rows="$(db_json "SELECT id, team, env, paused, version, data FROM routines WHERE team = $(db_q "$1") ORDER BY id;")" || return 1
  runs="$(db_json "SELECT r.routine_id, r.id, r.state, r.reason, r.session, r.pr_url, r.started_at, r.ended_at, r.state IN (${_ROUTINE_LIVE_STATES}) AS live
    FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE t.team = $(db_q "$1") AND r.id IN
    (SELECT max(id) FROM routine_runs GROUP BY routine_id, state IN (${_ROUTINE_LIVE_STATES}));")" || return 1
  tick="$(db_value "SELECT at FROM routine_tick WHERE id = 1;")" || return 1
  f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    jq -c '.data | fromjson' <<< "$r" > "$f"
    out="$(jq -c --argjson r "$r" --argjson next "$(_ROUTINE_PY next "$f" | jq -R . | jq -sc .)" --argjson runs "$runs" --arg tick "$tick" \
      '($runs | map(select(.routine_id == $r.id)) | map(del(.routine_id))) as $mine
       | . + [$r + {data: ($r.data | fromjson), next: $next, live: ($mine | map(select(.live == 1)) | first),
          last: ($mine | map(select(.live == 0)) | first), tick: ($tick | tonumber? // null)}]' <<< "$out")"
  done < <(jq -c '.[]' <<< "$rows")
  rm -f "$f"; printf '%s\n' "$out"
}

routine_get() { _routine_id "$1" || return 1; local r; r="$(_routine_row "$1")"; [ -n "$r" ] || { echo "ERROR: no routine $1" >&2; return 1; }; jq -c '.data |= fromjson' <<< "$r"; }

# routine_set <team> <file> [<id> <version>]   Validate, then insert, or update only at that version.
routine_set() {
  local team="$1" file="$2" id="${3:-}" ver="${4:-}" prof idx out n row old
  [[ "$team" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [ -f "$file" ] || { echo "usage: routine set <team> <file> [--id <id> --version <v>]" >&2; return 1; }
  [ -n "$id" ] || [ -z "$ver" ] || { echo "ERROR: an edit needs --id" >&2; return 1; }
  # A team record that is gone, or that teams_delete is removing, takes no new routine.
  if [ -e "${FXA_TEAMS_DIR}/${team}.deleting" ] || { [ ! -f "${FXA_TEAMS_DIR}/${team}.json" ] && ! pipeline_folder_teams | grep -qx "$team"; }; then
    echo "ERROR: no team ${team}" >&2; return 1
  fi
  if [ -n "$id" ]; then
    _routine_id "$id" && [[ "$ver" =~ $_ROUTINE_NUM ]] || { echo "ERROR: an edit needs --id and --version (a number)" >&2; return 1; }
    row="$(_routine_of "$team" "$id")" || return 1
  fi
  prof="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  _routine_profile "$team" > "$prof" && [ -s "$prof" ] || { rm -f "$prof"; echo "ERROR: team ${team} does not load" >&2; return 1; }
  # For the validator's field line only: the INSERT holds the cap itself.
  n="$(db_value "SELECT count(*) FROM routines WHERE team = $(db_q "$team") AND id != ${id:-0};")" && [[ "$n" =~ ^[0-9]+$ ]] \
    || { rm -f "$prof"; echo "$_ROUTINE_STORE" >&2; return 1; }
  local rc=0; out="$(_ROUTINE_PY validate "$file" "$team" --profile "$prof" --index "${FXA_TEAMS_DIR:-/nonexistent}/index.json" \
    --bot-env "${FXA_BOT_ENV:-${SANDBOX_ROOT}/../fxa-agent-bot/.env}" --count "${n:-8}")" || rc=$?
  rm -f "$prof"; [ "$rc" = 0 ] || return 1
  local who env; who="$(_teams_actor)"; env="$(jq -r .env <<< "$out")"
  if [ -z "$id" ]; then
    # The cap in the INSERT itself: two saves at once cannot both pass a count read before them.
    id="$(db_value "INSERT INTO routines (team, data, env, created_by, updated_by, updated_at, saved_at) SELECT $(db_q "$team"), json($(db_q "$out")), $(db_q "$env"), $(db_q "$who"), $(db_q "$who"), $(date +%s), $(_routine_now)
      WHERE (SELECT count(*) FROM routines WHERE team = $(db_q "$team")) < 8; SELECT CASE WHEN changes() = 1 THEN last_insert_rowid() ELSE 0 END;")" || id=""
    case "$id" in ''|*[!0-9]*) echo "$_ROUTINE_STORE" >&2; return 1 ;; 0) echo "routine: A team has at most 8 routines" >&2; return 1 ;; esac
    _teams_audit_note routine-create "$team" "routine ${id}"
    echo "created routine ${id}"; return 0
  fi
  old="$(jq -c '.data | fromjson' <<< "$row")"
  local n_up; n_up="$(db_value "UPDATE routines SET data = json($(db_q "$out")), env = $(db_q "$env"), version = version + 1, updated_by = $(db_q "$who"), updated_at = $(date +%s), saved_at = $(_routine_now) WHERE id = ${id} AND version = ${ver}; SELECT changes();")" || n_up=""
  case "$n_up" in 1) ;; 0) echo "ERROR: ${_ROUTINE_STALE}" >&2; return 2 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
  # The names of the changed fields, never their values: a prompt is the team's text.
  _teams_audit_note routine-set "$team" "routine ${id}: $(jq -nr --argjson a "$old" --argjson b "$out" '[($a + $b | keys[]) | select($a[.] != $b[.])] | join(",")')"
  echo "saved routine ${id} (version $((ver + 1)))"
}

# routine_state <team> <id> <pause|resume|delete>
routine_state() {
  local team="$1"; shift
  _routine_of "$team" "$1" >/dev/null || return 1
  case "$2" in
    pause|resume) db_exec "UPDATE routines SET paused = $([ "$2" = pause ] && echo 1 || echo 0), version = version + 1, updated_by = $(db_q "$(_teams_actor)"), updated_at = $(date +%s) WHERE id = $1;" || return 1 ;;
    delete)
      # A live run keeps its row: it reports back to this routine when it ends. One statement, so a run
      # claimed between a check and the delete cannot lose its routine.
      local n_del; n_del="$(db_value "DELETE FROM routines WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM routine_runs WHERE routine_id = $1 AND state IN (${_ROUTINE_LIVE_STATES})); SELECT changes();")" || n_del=""
      case "$n_del" in 1) ;; 0) echo "ERROR: a run of routine $1 is in progress; stop it first" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac ;;
  esac
  _teams_audit_note "routine-$2" "$team" "routine $1"
  echo "routine $1: $2 done"
}

_ROUTINE_LIVE="EXISTS (SELECT 1 FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE t.team = %s AND r.state IN (${_ROUTINE_LIVE_STATES}))"

# routines_drop_team <team>   A deleted team's routines go with it, so a later team of that name gets none;
# their history stays. Refused while one of them has a live run. A store error fails: the caller then
# deletes nothing more.
routines_drop_team() {
  # No store on this host (no sqlite3): no routine can exist here.
  declare -F db_exec >/dev/null && command -v sqlite3 >/dev/null || return 0
  local q live n; q="$(db_q "$1")"; live="$(printf "$_ROUTINE_LIVE" "$q")"
  n="$(db_value "SELECT count(*) FROM routines WHERE team = $q; SELECT $live;")" && [[ "$n" =~ ^[0-9]+$'\n'[01]$ ]] \
    || { echo "ERROR: could not read team $1's routines from the store" >&2; return 1; }
  [ "${n#*$'\n'}" = 0 ] || { echo "ERROR: team $1 has a routine run in progress; stop it first" >&2; return 1; }
  [ "${n%$'\n'*}" -gt 0 ] || return 0
  # One statement, with the live-run guard in it; the audit count is what it removed.
  n="$(db_value "DELETE FROM routines WHERE team = $q AND NOT $live; SELECT changes();")" && [[ "$n" =~ ^[0-9]+$ ]] \
    || { echo "ERROR: could not delete team $1's routines from the store" >&2; return 1; }
  _teams_audit_note routine-delete "$1" "all ${n} routines, with the team"
}

# routines_clear_name <team> <since epoch>   A new team, or a record this host sees for the first time:
# routines saved under the name before that time belong to an earlier team of the name (a save that raced
# its delete), and a .deleting marker is stale. A team never inherits them.
routines_clear_name() {
  rm -f "${FXA_TEAMS_DIR}/$1.deleting"
  declare -F db_exec >/dev/null && command -v sqlite3 >/dev/null && [[ "${2:-}" =~ ^[0-9]+$ ]] || return 0
  local n; n="$(db_value "DELETE FROM routines WHERE team = $(db_q "$1") AND coalesce(updated_at, 0) < $2; SELECT changes();")" && [[ "$n" =~ ^[0-9]+$ ]] \
    || { echo "ERROR: could not clear old routines under the name $1" >&2; return 1; }
  [ "$n" = 0 ] || _teams_audit_note routine-delete "$1" "${n} routines of an earlier team of this name"
}

routine_history() { _routine_of "$1" "$2" >/dev/null || return 1; db_json "SELECT id, period, trigger, actor, state, reason, session, pr_url, cost_usd, started_at, ended_at FROM routine_runs WHERE routine_id = $2 ORDER BY id DESC LIMIT 20;"; }

cmd_routine() {
  case "${1:-}" in
    list) routine_list "${2:-}" ;;
    get) routine_get "${2:-}" ;;
    history) routine_history "${2:-}" "${3:-}" ;;
    templates) _ROUTINE_PY templates ;;
    tick) shift; routine_tick "$@" ;;
    done) shift; routine_done "$@" ;;
    posted) routine_posted "${2:-}" ;;
    run-now) routine_runnow "${2:-}" "${3:-}" ;;
    stop) routine_stop "${2:-}" "${3:-}" ;;
    set) local team="${2:-}" file="${3:-}" id="" ver=""; shift 3 2>/dev/null || shift $#
         while [ $# -gt 0 ]; do
           case "$1" in --id) id="${2:-}"; shift 2 2>/dev/null || shift ;; --version) ver="${2:-}"; shift 2 2>/dev/null || shift ;;
             *) echo "ERROR: unknown option $1" >&2; return 1 ;; esac
         done
         routine_set "$team" "$file" "$id" "$ver" ;;
    pause|resume|delete) routine_state "${2:-}" "${3:-}" "$1" ;;
    *) echo "usage: fxa-sandbox-ctl routine list <team> | get <id> | history <team> <id> | templates | set <team> <file> [--id <id> --version <v>] | pause|resume|delete|run-now|stop <team> <id> | tick --env live|dev | done <run> ... | posted <run>" >&2; return 1 ;;
  esac
}

# routine_run_read <run> <team>   The claimed run's row ({id, routine_id, team, config, heads}), for cmd_task
# (D7: ctl reads what to run from the row, never from the caller). Refuses a run of another team, one that
# is not claimed, or one that already has a session. A store error says so.
routine_run_read() {
  _routine_id "$1" || return 1
  local j r; j="$(db_json "SELECT r.id, r.routine_id, t.team, r.state, r.session, r.config, r.heads FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE r.id = $1;")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  r="$(jq -c '.[0] // empty' <<< "$j")"
  [ -n "$r" ] || { echo "ERROR: no routine run $1" >&2; return 1; }
  [ "$(jq -r .team <<< "$r")" = "$2" ] || { echo "ERROR: routine run $1 is not a run of team $2" >&2; return 1; }
  [ "$(jq -r '"\(.state)|\(.session // "")"' <<< "$r")" = "claimed|" ] || { echo "ERROR: routine run $1 is not claimed" >&2; return 1; }
  jq -c '{id, routine_id, team, config: (.config // "null" | fromjson), heads: (.heads // "null" | fromjson)}' <<< "$r" 2>/dev/null \
    || { echo "ERROR: routine run $1 has no readable config" >&2; return 1; }
}

# routine_run_start <run> <key>   Take the claimed run for this session: one guarded UPDATE, so of two
# callers at once only one gets it.
routine_run_start() {
  local n; n="$(db_value "UPDATE routine_runs SET state = 'started', session = $(db_q "$2"), started_at = $(date +%s) WHERE id = $1 AND state = 'claimed' AND session IS NULL; SELECT changes();")" || n=""
  case "$n" in 1) ;; 0) echo "ERROR: routine run $1 is not claimed" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
}

# routine_run_fail <run> <reason>   A started run whose session could not start.
routine_run_fail() {
  db_exec "UPDATE routine_runs SET state = 'failed', reason = $(db_q "$2"), ended_at = $(date +%s) WHERE id = $1 AND state IN (${_ROUTINE_LIVE_STATES});" >/dev/null
}

# ── The tick (slice 3): the bot calls `routine tick --env live|dev` every 60 s (D4, D5) ──

# The clock: FXA_ROUTINE_NOW in a check, else the host's.
_routine_now() { if [[ "${FXA_ROUTINE_NOW:-}" =~ ^[0-9]{9,11}$ ]]; then echo "$FXA_ROUTINE_NOW"; else date +%s; fi; }

# _routine_head <slug> <branch or "">   The branch head's 40-hex SHA (the default branch when none), or fail.
_routine_head() {
  local sha; sha="$(gh api "repos/$1/commits/${2:-HEAD}" --jq .sha 2>/dev/null)" && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && echo "$sha"
}
# _routine_team_paused <team>   The pause reason of the team's pipeline (exit 0), nothing (exit 1), or exit 2
# when the team does not load (fail closed: the caller skips it).
_routine_team_paused() {
  local out rc=0; out="$( ( pipeline_load "$1" >/dev/null 2>&1 || exit 2; pipeline_paused ) )" || rc=$?
  [ "$rc" = 2 ] && return 2; [ "$rc" = 0 ] && { printf '%s\n' "${out:-paused}"; return 0; }; return 1
}
# _routine_sessions_paused   The operator's sessions pause reason, or nothing.
_routine_sessions_paused() { local w=""; w="$(sessions_paused 2>/dev/null)" || w=""; printf '%s' "$w"; }
# _routine_free_slots   Session slots left under the cap.
_routine_free_slots() {
  local f live=0; for f in "$SESSION_DIR"/agent-*.json; do [ -f "$f" ] && session_live "$(basename "$f" .json)" && live=$((live + 1)); done
  echo $(( $(_session_cap) - live ))
}
# _routine_team_state <team>   active, or why not; "" when no such team (no record and no folder).
_routine_team_state() {
  if [ -f "${FXA_TEAMS_DIR}/$1.json" ]; then
    local st; st="$(jq -r '.status // "draft"' "${FXA_TEAMS_DIR}/$1.json" 2>/dev/null)" || { echo "the team's record cannot be read"; return 0; }
    [ "$st" = active ] && echo active || echo "the team is not active"
  elif pipeline_folder_teams | grep -qx "$1"; then echo active; fi
}
# _routine_post <routine> <reason>   true unless the last posted skip of this routine had the same reason and no
# result came after it (D23).
_routine_post() {
  local last; last="$(db_value "SELECT state || char(9) || coalesce(reason, '') FROM routine_runs WHERE routine_id = $1 AND ((posted = 1 AND state IN ('skipped','failed')) OR state IN ('ok','report','nochange')) ORDER BY id DESC LIMIT 1;")" || return 1
  case "$last" in skipped$'\t'"$2"|failed$'\t'"$2") echo false ;; *) echo true ;; esac
}
# _routine_heads <config json> <routine id>   {"<slug>": {start, head}}: each head read live (fail closed), each
# start the head of this routine's last started run.
_routine_heads() {
  local slug br head start out="{}" prev
  # Only a run that reached a result: a stopped or failed one reviewed nothing, so it moves no start.
  prev="$(db_value "SELECT heads FROM routine_runs WHERE routine_id = $2 AND heads IS NOT NULL AND state IN ('ok','report','nochange') ORDER BY id DESC LIMIT 1;")" || return 1
  [ -n "$prev" ] || prev='{}'
  br="$(jq -r '.branch // ""' <<< "$1")"
  for slug in $(jq -r '.repos[]' <<< "$1"); do
    head="$(_routine_head "$slug" "$br")" || { echo "cannot read the head of ${slug}" >&2; return 3; }
    start="$(jq -r --arg s "$slug" '.[$s].head // empty' <<< "$prev" 2>/dev/null || true)"
    out="$(jq -c --arg s "$slug" --arg h "$head" --arg st "$start" '. + {($s): {start: (if $st == "" then null else $st end), head: $h}}' <<< "$out")"
  done
  printf '%s\n' "$out"
}

# _routine_run_info <routine id> <team> <config json>   What the bot posts and checks for a run: the name, mode,
# template, repos and branch, private (the team has a private repo; true when the team does not load, so the
# bot's private-channel check fails closed), and since (the start of the last run with a result, or null).
_routine_run_info() {
  local priv since
  priv="$(_routine_profile "$2" 2>/dev/null | jq -r 'if .private == false then "false" else "true" end' 2>/dev/null)" || priv=true
  [ "$priv" = false ] || priv=true
  since="$(db_value "SELECT started_at FROM routine_runs WHERE routine_id = $1 AND state IN ('ok','report','nochange') ORDER BY id DESC LIMIT 1;")" || since=""
  jq -c --argjson p "$priv" --arg s "$since" '{name, mode, template: (.template // "blank"), repos, branch: (.branch // null), private: $p,
    since: (if $s == "" then null else ($s | tonumber) end)}' <<< "$3"
}

# routine_tick --env <live|dev>   One pass: heartbeat, reconcile, then each routine of that env's latest period.
# Answers {"runs": [...], "skips": [...]} for the bot. A store error answers nothing and exits 1.
routine_tick() {
  [ "${1:-}" = --env ] && [[ "${2:-}" =~ ^(live|dev)$ ]] || { echo "usage: routine tick --env live|dev" >&2; return 1; }
  local env="$2" now; now="$(_routine_now)"
  db_exec "INSERT INTO routine_tick (id, at) VALUES (1, $now) ON CONFLICT (id) DO UPDATE SET at = excluded.at;" >/dev/null || { echo "$_ROUTINE_STORE" >&2; return 1; }
  routine_reconcile "$now" || return 1
  local rows; rows="$(db_json "SELECT id, team, paused, data, coalesce(saved_at, 0) AS saved_at FROM routines WHERE env = $(db_q "$env") ORDER BY id;")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  # A manual run (Run now) waits as queued: one guarded UPDATE hands it to this tick only.
  local free; free="$(_routine_free_slots)"
  local queued q runs="[]" skips="[]"
  queued="$(db_json "SELECT r.id, r.routine_id, t.team, t.data FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE r.state = 'queued' AND t.env = $(db_q "$env");")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    # The slot gate as for a scheduled run: it waits queued (and reconcile fails it after 60 min).
    [ "$free" -ge 2 ] || continue
    [ "$(db_value "UPDATE routine_runs SET state = 'claimed', started_at = $now WHERE id = $(jq -r .id <<< "$q") AND state = 'queued'
      AND NOT EXISTS (SELECT 1 FROM routine_runs o WHERE o.routine_id = $(jq -r .routine_id <<< "$q") AND o.id != $(jq -r .id <<< "$q") AND o.state IN ('claimed','started')); SELECT changes();")" = 1 ] || continue
    free=$((free - 1))
    runs="$(jq -c --argjson q "$q" --argjson i "$(_routine_run_info "$(jq -r .routine_id <<< "$q")" "$(jq -r .team <<< "$q")" "$(jq -c '.data | fromjson' <<< "$q")")" \
      '. + [{run: $q.id, routine: $q.routine_id, team: $q.team, trigger: "manual", channel: ($q.data | fromjson | .channel)} + $i]' <<< "$runs")"
  done < <(jq -c '.[]' <<< "$queued")
  local r f; f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  local spaused; spaused="$(_routine_sessions_paused)"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    local id team cfg due period at next age why heads n post st tp
    id="$(jq -r .id <<< "$r")"; team="$(jq -r .team <<< "$r")"; cfg="$(jq -c '.data | fromjson' <<< "$r")"
    printf '%s' "$cfg" > "$f"
    due="$(_ROUTINE_PY due "$f" "$now" "$(jq -r '.saved_at // 0' <<< "$r")")" || continue
    [ "$due" != null ] || continue
    period="$(jq -r .period <<< "$due")"; at="$(jq -r .at <<< "$due")"; next="$(jq -r '.next // empty' <<< "$due")"
    n="$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $id AND period = $(db_q "$period");")" || { rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1; }
    [ "$n" = 0 ] || continue
    age=$((now - at))
    # A late period is not caught up (D17).
    if [ "$age" -gt 3600 ]; then
      db_exec "INSERT OR IGNORE INTO routine_runs (routine_id, period, trigger, state, reason, ended_at) VALUES ($id, $(db_q "$period"), 'schedule', 'missed', 'the tick did not run within 60 min of the time', $now);" >/dev/null
      continue
    fi
    # A routine of a team that is gone is never claimed, and records nothing.
    st="$(_routine_team_state "$team")"; [ -n "$st" ] || continue
    why=""; heads=""
    if [ "$st" != active ]; then why="$st"
    elif [ -n "$spaused" ]; then why="agent sessions are paused: ${spaused}"
    else
      local prc=0; tp="$(_routine_team_paused "$team")" || prc=$?
      case $prc in 0) why="the team is paused: ${tp}" ;; 2) why="the team does not load" ;; esac
    fi
    [ -n "$why" ] || why="$(_ROUTINE_PY budget "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.json" "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.spend.json" "$now")"
    [ -n "$why" ] || [ "$(jq -r .paused <<< "$r")" = 0 ] || why="the routine is paused"
    if [ -z "$why" ]; then
      n="$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES});")" || { rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1; }
      [ "$n" = 0 ] || why="a run of this routine is still in progress"
    fi
    if [ -z "$why" ]; then
      local hrc=0; heads="$(_routine_heads "$cfg" "$id" 2>/dev/null)" || hrc=$?
      case $hrc in 0) ;; 3) why="cannot read the branch head" ;; *) rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
    fi
    if [ -z "$why" ] && [ "$(jq -r '.skip_no_commits // true' <<< "$cfg")" = true ] \
        && [ "$(jq -r '[.[] | .start == .head] | all' <<< "$heads")" = true ]; then why="no new commits since the last run"; fi
    if [ -z "$why" ] && [ "$free" -lt 2 ]; then
      # Waiting for a slot stays unclaimed; 30 min after the time it fails (D16).
      [ "$age" -ge 1800 ] || continue
      why="no runner free"; st=failed
    elif [ -n "$why" ]; then st=skipped
    else st=claimed; fi
    # A claim also checks, in the same statement, that no run of the routine is live (a run-now raced it).
    n="$(db_value "INSERT OR IGNORE INTO routine_runs (routine_id, period, trigger, state, reason, config, heads, started_at, ended_at)
      SELECT $id, $(db_q "$period"), 'schedule', '$st', $( [ -n "$why" ] && db_q "$why" || echo NULL ), json($(db_q "$cfg")), $( [ -n "$heads" ] && echo "json($(db_q "$heads"))" || echo NULL ),
      $( [ "$st" = claimed ] && echo "$now" || echo NULL ), $( [ "$st" = claimed ] && echo NULL || echo "$now" )
      WHERE '$st' != 'claimed' OR NOT EXISTS (SELECT 1 FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES}));
      SELECT changes() || '|' || last_insert_rowid();")" \
      || { rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1; }
    # Only the tick whose INSERT wrote the row answers it: two ticks at once answer one run (D15).
    [ "${n%%|*}" = 1 ] || continue
    if [ "$st" = claimed ]; then
      free=$((free - 1))
      runs="$(jq -c --argjson id "${n#*|}" --argjson rid "$id" --arg t "$team" --argjson c "$cfg" --argjson i "$(_routine_run_info "$id" "$team" "$cfg")" \
        '. + [{run: $id, routine: $rid, team: $t, trigger: "schedule", channel: $c.channel} + $i]' <<< "$runs")"
    else
      post="$(_routine_post "$id" "$why")" || post=false
      [ "$(jq -r .paused <<< "$r")" = 0 ] || post=false   # an admin's own pause is not news in Slack
      # template and private: the bot checks the channel before it posts a skip too (D8).
      skips="$(jq -c --argjson id "${n#*|}" --argjson rid "$id" --arg t "$team" --argjson c "$cfg" --arg why "$why" --arg next "$next" --argjson post "$post" \
        --argjson i "$(_routine_run_info "$id" "$team" "$cfg")" \
        '. + [{run: $id, routine: $rid, team: $t, name: $c.name, channel: $c.channel, template: $i.template, private: $i.private, reason: $why, next: (if $next == "" then null else ($next | tonumber) end), post: $post}]' <<< "$skips")"
    fi
  done < <(jq -c '.[]' <<< "$rows")
  rm -f "$f"
  jq -nc --argjson runs "$runs" --argjson skips "$skips" '{runs: $runs, skips: $skips}'
}

# routine_reconcile <now>   Live runs, from their session records (D14): a run the bot never reported on still
# ends. pr_open or a pr_url is ok with that PR; a session that is gone, unreadable, paused, stopped or failed with
# no done call fails (a paused one is stopped first: nobody will answer it); a started run past 120 min is stopped
# and fails; a claimed run with no session after 10 min, or a queued one after 60, fails. Each change is one
# UPDATE guarded on the state it read, so a done call or a second tick at the same time cannot be undone.
routine_reconcile() {
  local now="$1" rows r id st sess since rec sst pr why
  rows="$(db_json "SELECT id, state, coalesce(session, '') AS session, coalesce(started_at, 0) AS since FROM routine_runs WHERE state IN (${_ROUTINE_LIVE_STATES});")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    id="$(jq -r .id <<< "$r")"; st="$(jq -r .state <<< "$r")"; sess="$(jq -r .session <<< "$r")"; since="$(jq -r .since <<< "$r")"
    why=""; pr=""; sst=""
    case "$st" in
      queued) [ "$since" -gt 0 ] && [ $((now - since)) -gt 3600 ] && why="no tick started it within 60 min" ;;
      claimed) [ -z "$sess" ] && [ "$since" -gt 0 ] && [ $((now - since)) -gt 600 ] && why="no session started within 10 min" ;;
      started)
        rec="${SESSION_DIR}/${sess}.json"
        if ! [[ "$sess" =~ ^agent-[a-z0-9]{4,12}$ ]] || [ ! -f "$rec" ]; then why="the run's session is gone"
        elif ! sst="$(jq -r '"\(.state // "")\t\(.pr_url // "")"' "$rec" 2>/dev/null)"; then why="the run's session record cannot be read"
        else
          pr="${sst#*$'\t'}"; sst="${sst%%$'\t'*}"
          # A session that ended (stopped, failed or pr_open) keeps its run for 10 min from the record's last
          # write, so the bot's own done call, a little late, still lands on a live row.
          local ended=0; { [ -n "$pr" ] || [[ "$sst" =~ ^(stopped|failed|pr_open)$ ]]; } && ! session_live "$sess" && ended=1
          if [ "$ended" = 1 ] && [ $((now - $(_mtime "$rec" 2>/dev/null || echo 0))) -lt 600 ]; then continue; fi
          if { [ -n "$pr" ] || [ "$sst" = pr_open ]; } && ! session_live "$sess"; then :
          else
            pr=""
            case "$sst" in
              paused) session_stop "$sess" </dev/null >/dev/null 2>&1 || true; why="the session paused with no result" ;;
              stopped|failed) why="the session ${sst} with no result" ;;
              *) [ "$since" -gt 0 ] && [ $((now - since)) -gt 7200 ] && { session_stop "$sess" </dev/null >/dev/null 2>&1 || true; why="the run took over 120 min"; } ;;
            esac
            [ -n "$why" ] || continue
          fi
        fi ;;
    esac
    if [ -n "$pr" ] || [ "$st:$sst" = "started:pr_open" ]; then
      db_exec "UPDATE routine_runs SET state = 'ok', pr_url = $( [ -n "$pr" ] && db_q "$pr" || echo NULL ), ended_at = $now WHERE id = $id AND state = 'started';" >/dev/null \
        || { echo "$_ROUTINE_STORE" >&2; return 1; }
    elif [ -n "$why" ]; then
      local n; n="$(db_value "UPDATE routine_runs SET state = 'failed', reason = $(db_q "$why"), ended_at = $now WHERE id = $id AND state = '$st'; SELECT changes();")" \
        || { echo "$_ROUTINE_STORE" >&2; return 1; }
      [ "$n" = 1 ] && errors_record routine run_failed "$sess" "routine tick" "routine run ${id}: ${why}" ""
    fi
    sst=""
  done < <(jq -c '.[]' <<< "$rows")
  return 0
}

# _routine_session_cost <key>   What the session's run token spent (the LLM proxy's count), or nothing.
_routine_session_cost() {
  local d="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}" tok
  tok="$(cat "${d}/runs/$(worktree_branch_for "$1")" 2>/dev/null)" && [[ "$tok" =~ ^fxl_[A-Za-z0-9]{32}$ ]] || return 0
  jq -r '.spent_usd // empty' "${d}/tokens/${tok}.json" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)?$' || true
}

# routine done <run> --state ok|report|nochange|failed|stopped [--session <key>] [--pr <url>] [--reason <text>]
#   [--report-file <f>]   The bot's result. Idempotent: a run in an end state does not change. A report goes
#   through lib/pii_guard.py: a finding answers post false, and the report stays only in the row (D10).
#   Answers {changed, state, post, next}.
routine_done() {
  local run="${1:-}" state="" sess="" pr="" reason="" rf=""; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in --state) state="${2:-}" ;; --session) sess="${2:-}" ;; --pr) pr="${2:-}" ;; --reason) reason="${2:-}" ;; --report-file) rf="${2:-}" ;;
      *) echo "ERROR: unknown option $1" >&2; return 1 ;; esac
    shift 2 2>/dev/null || { echo "ERROR: $1 needs a value" >&2; return 1; }
  done
  _routine_id "$run" || return 1
  [[ "$state" =~ ^(ok|report|nochange|failed|stopped)$ ]] || { echo "ERROR: --state must be ok, report, nochange, failed or stopped" >&2; return 1; }
  # No --session: a run the bot refused before any session (its channel check), so the row must have none.
  [ -z "$sess" ] || [[ "$sess" =~ ^agent-[a-z0-9]{4,12}$ ]] || { echo "ERROR: --session must look like agent-7f3a" >&2; return 1; }
  [ -z "$pr" ] || [[ "$pr" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || { echo "ERROR: --pr must be a GitHub PR link" >&2; return 1; }
  [ ${#reason} -le 300 ] && [[ "$reason" != *$'\n'* ]] || { echo "ERROR: --reason is one line of at most 300 characters" >&2; return 1; }
  local j r; j="$(db_json "SELECT r.state, coalesce(r.session, '') AS session, t.data FROM routine_runs r LEFT JOIN routines t ON t.id = r.routine_id WHERE r.id = ${run};")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  r="$(jq -c '.[0] // empty' <<< "$j")"; [ -n "$r" ] || { echo "ERROR: no routine run ${run}" >&2; return 1; }
  [ "$(jq -r .session <<< "$r")" = "$sess" ] || { echo "ERROR: routine run ${run} is not session ${sess:-(none)}'s" >&2; return 1; }
  if [ -z "$sess" ]; then
    [ "$state" = failed ] || { echo "ERROR: done with no --session only fails a run" >&2; return 1; }
    [[ "$(jq -r .state <<< "$r")" =~ ^(claimed|queued)$ ]] || { echo "ERROR: routine run ${run} is $(jq -r .state <<< "$r"): done with no --session takes only a claimed or queued run" >&2; return 1; }
  fi
  local next="" f; f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  if jq -e '.data' <<< "$r" >/dev/null 2>&1; then jq -r .data <<< "$r" > "$f"; next="$(_ROUTINE_PY due "$f" "$(_routine_now)" 2>/dev/null | jq -r '.next // empty' 2>/dev/null)" || next=""; fi
  local post=true report="" n guard="state IN (${_ROUTINE_LIVE_STATES})"
  # A run with no session: guarded in the UPDATE too, so a session that took it meanwhile keeps it.
  [ -n "$sess" ] || guard="state IN ('claimed','queued') AND session IS NULL"
  if [ -n "$rf" ]; then
    [ -f "$rf" ] || { rm -f "$f"; echo "ERROR: no report file ${rf}" >&2; return 1; }
    report="$(head -c 65536 "$rf")"
    # Any finding, or a guard that does not answer, keeps the report off Slack (fail closed).
    # A report that cannot be written for the guard is not scanned, so it is not posted.
    if jq -n --arg t "$report" '{report: $t}' > "$f" 2>/dev/null; then
      : > "$f.diff"; python3 -I "${SANDBOX_ROOT}/lib/pii_guard.py" "$f" "$f.diff" >/dev/null 2>&1 || post=false
    else post=false; fi
    rm -f "$f.diff"
  fi
  rm -f "$f"
  n="$(db_value "UPDATE routine_runs SET state = $(db_q "$state"), reason = $( [ -n "$reason" ] && db_q "$reason" || echo NULL ),
      pr_url = $( [ -n "$pr" ] && db_q "$pr" || echo pr_url ), report = $( [ -n "$rf" ] && db_q "$report" || echo report ),
      cost_usd = $( { [ -n "$sess" ] && _routine_session_cost "$sess"; } | grep . || echo cost_usd), ended_at = $(_routine_now)
      WHERE id = ${run} AND ${guard}; SELECT changes();")" || n=""
  case "$n" in
    1) jq -nc --arg s "$state" --argjson p "$post" --arg n "$next" '{changed: true, state: $s, post: $p, next: (if $n == "" then null else ($n | tonumber) end)}' ;;
    0) jq -nc --arg s "$(db_value "SELECT state FROM routine_runs WHERE id = ${run};")" --arg n "$next" '{changed: false, state: $s, post: false, next: (if $n == "" then null else ($n | tonumber) end)}' ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
}

# routine posted <run>   The bot posted this skip: a later skip with the same reason stays quiet (D23).
routine_posted() {
  _routine_id "${1:-}" || return 1
  local n; n="$(db_value "UPDATE routine_runs SET posted = 1 WHERE id = $1 AND state IN ('skipped','failed'); SELECT changes();")" || n=""
  case "$n" in 1) echo "posted ${1}" ;; 0) echo "ERROR: routine run $1 is not a skip or a failure" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
}

# routine run-now <team> <id>   Queue a manual run (period manual-<epoch second>, D15) when no run of the routine
# is live: the next tick hands it to the bot. The team's gates still apply; the routine's pause and the
# no-new-commits rule do not (an admin asked for it). One guarded INSERT: two admins at once queue one run.
routine_runnow() {
  local team="$1" id="$2" row cfg why tp now heads n
  row="$(_routine_of "$team" "$id")" || return 1
  cfg="$(jq -c '.data | fromjson' <<< "$row")"; now="$(_routine_now)"
  why="$(_routine_team_state "$team")"; [ "$why" = active ] && why=""
  [ -n "$why" ] || { why="$(_routine_sessions_paused)"; [ -z "$why" ] || why="agent sessions are paused: ${why}"; }
  if [ -z "$why" ]; then
    local prc=0; tp="$(_routine_team_paused "$team")" || prc=$?
    case $prc in 0) why="the team is paused: ${tp}" ;; 2) why="the team does not load" ;; esac
  fi
  [ -n "$why" ] || why="$(_ROUTINE_PY budget "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.json" "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.spend.json" "$now")"
  [ -z "$why" ] || { echo "ERROR: routine ${id} cannot run now: ${why}" >&2; return 1; }
  local hrc=0; heads="$(_routine_heads "$cfg" "$id" 2>/dev/null)" || hrc=$?
  case $hrc in 0) ;; 3) echo "ERROR: routine ${id} cannot run now: cannot read the branch head" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
  n="$(db_value "INSERT OR IGNORE INTO routine_runs (routine_id, period, trigger, actor, state, config, heads, started_at)
      SELECT $id, 'manual-${now}', 'manual', $(db_q "$(_teams_actor)"), 'queued', json($(db_q "$cfg")), json($(db_q "$heads")), $now
      WHERE NOT EXISTS (SELECT 1 FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES})); SELECT changes() || '|' || last_insert_rowid();")" || n=""
  case "${n%%|*}" in
    1) _teams_audit_note routine-run "$team" "routine ${id}: run ${n#*|}"; echo "queued run ${n#*|}: it starts within a minute" ;;
    0) if [ "$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES});")" = 0 ]; then
         echo "ERROR: routine ${id} ran in this same second; try again in a second" >&2
       else echo "ERROR: a run of routine ${id} is in progress" >&2; fi; return 1 ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
}

# routine stop <team> <id>   Stop the routine's live run: the row first (guarded, so two admins stop it once),
# then its session.
routine_stop() {
  local team="$1" id="$2" r run st sess n
  _routine_of "$team" "$id" >/dev/null || return 1
  r="$(db_json "SELECT id, state, coalesce(session, '') AS session FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES}) ORDER BY id DESC LIMIT 1;")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  run="$(jq -r '.[0].id // empty' <<< "$r")"; [ -n "$run" ] || { echo "ERROR: no run of routine ${id} is in progress" >&2; return 1; }
  st="$(jq -r '.[0].state' <<< "$r")"; sess="$(jq -r '.[0].session' <<< "$r")"
  n="$(db_value "UPDATE routine_runs SET state = 'stopped', reason = 'stopped by a team admin', ended_at = $(_routine_now) WHERE id = $run AND state = '$st'; SELECT changes();")" || n=""
  case "$n" in 1) ;; 0) echo "ERROR: no run of routine ${id} is in progress" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
  _teams_audit_note routine-stop "$team" "routine ${id}: run ${run}"
  [ -z "$sess" ] || session_stop "$sess" </dev/null >/dev/null 2>&1 || echo "WARN: run ${run} is stopped, but its session ${sess} did not stop; stop it with session stop" >&2
  echo "stopped run ${run}"
}
