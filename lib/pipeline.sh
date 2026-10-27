#!/bin/bash
# pipeline.sh: pass state and settings for a ticket-to-PR pipeline.
#
# A pipeline is a profile: profiles/<name>/profile.conf, or the older
# pipelines/<name>.conf. It names the repo, the label family, the queue JQL,
# and where durable pass state lives.
#
# Public API:
#   pipeline_load [NAME]        Source profiles/<NAME>/profile.conf or pipelines/<NAME>.conf (default: fxa-ai-fixme)
#   pipeline_label_for STATE    Print the label for a lifecycle state
#   pipeline_free_gb            Free GB on /
#   pipeline_lock / _unlock     One pass at a time
#   pipeline_pause / _resume    Kill switch: lock refuses while a PAUSED marker exists
#   pipeline_skip KEY [reason]  Record an admission skip; prints comment|silent <n>
#   pipeline_skipped [KEY]      List recorded skips
#   pipeline_skip_prune         Drop records whose ticket left the queue (queue keys on stdin)
#   pipeline_attempts KEY [bump]  Read or increment the real-fix attempt counter
#   pipeline_progress KEY       What the launcher actually did (authoritative)

[ -n "${_FXA_PIPELINE_LOADED:-}" ] && return 0
_FXA_PIPELINE_LOADED=1
# Automatic rounds per PR (rebase attempts, review rounds): PRODUCT.md says they stop at 2. Not a profile key.
_FXA_ROUND_CAP=2

: "${FXA_PIPELINE:=fxa-ai-fixme}"
# Team records (lib/team_record.py), cached on this host; config.sh sets the same default.
: "${FXA_TEAMS_DIR:=${HOME}/.claude/state/teams}"

