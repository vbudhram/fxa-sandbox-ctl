#!/usr/bin/env bash
# Routines (epic i168, design ai/docs/design-docs/2026-10-17-routines.md): a team's scheduled prompts, in the
# store (lib/db/006-routines.sql). lib/routine.py is the one validator. Each write checks the version (a stale
# one exits 2) and writes a team_audit row that names the routine and the changed fields, never the prompt.
#
#   routine list <team> | get <id> | history <team> <id> | templates | channels <team> [live|dev]
#   routine set <team> <file> [--id <id> --version <v>]   create, or replace one at that version
#   routine pause | resume | delete <team> <id>;  routine run-now <team> <id> [--pr <url>];  routine stop <team> <id> [--run <run>]
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

# routine_list <team>   The team's routines, each with its config, next three run times, its live run (claimed or
# started first, then the newest queued), lives (every live run in that order, each with its heads.fix as fix),
# its last result, its last 6 results (recent, oldest first), its channel's name when its bot is in it, and the
# scheduler's last tick (the dashboard warns when it is old).
routine_list() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: bad team name" >&2; return 1; }
  local rows r f out="[]" runs lives tick recent names; rows="$(db_json "SELECT id, team, env, paused, version, data FROM routines WHERE team = $(db_q "$1") ORDER BY id;")" || return 1
  lives="$(db_json "SELECT r.routine_id, r.id, r.state, r.reason, r.session, r.pr_url, r.started_at, r.ended_at, 1 AS live, r.heads->'fix' AS fix
    FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE t.team = $(db_q "$1") AND r.state IN (${_ROUTINE_LIVE_STATES})
    ORDER BY r.state = 'queued', r.id DESC;")" || return 1
  runs="$(db_json "SELECT r.routine_id, r.id, r.state, r.reason, r.session, r.pr_url, r.started_at, r.ended_at, r.state IN (${_ROUTINE_LIVE_STATES}) AS live
    FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE t.team = $(db_q "$1") AND r.id IN
    (SELECT max(id) FROM routine_runs GROUP BY routine_id, state IN (${_ROUTINE_LIVE_STATES}));")" || return 1
  tick="$(db_json "SELECT env, at FROM routine_tick_env;")" || return 1
  recent="$(db_json "SELECT routine_id, state, at FROM (SELECT r.routine_id, r.id, r.state, coalesce(r.ended_at, r.started_at) AS at,
    row_number() OVER (PARTITION BY r.routine_id ORDER BY r.id DESC) AS n FROM routine_runs r JOIN routines t ON t.id = r.routine_id
    WHERE t.team = $(db_q "$1") AND r.state NOT IN (${_ROUTINE_LIVE_STATES})) WHERE n <= 6 ORDER BY id;")" || return 1
  names="$(db_json "SELECT env, id, name FROM slack_channels;")" || return 1
  f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    jq -c '.data | fromjson' <<< "$r" > "$f"
    out="$(jq -c --argjson r "$r" --argjson next "$(_ROUTINE_PY next "$f" | jq -R . | jq -sc .)" --argjson runs "$runs" --argjson tick "$tick" \
      --argjson recent "$recent" --argjson names "$names" --argjson lives "$lives" \
      '($runs | map(select(.routine_id == $r.id)) | map(del(.routine_id))) as $mine | ($r.data | fromjson) as $d
       | ($lives | map(select(.routine_id == $r.id) | del(.routine_id) | .fix |= (fromjson? // null))) as $l
       | . + [$r + {data: $d, next: $next, live: ($l | first | del(.fix)?), lives: $l,
          last: ($mine | map(select(.live == 0)) | first), tick: ($tick | map(select(.env == $r.env)) | first | .at // null),
          recent: ($recent | map(select(.routine_id == $r.id) | del(.routine_id))),
          channel_name: ($names | map(select(.env == $r.env and .id == $d.channel)) | first | .name // null)}]' <<< "$out")"
  done < <(jq -c '.[]' <<< "$rows")
  rm -f "$f"; printf '%s\n' "$out"
}

# routine_channels <team> [live|dev]   The channels that env's bot is in, from the list the bot keeps in the
# store, each with why this team's routine may not post there: {at, channels}. at is null before the first list.
routine_channels() {
  local team="${1:-}" env="${2:-live}" rows prof f rc=0 out
  [[ "$team" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [[ "$env" =~ ^(live|dev)$ ]] || { echo "usage: routine channels <team> [live|dev]" >&2; return 1; }
  rows="$(db_json "SELECT id, name, private, shared, at FROM slack_channels WHERE env = $(db_q "$env");")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  prof="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")" f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  _routine_profile "$team" > "$prof" && [ -s "$prof" ] || { rm -f "$prof" "$f"; echo "ERROR: team ${team} does not load" >&2; return 1; }
  printf '%s' "$rows" > "$f"
  out="$(_ROUTINE_PY channels "$f" "$team" --profile "$prof" --index "${FXA_TEAMS_DIR:-/nonexistent}/index.json" \
    --bot-env "${FXA_BOT_ENV:-${SANDBOX_ROOT}/../fxa-agent-bot/.env}")" || rc=$?
  rm -f "$prof" "$f"; [ "$rc" = 0 ] || return 1
  jq -c --argjson rows "$rows" '{at: ($rows | map(.at) | max), channels: .}' <<< "$out"
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

routine_history() { _routine_of "$1" "$2" >/dev/null || return 1; db_json "SELECT id, period, trigger, actor, state, reason, session, pr_url, cost_usd, report, started_at, ended_at FROM routine_runs WHERE routine_id = $2 ORDER BY id DESC LIMIT 20;"; }

cmd_routine() {
  case "${1:-}" in
    list) routine_list "${2:-}" ;;
    get) routine_get "${2:-}" ;;
    history) routine_history "${2:-}" "${3:-}" ;;
    channels) routine_channels "${2:-}" "${3:-}" ;;
    templates) _ROUTINE_PY templates ;;
    tick) shift; routine_tick "$@" ;;
    done) shift; routine_done "$@" ;;
    posted) routine_posted "${2:-}" ;;
    run-now) [ $# -le 3 ] || { [ "$4" = --pr ] && [ $# = 5 ]; } || { echo "usage: routine run-now <team> <id> [--pr <url>]" >&2; return 1; }
             routine_runnow "${2:-}" "${3:-}" "${5:-}" ;;
    stop) [ $# -le 3 ] || { [ "$4" = --run ] && [ $# = 5 ]; } || { echo "usage: routine stop <team> <id> [--run <run>]" >&2; return 1; }
          routine_stop "${2:-}" "${3:-}" "${5:-}" ;;
    set) local team="${2:-}" file="${3:-}" id="" ver=""; shift 3 2>/dev/null || shift $#
         while [ $# -gt 0 ]; do
           case "$1" in --id) id="${2:-}"; shift 2 2>/dev/null || shift ;; --version) ver="${2:-}"; shift 2 2>/dev/null || shift ;;
             *) echo "ERROR: unknown option $1" >&2; return 1 ;; esac
         done
         routine_set "$team" "$file" "$id" "$ver" ;;
    pause|resume|delete) routine_state "${2:-}" "${3:-}" "$1" ;;
    *) echo "usage: fxa-sandbox-ctl routine list <team> | get <id> | history <team> <id> | templates | channels <team> [live|dev] | set <team> <file> [--id <id> --version <v>] | pause|resume|delete <team> <id> | run-now <team> <id> [--pr <url>] | stop <team> <id> [--run <run>] | tick --env live|dev | done <run> ... | posted <run>" >&2; return 1 ;;
  esac
}

