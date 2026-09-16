#!/bin/bash
# pipeline.sh — pass state and settings for a ticket-to-PR pipeline.
#
# A pipeline is one config file under pipelines/. It names the repo, the label
# family, the queue JQL, and where durable pass state lives. Everything that
# used to be a constant at the top of the skill's fixme.sh is here.
#
# Public API:
#   pipeline_load [NAME]        Source pipelines/<NAME>.conf (default: fxa-ai-fixme)
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

# pipeline_load [NAME]
#   Read the config, then let the environment win over every value in it. The
#   env names are the ones the skill has always used, so an existing override
#   in a cron entry or a shell keeps working.
pipeline_load() {
  local name="${1:-$FXA_PIPELINE}"
  local conf="${SANDBOX_ROOT}/pipelines/${name}.conf"
  if [ ! -f "$conf" ]; then
    echo "ERROR: no pipeline config at ${conf}" >&2
    echo "Available: $(ls "${SANDBOX_ROOT}/pipelines" 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$conf"
  PIPE_NAME="$name"

  PIPE_REPO="${FXA_REPO:-$PIPE_REPO}"
  PIPE_STATE_DIR="${FXA_FIXME_STATE:-$PIPE_STATE_DIR}"
  PIPE_RUNS_FILE="${FXA_FIXME_RUNS:-$PIPE_RUNS_FILE}"
  PIPE_COSTS_FILE="${FXA_FIXME_COSTS:-$PIPE_COSTS_FILE}"
  PIPE_MIN_FREE_GB="${FXA_MIN_FREE_GB:-$PIPE_MIN_FREE_GB}"
  # worktree.sh and the rest of ctl read FXA_REPO, so keep the two in step.
  export FXA_REPO="$PIPE_REPO"

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
  df -g / 2>/dev/null | awk 'NR==2 {print $4}'
}

# ── Pass lock ──────────────────────────────────────────────────
# mkdir is atomic, so it works as a lock without flock, which macOS does not
# ship. A lock older than 2 hours is stale: no legitimate pass runs that long
# once launches are backgrounded.
# Kill switch. A PAUSED marker makes every `lock` refuse, with no stale break,
# so passes stay off until someone runs `resume`. The marker is a local file, or
# an object at PIPE_PAUSE_URI (gs://bucket/path) so it works from any machine
# once the manager runs in GCP. Reading the object needs gcloud; if that call
# fails we treat it as not paused and say so, because a broken kill switch that
# silently pauses looks exactly like a healthy idle pipeline.
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
    local age; age=$(( $(date +%s) - $(stat -f %m "$PIPE_LOCK_DIR" 2>/dev/null || echo 0) ))
    # The cron fires every 20 min and a pass takes under 10. A lock older than
    # 30 min belongs to a session that died mid-pass, and holding it turns every
    # later pass into a silent no-op. The pid inside is the `lock` call's own,
    # already gone, so age is the only liveness signal.
    if [ "$age" -lt "${PIPE_LOCK_STALE_SECONDS:-1800}" ]; then
      echo "locked: another pass started ${age}s ago (pid $(cat "${PIPE_LOCK_DIR}/pid" 2>/dev/null || echo '?'))"
      return 1
    fi
    echo "clearing stale lock, ${age}s old" >&2
    rm -rf "$PIPE_LOCK_DIR"
  fi
  mkdir "$PIPE_LOCK_DIR" 2>/dev/null || { echo "locked: lost the race"; return 1; }
  echo $$ >"${PIPE_LOCK_DIR}/pid"
  # Stamp the pass. Taking the lock is the one thing EVERY pass does, so this is
  # the only liveness signal that does not depend on what the pass found to do.
  date +%s >"${PIPE_STATE_DIR}/last-pass"
  echo "acquired"
}

pipeline_unlock() {
  pipeline_require || return 1
  rm -rf "$PIPE_LOCK_DIR"
  echo "released"
}

# ── Admission skips ────────────────────────────────────────────
# Portable md5. Linux ships md5sum, macOS ships md5; this host has both.
_pipeline_hash() {
  if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'
  else md5 -q; fi
}