# Env overrides win over the config, so old cron and shell overrides still work.
# Keys only the controller sets: a team that set them would move its state, locks or mirror,
# read a credential, or run a command on the host. pipeline_load derives them from the name.
PIPE_HOST_KEYS="PIPE_NAME PIPE_STATE_DIR PIPE_LOCK_DIR PIPE_POOL_NAME PIPE_REPO PIPE_RUNS_FILE PIPE_COSTS_FILE PIPE_STATE_URI PIPE_PAUSE_URI PIPE_JIRA_BASIC PIPE_TOOLING_APPROVERS PIPE_RELOCK_CMD PIPE_RELOCK_SIGN PIPE_LOCK_STALE_SECONDS PIPE_JIRA_SITE PIPE_SECRET_TICKETS"
# pipeline_conf_lint <conf>   A profile may hold only comments, KEY=value with one word or one
# quoted string, and the rows of a KEY=( ... ) array. No command substitution, no second command.
pipeline_conf_lint() {
  local bad
  bad="$(grep -nvE "^[[:space:]]*(#.*)?\$|^(PIPE_[A-Z0-9_]+|_pipe_[a-z0-9_]+)=(\"[^\"]*\"|'[^']*'|[^[:space:]\"'#;&|<>()]*|\\()([[:space:]]+#.*)?\$|^[[:space:]]*\"[^\"]*\"[[:space:]]*\$|^\\)[[:space:]]*\$" "$1")" || true
  bad="$(printf '%s\n' "$bad"; grep -nE '^[^#]*(\$\(|`)' "$1" | sed 's/^/command substitution: /')" || true
  # A team value never expands: "$PIPE_JIRA_BASIC" would copy a host secret into the runner's prompt.
  # Only the built-in fxa profile (operator code, with its env overrides) may use $.
  local d root; d="$(cd "$(dirname "$1")" && pwd -P)"; root="${d%/profiles/*}"; root="${root%/pipelines}"
  if ! [ "$1" -ef "${root}/profiles/fxa/profile.conf" ]; then
    bad="$(printf '%s\n' "$bad"; grep -nE '^[[:space:]]*[^#[:space:]].*\$' "$1" | sed 's/^/expansion: /')" || true
    # Host and credential keys come from the controller, and a team is only the folder it is in.
    bad="$(printf '%s\n' "$bad"; grep -nE "^(${PIPE_HOST_KEYS// /|})=" "$1" | sed 's/^/host key: /')" || true
    bad="$(printf '%s\n' "$bad"; grep -nE '^PIPE_PROFILE=' "$1" | grep -vE "^[0-9]+:PIPE_PROFILE=\"?${d##*/}\"?([[:space:]]+#.*)?\$" | sed 's/^/another team: /')" || true
  fi
  bad="$(printf '%s\n' "$bad" | grep . || true)"
  [ -z "$bad" ] && return 0
  printf '%s\n' "$bad" | sed "s#^#${1##*/profiles/}: #" | head -5
  return 1
}

# pipeline_folder_teams   The folder teams: a folder under profiles/ with a profile.conf. A folder with
# only a record team's boot.sh or skills is not one, and does not reserve its name.
pipeline_folder_teams() { local f; for f in "${SANDBOX_ROOT}"/profiles/*/profile.conf; do [ -f "$f" ] && basename "$(dirname "$f")"; done | LC_ALL=C sort; return 0; }
# pipeline_profile_names   Every team: the folder teams, then the records in FXA_TEAMS_DIR.
pipeline_profile_names() {
  { pipeline_folder_teams; ls "$FXA_TEAMS_DIR" 2>/dev/null | sed -n 's/\.json$//p' | grep -vx index || true; } | awk '!seen[$0]++'
}

# _pipeline_team_jira <name>   A team with its own Jira credential (secrets.jira, "email:token" in Secret
# Manager): PIPE_JIRA_BASIC for its REST calls, and FXA_ACLI_HOME, a home that holds its own acli login.
# Both live under ~/.config/fxa/teams/<name> (mode 700), not in the state dir, which is mirrored to GCS.
# The secret is read again after an hour; acli logs in again only when the credential changed.
_pipeline_team_jira() {
  local d="${FXA_TEAMS_SECRET_DIR:-${HOME}/.config/fxa/teams}/$1" basic sum
  ( umask 077; mkdir -p "$d/acli-home" ) || return 1
  if [ ! -s "$d/jira.basic" ] || [ "$(( $(date +%s) - $(_mtime "$d/jira.basic" 2>/dev/null || echo 0) ))" -gt 3600 ]; then
    basic="$(gcloud secrets versions access latest --secret "$PIPE_JIRA_SECRET" ${FXA_GCE_PROJECT:+--project "$FXA_GCE_PROJECT"} 2>/dev/null)" \
      && [[ "$basic" =~ ^[^:@[:space:]]+@[^:[:space:]]+:[^[:space:]]+$ ]] \
      || { echo "ERROR: team $1: could not read its Jira credential (${PIPE_JIRA_SECRET}, email:token)" >&2; return 1; }
    ( umask 077; printf '%s' "$basic" > "$d/jira.basic" )
  fi
  basic="$(cat "$d/jira.basic")"
  sum="$(printf '%s' "$basic" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
  # A service account has no acli login: jira.sh sends its calls to REST.
  if ! [[ "$basic" == *@serviceaccount.atlassian.com:* ]] && [ "$(cat "$d/acli.sum" 2>/dev/null)" != "$sum" ]; then
    printf '%s' "${basic#*:}" | HOME="$d/acli-home" command acli jira auth login --site "$(s="${PIPE_JIRA_SITE:-https://mozilla-hub.atlassian.net}"; echo "${s#https://}")" --email "${basic%%:*}" --token >/dev/null 2>&1 \
      || { echo "ERROR: team $1: acli refused its Jira credential (${PIPE_JIRA_SECRET})" >&2; return 1; }
    printf '%s' "$sum" > "$d/acli.sum"
  fi
  export PIPE_JIRA_BASIC="$basic" FXA_ACLI_HOME="$d/acli-home"
}

# _pipeline_load_record <name>   A team record: validated and mapped by team_record.py, then set
# key by key from an allowlist. Never sourced or eval'd. Its prompts go beside the record.
_pipeline_load_record() {
  local name="$1" rec out k v
  rec="${FXA_TEAMS_DIR}/${name}.json"
  out="$(FXA_RESERVED_TEAMS="$(pipeline_folder_teams | tr '\n' ' ')" \
    python3 -I "${SANDBOX_ROOT}/lib/team_record.py" env "$rec" "$name")" || { echo "ERROR: team record ${name} is not valid" >&2; return 1; }
  PIPE_REPOS=()
  while IFS=$'\t' read -r k v; do
    case "$k" in
      REPO) PIPE_REPOS+=("$v") ;;
      PIPE_LABEL|PIPE_BASE_BRANCH|PIPE_STACK_DEFAULT|PIPE_STACK_DIR|PIPE_VM_BACKEND|PIPE_ANDROID|PIPE_DESKTOP_URL|PIPE_EGRESS_EXTRA|PIPE_MCP|PIPE_JIRA_PROJECT|PIPE_PR_OPEN|PIPE_PR_TEAM|PIPE_MAX_LAUNCHES_PER_DAY|PIPE_TEAM_SKILLS|PIPE_BOOT_SCRIPT|PIPE_BOOT_SHA256|PIPE_JIRA_SECRET|PIPE_TEAM_USD_DAY|PIPE_TEAM_USD_MONTH|PIPE_RUNTIME_SECRETS|PIPE_SECRET_TICKETS|PIPE_QUEUE_LABEL|PIPE_LABEL_PREFIX)
        printf -v "$k" '%s' "$v" ;;
      *) echo "ERROR: team record ${name}: unexpected key ${k}" >&2; return 1 ;;
    esac
  done <<< "$out"
  PIPE_PROFILE="$name"
  [ -z "${PIPE_JIRA_SECRET:-}" ] || _pipeline_team_jira "$name" || return 1
  python3 -I "${SANDBOX_ROOT}/lib/team_record.py" prompts "$rec" "${FXA_TEAMS_DIR}/${name}" \
    || { echo "ERROR: could not write the prompts of team ${name}" >&2; return 1; }
}

pipeline_load() {
  local name="${1:-$FXA_PIPELINE}" conf
  # A child inherits the FXA_REPO its parent's load exported; only a repo set by hand overrides.
  [ -n "${FXA_REPO:-}" ] && [ "$FXA_REPO" = "${_FXA_REPO_LOADED:-}" ] && unset FXA_REPO
  # The same for the base branch, the pool name and the secrets source (README: env overrides).
  [ -n "${FXA_WORKTREE_BASE:-}" ] && [ "$FXA_WORKTREE_BASE" = "${_FXA_BASE_LOADED:-}" ] && unset FXA_WORKTREE_BASE
  [ -n "${FXA_SHARED_WORKTREE_NAME:-}" ] && [ "$FXA_SHARED_WORKTREE_NAME" = "${_FXA_POOL_LOADED:-}" ] && unset FXA_SHARED_WORKTREE_NAME
  [ -n "${FXA_SECRETS_SOURCE:-}" ] && [ "$FXA_SECRETS_SOURCE" = "${_FXA_SECRETS_LOADED:-}" ] && unset FXA_SECRETS_SOURCE
  # Only a secret team's record sets these: a later load in the same shell (a subshell loop over teams)
  # must not keep a secret team's flag, labels or queue.
  [ -z "${PIPE_SECRET_TICKETS:-}" ] || unset PIPE_LABEL_PREFIX PIPE_QUEUE_JQL
  unset PIPE_SECRET_TICKETS PIPE_QUEUE_LABEL
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: bad profile name '${name}'" >&2; return 1; }
  conf="${SANDBOX_ROOT}/profiles/${name}/profile.conf"
  [ -f "$conf" ] || conf="${SANDBOX_ROOT}/pipelines/${name}.conf"
  if [ ! -f "$conf" ] && [ -f "${FXA_TEAMS_DIR}/${name}.json" ]; then
    _pipeline_load_record "$name" || return 1
  elif [ ! -f "$conf" ]; then
    echo "ERROR: no profile '${name}' in ${SANDBOX_ROOT}/profiles, pipelines or ${FXA_TEAMS_DIR}" >&2
    echo "Available: $(pipeline_profile_names | tr '\n' ' ')" >&2
    return 1
  else
    # The file is sourced as bash: refuse a line that would run a command before it runs.
    pipeline_conf_lint "$conf" >&2 || { echo "ERROR: profile ${name} (${conf}) holds more than assignments" >&2; return 1; }
    # shellcheck disable=SC1090
    # Unreadable (a deploy mid-extract) or broken: stop here, not later on an unset PIPE_REPO_SLUG.
    source "$conf" || { echo "ERROR: could not read profile ${name} (${conf})" >&2; return 1; }
  fi
  PIPE_NAME="$name"
  # A team that works on Android (PIPE_ANDROID=1): every runner it starts is an Android runner.
  if [ "${PIPE_ANDROID:-}" = 1 ]; then android_runner_env; fi
  # PIPE_REPOS: one row per repo, "slug path role [base]", role work, dep, data or ref; base
  # defaults to PIPE_BASE_BRANCH. The first work row is the session's repo; the old single values
  # come from the rows. Every work row goes in PIPE_WORK_ROWS ("slug path [base]"): what a stack may pick.
  PIPE_WORK_ROWS=()
  if [ -n "${PIPE_REPOS+x}" ]; then
    local row slug path role base deps="" paths=" "
    for row in "${PIPE_REPOS[@]}"; do
      read -r slug path role base <<< "$row"
      [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$path" =~ ^/home/agent/[a-z0-9-]+$ ]] && [[ "$role" =~ ^(work|dep|data|ref)$ ]] \
        && [[ -z "$base" || "$base" =~ ^[A-Za-z0-9._/-]{1,60}$ ]] \
        || { echo "ERROR: profile ${name}: bad repo row '${row}' (slug path role [base]; role is work, dep, data or ref)" >&2; return 1; }
      [[ "$paths" == *" $path "* ]] && { echo "ERROR: profile ${name}: two repo rows use ${path}" >&2; return 1; }
      paths="${paths}${path} "
      case "$role" in
        work) PIPE_WORK_ROWS+=("$slug $path${base:+ $base}")
          [ -n "${PIPE_REPO_SLUG:-}" ] || { PIPE_REPO_SLUG="$slug"; PIPE_WORKSPACE="$path"; } ;;
        dep) deps="${deps:+$deps }$slug" ;;
      esac
    done
    PIPE_DEP_REPOS="${PIPE_DEP_REPOS:-$deps}"
  fi
  # Defaults for the keys a profile may leave out. FxA sets them all.
  PIPE_PROFILE="${PIPE_PROFILE:-$name}"
  PIPE_BASE_BRANCH="${PIPE_BASE_BRANCH:-main}"
  PIPE_REPO="${PIPE_REPO:-$(pipeline_host_clone "${PIPE_REPO_SLUG:-}")}"
  PIPE_STATE_DIR="${PIPE_STATE_DIR:-${HOME}/.claude/state/${PIPE_PROFILE}}"
  PIPE_RUNS_FILE="${PIPE_RUNS_FILE:-${PIPE_STATE_DIR}/agent-runs.jsonl}"
  PIPE_COSTS_FILE="${PIPE_COSTS_FILE:-${PIPE_STATE_DIR}/agent-costs.json}"
  PIPE_MIN_FREE_GB="${PIPE_MIN_FREE_GB:-5}"
  PIPE_STALL_MINUTES="${PIPE_STALL_MINUTES:-20}"
  # Every team's tickets are on one Jira site; the REST calls (sprint, attachments) need it.
  PIPE_JIRA_SITE="${PIPE_JIRA_SITE:-https://mozilla-hub.atlassian.net}"
  # One label for every team: pipeline_jira_scope keeps each queue to its own project.
  PIPE_LABEL_PREFIX="${PIPE_LABEL_PREFIX:-ai-fixme}"
  # The label an engineer adds: the prefix, except for a secret team, whose states have their own prefix.
  PIPE_QUEUE_LABEL="${PIPE_QUEUE_LABEL:-$PIPE_LABEL_PREFIX}"
  PIPE_QUEUE_JQL="${PIPE_QUEUE_JQL:-labels = \"${PIPE_QUEUE_LABEL}\" AND statusCategory != Done ORDER BY created ASC}"
  # The pool sits beside the repo's clone, and every clone is in ~/Desktop/working2: each
  # profile needs its own name, or a second team's slots are FxA's.
  PIPE_POOL_NAME="${PIPE_POOL_NAME:-${PIPE_PROFILE}-auto}"
  # Every other team mirrors its state and has its own pause marker beside FxA's, from its name.
  if [ "$PIPE_PROFILE" != fxa ]; then
    local bucket="${PIPE_STATE_BUCKET:-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme}}"
    PIPE_STATE_URI="${bucket:+${bucket}/teams-state/${PIPE_PROFILE}/state}"
    PIPE_PAUSE_URI="${bucket:+${bucket}/teams-state/${PIPE_PROFILE}/PAUSED}"
  fi

  # A repo set by hand wins for any profile. The FXA_FIXME_* state overrides are the FxA
  # pipeline's: they must not move another team's state into FxA's.
  PIPE_REPO="${FXA_REPO:-$PIPE_REPO}"
  PIPE_BASE_BRANCH="${FXA_WORKTREE_BASE:-$PIPE_BASE_BRANCH}"
  PIPE_POOL_NAME="${FXA_SHARED_WORKTREE_NAME:-$PIPE_POOL_NAME}"
  if [ "$PIPE_PROFILE" = fxa ]; then
    PIPE_STATE_DIR="${FXA_FIXME_STATE:-$PIPE_STATE_DIR}"
    PIPE_RUNS_FILE="${FXA_FIXME_RUNS:-$PIPE_RUNS_FILE}"
    PIPE_COSTS_FILE="${FXA_FIXME_COSTS:-$PIPE_COSTS_FILE}"
    PIPE_MIN_FREE_GB="${FXA_MIN_FREE_GB:-$PIPE_MIN_FREE_GB}"
  fi
  # Another team's PR asks the repo's default reviewers (CODEOWNERS), not fxa-devs, unless its
  # profile names a team. FxA, and a team set by hand, keep finish's own default.
  [ "$PIPE_PROFILE" = fxa ] || [ -n "${FXA_PR_TEAM+x}" ] || export FXA_PR_TEAM="${PIPE_PR_TEAM:-}"
  # worktree.sh, finish and the rest of ctl read the FXA_* names, so keep them in step.
  export FXA_REPO="$PIPE_REPO" _FXA_REPO_LOADED="$PIPE_REPO" \
    FXA_SHARED_WORKTREE_NAME="$PIPE_POOL_NAME" _FXA_POOL_LOADED="$PIPE_POOL_NAME" \
    FXA_WORKTREE_BASE="$PIPE_BASE_BRANCH" _FXA_BASE_LOADED="$PIPE_BASE_BRANCH"
  # A private fork of FxA runs the stack from its own work repo, so the FxA dev secrets come from
  # the FxA host clone, as they do for FxA. A set FXA_SECRETS_SOURCE wins.
  if [ -n "${PIPE_STACK_DIR:-}" ] && [ "$PIPE_STACK_DIR" = "${PIPE_WORKSPACE:-}" ] && [ -z "${FXA_SECRETS_SOURCE:-}" ] \
     && [ "$(tr 'A-Z' 'a-z' <<< "${PIPE_REPO_SLUG:-}")" != mozilla/fxa ]; then
    local fs; fs="$(pipeline_host_clone mozilla/fxa)"
    export FXA_SECRETS_SOURCE="$fs" _FXA_SECRETS_LOADED="$fs"
  fi

  mkdir -p "$PIPE_STATE_DIR"
  PIPE_LOCK_DIR="${PIPE_STATE_DIR}/pass.lock"
  return 0
}

pipeline_require() {
  [ -n "${PIPE_STATE_DIR:-}" ] || pipeline_load || return 1
}

# The bare prefix is the queue label; only lifecycle states carry a suffix.
pipeline_label_for() {
  case "$1" in
    public|queued) printf '%s\n' "${PIPE_QUEUE_LABEL:-$PIPE_LABEL_PREFIX}" ;;
    *)             printf '%s-%s\n' "$PIPE_LABEL_PREFIX" "$1" ;;
  esac
}

# diff: a read-only profile's run finished as a patch for a person to review (finish_diff_only).
pipeline_states() { printf '%s\n' public inflight done blocked merged rejected diff; }

pipeline_free_gb() {
  _free_gb / 2>/dev/null
}

# ── Pass lock ──────────────────────────────────────────────────
# mkdir is atomic, so it works as a lock without flock, which macOS does not ship.
# Kill switch: a PAUSED marker (local file, or the object at PIPE_PAUSE_URI) makes
# every `lock` refuse, with no stale break. If gcloud fails, treat it as not
# paused: a kill switch that pauses silently looks like a healthy idle pipeline.
pipeline_pause_marker() { printf '%s' "${PIPE_STATE_DIR}/PAUSED"; }
pipeline_paused() {
  local m; m="$(pipeline_pause_marker)"
  if [ -f "$m" ]; then cat "$m"; return 0; fi
  if [ -n "${PIPE_PAUSE_URI:-}" ]; then
    local out
    if out="$(gcloud storage cat "$PIPE_PAUSE_URI" 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi
    gcloud storage ls "$PIPE_PAUSE_URI" >/dev/null 2>&1 && return 0
  fi
  return 1
}
# Existing-PRs-only mode: a HOLD-NEW marker keeps rounds on open PRs going but
# launches no new ticket. In the state dir, so `state push` mirrors it.
pipeline_hold_marker() { printf '%s' "${PIPE_STATE_DIR}/HOLD-NEW"; }
pipeline_holding_new() { [ -f "$(pipeline_hold_marker)" ]; }
pipeline_newtickets() {
  pipeline_require || return 1
  case "${1:-}" in
    off) printf '%s\n' "off by $(whoami) at $(date '+%Y-%m-%d %H:%M')" >"$(pipeline_hold_marker)"; echo "newtickets off: rounds on existing PRs only" ;;
    on)  rm -f "$(pipeline_hold_marker)"; echo "newtickets on" ;;
    "")  if pipeline_holding_new; then echo "off ($(cat "$(pipeline_hold_marker)"))"; else echo "on"; fi ;;
    *)   echo "ERROR: newtickets on|off" >&2; return 1 ;;
  esac
}

# Epic focus: a FOCUS marker holding one epic key narrows the queue to that
# epic's children. In the state dir, so `state push` mirrors it.
pipeline_focus_marker() { printf '%s' "${PIPE_STATE_DIR}/FOCUS"; }
pipeline_focus_key() { [ -f "$(pipeline_focus_marker)" ] && head -1 "$(pipeline_focus_marker)"; }
# pipeline_queue_jql [all]   The scope, the profile's filter in parentheses (a top-level OR in it
# must not escape the scope), then its ORDER BY. An epic focus narrows it, unless "all".
pipeline_queue_jql() {
  local k="" s f o=""; s="$(pipeline_jira_scope)" || return 1
  [ "${1:-}" = all ] || k="$(pipeline_focus_key || true)"
  # The marker is spliced into JQL, so it must be one key: `FXA-1 OR key = X` would OR past the scope.
  [ -z "$k" ] || [[ "$k" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { echo "ERROR: the focus marker is not one epic key" >&2; return 1; }
  f="${PIPE_QUEUE_JQL%% ORDER BY *}"; [ "$f" = "$PIPE_QUEUE_JQL" ] || o=" ORDER BY ${PIPE_QUEUE_JQL#* ORDER BY }"
  printf '%s%s AND (%s)%s' "${k:+parent = $k AND }" "$s" "$f" "$o"
}

# _pipeline_secret_labels   The labels that mark a ticket secret, as a quoted JQL list: PIPE_SECRET_LABELS
# (a team may set its own), else security and hackerone, the MCP gateway's and the Slack card's rule.
# An empty setting is not "none": every team keeps these two. A bad label fails the read.
_pipeline_secret_labels() {
  local l out="" seen=" "
  for l in security hackerone ${PIPE_SECRET_LABELS:-}; do
    [[ "$l" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "ERROR: PIPE_SECRET_LABELS has a bad label: ${l}" >&2; return 1; }
    case "$seen" in *" $l "*) continue ;; esac; seen="${seen}${l} "; out="${out:+$out, }\"$l\""
  done
  printf '%s' "$out"
}

# pipeline_jira_scope   The clause in front of every queue and state read: the profile's own
# Jira project (FXA for fxa), so another team's ticket with the same label never runs against
# this repo, and no secret ticket (a security level or a secret label), whose fix would go into a public PR.
# It goes first: the profile's JQL ends with ORDER BY.
# pipeline_jira_project   The profile's Jira project key (FXA for fxa), or an error.
pipeline_jira_project() {
  local p="${PIPE_JIRA_PROJECT:-}"
  [ -z "$p" ] && [ "${PIPE_PROFILE:-}" = fxa ] && p=FXA
  [[ "$p" =~ ^[A-Z][A-Z0-9]*$ ]] || { echo "ERROR: profile ${PIPE_PROFILE:-?} has no Jira project (PIPE_JIRA_PROJECT), so it has no queue" >&2; return 1; }
  printf '%s' "$p"
}
# pipeline_secret_team <PROJECT>   The active team that takes the project's secret tickets, from the teams
# index; nothing when none does, or when the index is missing or bad (a report then shows more, never less).
pipeline_secret_team() {
  jq -r --arg p "$1" '[.teams // {} | to_entries[] | select(.value.secret == true and .value.status == "active" and .value.jira == $p) | .key][0] // empty' \
    "${FXA_TEAMS_DIR:-/nonexistent}/index.json" 2>/dev/null || true
}
pipeline_jira_scope() {
  local p sl r
  p="$(pipeline_jira_project)" || return 1
  sl="$(_pipeline_secret_labels)" || return 1
  if [ "${PIPE_SECRET_TICKETS:-}" = 1 ]; then
    # A secret team takes exactly what the public scope leaves out, and only while GitHub confirms
    # that each work repo is private: no read, so no launch, on any other answer.
    [ "${#PIPE_WORK_ROWS[@]}" -gt 0 ] || { echo "ERROR: secret team ${PIPE_PROFILE:-?} has no work repo" >&2; return 1; }
    for r in "${PIPE_WORK_ROWS[@]}"; do
      github_repo_confirmed_private "${r%% *}" || { echo "ERROR: ${PIPE_PROFILE:-?}: ${r%% *} is not confirmed private, so no secret ticket is read or launched. The next pass checks again." >&2; return 1; }
    done
    printf 'project = %s AND (level IS NOT EMPTY OR labels IN (%s))' "$p" "$sl"
    return 0
  fi
  printf 'project = %s AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN (%s))' "$p" "$sl"
}
# pipeline_key_in_scope <KEY>   The queue's scope also gates a direct launch: a pass that a
# ticket's text steered could name any key. A Jira read that fails refuses.
pipeline_key_in_scope() {
  local s got; s="$(pipeline_jira_scope)" || return 1
  [[ "$1" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || return 1
  got="$(_jira_keys_for_jql "${s} AND key = $1")" || return 1
  [ "$got" = "$1" ]
}
# pipeline_ship_ok <KEY> [<worktree>]   Before a push: the ticket is still in this team's Jira scope, and a
# secret team's repos are still confirmed private (the scope checks them). A label can change during a run.
pipeline_ship_ok() {
  local key="${1:-}" wt="${2:-}" s got i t="" m
  [[ "$key" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { echo "ERROR: no ticket key in the handoff, so its scope cannot be checked; no push" >&2; return 1; }
  for i in 1 2 3; do
    if s="$(pipeline_jira_scope)" && got="$(_jira_keys_for_jql "${s} AND key = ${key}")"; then
      [ "$got" = "$key" ] && return 0
      [ "${PIPE_SECRET_TICKETS:-}" = 1 ] || t="$(pipeline_secret_team "$(pipeline_jira_project 2>/dev/null)" 2>/dev/null || true)"
      if [ -n "$t" ]; then t="team ${t}"; else t="the team that takes it"; fi
      m="${key} left team ${PIPE_PROFILE:-?}'s Jira scope; no push. Relabel it for ${t}: fxa-sandbox-ctl --pipeline ${PIPE_PROFILE:-?} label ${key} public (it leaves only ai-fixme)."
      echo "ERROR: ${m}" >&2; errors_record pipeline ship "$key" "pipeline_ship_ok" "$m" "" 2>/dev/null || true
      return 1
    fi
    [ "$i" = 3 ] || sleep "${FXA_SHIP_RETRY_S:-5}"
  done
  m="could not read Jira or GitHub to confirm ${key}'s scope; no push. Retry: fxa-sandbox-ctl --pipeline ${PIPE_PROFILE:-fxa} finish --worktree ${wt##*/} --create-pr"
  echo "ERROR: ${m}" >&2; errors_record pipeline ship "$key" "pipeline_ship_ok" "$m" "" 2>/dev/null || true
  return 1
}
pipeline_focus() {
  pipeline_require || return 1
  case "${1:-}" in
    off) rm -f "$(pipeline_focus_marker)"; echo "focus off: whole queue" ;;
    "")  local k; k="$(pipeline_focus_key || true)"; echo "${k:-off}" ;;
    [A-Z]*-[0-9]*) [[ "$1" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { echo "ERROR: focus takes one epic key" >&2; return 1; }
                printf '%s\n' "$1" >"$(pipeline_focus_marker)"; echo "focus $1: queue is that epic's children only" ;;
    *)   echo "ERROR: focus <EPIC-KEY>|off" >&2; return 1 ;;
  esac
}

