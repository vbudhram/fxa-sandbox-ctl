#!/bin/bash
# mcp-token.sh: per-run tokens for fxa-mcp-gateway (infra/mcp-gateway/gateway.py).
# With FXA_MCP_GATEWAY_URL set and connectors asked for, a runner holds one of
# these; the gateway holds the upstream credentials and serves read-only tools.
[ -n "${_FXA_MCP_TOKEN_LOADED:-}" ] && return 0
_FXA_MCP_TOKEN_LOADED=1
FXA_MCP_GATEWAY_DIR="${FXA_MCP_GATEWAY_DIR:-$HOME/.claude/state/mcp-gateway}"

# mcp_token_for <run> [connectors]   The run's token. The first call makes it
# with the comma-separated connectors; later calls (a session's next turn)
# reuse it and ignore the argument. Fails, printing nothing, when the run has
# no token and asks for no connectors.
mcp_token_for() {
  local run="$1" connectors="${2:-}" map tok
  [[ "$run" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: bad run name for a token" >&2; return 1; }
  map="${FXA_MCP_GATEWAY_DIR}/runs/${run}"
  tok="$(cat "$map" 2>/dev/null || true)"
  if [ -n "$tok" ] && jq -e '.expires > now' "${FXA_MCP_GATEWAY_DIR}/tokens/${tok}.json" >/dev/null 2>&1; then
    printf '%s\n' "$tok"; return 0
  fi
  [ -n "$connectors" ] || return 1
  [[ "$connectors" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ERROR: MCP connectors must look like jira,github" >&2; return 1; }
  mkdir -p "${FXA_MCP_GATEWAY_DIR}/tokens" "${FXA_MCP_GATEWAY_DIR}/runs" || return 1
  tok="fxm_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  ( umask 077
    jq -n --arg r "$run" --arg c "$connectors" --argjson now "$(date +%s)" \
      --argjson ttl "${FXA_MCP_TOKEN_TTL:-86400}" --argjson cap "${FXA_MCP_RUN_CAP_CALLS:-200}" \
      '{run: $r, created: $now, expires: ($now + $ttl), connectors: ($c | split(",")), cap_calls: $cap, calls: 0}' \
      > "${FXA_MCP_GATEWAY_DIR}/tokens/${tok}.json" ) || return 1
  printf '%s\n' "$tok" > "$map"
  printf '%s\n' "$tok"
}

# mcp_token_revoke <run>   Expire the run's token. The file stays, with its count.
mcp_token_revoke() {
  local map="${FXA_MCP_GATEWAY_DIR}/runs/${1:-}" tok f
  tok="$(cat "$map" 2>/dev/null || true)"; rm -f "$map"
  f="${FXA_MCP_GATEWAY_DIR}/tokens/${tok}.json"
  [ -n "$tok" ] && [ -f "$f" ] && jq '.expires = 0' "$f" > "${f}.tmp" && mv -f "${f}.tmp" "$f"
  return 0
}

# mcp_auth_lines <run>   The exports a runner sources to reach the gateway, or
# nothing when there is no gateway or the run has no connectors.
mcp_auth_lines() {
  [ -n "${FXA_MCP_GATEWAY_URL:-}" ] && [ -n "${1:-}" ] || return 0
  # Set only by a Slack session's boot and turns, never from .env, so pipeline runs get no MCP.
  local tok; tok="$(mcp_token_for "$1" "${_FXA_SESSION_MCP:-}")" || return 0
  printf 'export FXA_MCP_URL=%s/mcp\nexport FXA_MCP_TOKEN=%s\n' "${FXA_MCP_GATEWAY_URL%/}" "$tok"
}

# The launch scripts write the runner's MCP config from those exports, outside
# /workspace so it can never be committed. No single quotes: this text lands in
# scripts written from double-quoted heredocs.
_MCP_LAUNCH_SNIPPET='FXA_MCP_CONFIG=""
if [ -n "${FXA_MCP_URL:-}" ] && [ -n "${FXA_MCP_TOKEN:-}" ]; then
  FXA_MCP_CONFIG=/home/agent/.fxa-mcp.json
  ( umask 077; printf "{\"mcpServers\":{\"fxa\":{\"type\":\"http\",\"url\":\"%s\",\"headers\":{\"Authorization\":\"Bearer %s\"}}}}\n" "$FXA_MCP_URL" "$FXA_MCP_TOKEN" > "$FXA_MCP_CONFIG" )
  # The gateway caps each answer (max_result_bytes); an answer under the cap arrives whole.
  export MAX_MCP_OUTPUT_TOKENS=40000
fi'
# --strict-mcp-config: the gateway is the only MCP server the agent gets.
_MCP_CLAUDE_FLAGS=' ${FXA_MCP_CONFIG:+--mcp-config "$FXA_MCP_CONFIG" --strict-mcp-config}'
