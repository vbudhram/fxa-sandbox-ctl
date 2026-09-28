#!/bin/bash
# snapshot.sh: the whole pipeline state as one JSON document, for the dashboard.
# Every field comes from the functions the pass uses, so the page cannot disagree
# with the pipeline.

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

# Per-ticket detail for the runs in flight. One SSH per live VM, so the pool size bounds it.
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
    started="$( [ -f "$log" ] && pipeline_launch_started "$log" 2>/dev/null || echo '' )"
    # Progress is changed files and commits: the launcher's elapsed counter freezes
    # (macOS block-buffers its stdout). Carry the committed range too, since the
    # dirty tree drops to zero once the host commits.
    wt="$(_telemetry_worktree_for_key "$key" 2>/dev/null || echo '')"
    if [ -n "$wt" ]; then
      # gce: the tree and the transcript are on the runner until pulled.
      _worktree_pull_if_remote "$wt"
      # grep -c prints 0 and fails on no match: `|| echo 0` would add a second
      # line, which split into a phantom row with key "0".
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
      # Tells "agent still working" from "agent done, host has not pushed yet".
      [ -f "${wt}/.fxa-auto-done.json" ] && handoff=true || handoff=false
      agent="$(_snapshot_agent_json "${wt}/.fxa-auto-claude.jsonl" "$now")"
    else
      files=0; commits=0; stat_line=""; cfiles=0; cstat=""; handoff=false; agent=null
    fi
    attempts="$(cat "${PIPE_STATE_DIR}/${key}.attempts" 2>/dev/null | head -1 | tr -dc '0-9')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$branch" "$vm" "$alive" \
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

