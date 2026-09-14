#!/bin/bash
# snapshot.sh — the whole pipeline state as one JSON document.
#
# This is the dashboard's data source, and it is useful on its own for a quick
# `ctl snapshot | jq` at the terminal. Every field comes from the same functions
# the pass uses, so the page can never disagree with the pipeline.
#
# Public API:
#   snapshot_json    Print the full state as JSON

[ -n "${_FXA_SNAPSHOT_LOADED:-}" ] && return 0
_FXA_SNAPSHOT_LOADED=1

# Pool slots with the branch each holds and the agent running on it, as JSON.
_snapshot_pool() {
  local root parent slot path branch agent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    path="${parent}/${slot}"
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    agent="$(_worktree_agent_for_workspace "$path")"
    printf '%s\t%s\t%s\n' "$slot" "$branch" "$agent"
  done <<< "$(worktree_pool_slot_names)" \
  | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
      | map({ slot: .[0],
              branch: (if (.[1] // "") == "" then null else .[1] end),
              key:    (if (.[1] // "") == "" then null else (.[1] | ascii_upcase) end),
              agent:  (if (.[2] // "") == "" then null else .[2] end),
              busy:   ((.[2] // "") != "") })'
}

# Recorded admission skips. The reason is free text and holds spaces, so split
# on the first three fields only.
_snapshot_skipped() {
  pipeline_skipped 2>/dev/null \
  | jq -R -s 'split("\n") | map(select(length > 0)
      | capture("^(?<key>[^ ]+) (?<passes>[0-9]+) (?<last>[^ ]+) (?<reason>.*)$"))
      | map(.passes |= tonumber)'
}

# Per-ticket detail for the runs that are actually in flight. Costs one SSH per
# live VM, so it is bounded by the pool size, not by the queue.
_snapshot_inflight() {
  local keys="${1:-}"
  [ -n "$keys" ] || { echo '[]'; return 0; }
  local key branch stage vm alive log started now wt files commits stat_line
  local cfiles cstat handoff attempts agent
  now="$(date +%s)"
  for key in $keys; do
    branch="$(worktree_branch_for "$key")"
    if vm_is_running "$branch" 2>/dev/null; then
      vm=true
      if agent_alive "$branch" 2>/dev/null; then alive=true; else alive=false; fi
    else
      vm=false; alive=false
    fi
    # progress prints "KEY stage [detail]"; keep the stage and the detail apart.
    stage="$(pipeline_progress "$key" 2>/dev/null | cut -d' ' -f2- || echo 'unknown')"
    # The launch log is created at launch, so its birth time is the run's start.
    log="$(pipeline_launch_log "$key")"
    started="$( [ -f "$log" ] && stat -f %B "$log" 2>/dev/null || echo '' )"
    # Forward motion, the honest way. The launcher's own elapsed counter freezes
    # (macOS block-buffers its stdout with no TTY), so it is NOT a freshness
    # signal. Changed files and commits are.
    #
    # Working-tree numbers go to ZERO the moment the host squashes and commits,
    # which made a real 1-commit change read "0 files touched". So carry both:
    # the dirty tree while the agent is still writing, and the committed range
    # once it has committed.
    wt="$(_telemetry_worktree_for_key "$key" 2>/dev/null || echo '')"
    if [ -n "$wt" ]; then
      # gce: the tree and the transcript are on the runner until pulled.
      _worktree_pull_if_remote "$wt"
      # `grep -c` prints 0 AND exits non-zero on no match, so `|| echo 0` would
      # emit a SECOND 0. That extra newline split into a phantom inflight row
      # with key "0". Use `|| true` and take one line -- the same trap the
      # pgrep -c call in agent_alive already documents.
      files="$(git -C "$wt" status --porcelain 2>/dev/null \
               | grep -vcE '^\?\? (\.fxa-|packages/fxa-auth-server/config/newKey\.json)' \
               || true)"
      files="$(printf '%s' "$files" | head -1 | tr -dc '0-9')"
      commits="$(git -C "$wt" log --oneline "origin/${FXA_WORKTREE_BASE}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
      stat_line="$(git -C "$wt" diff --shortstat 2>/dev/null | tr -d '\n')"
      if [ "${commits:-0}" -gt 0 ]; then
        cfiles="$(git -C "$wt" diff --name-only "origin/${FXA_WORKTREE_BASE}...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
        cstat="$(git -C "$wt" diff --shortstat "origin/${FXA_WORKTREE_BASE}...HEAD" 2>/dev/null | tr -d '\n')"
      else
        cfiles=0; cstat=""
      fi
      # The handoff file is the trigger for the push. Without it, "agent still
      # working" and "agent finished, host has not pushed" look identical.
      [ -f "${wt}/.fxa-auto-done.json" ] && handoff=true || handoff=false
      agent="$(_snapshot_agent_json "${wt}/.fxa-auto-claude.jsonl" "$now")"
    else
      files=0; commits=0; stat_line=""; cfiles=0; cstat=""; handoff=false; agent=null
    fi
    attempts="$(cat "${PIPE_STATE_DIR}/${key}.attempts" 2>/dev/null | head -1 | tr -dc '0-9')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$branch" "$vm" "$alive" \
      "$( [ -n "$started" ] && echo $(( now - started )) || echo '' )" "$stage" \
      "${files:-0}" "${commits:-0}" "$stat_line" \
      "${cfiles:-0}" "$cstat" "$handoff" "${attempts:-0}" "${agent:-null}"
  done \
  | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
      | map({ key: .[0], branch: .[1],
              vm_running: (.[2] == "true"), agent_alive: (.[3] == "true"),
              elapsed_seconds: (if (.[4] // "") == "" then null else (.[4] | tonumber) end),
              stage: ((.[5] // "") | split(" ")[0]),
              detail: ((.[5] // "") | split(" ")[1:] | join(" ")),
              files_changed: ((.[6] // "0") | tonumber? // 0),
              commits: ((.[7] // "0") | tonumber? // 0),
              diffstat: (.[8] // ""),
              committed_files: ((.[9] // "0") | tonumber? // 0),
              committed_diffstat: (.[10] // ""),
              handoff: (.[11] == "true"),
              attempts: ((.[12] // "0") | tonumber? // 0),
              agent: ((.[13] // "null") | fromjson? // null) })'
}

# _snapshot_agent_json <jsonl> <now>
#   What the agent is doing, from its own transcript. `claude -p` streams one
#   JSON event per line; `tee` also catches stray stderr lines, so parse with
#   fromjson? and drop what is not JSON. idle_seconds is the strongest freshness
#   signal there is: the file's mtime moves on every event.
#   cost_usd and is_error exist only once the run ended (the result event).
_snapshot_agent_json() {
  local f="$1" now="$2" mtime
  [ -s "$f" ] || { echo null; return 0; }
  mtime="$(stat -f %m "$f" 2>/dev/null || echo "$now")"
  jq -R -s -c --argjson idle "$(( now - mtime ))" '
    split("\n") | map(fromjson?) |
    (map(select(.type=="assistant"))) as $a |
    ($a | map(.message.content[]? | select(.type=="text") | .text) | last // "") as $text |
    ($a | map(.message.content[]? | select(.type=="tool_use")
              | .name + " " + ((.input.command // .input.file_path // .input.pattern // .input.description // "") | tostring)) | last // "") as $tool |
    (map(select(.type=="result")) | last) as $r |
    { turns: ($a | length), idle_seconds: $idle,
      last_text: ($text | gsub("\\s+"; " ") | .[0:200]),
      last_tool: ($tool | .[0:160]),
      cost_usd: ($r.total_cost_usd // null),
      is_error: (if $r then $r.is_error else null end),
      num_turns: ($r.num_turns // null) }' "$f" 2>/dev/null || echo null
}

_snapshot_telemetry() {
  [ -f "$PIPE_RUNS_FILE" ] || { echo 'null'; return 0; }
  jq -s '{ runs: length,
           tickets: ([.[].issue] | unique | length),
           cost_usd: ([.[].cost_usd // 0] | add | .*100 | round / 100),
           median_minutes: (([.[].wall_seconds // 0] | sort | .[length/2|floor]) / 60 | round),
           last_recorded: ([.[].recorded_at] | max) }' "$PIPE_RUNS_FILE" 2>/dev/null || echo 'null'
}

# snapshot_json
#   One document describing every stage. Any section that fails to fetch is
#   `null` rather than empty, so the page can say "unknown" instead of drawing
#   a confident zero.
snapshot_json() {
  pipeline_require || return 1
  local started; started="$(date +%s)"

  # One call per state, each returning key AND summary. Keys are derived from
  # the same payload, so adding titles cost no extra request.
  local queue_items inflight_items done_items blocked_items
  queue_items="$(jira_queue_items)"
  inflight_items="$(jira_items_in_state inflight)"
  done_items="$(jira_items_in_state done)"
  blocked_items="$(jira_items_in_state blocked)"

  local queue inflight_keys done_keys
  queue="$(printf '%s' "$queue_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"
  inflight_keys="$(printf '%s' "$inflight_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"
  done_keys="$(printf '%s' "$done_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"

  local pool skipped inflight review telem freeslots
  pool="$(_snapshot_pool)"
  skipped="$(_snapshot_skipped)"
  inflight="$(_snapshot_inflight "$inflight_keys")"
  review="$(gh_pr_states_json "$done_keys")"
  local inflight_prs; inflight_prs="$(gh_pr_states_json "$inflight_keys")"
  telem="$(_snapshot_telemetry)"
  # If the inflight read failed we do not know which slots a ticket still owns,
  # and worktree_free_slots with an empty owner list calls EVERY idle slot
  # claimable. That is the same confident zero the review section guards
  # against, so report unknown instead.
  if [ "$inflight_items" = "null" ]; then
    freeslots="null"
  else
    freeslots="$(worktree_free_slots "$(printf '%s\n' "$inflight_keys" | tr '[:lower:]' '[:upper:]')" \
                 | jq -R -s 'split("\n") | map(select(length > 0))')"
  fi

  jq -n \
    --arg at "$(date -u +%FT%TZ)" \
    --arg pipeline "$PIPE_NAME" \
    --arg repo "$PIPE_REPO_SLUG" \
    --argjson secs "$(( $(date +%s) - started ))" \
    --argjson items "$queue_items" \
    --argjson inflight_items "$inflight_items" \
    --argjson blocked "$blocked_items" \
    --argjson health "$(pipeline_health_json)" \
    --argjson skipped "$skipped" \
    --argjson pool "$pool" \
    --argjson freeslots "$freeslots" \
    --argjson inflight "$inflight" \
    --argjson inflight_prs "$inflight_prs" \
    --argjson review "$review" \
    --argjson telemetry "$telem" \
    '($skipped | map(.key)) as $skipkeys
     | ($items // []) as $q
     | { generated_at: $at, pipeline: $pipeline, repo: $repo, took_seconds: $secs,
         queue: { total: (if $items == null then null else ($q | length) end),
                  fetch_failed: ($items == null),
                  ready:   [$q[] | select(.key as $k | ($skipkeys | index($k)) == null)],
                  skipped: [($q | map(.key)) as $qk
                            | $skipped[] as $s
                            | $s + {summary: (($q[] | select(.key == $s.key) | .summary) // null),
                                    in_queue: (($qk | index($s.key)) != null)}] },
         blocked: $blocked,
         health: $health,
         inflight_fetch_failed: ($inflight_items == null),
         pool: $pool, free_slots: $freeslots,
         inflight: [$inflight[] as $i
                    | $i
                      + {summary: ((($inflight_items // [])[] | select(.key == $i.key) | .summary) // null)}
                      + (((($inflight_prs // [])[] | select(.key == $i.key))
                          | {pr, pr_state: .state, ok, fail, running, review_decision: .review})
                         // {pr: null, pr_state: null, ok: 0, fail: 0, running: 0, review_decision: null})],
         review: $review,
         telemetry: $telemetry }'
}