# Fingerprint the ticket for skip purposes: description plus every comment that
# this pipeline did NOT write.
#
# Hashing the ticket view directly was wrong. The skill posts a 🤖 comment on a
# skip, that comment becomes part of the ticket, and the next pass therefore
# sees a changed ticket and comments again -- the pipeline invalidating its own
# fingerprint, forever. On 2026-08-18 FXA-4865 printed `comment` on a second
# pass for exactly this reason, which is the loop the guard was built to stop.
#
# So drop 🤖-led comments. A reporter answering the blocking question still
# invalidates the fingerprint, which is the behaviour that matters.
_pipeline_skip_fingerprint() {
  local key="$1"
  {
    acli jira workitem view "$key" 2>/dev/null
    acli jira workitem comment list --key "$key" --json 2>/dev/null \
      | jq -r '.comments[]? | select((.body // "") | startswith("🤖") | not) | .body'
  } | _pipeline_hash
}

# pipeline_skip <KEY> [reason...]
#   Record that admission rejected this ticket, and say whether the pass should
#   write a Jira comment about it.
#
#   Prints "comment" the first time, and on any later pass where the ticket has
#   CHANGED. Prints "silent <n>" when the ticket is byte-identical to the last
#   skip, where <n> is how many passes have now skipped it.
#
#   Why this exists: the queue is ordered oldest-first, and the oldest keys are
#   the ones most likely to be unlaunchable, so every pass re-grounds them and
#   re-derives the same skip. Without a fingerprint, "comment on a skip" becomes
#   one identical comment per pass, forever, on a ticket that may never become
#   eligible. FXA-4865 cannot be fixed in that repo at all, so no answer on the
#   ticket would ever stop the loop.
#
#   Do not weaken it to a comment count: an edited comment carries the answer
#   just as often as a new one does. On FXA-14325 an answer in a comment turned
#   a skip into a shipped PR.
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
#   Read-only twin of pipeline_skip: exit 0 when the ticket has no skip record
#   or its text changed since the record was written, exit 1 when it is the
#   same ticket the pass already judged. Prints `new` or `changed`. Never
#   writes, so a quiet-pass probe cannot bump the pass counter or move the
#   fingerprint the way `skip` does.
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