# routine_run_read <run> <team>   The claimed run's row ({id, routine_id, team, config, heads}), for cmd_task
# (D7: ctl reads what to run from the row, never from the caller). Refuses a run of another team, one that
# is not claimed, or one that already has a session. A store error says so.
routine_run_read() {
  _routine_id "$1" || return 1
  local j r; j="$(db_json "SELECT r.id, r.routine_id, t.team, r.state, r.session, r.trigger, r.actor, r.config, r.heads FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE r.id = $1;")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  r="$(jq -c '.[0] // empty' <<< "$j")"
  [ -n "$r" ] || { echo "ERROR: no routine run $1" >&2; return 1; }
  [ "$(jq -r .team <<< "$r")" = "$2" ] || { echo "ERROR: routine run $1 is not a run of team $2" >&2; return 1; }
  [ "$(jq -r '"\(.state)|\(.session // "")"' <<< "$r")" = "claimed|" ] || { echo "ERROR: routine run $1 is not claimed" >&2; return 1; }
  jq -c '{id, routine_id, team, trigger, actor, config: (.config // "null" | fromjson), heads: (.heads // "null" | fromjson)}' <<< "$r" 2>/dev/null \
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

# _prfix_skip <run> <why> <reason>   End a live fix row skipped, with heads.fix.why (the migration 012 trigger frees its head).
_prfix_skip() {
  _routine_id "$1" || return 1
  db_exec "UPDATE routine_runs SET state = 'skipped', reason = $(db_q "$3"), ended_at = $(_routine_now), heads = json_set(heads, '$.fix.why', $(db_q "$2"))
    WHERE id = $1 AND state IN (${_ROUTINE_LIVE_STATES}) AND json_extract(heads, '$.fix') IS NOT NULL;" >/dev/null
}

# _with_timeout <s> <cmd> [args...]   Run an outside command (not a shell function) for at most <s> seconds.
# macOS has no timeout(1). A perl alarm sends the command TERM; a timeout exits 124, as timeout(1) does.
_with_timeout() {
  [[ "${1:-}" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "ERROR: _with_timeout needs a number of seconds" >&2; return 1; }
  perl -e '$t = shift; $p = fork // exit 127; exec @ARGV or exit 127 unless $p;
    $SIG{ALRM} = sub { kill "TERM", $p; waitpid $p, 0; exit 124 }; alarm $t; waitpid $p, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}

# _prfix_set <run> <jq filter> [jq args...]   Apply the filter to heads.fix of a live fix row (queued, claimed or
# started), in one UPDATE guarded on that state and on the heads it read. Pass values as --arg, never in the
# filter. Exit 0 when it wrote, 1 when the row is not a live fix row or the store fails.
_prfix_set() {
  local run="$1" filter="$2" old new n try; shift 2
  _routine_id "$run" || return 1
  for try in 1 2 3; do
    old="$(db_value "SELECT heads FROM routine_runs WHERE id = ${run} AND state IN (${_ROUTINE_LIVE_STATES}) AND json_extract(heads, '$.fix') IS NOT NULL;")" || return 1
    [ -n "$old" ] || return 1
    new="$(jq -c "$@" ".fix |= ($filter)" <<< "$old")" && [ -n "$new" ] || return 1
    n="$(db_value "UPDATE routine_runs SET heads = json($(db_q "$new")) WHERE id = ${run} AND state IN (${_ROUTINE_LIVE_STATES}) AND heads = $(db_q "$old"); SELECT changes();")" || return 1
    [ "$n" = 1 ] && return 0
  done
  return 1
}

# _prfix_claim_push <run> <sha>   Claim the push of a started fix row, before the PATCH: set heads.fix.pushing (now)
# and pending_sha, in one UPDATE guarded on state 'started' and pushing IS NULL, so a stop cannot end the row while
# the branch moves (every stop is guarded on pushing). Exit 0 claimed, 1 not (the run was stopped, or a store error).
_prfix_claim_push() {
  local n; _routine_id "$1" && [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  n="$(db_value "UPDATE routine_runs SET heads = json_set(heads, '$.fix.pushing', $(_routine_now), '$.fix.pending_sha', '$2')
    WHERE id = $1 AND state = 'started' AND json_extract(heads, '$.fix') IS NOT NULL AND json_extract(heads, '$.fix.pushing') IS NULL; SELECT changes();")" || return 1
  [ "$n" = 1 ]
}

# _prfix_gate <team> <paused> <trigger> <cfg file> <free slots> <routine id> <run id>   The first gate that holds a
# queued fix row, as a fixed text for heads.fix.wait (it reaches the public PR comment, so no operator reason), or nothing.
_prfix_gate() {
  local prc=0
  [ "$(_routine_team_state "$1")" = active ] || { echo "the team is not active"; return 0; }
  [ -z "$(_routine_sessions_paused)" ] || { echo "agent sessions are paused"; return 0; }
  _routine_team_paused "$1" >/dev/null || prc=$?
  case $prc in 0) echo "the team is paused"; return 0 ;; 2) echo "the team does not load"; return 0 ;; esac
  [ -z "$(_ROUTINE_PY budget "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/$1.json" "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/$1.spend.json" "$(_routine_now)")" ] \
    || { echo "the team budget is used"; return 0; }
  [ "$2" = 0 ] || [ "$3" = manual ] || { echo "the routine is paused"; return 0; }
  [ -z "$(_routine_recheck "$1" "$4")" ] || { echo "the routine no longer passes its checks"; return 0; }
  [ "$5" -ge 2 ] || { echo "no runner is free"; return 0; }
  [ "$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $6 AND id != $7 AND state IN ('claimed','started');")" = 0 ] \
    || echo "another run of this routine is in progress"
}

# _prfix_pr_read <url>   The PR as gh pr view gives it (one call, at most 30 s), or exit 1 when GitHub did not answer.
_prfix_pr_read() {
  local info
  [[ "$1" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || return 1
  info="$(_with_timeout 30 gh pr view "$1" --json number,url,title,state,headRefOid,headRefName,baseRefName,isCrossRepository,author,statusCheckRollup 2>/dev/null)" \
    && jq -e '.state and (.number | type == "number")' <<< "$info" >/dev/null 2>&1 && printf '%s\n' "$info"
}

# _prfix_pr_why <cfg json> <PR json> <url> [head sha]   Why the PR is not this routine's target, as a C2 code: merged,
# closed, fork, base, new-commit (not at [head sha]), or target (another repo or author, or a branch name that cannot
# be used). Nothing when it is the target.
_prfix_pr_why() {
  jq -r --argjson c "$1" --arg u "$3" --arg h "${4:-}" 'def who: ascii_downcase | sub("^app/"; "") | sub("\\[bot\\]$"; "");
    if .state == "MERGED" then "merged" elif .state != "OPEN" then "closed" elif .isCrossRepository then "fork"
    elif (.url | ascii_downcase) != ($u | ascii_downcase) or ($u | ascii_downcase | split("/")[3:5] | join("/")) != ($c.pr.repo | ascii_downcase)
      or ((.author.login | who) as $a | [$c.pr.authors[] | who] | index($a) | not)
      or (.headRefOid | test("^[0-9a-f]{40}$") | not) or (.headRefName | test("^[A-Za-z0-9._/@+-]+$") | not) or (.headRefName | contains("..")) then "target"
    elif .headRefName == .baseRefName or (.headRefName | test("^(main|master)$|^(release|train)[-/_]")) then "base"
    elif $h != "" and .headRefOid != $h then "new-commit" else empty end' <<< "$2"
}

# _prfix_target <cfg json> <fix json>   The PR against the routine before a claim: _prfix_pr_why at the row's head.
# Exit 1 when GitHub did not answer, so the row waits.
_prfix_target() {
  local url info; url="$(jq -r '.url // ""' <<< "$2")"
  [[ "$(jq -r '.head_sha // ""' <<< "$2")" =~ ^[0-9a-f]{40}$ ]] || { echo target; return 0; }
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || { echo target; return 0; }
  info="$(_prfix_pr_read "$url")" || return 1
  _prfix_pr_why "$1" "$info" "$url" "$(jq -r .head_sha <<< "$2")"
}

# _prfix_text <state> <fix json> <label> [PR ahead]   The public PR comment of a fix row: one fixed host text with its
# next step, from the state and heads.fix.why (C2), never agent text or a reason. Short SHAs only, no links.
_prfix_text() {
  local l="$3" why wait head sha
  why="$(jq -r '.why // ""' <<< "$2")"; wait="$(jq -r '.wait // ""' <<< "$2")"
  head="$(jq -r '.head_sha // "" | select(test("^[0-9a-f]{40}$")) | .[0:7]' <<< "$2")"
  sha="$(jq -r '.new_sha // "" | select(test("^[0-9a-f]{40}$")) | .[0:7]' <<< "$2")"
  case "$1:$why" in
    queued:*) if [ -n "$wait" ] && [ "$wait" != "another run of this routine is in progress" ]; then echo "Waiting: ${wait}. I try again each minute."
      elif [ -n "${4:-}" ]; then echo "In line behind #$4. The fix starts after that run ends."
      else echo "Queued: the fix starts when a runner is free."; fi ;;
    claimed:*|started:*) echo "Working: the agent is fixing the failing checks${head:+ on ${head}}." ;;
    ok:*) echo "Pushed ${sha:-the fix}. Next: review the fix commit, then approve the functional tests gate." ;;
    report:moved) echo "The branch moved, so nothing was pushed. Add ${l} again to retry." ;;
    report:guard:lock) echo "Nothing was pushed: the fix changes yarn.lock entries, which I do not push. Fix it by hand." ;;
    report:guard:tooling) echo "Nothing was pushed: the fix changes Yarn tooling files, which I do not push. Fix it by hand." ;;
    report:guard:frozen) echo "Nothing was pushed: the fix changes protected files, which I do not push. Fix it by hand." ;;
    report:guard:pii) echo "Nothing was pushed: the fix may hold personal data or a secret, so I do not push it. Fix it by hand." ;;
    report:guard:*) echo "Nothing was pushed: a guard refused the fix. Fix it by hand." ;;
    report:*|nochange:*) echo "No fix found on ${head:-the PR head}. A new commit allows a new run." ;;
    failed:boot|skipped:boot) echo "Not started: the sandbox did not start. Add ${l} again to retry." ;;
    failed:*) echo "The fix failed, and nothing was pushed. Add ${l} again to retry." ;;
    stopped:label) echo "Stopped: the ${l} label was removed. Nothing was pushed." ;;
    stopped:closed) echo "Stopped: the PR was closed. Nothing was pushed. Reopen it and add ${l} again to retry." ;;
    stopped:merged) echo "Stopped: the PR was merged. Nothing was pushed." ;;
    stopped:*) echo "Stopped by a team admin. Nothing was pushed. Add ${l} again to retry." ;;
    skipped:new-commit) echo "Not started: the PR has a new commit. Add ${l} again to fix the new head." ;;
    skipped:expired) echo "Not started: it waited 24 h. Add ${l} again to retry." ;;
    skipped:not-red) echo "Not started: CI passes on ${head:-the PR head}. Add ${l} again if CI fails." ;;
    skipped:used) echo "Not started: a run on ${head:-the PR head} already ended. A new commit allows a new run." ;;
    skipped:no-write) echo "Not started: the label needs a person with write access. Ask a person with write access to add ${l}." ;;
    skipped:fork) echo "Not started: the PR is from a fork. Fix it by hand." ;;
    skipped:base) echo "Not started: the PR branch is a base or release branch. Fix it by hand." ;;
    skipped:closed) echo "Not started: the PR is closed. Reopen it and add ${l} again." ;;
    skipped:merged) echo "Not started: the PR is merged. No step is needed." ;;
    skipped:target) echo "Not started: the PR no longer matches the routine's repo, author or branch rules. Fix it by hand." ;;
    skipped:*) echo "Not started: the run could not start. Add ${l} again to retry." ;;
  esac
}

