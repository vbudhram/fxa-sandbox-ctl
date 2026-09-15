#!/bin/bash
# telemetry.sh — token, cost, and run accounting for a pipeline.
#
# Reference data only. Nothing here reaches Jira or a PR.
#
# Public API:
#   telemetry_usage KEY     Token and model usage read out of the VM
#   telemetry_record KEY    Append one run to the event log, then roll up
#   telemetry_costs         Rebuild the per-issue rollup from the event log

[ -n "${_FXA_TELEMETRY_LOADED:-}" ] && return 0
_FXA_TELEMETRY_LOADED=1

# jq that sums a Claude Code transcript. Runs inside the VM.
read -r -d '' _TELEMETRY_REMOTE <<'REMOTE' || true
f=$(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || { echo "{}"; exit 0; }
jq -s "[.[] | select(.message.usage != null)] as \$m
  | { messages: (\$m|length),
      model: (\$m|map(.message.model)|unique-[null,\"<synthetic>\"]|first),
      input: (\$m|map(.message.usage.input_tokens // 0)|add),
      output: (\$m|map(.message.usage.output_tokens // 0)|add),
      cache_write: (\$m|map(.message.usage.cache_creation_input_tokens // 0)|add),
      cache_read: (\$m|map(.message.usage.cache_read_input_tokens // 0)|add) }" "$f"
REMOTE

# jq that sums the stream-json transcript the launcher pulls back into the slot
# as .fxa-auto-claude.jsonl. The `result` event carries per-model totals for the
# whole run (modelUsage), which is the authoritative count and includes subagent
# models. A run that died before its result event falls back to summing the
# assistant messages, which undercounts subagents but is never empty.
read -r -d '' _TELEMETRY_LOCAL <<'LOCAL' || true
def sum_models: to_entries | map(.value) |
  { input: (map(.inputTokens//0)|add), output: (map(.outputTokens//0)|add),
    cache_write: (map(.cacheCreationInputTokens//0)|add), cache_read: (map(.cacheReadInputTokens//0)|add) };
[.[] | select(.type=="result" and .modelUsage != null)] as $r
| if ($r|length) > 0 then
    ($r | map(.modelUsage) | add) as $mu
    | ($mu | sum_models) + {
        messages: ($r|map(.num_turns//0)|add), model: ($mu|to_entries|max_by(.value.costUSD//0)|.key),
        models: ($mu | with_entries(.value |= {input:(.inputTokens//0), output:(.outputTokens//0),
                   cache_write:(.cacheCreationInputTokens//0), cache_read:(.cacheReadInputTokens//0),
                   cost_reported:(.costUSD//0)})),
        agent_ms: ($r|map(.duration_ms//0)|add), source: "result" }
  else
    [.[] | select(.type=="assistant" and .message.usage != null and .message.model != "<synthetic>")] as $m
    | { messages: ($m|length), model: ($m|map(.message.model)|unique|first),
        input: ($m|map(.message.usage.input_tokens//0)|add), output: ($m|map(.message.usage.output_tokens//0)|add),
        cache_write: ($m|map(.message.usage.cache_creation_input_tokens//0)|add),
        cache_read: ($m|map(.message.usage.cache_read_input_tokens//0)|add), source: "assistant-sum" }
  end
LOCAL

# jq for Claude Code's session transcript (.fxa-auto-session.jsonl, fetched at
# handoff). One line per message with FINAL usage. Dedupe on message id: a
# message with several content blocks appears once per block.
read -r -d '' _TELEMETRY_SESSION <<'SESSION' || true
[.[] | select(.type=="assistant" and .message.usage != null and .message.model != "<synthetic>")]
| group_by(.message.id) | map(.[-1])
| group_by(.message.model) | map({key: .[0].message.model, value: {
    input: (map(.message.usage.input_tokens//0)|add), output: (map(.message.usage.output_tokens//0)|add),
    cache_write: (map(.message.usage.cache_creation_input_tokens//0)|add), cache_read: (map(.message.usage.cache_read_input_tokens//0)|add),
    n: length }}) | from_entries as $models
| ($models | to_entries | map(.value)) as $v
| { messages: ($v|map(.n)|add), model: ($models|to_entries|max_by(.value.output)|.key),
    input: ($v|map(.input)|add), output: ($v|map(.output)|add),
    cache_write: ($v|map(.cache_write)|add), cache_read: ($v|map(.cache_read)|add),
    models: ($models | with_entries(.value |= del(.n))), source: "session" }
SESSION

# jq for a Codex session log (~/.codex/sessions/.../rollout-*.jsonl). The
# token_count events carry the CUMULATIVE total, so the last one is the run.
# OpenAI's input_tokens includes the cached part; split it so the row means the
# same thing as a Claude row: input = uncached, cache_read = cached.
read -r -d '' _TELEMETRY_CODEX <<'CODEX' || true
([.[] | select(.type=="turn_context")] | last | .payload.model // "codex") as $model
| ([.[] | select(.type=="event_msg" and .payload.type=="token_count" and .payload.info.total_token_usage != null)]) as $tc
| ($tc | last | .payload.info.total_token_usage // {}) as $u
| { messages: ($tc|length), model: $model,
    input: (($u.input_tokens//0) - ($u.cached_input_tokens//0)), output: ($u.output_tokens//0),
    cache_write: ($u.cache_write_input_tokens//0), cache_read: ($u.cached_input_tokens//0),
    models: { ($model): { input: (($u.input_tokens//0) - ($u.cached_input_tokens//0)), output: ($u.output_tokens//0),
                          cache_write: ($u.cache_write_input_tokens//0), cache_read: ($u.cached_input_tokens//0) } },
    source: "codex-session" }
CODEX

# telemetry_usage <KEY>
#   Prefer the transcript copy in the slot: on GCE the runner is deleted the
#   moment the PR opens, so the VM path only works mid-run. Fall back to the VM.
telemetry_usage() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: usage needs <KEY>" >&2; return 1; }
  local wt f
  if wt="$(_telemetry_worktree_for_key "$key")"; then
    f="${wt}/.fxa-auto-session.jsonl"
    if [ -s "$f" ]; then
      if grep -q '"token_count"' "$f"; then jq -s "$_TELEMETRY_CODEX" "$f" 2>/dev/null && return 0
      else jq -s "$_TELEMETRY_SESSION" "$f" 2>/dev/null && return 0; fi
    fi
    f="${wt}/.fxa-auto-claude.jsonl";  [ -s "$f" ] && jq -s "$_TELEMETRY_LOCAL" "$f" 2>/dev/null && return 0
  fi
  local name; name="$(worktree_branch_for "$key")" || return 1
  agent_ssh_exec "$name" "$_TELEMETRY_REMOTE" 2>/dev/null || { echo '{"error":"no-transcript"}'; return 1; }
}

# List pricing in USD per 1M tokens: input, output, cache_write, cache_read.
# Priced at record time, because reconstructing later means guessing which
# pricing applied on the day. Source: platform.claude.com/docs/en/about-claude/pricing
# (read 2026-09-01). cache_write is the 5-minute rate (1.25x input).
#
# Order matters: the fable-5-1 row must precede the fable-5 glob. Fable 5.1 is
# the one model whose cache reads are 0.025x input, not 0.1x.
_telemetry_price_for() {
  case "$1" in
    claude-fable-5-1*) echo "10.00 50.00 12.50 0.25" ;;
    claude-fable-5*)   echo "10.00 50.00 12.50 1.00" ;;
    claude-opus-5*)    echo "5.00 25.00 6.25 0.50" ;;
    claude-sonnet-5*)  echo "2.00 10.00 2.50 0.20" ;;
    claude-haiku-4-5*) echo "1.00  5.00 1.25 0.10" ;;
    # OpenAI list prices, developers.openai.com/api/docs/pricing (read 2026-09-15):
    # input 10, output 50, cache write 12.50, cached input 1.00.
    gpt-6-astra*)      echo "10.00 50.00 12.50 1.00" ;;
    *) echo "" ;;
  esac
}

# Which pool worktree currently holds this ticket's branch. Hardcoding the first
# slot recorded every slot-2 ticket against slot 1's HEAD: on 2026-08-13
# FXA-14104 stored FXA-14150's sha and file count.
_telemetry_worktree_for_key() {
  local br root parent slot path
  br="$(worktree_branch_for "$1")" || return 1
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    path="${parent}/${slot}"
    if [ "$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$br" ]; then
      printf '%s\n' "$path"; return 0
    fi
  done <<< "$(worktree_pool_slot_names)"
  return 1
}

# telemetry_record <KEY>
#   Append one run to the event log. The log is append-only, one line per run,
#   so a relaunched ticket keeps both attempts. The rollup is derived from it.
telemetry_record() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: record needs <KEY>" >&2; return 1; }
  local wt; wt="$(_telemetry_worktree_for_key "$key")" || {
    echo "WARN: no pool worktree is on $(worktree_branch_for "$key"); commit and files_changed will be empty." >&2
    wt=""
  }
  local log; log="$(pipeline_launch_log "$key")"
  local usage secs pr sha files base
  usage="$(telemetry_usage "$key" 2>/dev/null || echo '{}')"
  # The launch log's own lifespan, not "now minus launch". `record` can run long
  # after the agent stopped, and then "now" measures the delay, not the run. On
  # 2026-09-08 FXA-14471 recorded 119 hours because it was recorded five days
  # late; its real run was 49 minutes. This is only correct because the launcher
  # deletes the log before each launch, giving every run a true birth time.
  secs="$( [ -f "$log" ] && python3 -c "import os,sys;s=os.stat(sys.argv[1]);print(max(0,int(s.st_mtime-s.st_birthtime)))" "$log" || echo 0 )"
  pr="$( { grep -o 'https://github.com/[^ ]*/pull/[0-9]*' "$log" 2>/dev/null || true; } | tail -1)"
  if [ -n "$wt" ]; then
    base="origin/${FXA_WORKTREE_BASE}"
    sha="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || echo '')"
    files="$(git -C "$wt" diff --name-only "${base}...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  else
    sha=""; files=0
  fi

  # Price this run from its own model, then store the rate alongside it so an
  # old row stays interpretable after list prices move.
  local model rates cost
  model="$(printf '%s\n' "$usage" | jq -r '.model // ""')"
  rates="$(_telemetry_price_for "$model")"
  # A run with a per-model breakdown (subagents on a cheaper model) is priced
  # model by model; the single-rate path below is the fallback for old rows.
  if [ "$(printf '%s\n' "$usage" | jq -r '.models // empty | length')" != "" ]; then
    local m table="" mr
    for m in $(printf '%s\n' "$usage" | jq -r '.models | keys[]'); do
      mr="$(_telemetry_price_for "$m")"; [ -n "$mr" ] || { echo "WARN: no price row for model '$m'" >&2; continue; }
      table="${table}${m} ${mr}\n"
    done
    cost="$(printf '%s\n' "$usage" | jq -c --arg t "$(printf "$table")" '
      ($t | split("\n") | map(select(length>0) | split(" ") | {key:.[0], value:(.[1:]|map(tonumber))}) | from_entries) as $p
      | { cost_usd: ([.models | to_entries[] | select($p[.key] != null) |
            (.value.input*$p[.key][0] + .value.output*$p[.key][1] + .value.cache_write*$p[.key][2] + .value.cache_read*$p[.key][3]) / 1000000]
            | add // 0 | . * 100 | round / 100),
          priced: ($p | with_entries(.value |= {input:.[0], output:.[1], cache_write:.[2], cache_read:.[3]})) }')"
  elif [ -n "$rates" ]; then
    cost="$(printf '%s\n' "$usage" | jq -c --arg r "$rates" '
      ($r | split(" ") | map(select(length>0) | tonumber)) as $p
      | { cost_usd: (((.input//0)*$p[0] + (.output//0)*$p[1]
                    + (.cache_write//0)*$p[2] + (.cache_read//0)*$p[3]) / 1000000
                    * 100 | round / 100),
          priced: {input:$p[0], output:$p[1], cache_write:$p[2], cache_read:$p[3]} }')"
  else
    # Say so at record time. An unpriced row is silent in the rollup, so the
    # total reads low and nobody knows why until someone counts the rows.
    echo "WARN: no price row for model '${model:-<none>}'; this run is recorded unpriced and the rollup understates spend." >&2
    cost='{"cost_usd":null,"priced":null}'
  fi

  # Which credential paid for this run. A subscription token is not metered per
  # token, so blending the two makes cost per ticket meaningless.
  local billing="api"
  case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in sk-ant-oat*) billing="subscription" ;; esac

  mkdir -p "$(dirname "$PIPE_RUNS_FILE")"
  printf '%s\n' "$usage" | jq -c --arg k "$key" --arg pr "$pr" --arg sha "$sha" \
      --argjson secs "${secs:-0}" --argjson files "${files:-0}" --arg at "$(date -u +%FT%TZ)" \
      --argjson cost "$cost" --arg billing "$billing" \
      '. + $cost + {issue:$k, pr:$pr, commit:$sha, files_changed:$files, wall_seconds:$secs, recorded_at:$at, billing:$billing}' \
    >>"$PIPE_RUNS_FILE"
  echo "recorded $key -> $PIPE_RUNS_FILE"
  tail -1 "$PIPE_RUNS_FILE"
  telemetry_costs >/dev/null && echo "rolled up -> $PIPE_COSTS_FILE"
}

# Roll the event log up into a per-issue view. Rebuilt from scratch each time,
# so it can never drift from the event log.
telemetry_costs() {
  pipeline_require || return 1
  [ -f "$PIPE_RUNS_FILE" ] || { echo "ERROR: no run log at $PIPE_RUNS_FILE" >&2; return 1; }
  mkdir -p "$(dirname "$PIPE_COSTS_FILE")"
  jq -s 'group_by(.issue) | map({
      key: .[0].issue,
      value: {
        runs: length,
        cost_usd: (map(.cost_usd // 0) | add | .*100 | round / 100),
        unpriced_runs: (map(select(.cost_usd == null)) | length),
        billing: (map(.billing) | unique - [null] | join(",")),
        model: (map(.model) | unique - [null] | join(",")),
        pr: (map(.pr) | map(select(. != null and . != "")) | last // ""),
        commit: (map(.commit) | map(select(. != null and . != "")) | last // ""),
        files_changed: (map(.files_changed // 0) | max),
        wall_seconds: (map(.wall_seconds // 0) | add),
        tokens: {
          input:       (map(.input // 0)       | add),
          output:      (map(.output // 0)      | add),
          cache_write: (map(.cache_write // 0) | add),
          cache_read:  (map(.cache_read // 0)  | add)
        },
        last_recorded: (map(.recorded_at) | max)
      }
    }) | from_entries' "$PIPE_RUNS_FILE" >"${PIPE_COSTS_FILE}.tmp" \
    && mv "${PIPE_COSTS_FILE}.tmp" "$PIPE_COSTS_FILE"
  echo "$PIPE_COSTS_FILE"
}

# telemetry_merge_comment <KEY>
#   Render the 🤖 comment posted when a ticket is labelled merged: what landed,
#   how long the agent runs took, which models, the token counts, and the
#   API-list-price estimate. Rows come from the run log; a ticket with no rows
#   gets a one-line comment rather than invented numbers. Deliberately says
#   nothing about how the runs were billed.
telemetry_merge_comment() {
  pipeline_require || return 1
  local key="${1:-}" pr="${2:-}"
  [ -s "$PIPE_RUNS_FILE" ] || { printf '🤖 Merged%s. No run telemetry was recorded for this ticket.\n' "${pr:+ as $pr}"; return 0; }
  jq -r -s --arg k "$key" --arg pr "$pr" '
    def n: tostring | gsub("(?<a>\\d)(?=(?:\\d{3})+$)"; "\(.a),");
    def mins: (. / 60 | round) as $m | if $m >= 60 then "\($m/60|floor)h \($m%60)m" else "\($m)m" end;
    [.[] | select(.issue == $k)] as $r
    | if ($r|length) == 0 then "🤖 Merged\(if $pr != "" then " as \($pr)" else "" end). No run telemetry was recorded for this ticket."
      else
        ($r | map(.wall_seconds//0) | add) as $wall
        | ($r | map(.cost_usd//0) | add) as $cost
        | ($r | map(.models // {(.model//"unknown"): {input:.input, output:.output, cache_write:.cache_write, cache_read:.cache_read}})
             | add // {}) as $models
        | ($r | map(.models // {} | to_entries[]) | group_by(.key) | map({key: .[0].key, value: (map(.value) | {input:(map(.input)|add), output:(map(.output)|add), cache_write:(map(.cache_write)|add), cache_read:(map(.cache_read)|add)})}) | from_entries) as $bymodel
        | (if ($bymodel|length) > 0 then $bymodel else $models end) as $bm
        | (($r|map(.pr)|map(select(. != ""))|last) // $pr) as $url
        | [ "🤖 Merged\(if $url != "" and $url != null then " as \($url)" else "" end).",
            "Agent runs: \($r|length). Wall time launch→PR: \($wall|mins). Models: \($bm|keys|join(", ")).",
            "Tokens: input \($r|map(.input//0)|add|n), output \($r|map(.output//0)|add|n), cache write \($r|map(.cache_write//0)|add|n), cache read \($r|map(.cache_read//0)|add|n).",
            "Estimated API cost at list price: $\($cost*100|round/100)." ]
          + ( if ($bm|length) > 1 then [ "Per model: " + ($bm | to_entries | map("\(.key) out \(.value.output|n) / cache read \(.value.cache_read|n)") | join("; ")) + "." ] else [] end )
          + ( ($r | map(select(.source == "assistant-sum")) | length) as $approx
              | if $approx > 0 then [ "Output tokens are undercounted for \($approx) run(s) recorded from the stream log; the cost estimate is a floor." ] else [] end )
        | join("\n")
      end' "$PIPE_RUNS_FILE"
}