pipeline_pause() {
  pipeline_require || return 1
  local reason="${*:-paused by $(whoami) at $(date '+%Y-%m-%d %H:%M')}"
  printf '%s\n' "$reason" >"$(pipeline_pause_marker)"
  if [ -n "${PIPE_PAUSE_URI:-}" ]; then
    printf '%s\n' "$reason" | gcloud storage cp - "$PIPE_PAUSE_URI" >/dev/null 2>&1 || echo "WARN: could not write ${PIPE_PAUSE_URI}; only this machine is paused" >&2
  fi
  echo "paused: ${reason}"
}
pipeline_resume() {
  pipeline_require || return 1
  rm -f "$(pipeline_pause_marker)"
  if [ -n "${PIPE_PAUSE_URI:-}" ]; then
    gcloud storage rm "$PIPE_PAUSE_URI" >/dev/null 2>&1 || true
  fi
  echo "resumed"
}

pipeline_lock() {
  pipeline_require || return 1
  local why
  if why="$(pipeline_paused)"; then
    echo "paused: ${why:-no reason recorded}. Run \`fxa-sandbox-ctl resume\` to restart passes."
    return 1
  fi
  if [ -d "$PIPE_LOCK_DIR" ]; then
    local age; age=$(( $(date +%s) - $(_mtime "$PIPE_LOCK_DIR" 2>/dev/null || echo 0) ))
    # A pass takes under 10 min, so an older lock is a dead session. The pid
    # inside is the `lock` call's own and already gone, so age is the only signal.
    if [ "$age" -lt "${PIPE_LOCK_STALE_SECONDS:-1800}" ]; then
      echo "locked: another pass started ${age}s ago (pid $(cat "${PIPE_LOCK_DIR}/pid" 2>/dev/null || echo '?'))"
      return 1
    fi
    echo "clearing stale lock, ${age}s old" >&2
    rm -rf "$PIPE_LOCK_DIR"
  fi
  mkdir "$PIPE_LOCK_DIR" 2>/dev/null || { echo "locked: lost the race"; return 1; }
  echo $$ >"${PIPE_LOCK_DIR}/pid"
  # Every pass takes the lock, so this stamp is the one sure liveness signal.
  date +%s >"${PIPE_STATE_DIR}/last-pass"
  echo "acquired"
}