# prfix_report <run>   Set the App's PR comment of a fix row to the text of its state, and at an end remove the label.
# It edits only when the text differs from heads.fix.comment, and keeps the text there only after the edit (and the
# label remove) worked, so the next call repeats a failed one. A row with no fix: nothing. Exit 1 when GitHub failed.
prfix_report() {
  local j r st fix cfg repo label pr text ahead=""
  _routine_id "${1:-}" || return 1
  j="$(db_json "SELECT r.routine_id, r.state, r.heads->'fix' AS fix, coalesce(r.config, t.data) AS cfg FROM routine_runs r LEFT JOIN routines t ON t.id = r.routine_id WHERE r.id = $1;")" || return 1
  r="$(jq -c '.[0] // empty' <<< "$j")"; [ -n "$r" ] || return 0
  fix="$(jq -c '.fix // empty | fromjson? // empty' <<< "$r")"; [ -n "$fix" ] || return 0
  st="$(jq -r .state <<< "$r")"; cfg="$(jq -c '.cfg // "{}" | fromjson? // {}' <<< "$r")"
  repo="$(jq -r '.pr.repo // ""' <<< "$cfg")"; label="$(jq -r '.pr.label // "agent-help"' <<< "$cfg")"; pr="$(jq -r '.pr // ""' <<< "$fix")"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  if [ "$st" = queued ]; then
    # The run ahead in line: a live fix run of the routine, else an older queued one.
    ahead="$(db_value "SELECT json_extract(heads, '$.fix.pr') FROM routine_runs WHERE routine_id = $(jq -r .routine_id <<< "$r") AND id != $1
      AND json_extract(heads, '$.fix') IS NOT NULL AND (state IN ('claimed','started') OR (state = 'queued' AND id < $1)) ORDER BY state = 'queued', id LIMIT 1;")" || ahead=""
    [[ "$ahead" =~ ^[1-9][0-9]*$ ]] || ahead=""
  fi
  text="$(_prfix_text "$st" "$fix" "$label" "$ahead")"; [ -n "$text" ] || return 0
  [ "$text" != "$(jq -r '.comment // ""' <<< "$fix")" ] || return 0
  prfix_comment "$repo" "$pr" "$text" || return 1
  case "$st" in queued|claimed|started) ;; *) prfix_label "$repo" "$pr" remove "$label" || return 1 ;; esac
  db_exec "UPDATE routine_runs SET heads = json_set(heads, '$.fix.comment', $(db_q "$text")) WHERE id = $1 AND state = '$st';" >/dev/null
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

