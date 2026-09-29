#!/bin/bash
# llm-token.sh: per-run tokens for fxa-llm-proxy (infra/llm-proxy/proxy.py).
# With FXA_LLM_PROXY_URL set, a runner holds one of these instead of the
# Anthropic API key; the proxy swaps in the key and counts the run's spend.
[ -n "${_FXA_LLM_TOKEN_LOADED:-}" ] && return 0
_FXA_LLM_TOKEN_LOADED=1
FXA_LLM_PROXY_DIR="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}"

# llm_token_for <run>   The run's token, made the first time. A Slack session
# rewrites its credential every turn, so it keeps one token for its life.
llm_token_for() {
  local run="$1" map tok
  [[ "$run" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: bad run name for a token" >&2; return 1; }
  map="${FXA_LLM_PROXY_DIR}/runs/${run}"
  mkdir -p "${FXA_LLM_PROXY_DIR}/tokens" "${FXA_LLM_PROXY_DIR}/runs" || return 1
  tok="$(cat "$map" 2>/dev/null || true)"
  if [ -n "$tok" ] && jq -e '.expires > now' "${FXA_LLM_PROXY_DIR}/tokens/${tok}.json" >/dev/null 2>&1; then
    printf '%s\n' "$tok"; return 0
  fi
  tok="fxl_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  ( umask 077
    jq -n --arg r "$run" --argjson now "$(date +%s)" --argjson ttl "${FXA_LLM_TOKEN_TTL:-86400}" \
      --argjson cap "${FXA_LLM_RUN_CAP_USD:-50}" \
      '{run: $r, created: $now, expires: ($now + $ttl), cap_usd: $cap, spent_usd: 0}' \
      > "${FXA_LLM_PROXY_DIR}/tokens/${tok}.json" ) || return 1
  printf '%s\n' "$tok" > "$map"
  printf '%s\n' "$tok"
}

# llm_token_revoke <run>   Expire the run's token. The file stays, with its spend.
llm_token_revoke() {
  local map="${FXA_LLM_PROXY_DIR}/runs/${1:-}" tok f
  tok="$(cat "$map" 2>/dev/null || true)"; rm -f "$map"
  f="${FXA_LLM_PROXY_DIR}/tokens/${tok}.json"
  [ -n "$tok" ] && [ -f "$f" ] && jq '.expires = 0' "$f" > "${f}.tmp" && mv -f "${f}.tmp" "$f"
  return 0
}