pipeline_unlock() {
  pipeline_require || return 1
  rm -rf "$PIPE_LOCK_DIR"
  echo "released"
  # A failed push warns and goes on: under set -e its status ended precheck before the pass row and the quiet line.
  pipeline_state_push || true
}

# ── State mirror ───────────────────────────────────────────────
# PIPE_STATE_URI (gs://bucket/prefix) mirrors the state dir. Push runs at every
# unlock. Pull is manual: it could roll back a launch log that is still growing.
# Left out: the lock, the pause marker, reporters.tsv (emails), and temp files.
_pipeline_state_exclude='^(pass\.lock(/.*)?|PAUSED|reporters\.tsv|.*\.tmp)$'
pipeline_state_push() {
  pipeline_require || return 1
  [ -n "${PIPE_STATE_URI:-}" ] || return 0
  if gcloud storage rsync "$PIPE_STATE_DIR" "$PIPE_STATE_URI" --recursive \
       --exclude="$_pipeline_state_exclude" >/dev/null 2>&1; then
    echo "state pushed to ${PIPE_STATE_URI}"
  else
    echo "WARN: state push to ${PIPE_STATE_URI} failed; local state is still authoritative." >&2
    return 1
  fi
}
pipeline_state_pull() {
  pipeline_require || return 1
  [ -n "${PIPE_STATE_URI:-}" ] || { echo "ERROR: PIPE_STATE_URI is not set." >&2; return 1; }
  [ -d "$PIPE_LOCK_DIR" ] && { echo "ERROR: a pass holds the lock; pull after it releases." >&2; return 1; }
  gcloud storage rsync "$PIPE_STATE_URI" "$PIPE_STATE_DIR" --recursive \
    --exclude="$_pipeline_state_exclude" 2>&1 | grep -v '^$' | tail -3
  echo "state pulled from ${PIPE_STATE_URI} into ${PIPE_STATE_DIR}"
}
pipeline_state_status() {
  pipeline_require || return 1
  [ -n "${PIPE_STATE_URI:-}" ] || { echo "state mirror: off (PIPE_STATE_URI unset)"; return 0; }
  local n
  n="$(gcloud storage ls --recursive "$PIPE_STATE_URI" 2>/dev/null | grep -c -v ':$' || true)"
  echo "state mirror: ${PIPE_STATE_URI}  objects=${n:-0}  local_files=$(find "$PIPE_STATE_DIR" -type f | wc -l | tr -d ' ')"
  echo "pause marker: ${PIPE_PAUSE_URI:-local only}"
}