# Drop skip records for tickets that left the queue (resolved, or the label was
# removed). The fingerprint exists to silence repeat comments on a ticket the
# pass keeps seeing; once the queue no longer returns the key, it is dead weight
# and the dashboard lists it as stale. Takes the queue keys on stdin so a failed
# Jira read (empty list) prunes nothing: wiping every record on an outage would
# make the next pass re-comment on every skipped ticket at once.
pipeline_skip_prune() {
  pipeline_require || return 1
  local -a queue=(); local k f n=0
  while IFS= read -r k; do [ -n "$k" ] && queue+=("$k"); done
  [ "${#queue[@]}" -gt 0 ] || return 0
  for f in "$PIPE_STATE_DIR"/*.skipped; do
    [ -f "$f" ] || continue
    k="$(basename "$f" .skipped)"
    printf '%s\n' "${queue[@]}" | grep -qx "$k" && continue
    rm -f "$f"; n=$((n + 1)); echo "$k skip record pruned (left the queue)"
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

pipeline_launch_log() { printf '%s/%s.launch.log\n' "$PIPE_STATE_DIR" "$1"; }

# _pipeline_stalled_reason <KEY> <ELAPSED-SECONDS>
#   Print a reason and return 0 when a run is alive but producing nothing.
#   Return 1 when the run looks healthy.
#
#   This exists because "alive but doing nothing" was invisible. On 2026-08-31
#   FXA-10214's prompt was pasted into the TUI and the Enter never took. The
#   agent held the text in its input box for 15 minutes while `progress` said
#   `watching`, `alive` said `alive`, and `list` said `running`. Every health
#   signal agreed it was fine. The launcher's own elapsed counter is frozen
#   (macOS block-buffers its stdout with no TTY), so it could not help either.
#
#   Two checks, strongest first.
_pipeline_stalled_reason() {
  local key="$1" elapsed="${2:-0}" name hc wt files commits

  name="$(worktree_branch_for "$key" 2>/dev/null)" || return 1
  wt="$(_telemetry_worktree_for_key "$key" 2>/dev/null || echo '')"
  # 1. DEFINITIVE. Both runtimes run to completion and exit: `claude -p` and
  #    `codex exec`. A VM that is up with no agent process and no handoff file
  #    is a run that ended without one. That is an error, not a 20-minute
  #    heuristic. Claude names the commonest cause: a /goal over 4000 chars
  #    ends the run at once with num_turns 0 and no error flag.
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

  # 2. HEURISTIC. Past the threshold with nothing written and nothing committed.
  #    Generous by design: a big ticket can be read for a while before the first
  #    edit, and a false stall costs a slot and a relaunch.
  [ "$elapsed" -ge $(( ${PIPE_STALL_MINUTES:-20} * 60 )) ] || return 1
  [ -n "$wt" ] || return 1
  _worktree_pull_if_remote "$wt"
  # `grep -c` prints 0 AND exits non-zero on no match, so `|| true` and one line.
  files="$(git -C "$wt" status --porcelain 2>/dev/null \
           | grep -vcE '^\?\? \.fxa-' || true)"
  files="$(printf '%s' "$files" | head -1 | tr -dc '0-9')"
  commits="$(git -C "$wt" log --oneline "origin/${FXA_WORKTREE_BASE}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${files:-0}" -eq 0 ] && [ "${commits:-0}" -eq 0 ]; then
    printf 'no-motion'; return 0
  fi
  return 1
}

# The authoritative record of what the launcher did. Read this before drawing
# any conclusion from process state. On 2026-08-11 a run was called "stalled"
# from process sampling while this log already held "PR opened" at line 87.
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
  # A feedback round's first push is rejected as non-fast-forward and then
  # retried with --force-with-lease; that "! [rejected]" line is routine when a
  # "(forced update)" follows it, and reading it as an error hid every round's
  # real state until the PR line landed.
  if grep -q '(forced update)' "$log"; then
    err="$(grep -m1 -E '^ERROR|fatal:' "$log" || true)"
  else
    err="$(grep -m1 -E '^ERROR|fatal:|rejected' "$log" || true)"
  fi
  if [ -n "$err" ]; then echo "$key error ${err}"; return 0; fi
  if grep -q "Pushing " "$log"; then echo "$key pushed"; return 0; fi
  if grep -q "Squashing " "$log"; then echo "$key squashing"; return 0; fi
  if grep -q "Watching for" "$log"; then
    # Stall detection rides on `progress` deliberately. The reconcile table
    # already reads this first for every inflight key, so the rule cannot be
    # skipped -- the same binding that hangs the VM reap off the label write.
    local started elapsed reason
    started="$(stat -f %B "$log" 2>/dev/null || echo 0)"
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
#   Is the pipeline itself alive, as opposed to merely idle? A dashboard that
#   cannot tell those apart shows all-green while nothing has run for days.
#
#   There is no direct "is the cron armed" signal, because the schedule is
#   session-scoped. So use the strongest available proxy: every pass rewrites a
#   fingerprint for each ticket it skips, and the queue always holds skippable
#   tickets, so the newest fingerprint timestamp is when a pass last ran.
pipeline_health_json() {
  pipeline_require || return 1
  local last_pass last_launch lock free stamped newest_skip
  # Take the most recent of every trace a pass leaves. Using skip fingerprints
  # alone was wrong in the worst direction: a pass that launches a ticket skips
  # nothing and writes no fingerprint, so the healthiest passes looked like no
  # pass at all. On 2026-08-31 a pass launched FXA-5807 and the page still read
  # "no pass in 5.2 days".
  stamped="$(cat "${PIPE_STATE_DIR}/last-pass" 2>/dev/null)"
  newest_skip="$(cut -f2 "$PIPE_STATE_DIR"/*.skipped 2>/dev/null | sort -rn | head -1)"
  last_launch="$(ls -t "$PIPE_STATE_DIR"/*.launch.log 2>/dev/null | head -1)"
  last_launch="$( [ -n "$last_launch" ] && stat -f %m "$last_launch" 2>/dev/null || echo '' )"
  last_pass="$(printf '%s\n%s\n%s\n' "$stamped" "$newest_skip" "$last_launch" \
               | grep -E '^[0-9]+$' | sort -rn | head -1)"
  [ -d "$PIPE_LOCK_DIR" ] && lock=true || lock=false
  free="$(pipeline_free_gb)"
  jq -n --arg lp "${last_pass:-}" --arg ll "${last_launch:-}" \
        --argjson lock "$lock" --arg free "${free:-}" \
        --argjson floor "${PIPE_MIN_FREE_GB:-0}" --argjson now "$(date +%s)" \
    '{ last_pass_epoch:   (if $lp == "" then null else ($lp | tonumber) end),
       last_launch_epoch: (if $ll == "" then null else ($ll | tonumber) end),
       seconds_since_pass: (if $lp == "" then null else ($now - ($lp | tonumber)) end),
       lock_held: $lock,
       free_gb:   (if $free == "" then null else ($free | tonumber) end),
       min_free_gb: $floor }'
}
