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

: "${FXA_PIPELINE:=fxa-ai-fixme}"

# Env overrides win over the config, so old cron and shell overrides still work.
pipeline_load() {
  local name="${1:-$FXA_PIPELINE}" conf
  # A child inherits the FXA_REPO its parent's load exported; only a repo set by hand overrides.
  [ -n "${FXA_REPO:-}" ] && [ "$FXA_REPO" = "${_FXA_REPO_LOADED:-}" ] && unset FXA_REPO
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: bad profile name '${name}'" >&2; return 1; }
  conf="${SANDBOX_ROOT}/profiles/${name}/profile.conf"
  [ -f "$conf" ] || conf="${SANDBOX_ROOT}/pipelines/${name}.conf"
  if [ ! -f "$conf" ]; then
    echo "ERROR: no profile '${name}' in ${SANDBOX_ROOT}/profiles or pipelines" >&2
    echo "Available: $(ls "${SANDBOX_ROOT}/profiles" "${SANDBOX_ROOT}/pipelines" 2>/dev/null | grep -v ':$' | sed 's/\.conf$//' | sort -u | tr '\n' ' ')" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$conf"
  PIPE_NAME="$name"
  # Defaults for the keys a profile may leave out. FxA sets them all.
  PIPE_PROFILE="${PIPE_PROFILE:-$name}"
  PIPE_BASE_BRANCH="${PIPE_BASE_BRANCH:-main}"
  PIPE_REPO="${PIPE_REPO:-${HOME}/Desktop/working2/${PIPE_REPO_SLUG##*/}}"
  PIPE_STATE_DIR="${PIPE_STATE_DIR:-${HOME}/.claude/state/${PIPE_PROFILE}}"
  PIPE_RUNS_FILE="${PIPE_RUNS_FILE:-${PIPE_STATE_DIR}/agent-runs.jsonl}"
  PIPE_COSTS_FILE="${PIPE_COSTS_FILE:-${PIPE_STATE_DIR}/agent-costs.json}"
  PIPE_MIN_FREE_GB="${PIPE_MIN_FREE_GB:-5}"
  PIPE_STALL_MINUTES="${PIPE_STALL_MINUTES:-20}"

  PIPE_REPO="${FXA_REPO:-$PIPE_REPO}"
  PIPE_STATE_DIR="${FXA_FIXME_STATE:-$PIPE_STATE_DIR}"
  PIPE_RUNS_FILE="${FXA_FIXME_RUNS:-$PIPE_RUNS_FILE}"
  PIPE_COSTS_FILE="${FXA_FIXME_COSTS:-$PIPE_COSTS_FILE}"
  PIPE_MIN_FREE_GB="${FXA_MIN_FREE_GB:-$PIPE_MIN_FREE_GB}"
  # worktree.sh and the rest of ctl read FXA_REPO, so keep the two in step.
  export FXA_REPO="$PIPE_REPO" _FXA_REPO_LOADED="$PIPE_REPO"

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
    public|queued) printf '%s\n' "$PIPE_LABEL_PREFIX" ;;
    *)             printf '%s-%s\n' "$PIPE_LABEL_PREFIX" "$1" ;;
  esac
}

pipeline_states() { printf '%s\n' public inflight done blocked merged rejected; }

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
pipeline_queue_jql() {
  local k; k="$(pipeline_focus_key || true)"
  if [ -n "$k" ]; then printf 'parent = %s AND %s' "$k" "$PIPE_QUEUE_JQL"; else printf '%s' "$PIPE_QUEUE_JQL"; fi
}
pipeline_focus() {
  pipeline_require || return 1
  case "${1:-}" in
    off) rm -f "$(pipeline_focus_marker)"; echo "focus off: whole queue" ;;
    "")  local k; k="$(pipeline_focus_key || true)"; echo "${k:-off}" ;;
    FXA-[0-9]*) printf '%s\n' "$1" >"$(pipeline_focus_marker)"; echo "focus $1: queue is that epic's children only" ;;
    *)   echo "ERROR: focus FXA-<epic>|off" >&2; return 1 ;;
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
  pipeline_state_push
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

# Hash the ticket plus every comment not led by 🤖. Our own skip comment would
# otherwise change the hash and cause another comment on every pass.
_pipeline_skip_fingerprint() {
  local key="$1"
  {
    acli jira workitem view "$key" 2>/dev/null
    acli jira workitem comment list --key "$key" --json 2>/dev/null \
      | jq -r '.comments[]? | select((.body // "") | startswith("🤖") | not) | .body'
  } | _pipeline_hash
}