# _snapshot_instances   Every VM the backend knows, owned or not: on gce a leaked
# instance keeps billing, and nothing else on the page shows it.
_snapshot_instances() {
  local line name state age
  vm_list 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "${FXA_VM_BACKEND:-tart}" in
      gce)  IFS=$'\t' read -r name state age <<< "$line" ;;
      *)    name="$(printf '%s' "$line" | awk '{print $2}')"; state="$(printf '%s' "$line" | awk '{print $NF}')"; age="" ;;
    esac
    printf '%s\t%s\t%s\n' "$name" "$state" "$age"
  done | jq -R -s --argjson max "${FXA_GCE_MAX_RUN_SECONDS:-5400}" 'split("\n") | map(select(length > 0) | split("\t"))
      | map({ name: .[0], state: (.[1] // "" | ascii_downcase),
              age_seconds: (if (.[2] // "") == "" then null else (.[2] | tonumber) end),
              max_seconds: $max })'
}

# _snapshot_agent_json <jsonl> <now>   What the agent is doing, from its transcript.
# tee also catches stray stderr lines, so fromjson? drops what is not JSON.
# idle_seconds uses the file's mtime, which moves on every event. cost_usd and
# is_error come only with the result event; cost_so_far shows spend mid-run.
_snapshot_agent_json() {
  local f="$1" now="$2" mtime model rates
  [ -s "$f" ] || { echo null; return 0; }
  mtime="$(_mtime "$f" 2>/dev/null || echo "$now")"
  # rsync -a keeps the runner's mtime and its clock can run ahead of ours.
  [ "$mtime" -gt "$now" ] && mtime="$now"
  # The first assistant event ("Goal set") reports model <synthetic>; skip it.
  model="$(jq -R -r 'fromjson? | select(.type=="assistant") | .message.model // empty | select(startswith("<") | not)' "$f" 2>/dev/null | head -1)"
  rates="$(_telemetry_price_for "$model")"
  [ -n "$rates" ] || rates="0 0 0 0"
  jq -R -s -c --argjson idle "$(( now - mtime ))" --arg model "$model" \
     --argjson p "$(printf '%s' "$rates" | awk '{printf "[%s,%s,%s,%s]",$1,$2,$3,$4}')" '
    split("\n") | map(fromjson?) |
    (map(select(.type=="assistant"))) as $a |
    ($a | map(.message.content[]? | select(.type=="text") | .text) | last // "") as $text |
    ($a | map(.message.content[]? | select(.type=="tool_use")
              | .name + " " + ((.input.command // .input.file_path // .input.pattern // .input.description // "") | tostring)) | last // "") as $tool |
    (map(select(.type=="result")) | last) as $r |
    ($a | map(.message.usage // {}) |
      { in: (map(.input_tokens // 0) | add // 0), out: (map(.output_tokens // 0) | add // 0),
        cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
        cache_write: (map(.cache_creation_input_tokens // 0) | add // 0) }) as $u |
    { turns: ($a | length), idle_seconds: $idle, model: $model, tokens: $u,
      cost_so_far: ((($u.in * $p[0] + $u.out * $p[1] + $u.cache_write * $p[2] + $u.cache_read * $p[3]) / 1000000 * 100 | round) / 100),
      last_text: ($text | split("\n") | map(select(test("\\S"))) | first // "" | gsub("\\s+"; " ") | .[0:200]),
      last_tool: ($tool | gsub("\\s+"; " ") | .[0:160]),
      cost_usd: ($r.total_cost_usd // null),
      is_error: (if $r then $r.is_error else null end),
      num_turns: ($r.num_turns // null) } as $out |
    # Codex events carry no model or price; tokens come from turn.completed.
    (map(select(.type=="item.completed") | .item)) as $cx |
    if ($a | length) > 0 or ($cx | length) == 0 then $out else
      (map(select(.type=="turn.completed") | .usage // {})) as $cu |
      $out + { turns: ($cu | length),
        tokens: { in: ($cu | map(.input_tokens // 0) | add // 0), out: ($cu | map(.output_tokens // 0) | add // 0),
                  cache_read: ($cu | map(.cached_input_tokens // 0) | add // 0), cache_write: 0 },
        last_text: ($cx | map(select(.type=="agent_message") | .text) | last // "" | split("\n") | map(select(test("\\S"))) | first // "" | gsub("\\s+"; " ") | .[0:200]),
        last_tool: ($cx | map(select(.type=="command_execution") | .command | sub("^/bin/bash -lc \u0027(?<c>.*)\u0027$"; "\(.c)")) | last // "" | gsub("\\s+"; " ") | .[0:160]) }
    end' "$f" 2>/dev/null || echo null
}

# snapshot_stats_json   Run-log totals for the Stats page: weekly runs and
# spend, three ranges of whole Monday weeks, run kinds, costliest tickets and
# models. Cost is the log's token-based estimate; billing is left out.
snapshot_stats_json() {
  pipeline_require || return 1
  [ -s "$PIPE_RUNS_FILE" ] || { echo 'null'; return 0; }
  jq -s -c '
    def med: sort | if length == 0 then null else .[length / 2 | floor] end;
    def r2: . * 100 | round / 100;
    def wk: (.recorded_at[0:10] | strptime("%Y-%m-%d") | mktime) as $t | $t - ((($t / 86400 | floor) + 3) % 7) * 86400;
    map(. + {wk: wk}) as $all |
    ($all | map(.wk) | unique) as $weeks |
    def summary($r): {
      runs: ($r | length), tickets: ($r | map(.issue) | unique | length),
      spend: ($r | map(.cost_usd // 0) | add // 0 | r2),
      median_min: ($r | map(.wall_seconds // 0) | med | if . == null then null else . / 60 | round end),
      per_ticket: ($r | group_by(.issue) | map(map(.cost_usd // 0) | add) | med | if . == null then null else r2 end),
      max_runs: ($r | group_by(.issue) | map(length) | max),
      from: ($r | map(.wk) | min | strftime("%b %-d")), to: ($r | map(.recorded_at) | max | .[0:10]) };
    {
      weeks: ($all | group_by(.wk) | map({ start: (.[0].wk | strftime("%Y-%m-%d")), label: (.[0].wk | strftime("%b %-d")),
                                           runs: length, spend: (map(.cost_usd // 0) | add | r2) })),
      ranges: {
        all: summary($all),
        w5: summary($all | map(select(.wk >= ($weeks[-5] // $weeks[0])))),
        w2: summary($all | map(select(.wk >= ($weeks[-2] // $weeks[0]))))
      },
      kinds: ($all | group_by(.kind // "") | map({ kind: (.[0].kind // "not recorded"), runs: length,
               avg: (map(.cost_usd // 0) | add / length | r2), median_min: (map(.wall_seconds // 0) | med / 60 | round) }) | sort_by(-.runs)),
      top: ($all | group_by(.issue) | map({ issue: .[0].issue, cost: (map(.cost_usd // 0) | add | r2), runs: length }) | sort_by(-.cost) | .[0:5]),
      models: ($all | map(.model // "") | map(select(. != "" and (startswith("<") | not))) | group_by(.) | map({ model: .[0], runs: length }) | sort_by(-.runs)),
      tickets: ($all | group_by(.issue) | map({ key: .[0].issue, value: {
        runs: length, cost: (map(.cost_usd // 0) | add | r2), turns: (map(.messages // 0) | add),
        models: (map(.model // "") | map(select(. != "" and (startswith("<") | not))) | unique),
        kinds: (group_by(.kind // "not recorded") | map({ key: (.[0].kind // "not recorded"), value: length }) | from_entries),
        median_min: (map(.wall_seconds // 0) | med / 60 | round),
        files: (sort_by(.recorded_at) | last | .files_changed // null),
        last: (map(.recorded_at) | max) } }) | from_entries)
    }' "$PIPE_RUNS_FILE" | _stats_add_rounds
}

# Fix attempts and feedback rounds live in the pipeline's state files.
_stats_add_rounds() {
  local rounds='{}' f k
  for f in "${PIPE_STATE_DIR}"/*.attempts "${PIPE_STATE_DIR}"/*.feedback-rounds; do
    [ -f "$f" ] || continue
    k="$(basename "$f")"
    local n; n="$(tr -dc '0-9' < "$f" | head -c 9)"; n="${n:-0}"
    rounds="$(jq -c --arg k "${k%%.*}" --arg what "${k#*.}" --argjson n "$n" \
      '.[$k][$what] = $n' <<< "$rounds")"
  done
  jq -c --argjson r "$rounds" '.tickets |= with_entries(.value += { attempts: ($r[.key].attempts // 0), feedback_rounds: ($r[.key]["feedback-rounds"] // 0) })'
}

_snapshot_telemetry() {
  [ -f "$PIPE_RUNS_FILE" ] || { echo 'null'; return 0; }
  jq -s '{ runs: length,
           tickets: ([.[].issue] | unique | length),
           cost_usd: ([.[].cost_usd // 0] | add | .*100 | round / 100),
           median_minutes: (([.[].wall_seconds // 0] | sort | .[length/2|floor]) / 60 | round),
           last_recorded: ([.[].recorded_at] | max) }' "$PIPE_RUNS_FILE" 2>/dev/null || echo 'null'
}

# _snapshot_runner_row <meta> <now>   One TSV row per launched runner, none if its VM is gone.
_snapshot_runner_row() {
  local meta="$1" now="$2"
  local NAME="" WORKSPACE="" STARTED="" BASE=""
  # shellcheck source=/dev/null
  source "$meta" 2>/dev/null
  [ -n "$NAME" ] && [ -n "$WORKSPACE" ] || return 0
  # Session runners have their own rows; their run dir is not a checkout to pull into.
  case "$WORKSPACE" in "${SESSION_DIR}"/*) return 0 ;; esac
  vm_is_running "$NAME" 2>/dev/null || return 0
  local key branch slot alive stage line files stat_line handoff agent base_ok head elapsed
  branch="$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  key="$(worktree_key_for "$branch" 2>/dev/null || echo '')"
  # No branch means the slot is gone or unreadable; there is nothing to show.
  [ -n "$branch" ] && [ -n "$key" ] || return 0
  slot="$(basename "$WORKSPACE")"
  # finish is committing on this slot: no git reads either, they take the index lock.
  if [ -f "${LOG_DIR}/${slot}.finishing" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$NAME" "$key" "$branch" "$slot" "true" "squashing" "host is committing" "" "0" "" "true" "null" "null"
    return 0
  fi
  _worktree_pull_if_remote "$WORKSPACE"
  if agent_alive "$NAME" 2>/dev/null; then alive=true; else alive=false; fi
  line="$(pipeline_progress "$key" 2>/dev/null || echo "$key unknown")"
  stage="$(printf '%s' "$line" | cut -d' ' -f2)"
  files="$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | grep -vcE '^\?\? (\.fxa-|ai/?$|\.claude(/|$)|packages/fxa-auth-server/config/newKey\.json)' || true)"
  files="$(printf '%s' "$files" | head -1 | tr -dc '0-9')"
  stat_line="$(git -C "$WORKSPACE" diff --shortstat 2>/dev/null | tr -d '\n')"
  [ -f "${WORKSPACE}/.fxa-auto-done.json" ] && handoff=true || handoff=false
  agent="$(_snapshot_agent_json "${WORKSPACE}/.fxa-auto-claude.jsonl" "$now")"
  head="$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo '')"
  if [ -z "$BASE" ]; then base_ok=null; elif [ "$BASE" = "$head" ]; then base_ok=true; else base_ok=false; fi
  # STARTED is UTC (the Z); parse it as such or the elapsed time is off by the zone.
  elapsed="$( [ -n "$STARTED" ] && echo $(( now - $(_epoch_of "$STARTED" 2>/dev/null || echo "$now") )) || echo '' )"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NAME" "$key" "$branch" "$slot" "$alive" "$stage" "$(printf '%s' "$line" | cut -d' ' -f3-)" \
    "$elapsed" "${files:-0}" "$stat_line" "$handoff" "$base_ok" "${agent:-null}"
}

# _snapshot_sessions <now>   Session records plus what each agent is doing.
# Ended sessions stay listed for a day.
_snapshot_sessions() {
  local now="$1" f tmp; tmp="$(mktemp -d)"
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] || continue
    ( _snapshot_session_row "$f" "$now" > "${tmp}/$(basename "$f")" 2>/dev/null ) &
  done
  wait
  # No rows is the normal case; cat's failure must not add a second [].
  { cat "$tmp"/*.json 2>/dev/null || true; } | jq -s -c 'sort_by(-(.created // 0))'
  rm -rf "$tmp"
}

_snapshot_session_row() {
  local f="$1" now="$2" key name agent=null alive=false t mtime
  key="$(jq -r .key "$f")"; name="$(worktree_branch_for "$key")"
  if ! session_live "$key"; then
    [ $(( now - $(jq -r '.last_activity // 0 | floor' "$f") )) -lt 86400 ] || return 0
  elif vm_is_running "$name" 2>/dev/null; then
    t="$(mktemp)"
    # First line is the transcript's mtime on the runner: the local copy's is always now.
    # ponytail: last 2000 events per feed, so cost_so_far undercounts a very long session.
    _session_sh "$name" 'f=/workspace/.fxa-auto-claude.jsonl; stat -c %Y "$f" 2>/dev/null || echo 0; tail -n 2000 "$f" 2>/dev/null' > "$t" 2>/dev/null || true
    mtime="$(head -1 "$t" | tr -dc '0-9')"
    agent="$(tail -n +2 "$t" > "${t}.j"; _snapshot_agent_json "${t}.j" "$now")"
    [ -n "$mtime" ] && [ "$mtime" -gt 0 ] && [ "$agent" != null ] && \
      agent="$(jq -c --argjson i "$(( now > mtime ? now - mtime : 0 ))" '.idle_seconds = $i' <<< "$agent")"
    rm -f "$t" "${t}.j"
    _session_turn_running "$key" && alive=true
  fi
  # Media the host kept, oldest first, with each file's time so the conversation can place it.
  # Each stage may find nothing; a fallback here would print a second [] and drop the row.
  local media; media="$( { cd "${SESSION_DIR}/${key}.media" 2>/dev/null && for m in *; do
      [[ "$m" =~ ^[A-Za-z0-9._-]{1,120}\.(png|jpe?g|gif|webp|mp4|webm)$ ]] || continue
      printf '%s\t%s\n' "$(_mtime "$m")" "$m"
    done; } | jq -R 'split("\t") | {at: (.[0] | tonumber), name: .[1]}' | jq -sc 'sort_by(.at)' )"
  jq -c --argjson agent "${agent:-null}" --argjson alive "$alive" --argjson media "${media:-[]}" \
    --arg request "$(head -c 300 "${SESSION_DIR}/${key}.prompt.md" 2>/dev/null)" \
    '. + {agent: $agent, agent_alive: $alive, request: $request, media: $media}' "$f"
}

# snapshot_agents_json   The fast feed: runners, pool and instances, with no Jira
# or GitHub, so it can run every 30 s while the slow full snapshot runs every few
# minutes. The page merges the two by key.
snapshot_agents_json() {
  local started now; started="$(date +%s)"; now="$started"
  # Fill the instance-state memo here, in the parent shell, so every $(...)
  # below inherits it instead of paying its own instance list.
  vm_is_running __prime >/dev/null 2>&1 || true
  local meta tmp; tmp="$(mktemp -d)"
  # One subshell per runner: each pays an rsync and an ssh through IAP, about
  # six seconds apiece, and the feed should cost one runner's worth, not the sum.
  for meta in "${LOG_DIR}"/*.meta; do
    [ -f "$meta" ] || continue
    ( _snapshot_runner_row "$meta" "$now" > "${tmp}/$(basename "$meta").row" 2>/dev/null ) &
  done
  wait
  [ -n "${FXA_SNAPSHOT_TIMING:-}" ] && echo "runners: $(( $(date +%s) - started ))s" >&2
  # No row files when no runner is up; cat then fails and set -e would end the feed.
  local rows; rows="$(cat "${tmp}"/*.row 2>/dev/null || true)"; rm -rf "$tmp"
  local runners; runners="$(printf '%s' "$rows" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
    | map({ name: .[0], key: .[1], branch: .[2], slot: .[3], agent_alive: (.[4] == "true"),
            stage: .[5], detail: (.[6] // ""),
            elapsed_seconds: (if (.[7] // "") == "" then null else (.[7] | tonumber) end),
            files_changed: ((.[8] // "0") | tonumber? // 0), diffstat: (.[9] // ""),
            handoff: (.[10] == "true"),
            base_ok: (if .[11] == "true" then true elif .[11] == "false" then false else null end),
            agent: ((.[12] // "null") | fromjson? // null) })')"
  local instances pool free cap today
  instances="$(_snapshot_instances)"
  [ -n "${FXA_SNAPSHOT_TIMING:-}" ] && echo "instances: $(( $(date +%s) - started ))s" >&2
  pool="$(_snapshot_pool)"
  [ -n "${FXA_SNAPSHOT_TIMING:-}" ] && echo "pool: $(( $(date +%s) - started ))s" >&2
  free="$(cmd_freeslots 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')"
  cap="$(cmd_launchcap 2>/dev/null || echo 0)"
  [ -n "${FXA_SNAPSHOT_TIMING:-}" ] && echo "slots: $(( $(date +%s) - started ))s" >&2
  today="$(_snapshot_today)"
  local sessions; sessions="$(_snapshot_sessions "$now")"
  [ -n "${FXA_SNAPSHOT_TIMING:-}" ] && echo "sessions: $(( $(date +%s) - started ))s" >&2
  jq -n --arg at "$(date -u +%FT%TZ)" --argjson secs "$(( $(date +%s) - started ))" \
    --arg backend "${FXA_VM_BACKEND:-tart}" \
    --arg zone "$( [ "${FXA_VM_BACKEND:-tart}" = gce ] && printf '%s' "$FXA_GCE_ZONE" )" \
    --argjson hourly "${FXA_GCE_HOURLY_USD:-0.13}" --argjson cap "${cap:-0}" \
    --argjson runners "$runners" --argjson instances "$instances" --argjson pool "$pool" \
    --argjson free "$free" --argjson today "$today" --argjson sessions "${sessions:-[]}" \
    '{ generated_at: $at, took_seconds: $secs, backend: $backend,
       zone: (if $zone == "" then null else $zone end),
       launchcap: $cap, free_slots: $free, pool: $pool, instances: $instances,
       runner_hourly_usd: (if $backend == "gce" then ($instances | map(select(.state == "running")) | length) * $hourly else 0 end),
       runners: $runners, sessions: $sessions, session_cap: '"$(_session_cap)"',
       session_idle_seconds: '"${FXA_SESSION_IDLE_SECONDS:-1800}"', session_max_run_seconds: '"${FXA_SESSION_MAX_RUN_SECONDS:-14400}"',
       session_models: { claude: "'"${FXA_AGENT_MODEL:-claude-opus-5-5}"'", codex: "'"${FXA_CODEX_MODEL:-gpt-6-astra}"'" },
       today: $today }'
}

# _snapshot_today   Runs recorded today (UTC). The footer keeps all time.
_snapshot_today() {
  [ -f "$PIPE_RUNS_FILE" ] || { echo 'null'; return 0; }
  jq -s --arg d "$(date -u +%F)" '
    map(select((.recorded_at // "") | startswith($d))) |
    { runs: length, tickets: ([.[].issue] | unique | length),
      cost_usd: ([.[].cost_usd // 0] | add // 0 | .*100 | round / 100),
      prs: ([.[].pr] | map(select(. != null)) | unique | length),
      median_minutes: (if length == 0 then null else (([.[].wall_seconds // 0] | sort | .[length/2|floor]) / 60 | round) end) }' \
    "$PIPE_RUNS_FILE" 2>/dev/null || echo 'null'
}

# snapshot_json   Every stage in one document. A section that fails to fetch is
# null, not empty, so the page says "unknown" instead of a confident zero.
snapshot_json() {
  vm_is_running __prime >/dev/null 2>&1 || true
  pipeline_require || return 1
  local started; started="$(date +%s)"

  # One call per state returns keys and summaries, so titles cost no extra request.
  local queue_items inflight_items done_items blocked_items
  queue_items="$(jira_queue_items)"
  inflight_items="$(jira_items_in_state inflight)"
  done_items="$(jira_items_in_state done)"
  blocked_items="$(jira_items_in_state blocked)"

  local queue inflight_keys done_keys
  queue="$(printf '%s' "$queue_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"
  inflight_keys="$(printf '%s' "$inflight_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"
  done_keys="$(printf '%s' "$done_items" | jq -r '.[]?.key // empty' 2>/dev/null || echo '')"

  local pool skipped inflight review telem freeslots instances
  pool="$(_snapshot_pool)"
  instances="$(_snapshot_instances)"
  skipped="$(_snapshot_skipped)"
  inflight="$(_snapshot_inflight "$inflight_keys")"
  review="$(gh_pr_states_json "$done_keys")"
  local inflight_prs; inflight_prs="$(gh_pr_states_json "$inflight_keys")"
  telem="$(_snapshot_telemetry)"
  # Known repo-infrastructure reds, so the page groups them instead of blaming
  # each PR. gh_red_infra caches per head sha, so this reads each log once.
  local infra='{}' k why
  for k in $(printf '%s' "$review" | jq -r '.[]? | select(.fail > 0) | .key' 2>/dev/null); do
    why="$(gh_red_infra "$k" 2>/dev/null)" && infra="$(jq -c --arg k "$k" --arg w "$why" '. + {($k): $w}' <<<"$infra")"
  done
  local hold; hold="$(pipeline_holding_new && cat "$(pipeline_hold_marker)" || true)"
  # A failed inflight read gives an empty owner list, and worktree_free_slots
  # then calls every idle slot claimable. Report unknown instead.
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
    --argjson infra "$infra" \
    --arg hold "$hold" \
    --arg focus "$(pipeline_focus_key || true)" \
    --argjson instances "$instances" \
    --arg backend "${FXA_VM_BACKEND:-tart}" \
    --arg zone "$( [ "${FXA_VM_BACKEND:-tart}" = gce ] && printf '%s' "$FXA_GCE_ZONE" )" \
    '($skipped | map(.key)) as $skipkeys
     | ($items // []) as $q
     | { generated_at: $at, pipeline: $pipeline, repo: $repo, took_seconds: $secs,
         backend: $backend, zone: (if $zone == "" then null else $zone end),
         instances: $instances,
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
         review: (if $review == null then null else $review | map(. + {infra: ($infra[.key] // null)}) end),
         mode: { newtickets: (if $hold == "" then "on" else "off" end),
                 newtickets_note: (if $hold == "" then null else $hold end),
                 focus: (if $focus == "" then null else $focus end) },
         telemetry: $telemetry }'
}
