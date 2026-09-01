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
      model: (\$m|map(.message.model)|unique-[null]|first),
      input: (\$m|map(.message.usage.input_tokens // 0)|add),
      output: (\$m|map(.message.usage.output_tokens // 0)|add),
      cache_write: (\$m|map(.message.usage.cache_creation_input_tokens // 0)|add),
      cache_read: (\$m|map(.message.usage.cache_read_input_tokens // 0)|add) }" "$f"
REMOTE

# telemetry_usage <KEY>
#   The transcript lives only inside the VM, so this MUST run before the VM is
#   stopped or the numbers are lost for good.
telemetry_usage() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: usage needs <KEY>" >&2; return 1; }
  local name; name="$(worktree_branch_for "$key")" || return 1
  agent_ssh_exec "$name" "$_TELEMETRY_REMOTE" 2>/dev/null || { echo '{"error":"no-vm"}'; return 1; }
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
  secs="$( [ -f "$log" ] && python3 -c "import os,time;print(int(time.time()-os.stat('$log').st_birthtime))" || echo 0 )"
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
  if [ -n "$rates" ]; then
    cost="$(printf '%s\n' "$usage" | jq -c --arg r "$rates" '
      ($r | split(" ") | map(select(length>0) | tonumber)) as $p
      | { cost_usd: (((.input//0)*$p[0] + (.output//0)*$p[1]
                    + (.cache_write//0)*$p[2] + (.cache_read//0)*$p[3]) / 1000000
                    * 100 | round / 100),
          priced: {input:$p[0], output:$p[1], cache_write:$p[2], cache_read:$p[3]} }')"
  else
    cost='{"cost_usd":null,"priced":null}'
  fi

  mkdir -p "$(dirname "$PIPE_RUNS_FILE")"
  printf '%s\n' "$usage" | jq -c --arg k "$key" --arg pr "$pr" --arg sha "$sha" \
      --argjson secs "${secs:-0}" --argjson files "${files:-0}" --arg at "$(date -u +%FT%TZ)" \
      --argjson cost "$cost" \
      '. + $cost + {issue:$k, pr:$pr, commit:$sha, files_changed:$files, wall_seconds:$secs, recorded_at:$at}' \
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