# routine_tick --env <live|dev> [--resume]   One pass: heartbeat, reconcile, then each routine of that env's latest period.
# --resume (the bot's first tick after a start) also answers each run a dead bot claimed but never started.
# Answers {"runs": [...], "skips": [...]} for the bot. A store error answers nothing and exits 1.
# _routine_recheck <team> <cfg file>   The saved routine against the team as it is now (D8: a team that
# turns private, or a channel unbound since the save): the first refusal, or nothing. A team that does not load refuses.
_routine_recheck() {
  local prof err rc=0
  prof="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")" || { echo "the team does not load"; return 0; }
  _routine_profile "$1" > "$prof" && [ -s "$prof" ] || { rm -f "$prof"; echo "the team does not load"; return 0; }
  err="$(_ROUTINE_PY validate "$2" "$1" --profile "$prof" --index "${FXA_TEAMS_DIR:-/nonexistent}/index.json" \
    --bot-env "${FXA_BOT_ENV:-${SANDBOX_ROOT}/../fxa-agent-bot/.env}" --count 0 2>&1 >/dev/null)" || rc=$?
  rm -f "$prof"
  # A channel refusal comes first, so _routine_quiet keeps the skip out of a channel the results may not go to.
  [ "$rc" = 0 ] || echo "the routine no longer passes its checks: $(printf '%s\n' "$err" | grep -m1 '^channel:' || printf '%s\n' "$err" | head -1)"
}

# _routine_quiet <why>   True for a recheck refusal whose skip must not post: the channel itself, or a team that
# does not load (its channels are unknown). Other refusals post once, as any skip (D23).
_routine_quiet() { case "$1" in "the team does not load"|*"passes its checks: channel:"*) return 0 ;; *) return 1 ;; esac; }

