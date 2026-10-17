#!/usr/bin/env bash
# Routines (epic i168, design ai/docs/design-docs/2026-10-17-routines.md): a team's scheduled prompts, in the
# store (lib/db/006-routines.sql). lib/routine.py is the one validator. Each write checks the version (a stale
# one exits 2) and writes a team_audit row that names the routine and the changed fields, never the prompt.
#
#   routine list <team> | get <id> | history <team> <id> | templates
#   routine set <team> <file> [--id <id> --version <v>]   create, or replace one at that version
#   routine pause | resume | delete <team> <id>
# A command that names a team refuses a routine of another team.

_ROUTINE_PY() { python3 -I "${SANDBOX_ROOT}/lib/routine.py" "$@"; }
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

# routine_list <team>   The team's routines, each with its config and next three run times.
routine_list() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: bad team name" >&2; return 1; }
  local rows r f out="[]"; rows="$(db_json "SELECT id, team, env, paused, version, data FROM routines WHERE team = $(db_q "$1") ORDER BY id;")" || return 1
  f="$(mktemp "${TMPDIR:-/tmp}/fxa-routine.XXXXXX")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    jq -c '.data | fromjson' <<< "$r" > "$f"
    out="$(jq -c --argjson r "$r" --argjson next "$(_ROUTINE_PY next "$f" | jq -R . | jq -sc .)" \
      '. + [$r + {data: ($r.data | fromjson), next: $next}]' <<< "$out")"
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
    id="$(db_value "INSERT INTO routines (team, data, env, created_by, updated_by, updated_at) SELECT $(db_q "$team"), json($(db_q "$out")), $(db_q "$env"), $(db_q "$who"), $(db_q "$who"), $(date +%s)
      WHERE (SELECT count(*) FROM routines WHERE team = $(db_q "$team")) < 8; SELECT CASE WHEN changes() = 1 THEN last_insert_rowid() ELSE 0 END;")" || id=""
    case "$id" in ''|*[!0-9]*) echo "$_ROUTINE_STORE" >&2; return 1 ;; 0) echo "routine: A team has at most 8 routines" >&2; return 1 ;; esac
    _teams_audit_note routine-create "$team" "routine ${id}"
    echo "created routine ${id}"; return 0
  fi
  old="$(jq -c '.data | fromjson' <<< "$row")"
  local n_up; n_up="$(db_value "UPDATE routines SET data = json($(db_q "$out")), env = $(db_q "$env"), version = version + 1, updated_by = $(db_q "$who"), updated_at = $(date +%s) WHERE id = ${id} AND version = ${ver}; SELECT changes();")" || n_up=""
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
      local n_del; n_del="$(db_value "DELETE FROM routines WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM routine_runs WHERE routine_id = $1 AND state IN ('claimed','started')); SELECT changes();")" || n_del=""
      case "$n_del" in 1) ;; 0) echo "ERROR: a run of routine $1 is in progress; stop it first" >&2; return 1 ;; *) echo "$_ROUTINE_STORE" >&2; return 1 ;; esac ;;
  esac
  _teams_audit_note "routine-$2" "$team" "routine $1"
  echo "routine $1: $2 done"
}

_ROUTINE_LIVE="EXISTS (SELECT 1 FROM routine_runs r JOIN routines t ON t.id = r.routine_id WHERE t.team = %s AND r.state IN ('claimed','started'))"

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
    set) local team="${2:-}" file="${3:-}" id="" ver=""; shift 3 2>/dev/null || shift $#
         while [ $# -gt 0 ]; do
           case "$1" in --id) id="${2:-}"; shift 2 2>/dev/null || shift ;; --version) ver="${2:-}"; shift 2 2>/dev/null || shift ;;
             *) echo "ERROR: unknown option $1" >&2; return 1 ;; esac
         done
         routine_set "$team" "$file" "$id" "$ver" ;;
    pause|resume|delete) routine_state "${2:-}" "${3:-}" "$1" ;;
    *) echo "usage: fxa-sandbox-ctl routine list <team> | get <id> | history <team> <id> | templates | set <team> <file> [--id <id> --version <v>] | pause|resume|delete <team> <id>" >&2; return 1 ;;
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
  db_exec "UPDATE routine_runs SET state = 'failed', reason = $(db_q "$2"), ended_at = $(date +%s) WHERE id = $1 AND state IN ('claimed','started');" >/dev/null
}