# ── Admission skips ────────────────────────────────────────────
# Portable md5. Linux ships md5sum, macOS ships md5; this host has both.
_pipeline_hash() {
  if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'
  else md5 -q; fi
}

# Hash the ticket plus every comment a person wrote: not by the service account, not led by 🤖.
# Our own skip comment would otherwise change the hash and cause another comment on every pass.
# A failed read prints nothing: md5 of a partial read looked like an edit and woke a model pass.
# The trailing . keeps the bytes the hash saw before, trailing newlines included.
_pipeline_skip_fingerprint() {
  local key="$1" v c t=""
  v="$(acli jira workitem view "$key" 2>/dev/null && echo .)" || return 0
  c="$(acli jira workitem comment list --key "$key" --json --paginate 2>/dev/null)" || return 0
  local me=""; if _jira_sa; then me="$(_jira_rest GET /rest/api/3/myself | jq -r '.displayName // empty')" && [ -n "$me" ] || return 0; fi
  c="$(printf '%s\n' "$c" | jq -r --arg me "$me" '.comments[]? | select(((.body // "") | startswith("🤖")) or ($me != "" and .author == $me) | not) | .body' && echo .)" || return 0
  # The plain view prints no labels, and the allow-tooling label is how a tooling skip is unblocked.
  # Only that label counts: hashing every label would wake each skipped ticket once.
  if [ -n "${PIPE_TOOLING_LABEL:-}" ]; then
    t="$(acli jira workitem view "$key" --fields labels --json 2>/dev/null)" || return 0
    t="$(printf '%s' "$t" | jq -r --arg l "$PIPE_TOOLING_LABEL" 'if (.fields.labels // []) | index($l) then $l else "" end')" || return 0
  fi
  printf '%s%s%s' "${v%.}" "${c%.}" "$t" | _pipeline_hash
}

# pipeline_skip <KEY> [reason...]
#   Record an admission skip. Print "comment" the first time or when the ticket
#   changed, else "silent <n>" (passes that skipped it), so a skip gets one
#   comment, not one per pass. Keep the hash: a comment count misses edits.
# _pipeline_one_line <text...>   One clean line for a state file: escape sequences and other control
# characters go, tabs and newlines become one space, and it is cut at 300 characters.
_pipeline_one_line() {
  printf '%s' "$*" | LC_ALL=C sed $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g; s/\x1b[@-_]//g' | tr '\t\n\r' '   ' \
    | LC_ALL=C tr -d '\000-\037\177' | tr -s ' ' | cut -c1-300   # ponytail: GNU cut counts bytes, so a long non-ASCII reason can lose its last character
}

# The kinds of a blocked label and of an admission skip (the pass skill names them; lib/skill-kinds.check.sh reads these).
_PIPE_BLOCKED_KINDS="stalled dead_vm attempts rounds refused_ship frozen operator"
_PIPE_SKIP_KINDS="needs_decision underspecified depends_on already_done"