routine_tick() {
  [ "${1:-}" = --env ] && [[ "${2:-}" =~ ^(live|dev)$ ]] && [[ "${3:-}" =~ ^(--resume)?$ ]] && [ $# -le 3 ] \
    || { echo "usage: routine tick --env live|dev [--resume]" >&2; return 1; }
  local env="$2" resume="${3:-}" now; now="$(_routine_now)"
  db_exec "INSERT INTO routine_tick_env (env, at) VALUES ($(db_q "$env"), $now) ON CONFLICT (env) DO UPDATE SET at = excluded.at;" >/dev/null || { echo "$_ROUTINE_STORE" >&2; return 1; }
  local expired; expired="$(routine_reconcile "$now" "$env")" || return 1
  local rows; rows="$(db_json "SELECT id, team, paused, data, coalesce(saved_at, 0) AS saved_at FROM routines WHERE env = $(db_q "$env") ORDER BY id;")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  # A manual run (Run now) waits as queued: one guarded UPDATE hands it to this tick only.
  local free; free="$(_routine_free_slots)"
  local queued q qid qrid qt qwhy qpost qfix recheck runs="[]" skips="[]"
  local f id team paused period at next cfg x; f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  # The fix rows that reconcile expired: each posts once, as a skip with its fix.
  for x in $expired; do
    [[ "$x" =~ ^[1-9][0-9]*$ ]] || continue
    q="$(db_json "SELECT r.id, r.routine_id, t.team, t.data, r.heads->'fix' AS fix FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE r.id = $x;" | jq -c '.[0] // empty')" || q=""
    [ -n "$q" ] || continue
    skips="$(jq -c --argjson q "$q" --argjson i "$(_routine_run_info "$(jq -r .routine_id <<< "$q")" "$(jq -r .team <<< "$q")" "$(jq -c '.data | fromjson' <<< "$q")")" \
      '($q.data | fromjson) as $d | ($q.fix | fromjson) as $x | . + [{run: $q.id, routine: $q.routine_id, team: $q.team, name: $d.name, channel: $d.channel,
        template: $i.template, private: $i.private, reason: "it waited 24 h", next: null, post: ($d.channel != null), fix: {pr: $x.pr, url: $x.url, why: "expired"}}]' <<< "$skips")"
  done
  queued="$(db_json "SELECT r.id, r.routine_id, t.team, t.data, t.paused, coalesce(r.trigger, 'manual') AS trigger, coalesce(r.actor, '') AS actor, r.heads->'fix' AS fix
    FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE r.state = 'queued' AND t.env = $(db_q "$env") ORDER BY r.id;")" || { rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1; }
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    # A fix row (heads.fix): every gate, then the PR target, before the claim. A gate keeps it queued with its text.
    qfix="$(jq -c '.fix // empty | fromjson? // empty' <<< "$q")"
    if [ -n "$qfix" ]; then
      qid="$(jq -r .id <<< "$q")"; qrid="$(jq -r .routine_id <<< "$q")"; qt="$(jq -r .team <<< "$q")"
      jq -j '.data' <<< "$q" > "$f"
      qwhy="$(_prfix_gate "$qt" "$(jq -r .paused <<< "$q")" "$(jq -r .trigger <<< "$q")" "$f" "$free" "$qrid" "$qid")"
      if [ -z "$qwhy" ]; then
        local trc=0; qwhy="$(_prfix_target "$(jq -c '.data | fromjson' <<< "$q")" "$qfix")" || { trc=1; qwhy="GitHub did not answer"; }
        if [ "$trc" = 0 ] && [ -n "$qwhy" ]; then
          [ "$(db_value "UPDATE routine_runs SET state = 'skipped', reason = $(db_q "the PR is no longer the run's target: ${qwhy}"), ended_at = $now,
            heads = json_set(heads, '$.fix.why', $(db_q "$qwhy")) WHERE id = $qid AND state = 'queued'; SELECT changes();")" = 1 ] || continue
          skips="$(jq -c --argjson q "$q" --argjson x "$qfix" --arg why "$qwhy" --argjson i "$(_routine_run_info "$qrid" "$qt" "$(jq -c '.data | fromjson' <<< "$q")")" \
            '($q.data | fromjson) as $d | . + [{run: $q.id, routine: $q.routine_id, team: $q.team, name: $d.name, channel: $d.channel, template: $i.template, private: $i.private,
              reason: "the PR is no longer the run'"'"'s target: \($why)", next: null, post: ($d.channel != null), fix: {pr: $x.pr, url: $x.url, why: $why}}]' <<< "$skips")"
          continue
        fi
      fi
      if [ -n "$qwhy" ]; then
        [ "$(jq -r '.wait // ""' <<< "$qfix")" = "$qwhy" ] || _prfix_set "$qid" '.wait = $w' --arg w "$qwhy" || true
        continue
      fi
      [ "$(db_value "UPDATE routine_runs SET state = 'claimed', started_at = $now, heads = json_remove(heads, '$.fix.wait') WHERE id = $qid AND state = 'queued'
        AND NOT EXISTS (SELECT 1 FROM routine_runs o WHERE o.routine_id = $qrid AND o.id != $qid AND o.state IN ('claimed','started')); SELECT changes();")" = 1 ] || continue
      free=$((free - 1))
      runs="$(jq -c --argjson q "$q" --argjson x "$qfix" --argjson i "$(_routine_run_info "$qrid" "$qt" "$(jq -c '.data | fromjson' <<< "$q")")" \
        '. + [{run: $q.id, routine: $q.routine_id, team: $q.team, trigger: $q.trigger, actor: $q.actor, channel: ($q.data | fromjson | .channel)} + $i
          + {fix: {pr: $x.pr, url: $x.url, actor: $q.actor, package: ($x.packages // [] | first)}}]' <<< "$runs")"
      continue
    fi
    # The slot gate as for a scheduled run: it waits queued (and reconcile fails it after 60 min).
    [ "$free" -ge 2 ] || continue
    # The saved routine against its team as it is now (D8), as for a scheduled run.
    qid="$(jq -r .id <<< "$q")"; qrid="$(jq -r .routine_id <<< "$q")"; qt="$(jq -r .team <<< "$q")"
    jq -j '.data' <<< "$q" > "$f"; qwhy="$(_routine_recheck "$qt" "$f")"
    if [ -n "$qwhy" ]; then
      [ "$(db_value "UPDATE routine_runs SET state = 'skipped', reason = $(db_q "$qwhy"), ended_at = $now WHERE id = $qid AND state = 'queued'; SELECT changes();")" = 1 ] || continue
      qpost=false; _routine_quiet "$qwhy" || qpost="$(_routine_post "$qrid" "$qwhy")" || qpost=false
      jq -e '.data | fromjson | .channel // empty' <<< "$q" >/dev/null || qpost=false   # no channel: History only (D32)
      skips="$(jq -c --argjson q "$q" --arg why "$qwhy" --argjson post "$qpost" --argjson i "$(_routine_run_info "$qrid" "$qt" "$(jq -c '.data | fromjson' <<< "$q")")" \
        '. + [{run: $q.id, routine: $q.routine_id, team: $q.team, name: ($q.data | fromjson | .name), channel: ($q.data | fromjson | .channel), template: $i.template, private: $i.private, reason: $why, next: null, post: $post}]' <<< "$skips")"
      continue
    fi
    [ "$(db_value "UPDATE routine_runs SET state = 'claimed', started_at = $now WHERE id = $(jq -r .id <<< "$q") AND state = 'queued'
      AND NOT EXISTS (SELECT 1 FROM routine_runs o WHERE o.routine_id = $(jq -r .routine_id <<< "$q") AND o.id != $(jq -r .id <<< "$q") AND o.state IN ('claimed','started')); SELECT changes();")" = 1 ] || continue
    free=$((free - 1))
    runs="$(jq -c --argjson q "$q" --argjson i "$(_routine_run_info "$(jq -r .routine_id <<< "$q")" "$(jq -r .team <<< "$q")" "$(jq -c '.data | fromjson' <<< "$q")")" \
      '. + [{run: $q.id, routine: $q.routine_id, team: $q.team, trigger: "manual", channel: ($q.data | fromjson | .channel)} + $i]' <<< "$runs")"
  done < <(jq -c '.[]' <<< "$queued")
  # A claimed run with no session is in a bot's hands only in memory: after a restart it starts again, inside the
  # 10 min that reconcile gives it. The claimed to started UPDATE in the task still lets one start take it.
  # A run this tick claimed above has started_at = now: it is in runs already.
  if [ -n "$resume" ]; then
    local orphans o
    orphans="$(db_json "SELECT r.id, r.routine_id, r.trigger, t.team, t.data FROM routine_runs r JOIN routines t ON t.id = r.routine_id
      WHERE r.state = 'claimed' AND r.session IS NULL AND r.started_at > $((now - 600)) AND r.started_at < $now AND coalesce(json_extract(r.config, '$.env'), t.env) = $(db_q "$env");")" \
      || { rm -f "$f"; echo "$_ROUTINE_STORE" >&2; return 1; }
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      free=$((free - 1))
      runs="$(jq -c --argjson q "$o" --argjson i "$(_routine_run_info "$(jq -r .routine_id <<< "$o")" "$(jq -r .team <<< "$o")" "$(jq -c '.data | fromjson' <<< "$o")")" \
        '. + [{run: $q.id, routine: $q.routine_id, team: $q.team, trigger: $q.trigger, channel: ($q.data | fromjson | .channel)} + $i]' <<< "$runs")"
    done < <(jq -c '.[]' <<< "$orphans")
  fi
  local spaused; spaused="$(_routine_sessions_paused)"
  # One routine.py start finds the due routines, so a tick costs no process for a routine that is not due.
  local rf="$f.rows"; printf '%s' "$rows" > "$rf"
  local dues; dues="$(_ROUTINE_PY due-rows "$rf" "$now")" || dues=""; rm -f "$rf"
  while IFS=$'\x1f' read -r id team paused period at next cfg; do
    [ -n "$id" ] || continue
    local age why heads n post st tp
    printf '%s' "$cfg" > "$f"
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
    [ -n "$why" ] || [ "$paused" = 0 ] || why="the routine is paused"
    recheck=""; [ -n "$why" ] || { why="$(_routine_recheck "$team" "$f")"; recheck="$why"; }
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
      [ "$paused" = 0 ] || post=false   # an admin's own pause is not news in Slack
      # The channel may no longer be one the team's results can go to, also when an earlier gate gave the reason.
      [ -n "$recheck" ] || recheck="$(_routine_recheck "$team" "$f")"
      [ -z "$recheck" ] || ! _routine_quiet "$recheck" || post=false
      jq -e '.channel // empty' <<< "$cfg" >/dev/null || post=false   # no channel: History only (D32)
      # template and private: the bot checks the channel before it posts a skip too (D8).
      skips="$(jq -c --argjson id "${n#*|}" --argjson rid "$id" --arg t "$team" --argjson c "$cfg" --arg why "$why" --arg next "$next" --argjson post "$post" \
        --argjson i "$(_routine_run_info "$id" "$team" "$cfg")" \
        '. + [{run: $id, routine: $rid, team: $t, name: $c.name, channel: $c.channel, template: $i.template, private: $i.private, reason: $why, next: (if $next == "" then null else ($next | tonumber) end), post: $post}]' <<< "$skips")"
    fi
  done <<< "$dues"
  rm -f "$f"
  jq -nc --argjson runs "$runs" --argjson skips "$skips" '{runs: $runs, skips: $skips}'
}

# _prfix_end <run> <fix json> <state>   The end of a live fix row from heads.fix, never from the bot's word or
# the session's pr_url (the checkout sets it at boot): new_sha is ok; why moved or guard:* is report; a push claim with
# no new_sha reads the PR head: at pending_sha it is ok (new_sha is written), else failed; an ok with no push is failed;
# else <state>. Exit 1 when GitHub did not answer about a claimed push.
_prfix_end() {
  local why pend info
  why="$(jq -r '.why // ""' <<< "$2")"; pend="$(jq -r '.pending_sha // ""' <<< "$2")"
  if [ -n "$(jq -r '.new_sha // ""' <<< "$2")" ]; then echo ok
  elif [ "$why" = moved ] || [[ "$why" == guard:* ]]; then echo report
  elif [ -n "$(jq -r '.pushing // ""' <<< "$2")" ] && [[ "$pend" =~ ^[0-9a-f]{40}$ ]]; then
    # ponytail: the PR's headRefOid can lag a ref move by seconds; done reads it right after finish, reconcile 10 min later.
    info="$(_prfix_pr_read "$(jq -r '.url // ""' <<< "$2")")" || return 1
    if [ "$(jq -r .headRefOid <<< "$info")" = "$pend" ]; then _prfix_set "$1" '.new_sha = $s' --arg s "$pend" || return 1; echo ok; else echo failed; fi
  elif [ "$3" = ok ]; then echo failed
  else echo "$3"; fi
}

# routine_reconcile <now> <env>   Live runs of that env's routines (the other env's bot has other session records), from their session records (D14): a run the bot never reported on still
# ends. pr_open or a pr_url is ok with that PR; a session that is gone, unreadable, paused, stopped or failed with
# no done call fails (a paused one is stopped first: nobody will answer it); a started run past 120 min is stopped
# and fails; a claimed run with no session after 10 min, or a queued one with no free runner after 60, fails. Each change is one
# UPDATE guarded on the state it read, so a done call or a second tick at the same time cannot be undone.
routine_reconcile() {
  local now="$1" env="$2" rows r id st sess since rec sst pr why free="" fix
  rows="$(db_json "SELECT r.id AS id, r.state AS state, coalesce(r.session, '') AS session, coalesce(r.started_at, 0) AS since, r.heads->'fix' AS fix FROM routine_runs r
    LEFT JOIN routines t ON t.id = r.routine_id WHERE r.state IN (${_ROUTINE_LIVE_STATES}) AND coalesce(json_extract(r.config, '$.env'), t.env, 'live') = $(db_q "$env");")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    id="$(jq -r .id <<< "$r")"; st="$(jq -r .state <<< "$r")"; sess="$(jq -r .session <<< "$r")"; since="$(jq -r .since <<< "$r")"
    why=""; pr=""; sst=""
    fix="$(jq -c '.fix // empty | fromjson? // empty' <<< "$r")"
    if [ "$st" = started ] && [ -n "$fix" ]; then _prfix_reconcile "$now" "$id" "$sess" "$since" "$fix" || return 1; continue; fi
    # A queued fix row waits for its gates up to 24 h, not 60 min. Then it ends skipped (no operator error), and its
    # id goes to stdout, so the tick posts it once on its skips list.
    if [ "$st" = queued ] && [ -n "$fix" ]; then
      [ "$since" -gt 0 ] && [ $((now - since)) -gt 86400 ] || continue
      [ "$(db_value "UPDATE routine_runs SET state = 'skipped', reason = 'it waited 24 h', ended_at = $now, heads = json_set(heads, '$.fix.why', 'expired')
        WHERE id = $id AND state = 'queued'; SELECT changes();")" = 1 ] && echo "$id"
      continue
    fi
    case "$st" in
      queued) if [ "$since" -gt 0 ] && [ $((now - since)) -gt 3600 ]; then
          [ -n "$free" ] || free="$(_routine_free_slots)"
          if [ "$free" -ge 2 ]; then why="no tick started it within 60 min"; else why="no runner free within 60 min"; fi
        fi ;;
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

# _prfix_reconcile <now> <run> <session> <since> <fix json>   A started fix row the bot did not end: its end from heads.fix
# (_prfix_end) once its session ended (after the 10 min grace for a late done call), took over 120 min, or is gone, or once
# its push claim is 10 min old with no new_sha. A failed end is an operator error; report and ok are not. Exit 1 on a store error.
_prfix_reconcile() {
  local now="$1" id="$2" sess="$3" since="$4" fix="$5" rec="${SESSION_DIR}/$3.json" sst why="" push end n
  push="$(jq -r '.pushing // 0' <<< "$fix")"
  if [ -z "$(jq -r '.new_sha // ""' <<< "$fix")" ] && [[ "$push" =~ ^[1-9][0-9]*$ ]]; then
    [ $((now - push)) -gt 600 ] || return 0
    why="the push did not report back"
  elif ! [[ "$sess" =~ ^agent-[a-z0-9]{4,12}$ ]] || [ ! -f "$rec" ]; then why="the run's session is gone"
  elif ! sst="$(jq -r '.state // ""' "$rec" 2>/dev/null)"; then why="the run's session record cannot be read"
  elif session_live "$sess"; then
    [ "$since" -gt 0 ] && [ $((now - since)) -gt 7200 ] || return 0
    session_stop "$sess" </dev/null >/dev/null 2>&1 || true; why="the run took over 120 min"
  else
    [ $((now - $(_mtime "$rec" 2>/dev/null || echo 0))) -ge 600 ] || return 0
    [ "$sst" != paused ] || session_stop "$sess" </dev/null >/dev/null 2>&1 || true
    why="the session ${sst:-ended} with no result"
  fi
  # GitHub did not answer about a claimed push: the next tick asks again.
  end="$(_prfix_end "$id" "$fix" failed)" || return 0
  n="$(db_value "UPDATE routine_runs SET state = '$end', reason = $( [ "$end" = failed ] && db_q "$why" || echo NULL ), ended_at = $now WHERE id = $id AND state = 'started'; SELECT changes();")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  [ "$n" = 1 ] && [ "$end" = failed ] && errors_record routine run_failed "$sess" "routine tick" "routine run ${id}: ${why}" ""
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
#   Answers {changed, state, post, next}. A fix run's state comes from heads.fix (_prfix_end), and the answer adds
#   fix {pr, url, sha, why}; its state can be one ctl wrote first (stopped or skipped).
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
  local j r fix=""; j="$(db_json "SELECT r.state, coalesce(r.session, '') AS session, t.data, coalesce(r.config, t.data) AS cfg, r.heads->'fix' AS fix FROM routine_runs r LEFT JOIN routines t ON t.id = r.routine_id WHERE r.id = ${run};")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  r="$(jq -c '.[0] // empty' <<< "$j")"; [ -n "$r" ] || { echo "ERROR: no routine run ${run}" >&2; return 1; }
  [ "$(jq -r .session <<< "$r")" = "$sess" ] || { echo "ERROR: routine run ${run} is not session ${sess:-(none)}'s" >&2; return 1; }
  if [ -z "$sess" ]; then
    [ "$state" = failed ] || { echo "ERROR: done with no --session only fails a run" >&2; return 1; }
    [[ "$(jq -r .state <<< "$r")" =~ ^(claimed|queued)$ ]] || { echo "ERROR: routine run ${run} is $(jq -r .state <<< "$r"): done with no --session takes only a claimed or queued run" >&2; return 1; }
  fi
  fix="$(jq -c '.fix // empty | fromjson? // empty' <<< "$r")"
  if [ -n "$fix" ] && [[ "$(jq -r .state <<< "$r")" =~ ^(queued|claimed|started)$ ]]; then
    local given="$state"
    state="$(_prfix_end "$run" "$fix" "$state")" || { echo "ERROR: GitHub did not answer about the fix push of run ${run}; the tick decides its end" >&2; return 1; }
    [ "$given:$state" != ok:failed ] || [ -n "$reason" ] || reason="the fix was not pushed"
  fi
  local next="" f; f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  if jq -e '.data' <<< "$r" >/dev/null 2>&1; then jq -r .data <<< "$r" > "$f"; next="$(_ROUTINE_PY due "$f" "$(_routine_now)" 2>/dev/null | jq -r '.next // empty' 2>/dev/null)" || next=""; fi
  local post=true report="" n guard="state IN (${_ROUTINE_LIVE_STATES})" nochan=""
  # A run of a routine with no channel posts nothing: its results are in History only (D32). The run's own
  # config decides, as for its start, so a channel edit or a delete during the run does not change it.
  jq -e '(.cfg // "{}") | fromjson | has("channel") | not' <<< "$r" >/dev/null 2>&1 && nochan=1
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
    # The reason marks a held report, so History and the last result say where to read it.
    [ "$post" = true ] || [ -n "$reason" ] || [ -n "$nochan" ] || reason="kept off Slack: it may hold personal data or a secret"
  fi
  [ -z "$nochan" ] || post=false
  rm -f "$f"
  n="$(db_value "UPDATE routine_runs SET state = $(db_q "$state"), reason = $( [ -n "$reason" ] && db_q "$reason" || echo NULL ),
      pr_url = $( [ -n "$pr" ] && db_q "$pr" || echo pr_url ), report = $( [ -n "$rf" ] && db_q "$report" || echo report ),
      cost_usd = $( { [ -n "$sess" ] && _routine_session_cost "$sess"; } | grep . || echo cost_usd), ended_at = $(_routine_now)
      WHERE id = ${run} AND ${guard}; SELECT changes();")" || n=""
  local add='{}'
  [ -z "$fix" ] || add="$(db_value "SELECT heads->'fix' FROM routine_runs WHERE id = ${run};" | jq -c '{fix: {pr, url, sha: .new_sha, why}}' 2>/dev/null)" || add=""
  [ -n "$add" ] || add='{}'
  case "$n" in
    1) jq -nc --arg s "$state" --argjson p "$post" --arg n "$next" --argjson x "$add" '{changed: true, state: $s, post: $p, next: (if $n == "" then null else ($n | tonumber) end)} + $x' ;;
    0) jq -nc --arg s "$(db_value "SELECT state FROM routine_runs WHERE id = ${run};")" --arg n "$next" --argjson x "$add" '{changed: false, state: $s, post: false, next: (if $n == "" then null else ($n | tonumber) end)} + $x' ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
}

