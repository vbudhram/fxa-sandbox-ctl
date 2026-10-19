#!/bin/bash
# llm-token.sh: per-run tokens for fxa-llm-proxy (infra/llm-proxy/proxy.py).
# With FXA_LLM_PROXY_URL set, a runner holds one of these instead of the
# Anthropic API key; the proxy swaps in the key and counts the run's spend.
[ -n "${_FXA_LLM_TOKEN_LOADED:-}" ] && return 0
_FXA_LLM_TOKEN_LOADED=1
FXA_LLM_PROXY_DIR="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}"

# llm_token_for <run>   The run's token, made the first time. A Slack session
# rewrites its credential every turn, so it keeps one token for its life.
# The token carries the Slack thread (FXA_THREAD, else the session's record), so usage rows sum by thread.
llm_token_for() {
  local run="$1" map tok thread="${FXA_THREAD:-}"
  [ -n "$thread" ] || { declare -F session_get >/dev/null && thread="$(session_get "$run" thread)"; }
  [[ "$run" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: bad run name for a token" >&2; return 1; }
  map="${FXA_LLM_PROXY_DIR}/runs/${run}"
  mkdir -p "${FXA_LLM_PROXY_DIR}/tokens" "${FXA_LLM_PROXY_DIR}/runs" || return 1
  tok="$(cat "$map" 2>/dev/null || true)"
  local dl; dl="$(_run_deadline "$FXA_LLM_PROXY_DIR" "$run")"
  if [ -n "$tok" ] && jq -e '.expires > now' "${FXA_LLM_PROXY_DIR}/tokens/${tok}.json" >/dev/null 2>&1; then
    [ -z "$dl" ] || _tok_expires "${FXA_LLM_PROXY_DIR}/tokens/${tok}.json" "$dl"
    printf '%s\n' "$tok"; return 0
  fi
  tok="fxl_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)"
  # The team's caps for the proxy, from its record (none for a team without them): written at each new token.
  local team="${PIPE_PROFILE:-fxa}"
  if [[ "$team" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
    mkdir -p "${FXA_LLM_PROXY_DIR}/teams" && jq -n --arg d "${PIPE_TEAM_USD_DAY:-}" --arg m "${PIPE_TEAM_USD_MONTH:-}" \
      '{} + (if $d != "" then {day_usd: ($d | tonumber)} else {} end) + (if $m != "" then {month_usd: ($m | tonumber)} else {} end)' \
      > "${FXA_LLM_PROXY_DIR}/teams/${team}.json.$$" && mv -f "${FXA_LLM_PROXY_DIR}/teams/${team}.json.$$" "${FXA_LLM_PROXY_DIR}/teams/${team}.json"
  fi
  ( umask 077
    jq -n --arg r "$run" --arg th "$thread" --arg tm "$team" --argjson now "$(date +%s)" --argjson ttl "${FXA_LLM_TOKEN_TTL:-86400}" \
      --argjson cap "${FXA_LLM_RUN_CAP_USD:-50}" \
      --argjson dl "${dl:-0}" \
      '{run: $r, team: $tm, created: $now, expires: (if $dl > 0 then $dl else $now + $ttl end), cap_usd: $cap, spent_usd: 0} + (if $th != "" then {thread: $th} else {} end)' \
      > "${FXA_LLM_PROXY_DIR}/tokens/${tok}.json" ) || return 1
  printf '%s\n' "$tok" > "$map"
  printf '%s\n' "$tok"
}

# A GCE runner is deleted at a fixed time (max-run-duration), with no agent_stop to revoke its
# tokens. vm_clone writes runs/<run>.deadline (that time + 10 min) in each token dir; a token made
# or reused for the run expires then, not after the 24 h default.
# _run_deadline <dir> <run>   The run's deadline when it is still ahead, else nothing.
_run_deadline() {
  local d; d="$(tr -dc 0-9 2>/dev/null < "$1/runs/$2.deadline" || true)"
  [ -n "$d" ] && [ "$d" -gt "$(date +%s)" ] && printf '%s\n' "$d"; return 0
}
# _tok_expires <token file> <epoch>
_tok_expires() { jq --argjson e "$2" '.expires = $e' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

# run_tokens_deadline <run> <epoch>   Set the run's deadline, and move its live tokens to it.
run_tokens_deadline() {
  local d tok
  for d in "$FXA_LLM_PROXY_DIR" "${FXA_MCP_GATEWAY_DIR:-}"; do
    [ -n "$d" ] && mkdir -p "$d/runs" || continue
    printf '%s\n' "$2" > "$d/runs/$1.deadline"
    # Only a mapped token: revoke removes the map, so a revoked token is never revived.
    tok="$(cat "$d/runs/$1" 2>/dev/null || true)"
    [ -n "$tok" ] && [ -f "$d/tokens/$tok.json" ] && _tok_expires "$d/tokens/$tok.json" "$2"
  done
  return 0
}

# llm_token_revoke <run>   Expire the run's token. The file stays, with its spend.
llm_token_revoke() {
  local map="${FXA_LLM_PROXY_DIR}/runs/${1:-}" tok f
  tok="$(cat "$map" 2>/dev/null || true)"; rm -f "$map"
  f="${FXA_LLM_PROXY_DIR}/tokens/${tok}.json"
  [ -n "$tok" ] && [ -f "$f" ] && jq '.expires = 0' "$f" > "${f}.tmp" && mv -f "${f}.tmp" "$f"
  return 0
}