# pipeline_blocked_why <KEY> <state> [kind] [reason...]   Why the ticket is blocked, for the Board: one
# "epoch<TAB>kind<TAB>reason" line in <KEY>.blocked-why, cleared by any other state. A kind is a whole
# argument from _PIPE_BLOCKED_KINDS, else "other". It never fails the label: a problem is a WARN.
pipeline_blocked_why() {
  local k state="${2:-}" kind=other reason f t at; k="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  [[ "$k" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "WARN: no blocked reason kept: '${1:-}' is not a ticket key" >&2; return 0; }
  f="${PIPE_STATE_DIR}/${k}.blocked-why"
  [ "$state" = blocked ] || { rm -f "$f"; return 0; }
  shift 2
  if [ $# -gt 0 ] && [[ " $_PIPE_BLOCKED_KINDS " == *" $1 "* ]]; then kind="$1"; shift
  elif [ $# -gt 0 ] && [[ "$1" =~ ^[a-z]+(_[a-z]+)+$ ]]; then echo "WARN: '$1' is not a blocked kind (${_PIPE_BLOCKED_KINDS}); kept as other" >&2; fi
  reason="$(_pipeline_one_line "$*")"; at="$(date +%s)"
  # A repeat with the same kind keeps when the ticket was first blocked.
  [ -f "$f" ] && [ "$(cut -f2 "$f" 2>/dev/null)" = "$kind" ] && at="$(cut -f1 "$f")"
  t="$(mktemp "${PIPE_STATE_DIR}/.blocked-why.XXXXXX" 2>/dev/null)" && printf '%s\t%s\t%s\n' "$at" "$kind" "$reason" > "$t" && mv "$t" "$f" \
    || { rm -f "${t:-}"; echo "WARN: could not keep why $k is blocked" >&2; }
  return 0
}

pipeline_skip() {
  pipeline_require || return 1
  local key; key="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  # The key names a state file: refuse anything that is not a ticket key before a path is built.
  [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "ERROR: skip needs a ticket key (FXA-1234), not '${1:-}'" >&2; return 1; }
  shift || true
  local kind=""; [ $# -gt 1 ] && [[ " $_PIPE_SKIP_KINDS " == *" ${1:-} "* ]] && { kind="$1"; shift; }
  local reason; reason="$(_pipeline_one_line "$*")"
  local f="${PIPE_STATE_DIR}/${key}.skipped"
  rm -f "${PIPE_STATE_DIR}/${key}.held"  # a plain skip replaces a hold; pipeline_hold writes it again after
  local fp; fp="$(_pipeline_skip_fingerprint "$key")"
  # An empty hash means the ticket read failed. Comment rather than record a
  # fingerprint that would silence a real change later.
  [ -n "$fp" ] || { echo "comment"; return 0; }
  if [ -f "$f" ]; then
    local old n
    old="$(awk -F'\t' 'NR==1{print $1}' "$f")"
    n="$(awk -F'\t' 'NR==1{print $3+0}' "$f")"
    if [ "$old" = "$fp" ]; then
      n=$((n + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$fp" "$(date +%s)" "$n" "$reason" "$kind" > "$f"
      echo "silent $n"
      return 0
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$fp" "$(date +%s)" 1 "$reason" "$kind" > "$f"
  echo "comment"
}

# pipeline_hold <KEY> <BLOCKER> [reason...]
#   A skip that waits on another ticket (both edit the same files, or the ticket says so). Quiet
#   until BLOCKER is merged or closed in Jira, or KEY changes; then one pass looks again. Prints
#   what pipeline_skip prints. Unrecorded, a held ticket woke the model on every pass.
pipeline_hold() {
  local key blocker="${2:-}"; key="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  [[ "$blocker" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] && [ "$blocker" != "$key" ] \
    || { echo "ERROR: hold needs <KEY> <BLOCKER-KEY> [reason]" >&2; return 1; }
  shift 2
  local out; out="$(pipeline_skip "$key" depends_on "held until ${blocker} merges: $*")" || return 1
  printf '%s\n' "$blocker" > "${PIPE_STATE_DIR}/${key}.held"
  printf '%s\n' "$out"
}

# _pipeline_blocker_done <KEY>   0 when the ticket's PR merged (the merged label) or Jira closed it.
_pipeline_blocker_done() {
  acli jira workitem view "$1" --fields labels,status --json 2>/dev/null \
    | jq -e --arg m "$(pipeline_label_for merged)" '((.fields.labels // []) | index($m)) != null or .fields.status.statusCategory.key == "done"' >/dev/null
}

# strftime() is a GNU awk extension and this host runs BSD awk, so format the
# timestamp with date instead. -r is BSD, -d @ is GNU.
_pipeline_skipped_row() {
  local f="$1"
  [ -f "$f" ] || return 0
  local key ts n reason when
  key="$(basename "$f" .skipped)"
  ts="$(cut -f2 "$f")"; n="$(cut -f3 "$f")"; reason="$(cut -f4 "$f")"
  when="$(date -r "$ts" +%Y-%m-%dT%H:%M 2>/dev/null \
          || date -d "@$ts" +%Y-%m-%dT%H:%M 2>/dev/null \
          || echo "$ts")"
  printf '%s %s %s %s\n' "$key" "$n" "$when" "$reason"
}

pipeline_skipped() {
  pipeline_require || return 1
  local key="${1:-}" f
  if [ -n "$key" ]; then
    _pipeline_skipped_row "${PIPE_STATE_DIR}/${key}.skipped"
    return 0
  fi
  for f in "$PIPE_STATE_DIR"/*.skipped; do
    _pipeline_skipped_row "$f"
  done
}

# pipeline_skip_changed <KEY>
#   Read-only twin of pipeline_skip, for the quiet-pass probe. Print `new` or
#   `changed` and exit 0, or exit 1 when the ticket is the same as the record.
pipeline_skip_changed() {
  pipeline_require || return 1
  local key="${1:-}" f fp old
  f="${PIPE_STATE_DIR}/${key}.skipped"
  [ -f "$f" ] || { echo "new"; return 0; }
  fp="$(_pipeline_skip_fingerprint "$key")"
  # A failed read is no edit: the next pass reads again.
  [ -n "$fp" ] || return 1
  old="$(awk -F'\t' 'NR==1{print $1}' "$f")"
  [ "$old" = "$fp" ] || { echo "changed"; return 0; }
  # A hold wakes a pass once its blocker is merged or closed.
  local b; b="$(cat "${PIPE_STATE_DIR}/${key}.held" 2>/dev/null || true)"
  if [ -n "$b" ] && _pipeline_blocker_done "$b"; then echo "unblocked: ${b} is merged"; return 0; fi
  return 1
}

# Launching clears the fingerprint: a later admission skip on this same key must
# not be silenced by a stale match.
pipeline_skip_clear() {
  pipeline_require || return 1
  rm -f "${PIPE_STATE_DIR}/${1}.skipped" "${PIPE_STATE_DIR}/${1}.held"
}

# Drop skip records for tickets that left the queue (keys on stdin). An empty
# list prunes nothing, so a Jira outage cannot trigger a re-comment on every skip.
pipeline_skip_prune() {
  pipeline_require || return 1
  local -a queue=(); local k f
  while IFS= read -r k; do [ -n "$k" ] && queue+=("$k"); done
  [ "${#queue[@]}" -gt 0 ] || return 0
  for f in "$PIPE_STATE_DIR"/*.skipped; do
    [ -f "$f" ] || continue
    k="$(basename "$f" .skipped)"
    printf '%s\n' "${queue[@]}" | grep -qx "$k" && continue
    rm -f "$f"; echo "$k skip record pruned (left the queue)"
  done
  return 0
}

pipeline_attempts() {
  pipeline_require || return 1
  local key="${1:-}" bump="${2:-}"
  [ -n "$key" ] || { echo "ERROR: attempts needs <KEY>" >&2; return 1; }
  local f="${PIPE_STATE_DIR}/${key}.attempts"
  local n; n="$(cat "$f" 2>/dev/null || echo 0)"
  if [ "$bump" = "bump" ]; then n=$((n + 1)); echo "$n" >"$f"; fi
  echo "$n"
}

# pipeline_launch_started <log>   The run's start (epoch): the launcher's first
# line, else the file's birth time. A copy to another host (the state mirror)
# keeps the line but not the birth time.
pipeline_launch_started() {
  local t; t="$(sed -n '1s/^Launched at: \([0-9]\{9,\}\)$/\1/p' "$1" 2>/dev/null)"
  if [ -n "$t" ]; then echo "$t"; else _btime "$1"; fi
}
pipeline_launch_log() { printf '%s/%s.launch.log\n' "$PIPE_STATE_DIR" "$1"; }

# _pipeline_stalled_reason <KEY> <ELAPSED-SECONDS>
#   Print a reason and return 0 when a run is alive but producing nothing, else
#   return 1. Every other health signal once read fine for 15 minutes while a
#   prompt sat unsent in the TUI.
_pipeline_stalled_reason() {
  local key="$1" elapsed="${2:-0}" name wt files commits

  name="$(worktree_branch_for "$key" 2>/dev/null)" || return 1
  wt="$(_telemetry_worktree_for_key "$key" 2>/dev/null || echo '')"
  # 1. DEFINITIVE. Both runtimes exit when done, so a VM with no agent process
  #    and no handoff file is a run that ended without one. A /goal over 4000
  #    chars ends the run at once with num_turns 0 and no error flag.
  local alive_rc=0
  if [ -n "$wt" ] && vm_is_running "$name" 2>/dev/null; then
    agent_alive "$name" 2>/dev/null; alive_rc=$?
  fi
  # rc 1 is "asked, no process". rc 2 is "could not ask", which is not a stall.
  if [ "$alive_rc" -eq 1 ] && [ ! -s "${wt}/.fxa-auto-done.json" ]; then
    # The run said it is blocked: a person decides, so the pass does not relaunch it. Runner text, so plain characters only.
    if [ -s "${wt}/.fxa-auto-blocked.txt" ]; then
      printf 'agent-blocked: %s' "$(head -1 "${wt}/.fxa-auto-blocked.txt" | tr -cd 'A-Za-z0-9 ._:/,-' | tr -s ' ' | cut -c1-120)"; return 0
    fi
    if grep -q '"type":"result".*"num_turns":0[,}]' "${wt}/.fxa-auto-claude.jsonl" 2>/dev/null; then
      printf 'goal-rejected'; return 0
    fi
    printf 'exited-without-handoff'; return 0
  fi

  # 2. HEURISTIC. Nothing written or committed past a generous threshold: a false
  #    stall costs a slot and a relaunch.
  [ "$elapsed" -ge $(( ${PIPE_STALL_MINUTES:-20} * 60 )) ] || return 1
  [ -n "$wt" ] || return 1
  if [ "${FXA_VM_BACKEND:-tart}" = gce ]; then
    # Ask the runner for the two counts. Pulling the whole tree for them took
    # over a minute a call, and every dashboard refresh made one per run.
    local out
    out="$(vm_exec_as_agent "$name" "cd /workspace && { git status --porcelain | grep -vcE '^\?\? \.fxa-' || true; } && git log --oneline 'origin/${FXA_WORKTREE_BASE}..HEAD' | wc -l" 2>/dev/null)" || return 1
    files="$(printf '%s\n' "$out" | sed -n 1p | tr -dc '0-9')"
    commits="$(printf '%s\n' "$out" | sed -n 2p | tr -dc '0-9')"
    [ -n "$files" ] && [ -n "$commits" ] || return 1  # could not ask: not a stall
  else
    # `grep -c` prints 0 AND exits non-zero on no match, so `|| true` and one line.
    files="$(git -C "$wt" status --porcelain 2>/dev/null \
             | grep -vcE '^\?\? \.fxa-' || true)"
    files="$(printf '%s' "$files" | head -1 | tr -dc '0-9')"
    commits="$(git -C "$wt" log --oneline "origin/${FXA_WORKTREE_BASE}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ "${files:-0}" -eq 0 ] && [ "${commits:-0}" -eq 0 ]; then
    printf 'no-motion'; return 0
  fi
  return 1
}

# The authoritative record of what the launcher did. Trust it over process
# state: a run once read as "stalled" while this log already held "PR opened".
pipeline_progress() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: progress needs <KEY>" >&2; return 1; }
  local log; log="$(pipeline_launch_log "$key")"
  [ -f "$log" ] || { echo "$key nolog"; return 0; }
  # Every grep here needs `|| true`: pipefail makes a no-match grep fail the
  # whole pipeline, and set -e then kills the function before it can report.
  local pr err t=""
  # A launch with an approved tooling label says so on every line (cmd_launch).
  grep -q '^tooling: scripts allowed' "$log" && t=" tooling=scripts"
  # Only the launcher's own PR line ("PR opened: <url>", "PR updated: <url>", or the bare URL gh
  # prints): a push hint (".../pull/new/<branch>") or a dumped handoff citing another PR is not it.
  pr="$( { grep -E '^(PR (opened|updated): )?https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$' "$log" || true; } | tail -1 | sed -E 's/^PR (opened|updated): //')"
  if [ -n "$pr" ]; then echo "$key pr $pr${t}"; return 0; fi
  # A feedback round's first push is rejected, then forced with a lease, so
  # "rejected" is routine when a "(forced update)" follows it.
  if grep -q '(forced update)' "$log"; then
    err="$(grep -m1 -E '^ERROR|fatal:' "$log" || true)"
  else
    err="$(grep -m1 -E '^ERROR|fatal:|rejected' "$log" || true)"
  fi
  if [ -n "$err" ]; then echo "$key error ${err}${t}"; return 0; fi
  if grep -qE "Pushing |Committing and pushing" "$log"; then echo "$key pushed${t}"; return 0; fi
  if grep -q "Squashing " "$log"; then echo "$key squashing${t}"; return 0; fi
  if grep -q "Watching for" "$log"; then
    # Stall detection lives here because reconcile reads `progress` for every
    # inflight key, so it cannot be skipped.
    local started elapsed reason
    started="$(pipeline_launch_started "$log" 2>/dev/null || echo 0)"
    elapsed=$(( $(date +%s) - started ))
    reason="$(_pipeline_stalled_reason "$key" "$elapsed" || true)"
    if [ -n "$reason" ]; then
      echo "$key stalled ${reason} $(( elapsed / 60 ))m${t}"; return 0
    fi
    local secs; secs="$( { grep -o '\[ *[0-9]*s\]' "$log" || true; } | tail -1 | tr -dc '0-9')"
    echo "$key watching ${secs:-0}s${t}"; return 0
  fi
  # Before the launcher watches for the handoff, say which boot step it is on.
  # On gce this stage lasts minutes, and "starting" alone hid all of them.
  local sub="boot"
  # A reship has no boot; its fallback starts one, so the boot steps below win.
  grep -q '^Reship:' "$log" && ! grep -q '^Reship fallback:' "$log" && sub="reship"
  grep -q "ready (" "$log"                   && sub="checkout"
  grep -q "Infrastructure ready" "$log"      && sub="hardening"
  grep -q "^Shipping \|Setting up .* config" "$log" && sub="config"
  grep -q "is running ===" "$log"            && sub="launching"
  echo "$key starting ${sub}${t}"
}

# pipeline_health_json
#   Is the pipeline alive, not merely idle? The cron is session-scoped, so there
#   is no direct signal; use the newest trace a pass leaves.
# pipeline_launches_24h   The launch ledger's epochs from the last 24 h, oldest first (cmd_launch's budget).
pipeline_launches_24h() {
  local ledger="${PIPE_STATE_DIR}/launches.log"
  # awk exits 2 on a missing file, and under set -e that killed the launch silently.
  [ -f "$ledger" ] || return 0
  awk -v t="$(( $(date +%s) - 86400 ))" '$1 >= t { print $1 }' "$ledger" | sort -n
}

# _pipeline_next_pass   The pass timer's next run as an epoch; "off" for a timer that is not active;
# nothing when this host has no systemd or the time cannot be read.
_pipeline_next_pass() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local u v; u="$(_pipeline_timer_unit)"
  systemctl is-active -q "$u" 2>/dev/null || { echo off; return 0; }
  # Only Linux hosts have systemctl, so GNU date reads its "Sun 2026-10-18 17:04:00 UTC"; @<epoch> also works.
  v="$(systemctl show -p NextElapseUSecRealtime --value "$u" 2>/dev/null)" || return 0
  case "$v" in @*) v="${v#@}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" ;; ?*) date -d "$v" +%s 2>/dev/null ;; esac || true
}

# _pipeline_timer_unit   FxA's pass is fxa-pass.timer (FXA_PIPELINE empty, fxa or fxa-ai-fixme, as
# claude-job.sh reads it); a team's is fxa-pass@<team>.timer.
_pipeline_timer_unit() {
  case "${FXA_PIPELINE:-}" in ''|fxa|fxa-ai-fixme) echo fxa-pass.timer ;; *) echo "fxa-pass@${FXA_PIPELINE}.timer" ;; esac
}

# _pipeline_pass_times   The pass timer's runs in the next 24 h, a sorted JSON array of epochs: [] when
# the timer is off, null with no systemctl or calendar tool (macOS) or when its specs do not parse.
# Each spec ("Mon..Fri *-*-* 07..19:04/5:00 America/New_York") is one quoted argument, never a glob.
_pipeline_pass_times() {
  local tool="${FXA_SYSTEMD_ANALYZE:-systemd-analyze}" u line spec now ep
  { command -v systemctl && command -v "$tool"; } >/dev/null 2>&1 || { echo null; return 0; }
  u="$(_pipeline_timer_unit)"
  systemctl is-active -q "$u" 2>/dev/null || { echo '[]'; return 0; }
  local -a specs=()
  # Each line is "{ OnCalendar=<spec> ; next_elapse=... }".
  while IFS= read -r line; do
    case "$line" in *'OnCalendar='*' ;'*) spec="${line#*OnCalendar=}"; specs+=("${spec%% ;*}") ;; esac
  done < <(systemctl show -p TimersCalendar --value "$u" 2>/dev/null || true)
  [ ${#specs[@]} -gt 0 ] || { echo null; return 0; }
  now="$(date +%s)"
  # One date call for every elapse line ("    Next elapse: Sat 2026-10-24 11:04:00 UTC", "Iteration #2: ...").
  ep="$(for spec in "${specs[@]}"; do TZ=UTC "$tool" calendar --iterations=300 -- "$spec" 2>/dev/null || true; done \
    | sed -nE 's/^ *(Next elapse|Iteration #[0-9]+): *//p' | date -u -f - +%s 2>/dev/null | grep -E '^[0-9]+$' | sort -un || true)"
  [ -n "$ep" ] || { echo null; return 0; }
  jq -sc --argjson now "$now" 'map(select(. > $now and . <= $now + 86400))' <<< "$ep"
}

pipeline_health_json() {
  pipeline_require || return 1
  local last_pass last_launch lock free stamped newest_skip
  # Not skip fingerprints alone: a pass that launches skips nothing, so the
  # healthiest passes looked like no pass at all.
  stamped="$(cat "${PIPE_STATE_DIR}/last-pass" 2>/dev/null)"
  newest_skip="$(cut -f2 "$PIPE_STATE_DIR"/*.skipped 2>/dev/null | sort -rn | head -1)"
  last_launch="$(ls -t "$PIPE_STATE_DIR"/*.launch.log 2>/dev/null | head -1)"
  last_launch="$( [ -n "$last_launch" ] && _mtime "$last_launch" 2>/dev/null || echo '' )"
  last_pass="$(printf '%s\n%s\n%s\n' "$stamped" "$newest_skip" "$last_launch" \
               | grep -E '^[0-9]+$' | sort -rn | head -1)"
  [ -d "$PIPE_LOCK_DIR" ] && lock=true || lock=false
  local lock_age=""; [ -d "$PIPE_LOCK_DIR" ] && lock_age="$(( $(date +%s) - $(_mtime "$PIPE_LOCK_DIR" 2>/dev/null || date +%s) ))"
  local launches max="${PIPE_MAX_LAUNCHES_PER_DAY:-20}" frees="" np timer=""; launches="$(pipeline_launches_24h)"
  local n; n="$(grep -c . <<< "$launches" || true)"
  # The budget frees when the oldest launch that keeps it full leaves the window: row n-max+1.
  [ "$n" -ge "$max" ] && frees="$(( $(sed -n "$((n - max + 1))p" <<< "$launches") + 86400 ))"
  np="$(_pipeline_next_pass)"; case "$np" in off) timer=off; np="" ;; '') ;; *) timer=on ;; esac
  free="$(pipeline_free_gb)"
  # The local marker only: the GCS one costs a round trip per snapshot, and a
  # pause from this machine writes both.
  local paused; paused="$(head -c 300 "$(pipeline_pause_marker)" 2>/dev/null | tr -d '\n' || true)"
  [ -f "$(pipeline_pause_marker)" ] && paused="${paused:-paused}"
  jq -n --arg lp "${last_pass:-}" --arg ll "${last_launch:-}" --arg paused "$paused" \
        --argjson lock "$lock" --arg free "${free:-}" \
        --argjson floor "${PIPE_MIN_FREE_GB:-0}" --argjson now "$(date +%s)" \
        --argjson n "$n" --argjson max "$max" --arg frees "$frees" --arg lage "$lock_age" \
        --argjson lstale "${PIPE_LOCK_STALE_SECONDS:-1800}" --arg np "$np" --arg timer "$timer" \
        --argjson pt "$(_pipeline_pass_times)" \
    '{ last_pass_epoch:   (if $lp == "" then null else ($lp | tonumber) end),
       last_launch_epoch: (if $ll == "" then null else ($ll | tonumber) end),
       seconds_since_pass: (if $lp == "" then null else ($now - ($lp | tonumber)) end),
       lock_held: $lock,
       free_gb:   (if $free == "" then null else ($free | tonumber) end),
       min_free_gb: $floor,
       paused: (if $paused == "" then null else $paused end),
       launches_24h: $n, max_launches_per_day: $max,
       launch_frees_at: (if $frees == "" then null else ($frees | tonumber) end),
       lock_age_seconds: (if $lage == "" then null else ($lage | tonumber) end),
       lock_stale_seconds: $lstale,
       next_pass_epoch: (if $np == "" then null else ($np | tonumber) end),
       pass_times: $pt,
       pass_timer: (if $timer == "" then null else $timer end) }'
}

# _profile_app_repos   The repos the GitHub App is installed on, one per line, cached
# for 10 minutes. Fails when the list cannot be read.
# The profile's work repos that the agent's GitHub App is installed on, one a line, cached 10 minutes.
# Asked of each repo with the App's JWT (200 or 404): the installation token's own list names only
# its installation's repos, so a repo under another installation read as "not installed".
_profile_app_repos() {
  # Keyed on the repo list: a repo added to the team is checked at once, not after the cache ages out.
  local slugs f t s code
  slugs="$( { trees_allowed 2>/dev/null || echo "${PIPE_REPO_SLUG:-}"; } | cut -d' ' -f1 | LC_ALL=C sort)"
  f="${PIPE_STATE_DIR}/app-repos.$(printf '%s' "$slugs" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12).txt"
  if [ ! -s "$f" ] || [ $(( $(date +%s) - $(_mtime "$f") )) -gt 600 ]; then
    t="$(mktemp "${f}.XXXXXX")" || return 1
    echo "# checked" > "$t"
    for s in $slugs; do
      code="$(_gh_jwt_conf 2>/dev/null | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K - \
        -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${s}/installation" 2>/dev/null)" || code=000
      case "$code" in 200) echo "$s" >> "$t" ;; 404) ;; *) rm -f "$t"; return 1 ;; esac
    done
    mv "$t" "$f"
  fi
  grep -v '^#' "$f" || true
}