# routine posted <run>   The bot posted this skip: a later skip with the same reason stays quiet (D23).
routine_posted() {
  _routine_id "${1:-}" || return 1
  local n; n="$(db_value "UPDATE routine_runs SET posted = 1 WHERE id = $1 AND state IN ('skipped','failed'); SELECT changes();")" || n=""
  case "$n" in 1) echo "posted ${1}" ;; 0) echo "ERROR: routine run $1 is not a skip or a failure" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
}

# routine run-now <team> <id> [<PR url>]   Queue a manual run (period manual-<epoch second>, D15) when no run of the routine
# is live: the next tick hands it to the bot. The team's gates still apply; the routine's pause and the
# no-new-commits rule do not (an admin asked for it). One guarded INSERT: two admins at once queue one run.
# A pr-label routine takes a PR instead: its run is 'pr-<n>-<head sha>', so UNIQUE is the guard (one run for each
# head, D4), and other live rows of the routine do not block it.
routine_runnow() {
  local team="$1" id="$2" pr="${3:-}" row cfg why tp now heads n
  row="$(_routine_of "$team" "$id")" || return 1
  cfg="$(jq -c '.data | fromjson' <<< "$row")"; now="$(_routine_now)"
  if [ "$(jq -r '.on // "schedule"' <<< "$cfg")" = pr-label ]; then
    [ -n "$pr" ] || { echo "ERROR: routine ${id} runs on a dependency PR: pass --pr <url>" >&2; return 1; }
  elif [ -n "$pr" ]; then echo "ERROR: routine ${id} is not a dependency PR routine, so it takes no --pr" >&2; return 1; fi
  why="$(_routine_team_state "$team")"; [ "$why" = active ] && why=""
  [ -n "$why" ] || { why="$(_routine_sessions_paused)"; [ -z "$why" ] || why="agent sessions are paused: ${why}"; }
  if [ -z "$why" ]; then
    local prc=0; tp="$(_routine_team_paused "$team")" || prc=$?
    case $prc in 0) why="the team is paused: ${tp}" ;; 2) why="the team does not load" ;; esac
  fi
  [ -n "$why" ] || why="$(_ROUTINE_PY budget "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.json" "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/teams/${team}.spend.json" "$now")"
  if [ -z "$why" ]; then
    local f; f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")" && printf '%s' "$cfg" > "$f" && why="$(_routine_recheck "$team" "$f")" || why="the routine cannot be checked"
    rm -f "$f"
  fi
  [ -z "$why" ] || { echo "ERROR: routine ${id} cannot run now: ${why}" >&2; return 1; }
  [ -z "$pr" ] || { _prfix_runnow "$team" "$id" "$cfg" "$pr" "$now"; return; }
  local hrc=0; heads="$(_routine_heads "$cfg" "$id" 2>/dev/null)" || hrc=$?
  case $hrc in 0) ;; 3) echo "ERROR: routine ${id} cannot run now: cannot read the branch head" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac
  n="$(db_value "INSERT OR IGNORE INTO routine_runs (routine_id, period, trigger, actor, state, config, heads, started_at)
      SELECT $id, 'manual-${now}', 'manual', $(db_q "$(_teams_actor)"), 'queued', json($(db_q "$cfg")), json($(db_q "$heads")), $now
      WHERE NOT EXISTS (SELECT 1 FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES})); SELECT changes() || '|' || last_insert_rowid();")" || n=""
  case "${n%%|*}" in
    1) _teams_audit_note routine-run "$team" "routine ${id}: run ${n#*|}"; echo "queued run ${n#*|}: it starts when a runner is free, within 60 min" ;;
    0) if [ "$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES});")" = 0 ]; then
         echo "ERROR: routine ${id} ran in this same second; try again in a second" >&2
       else echo "ERROR: a run of routine ${id} is in progress" >&2; fi; return 1 ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
}