# pipeline_skip <KEY> [reason...]
#   Record an admission skip. Print "comment" the first time or when the ticket
#   changed, else "silent <n>" (passes that skipped it), so a skip gets one
#   comment, not one per pass. Keep the hash: a comment count misses edits.
pipeline_skip() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: skip needs <KEY>" >&2; return 1; }
  shift || true
  local reason="$*"
  local f="${PIPE_STATE_DIR}/${key}.skipped"
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
      printf '%s\t%s\t%s\t%s\n' "$fp" "$(date +%s)" "$n" "$reason" > "$f"
      echo "silent $n"
      return 0
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$fp" "$(date +%s)" 1 "$reason" > "$f"
  echo "comment"
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
  [ -n "$fp" ] || { echo "changed"; return 0; }
  old="$(awk -F'\t' 'NR==1{print $1}' "$f")"
  [ "$old" = "$fp" ] && return 1
  echo "changed"
}

# Launching clears the fingerprint: a later admission skip on this same key must
# not be silenced by a stale match.
pipeline_skip_clear() {
  pipeline_require || return 1
  rm -f "${PIPE_STATE_DIR}/${1}.skipped"
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
  local pr err
  pr="$( { grep -o 'https://github.com/[^ ]*/pull/[0-9]*' "$log" || true; } | tail -1)"
  if [ -n "$pr" ]; then echo "$key pr $pr"; return 0; fi
  # A feedback round's first push is rejected, then forced with a lease, so
  # "rejected" is routine when a "(forced update)" follows it.
  if grep -q '(forced update)' "$log"; then
    err="$(grep -m1 -E '^ERROR|fatal:' "$log" || true)"
  else
    err="$(grep -m1 -E '^ERROR|fatal:|rejected' "$log" || true)"
  fi
  if [ -n "$err" ]; then echo "$key error ${err}"; return 0; fi
  if grep -qE "Pushing |Committing and pushing" "$log"; then echo "$key pushed"; return 0; fi
  if grep -q "Squashing " "$log"; then echo "$key squashing"; return 0; fi
  if grep -q "Watching for" "$log"; then
    # Stall detection lives here because reconcile reads `progress` for every
    # inflight key, so it cannot be skipped.
    local started elapsed reason
    started="$(pipeline_launch_started "$log" 2>/dev/null || echo 0)"
    elapsed=$(( $(date +%s) - started ))
    reason="$(_pipeline_stalled_reason "$key" "$elapsed" || true)"
    if [ -n "$reason" ]; then
      echo "$key stalled ${reason} $(( elapsed / 60 ))m"; return 0
    fi
    local secs; secs="$( { grep -o '\[ *[0-9]*s\]' "$log" || true; } | tail -1 | tr -dc '0-9')"
    echo "$key watching ${secs:-0}s"; return 0
  fi
  # Before the launcher watches for the handoff, say which boot step it is on.
  # On gce this stage lasts minutes, and "starting" alone hid all of them.
  local sub="boot"
  grep -q "ready (" "$log"                   && sub="checkout"
  grep -q "Infrastructure ready" "$log"      && sub="hardening"
  grep -q "^Shipping \|Setting up .* config" "$log" && sub="config"
  grep -q "is running ===" "$log"            && sub="launching"
  echo "$key starting ${sub}"
}

# pipeline_health_json
#   Is the pipeline alive, not merely idle? The cron is session-scoped, so there
#   is no direct signal; use the newest trace a pass leaves.
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
  free="$(pipeline_free_gb)"
  # The local marker only: the GCS one costs a round trip per snapshot, and a
  # pause from this machine writes both.
  local paused; paused="$(head -c 300 "$(pipeline_pause_marker)" 2>/dev/null | tr -d '\n' || true)"
  [ -f "$(pipeline_pause_marker)" ] && paused="${paused:-paused}"
  jq -n --arg lp "${last_pass:-}" --arg ll "${last_launch:-}" --arg paused "$paused" \
        --argjson lock "$lock" --arg free "${free:-}" \
        --argjson floor "${PIPE_MIN_FREE_GB:-0}" --argjson now "$(date +%s)" \
    '{ last_pass_epoch:   (if $lp == "" then null else ($lp | tonumber) end),
       last_launch_epoch: (if $ll == "" then null else ($ll | tonumber) end),
       seconds_since_pass: (if $lp == "" then null else ($now - ($lp | tonumber)) end),
       lock_held: $lock,
       free_gb:   (if $free == "" then null else ($free | tonumber) end),
       min_free_gb: $floor,
       paused: (if $paused == "" then null else $paused end) }'
}