# pipeline_profile_json   The loaded profile's repos and the effective write access of
# each, for the bot's team card: the profile must allow it and the App must be on the repo.
# pipeline_mcp <asked>   The MCP connectors for a new session: the profile's PIPE_MCP when it sets
# one (empty: none), else the asked list (the bot's MCP_CONNECTORS). The gateway must serve each.
pipeline_mcp() { if [ -n "${PIPE_MCP+x}" ]; then printf '%s' "$PIPE_MCP"; else printf '%s' "$1"; fi; }

pipeline_profile_json() {
  local app ok=1; app="$(_profile_app_repos)" || ok=0
  # The work rows a team stack may pick: every work row, or the one repo of a profile without rows.
  local works; works="$(trees_allowed 2>/dev/null | cut -d' ' -f1 | tr '\n' ' ')"; works="${works:-${PIPE_REPO_SLUG:-}}"
  # Any private repo, of any role: the bot keeps its code out of public channels and the watch page.
  local r priv=false
  for r in ${PIPE_REPO_SLUG:-} ${PIPE_DEP_REPOS:-} $(for r in ${PIPE_REPOS[@]+"${PIPE_REPOS[@]}"}; do echo "${r%% *}"; done); do
    github_repo_private "$r" && { priv=true; break; }
  done
  jq -nc --arg p "${PIPE_PROFILE:-}" --argjson private "$priv" --arg label "${PIPE_LABEL:-}" --arg works "$works" --arg deps "${PIPE_DEP_REPOS:-}" \
    --arg defaults "${PIPE_STACK_DEFAULT:-}" --arg ro "${PIPE_PR_OPEN:-1}" --arg app "$app" --argjson ok "$ok" \
    --arg mcp "${PIPE_MCP:-}" --argjson android "$([ "${PIPE_ANDROID:-}" = 1 ] && echo true || echo false)" --argjson mcp_set "$([ -n "${PIPE_MCP+x}" ] && echo true || echo false)" '
    ($ro == "0") as $read_only | ($app | split("\n") | map(ascii_downcase)) as $installed |
    { profile: $p, label: (if $label == "" then $p else $label end), read_only: $read_only, private: $private, android: $android,
      mcp: (if $mcp_set then ($mcp | split(",") | map(select(. != ""))) else null end),
      defaults: ($defaults | split(" ") | map(select(. != ""))),
      repos: (($works | split(" ") | map(select(. != "")) | map(. as $s | { slug: $s, role: "work",
                 why: (if $read_only then "the profile is read-only"
                       elif ($ok == 0) then "the GitHub App check failed"
                       elif ($installed | index($s | ascii_downcase)) == null then "the agent'"'"'s GitHub App is not installed on this repo"
                       else null end) } | . + { write: (.why == null) }))
              + ($deps | split(" ") | map(select(. != "")) | map({ slug: ., role: "dep", write: false, why: "it runs beside the work repo" }))) }'
}