# _prfix_runnow <team> <id> <cfg json> <PR url> <now>   run-now --pr: the PR against the routine's target, then one
# queued manual row with heads.fix. Each refusal is a fixed text with the next step.
_prfix_runnow() {
  local team="$1" id="$2" cfg="$3" url="$4" now="$5" repo info why num head fix n st
  repo="$(jq -r .pr.repo <<< "$cfg")"
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] && [ "$(cut -d/ -f4-5 <<< "$url" | tr 'A-Z' 'a-z')" = "$(tr 'A-Z' 'a-z' <<< "$repo")" ] \
    || { echo "ERROR: ${url:0:200} is not a PR of ${repo}. Use a PR link of ${repo}." >&2; return 1; }
  info="$(_prfix_pr_read "$url")" || { echo "ERROR: GitHub did not answer about ${url}. Try again in a minute." >&2; return 1; }
  num="$(jq -r .number <<< "$info")"; head="$(jq -r .headRefOid <<< "$info")"
  why="$(_prfix_pr_why "$cfg" "$info" "$url")"
  case "$why" in
    "") ;;
    merged|closed) echo "ERROR: PR #${num} is not open. Use an open dependency PR." >&2; return 1 ;;
    fork) echo "ERROR: PR #${num} is from a fork. The fix pushes to the PR branch, so use a PR from a branch of ${repo}." >&2; return 1 ;;
    base) echo "ERROR: PR #${num} is from the base or a release branch. Use a dependency PR." >&2; return 1 ;;
    *) echo "ERROR: PR #${num} is not a dependency PR this routine fixes: it must be by $(jq -r '.pr.authors | join(" or ")' <<< "$cfg"). Use one of their PRs." >&2; return 1 ;;
  esac
  # Only host-checked values: the package name from a 'bump <pkg> from' title, and the failed checks' https links.
  fix="$(jq -c --argjson now "$now" '{pr: .number, url, head_sha: .headRefOid, head_ref: .headRefName, base_ref: .baseRefName, author: .author.login,
    packages: [.title | capture("[Bb]ump (?<p>[^ ]+) from")? | .p | select(test("^[@a-z0-9._/-]{1,80}$"))], signal_at: $now,
    check_urls: [.statusCheckRollup[]? | select((.conclusion // .state) | IN("FAILURE", "TIMED_OUT", "CANCELLED", "ERROR"))
      | (.detailsUrl // .targetUrl) | select(type == "string" and test("^https://[A-Za-z0-9./_?=&-]+$"))][:10]}' <<< "$info")" || { echo "$_ROUTINE_STORE" >&2; return 1; }
  n="$(db_value "INSERT OR IGNORE INTO routine_runs (routine_id, period, trigger, actor, state, config, heads, started_at)
      VALUES ($id, $(db_q "pr-${num}-${head}"), 'manual', $(db_q "$(_teams_actor)"), 'queued', json($(db_q "$cfg")), json($(db_q "{\"fix\":${fix}}")), $now);
      SELECT changes() || '|' || last_insert_rowid();")" || n=""
  case "${n%%|*}" in
    1) _teams_audit_note routine-run "$team" "routine ${id}: run ${n#*|} on PR #${num}"; echo "queued run ${n#*|}: Queued for #${num}. The PR comment shows its state." ;;
    0) st="$(db_value "SELECT state FROM routine_runs WHERE routine_id = $id AND period = $(db_q "pr-${num}-${head}");")" || st=""
       case "$st" in
         queued|claimed|started) echo "ERROR: A run on #${num} at ${head:0:7} is already queued or in progress. The PR comment shows its state." >&2 ;;
         *) echo "ERROR: A run on ${head:0:7} already ended. A new commit allows a new run." >&2 ;;
       esac; return 1 ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
}

_PRFIX_PUSHING="The fix is being pushed. Try again after it ends."
# routine stop <team> <id> [<run>]   Stop a live run: that run, or with none the claimed or started one before a
# queued one. The row first (guarded on its state, so two admins stop it once, and on heads.fix.pushing IS NULL, so
# a fix push that started is never cut off), then its session.
routine_stop() {
  local team="$1" id="$2" want="${3:-}" r run st sess n none
  _routine_of "$team" "$id" >/dev/null || return 1
  none="ERROR: no run of routine ${id} is in progress"
  [ -z "$want" ] || { _routine_id "$want" || return 1; none="ERROR: run ${want} of routine ${id} is not in progress"; }
  r="$(db_json "SELECT id, state, coalesce(session, '') AS session, json_extract(heads, '$.fix.pushing') IS NOT NULL AS pushing FROM routine_runs
    WHERE routine_id = $id AND state IN (${_ROUTINE_LIVE_STATES})$([ -z "$want" ] || echo " AND id = $want") ORDER BY state = 'queued', id DESC LIMIT 1;")" \
    || { echo "$_ROUTINE_STORE" >&2; return 1; }
  run="$(jq -r '.[0].id // empty' <<< "$r")"; [ -n "$run" ] || { echo "$none" >&2; return 1; }
  st="$(jq -r '.[0].state' <<< "$r")"; sess="$(jq -r '.[0].session' <<< "$r")"
  n="$(db_value "UPDATE routine_runs SET state = 'stopped', reason = 'stopped by a team admin', ended_at = $(_routine_now) WHERE id = $run AND state = '$st'
    AND json_extract(heads, '$.fix.pushing') IS NULL; SELECT changes();")" || n=""
  case "$n" in
    1) ;;
    0) if [ "$(db_value "SELECT count(*) FROM routine_runs WHERE id = $run AND state = '$st' AND json_extract(heads, '$.fix.pushing') IS NOT NULL;")" = 1 ]; then
         echo "ERROR: ${_PRFIX_PUSHING}" >&2; else echo "$none" >&2; fi; return 1 ;;
    *) echo "$_ROUTINE_STORE" >&2; return 1 ;;
  esac
  _teams_audit_note routine-stop "$team" "routine ${id}: run ${run}"
  [ -z "$sess" ] || session_stop "$sess" </dev/null >/dev/null 2>&1 || echo "WARN: run ${run} is stopped, but its session ${sess} did not stop; stop it with session stop" >&2
  echo "stopped run ${run}"
}