# pipeline_host_clone <owner/repo>   This host's clone of a repo: ~/Desktop/working2/<repo>, unless a
# clone of another repo has that name (acme/fxa beside mozilla/fxa); then .repos/<owner>/<repo> there.
pipeline_host_clone() {
  local d="${HOME}/Desktop/working2/${1##*/}" u
  u="$(git -C "$d" config --get remote.origin.url 2>/dev/null || true)"
  u="${u%.git}"; u="${u#https://github.com/}"; u="${u#git@github.com:}"
  if [ -z "$u" ] || [ "$(tr 'A-Z' 'a-z' <<< "$u")" = "$(tr 'A-Z' 'a-z' <<< "$1")" ]; then printf '%s' "$d"
  else printf '%s/Desktop/working2/.repos/%s' "$HOME" "$1"; fi
}

# pipeline_ensure_clone   Clone the profile's work repo on this host the first time a
# session needs it (the manager has only FxA's clone from setup).
pipeline_ensure_clone() {
  [ -e "${PIPE_REPO}/.git" ] && return 0
  [[ "${PIPE_REPO_SLUG:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  echo "Cloning ${PIPE_REPO_SLUG} into ${PIPE_REPO}..." >&2
  mkdir -p "$(dirname "$PIPE_REPO")" && git clone --quiet "https://github.com/${PIPE_REPO_SLUG}.git" "$PIPE_REPO"
}
