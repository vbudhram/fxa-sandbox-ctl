#!/bin/bash
# mcp-token.sh: per-run tokens for fxa-mcp-gateway (infra/mcp-gateway/gateway.py).
# With FXA_MCP_GATEWAY_URL set and connectors asked for, a runner holds one of
# these; the gateway holds the upstream credentials and serves read-only tools.
[ -n "${_FXA_MCP_TOKEN_LOADED:-}" ] && return 0
_FXA_MCP_TOKEN_LOADED=1
FXA_MCP_GATEWAY_DIR="${FXA_MCP_GATEWAY_DIR:-$HOME/.claude/state/mcp-gateway}"

# mcp_ci_only <connectors>   The CI connectors of the list, the only ones a pipeline run, fix round or
# dependency fix run gets: their context holds untrusted text, so no jira, slack or github (PR comments).
mcp_ci_only() { tr ',' '\n' <<< "${1:-}" | grep -xE 'github-ci|circleci' | paste -sd, - || true; }
# mcp_investigate_only <connectors>   The read-only set of an investigation run: no slack, figma or other write path
# for the untrusted ticket text to steer. A team with no PIPE_MCP gets the whole set.
mcp_investigate_only() { tr ',' '\n' <<< "${1:-}" | grep -xE 'jira|github|github-ci|circleci|sentry|bugzilla' | paste -sd, - || true; }

# mcp_token_for <run> [connectors]   The run's token. The first call makes it
# with the comma-separated connectors; later calls (a session's next turn)
# reuse it while they ask for the same list or none. Another list revokes it
# and makes a new one, so a crashed run's token never lends its connectors.
# Fails, printing nothing, when the run has no token and asks for no connectors.
# With _FXA_MCP_WORK_ONLY set (a pipeline run), the token reads only the work-role repos.
mcp_token_for() {
  local run="$1" connectors="${2:-}" map tok
  [[ "$run" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: bad run name for a token" >&2; return 1; }
  map="${FXA_MCP_GATEWAY_DIR}/runs/${run}"
  tok="$(cat "$map" 2>/dev/null || true)"
  # A GCE runner's deadline (llm-token.sh run_tokens_deadline); claude-job.sh loads only this file.
  local dl; dl="$(tr -dc 0-9 2>/dev/null < "${map}.deadline" || true)"; [ -n "$dl" ] && [ "$dl" -gt "$(date +%s)" ] || dl=""
  local f="${FXA_MCP_GATEWAY_DIR}/tokens/${tok}.json"
  if [ -n "$tok" ] && [ -n "$connectors" ] && ! jq -e --arg c "$connectors" '(.connectors | join(",")) == $c' "$f" >/dev/null 2>&1; then
    mcp_token_revoke "$run"; tok=""
  fi
  if [ -n "$tok" ] && jq -e '.expires > now' "$f" >/dev/null 2>&1; then
    [ -z "$dl" ] || { jq --argjson e "$dl" '.expires = $e' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"; }
    printf '%s\n' "$tok"; return 0
  fi
  [ -n "$connectors" ] || return 1
  [[ "$connectors" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ERROR: MCP connectors must look like jira,github" >&2; return 1; }
  mkdir -p "${FXA_MCP_GATEWAY_DIR}/tokens" "${FXA_MCP_GATEWAY_DIR}/runs" || return 1
  # A bounded read: with SIGPIPE ignored (a GitHub runner, a systemd unit) BSD tr on an endless stream never stops.
  tok="fxm_$(head -c 96 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
  # A team reads its own repos, FxA too, and another team its own Jira project (the gateway's team_rules).
  # FxA keeps its Jira rules as written; a team with no project keeps FxA's, by design (PRODUCT.md, decisions taken).
  local projects="" repos="" row
  [ "${PIPE_PROFILE:-fxa}" = fxa ] || projects="${PIPE_JIRA_PROJECT:-}"
  for row in ${PIPE_REPOS[@]+"${PIPE_REPOS[@]}"}; do
    # A pipeline run writes PR text on its work repos, so it never reads a more private dependency's CI.
    [ -z "${_FXA_MCP_WORK_ONLY:-}" ] || [ "$(awk '{print $3}' <<< "$row")" = work ] || continue
    repos="${repos} ${row%% *}"
  done
  [ -n "$repos" ] || repos="${PIPE_REPO_SLUG:-}"
  local chans=""; [ "${PIPE_PROFILE:-fxa}" = fxa ] || chans="${PIPE_SLACK_CHANNELS:-}"
  ( umask 077
    jq -n --arg r "$run" --arg c "$connectors" --argjson now "$(date +%s)" \
      --argjson ttl "${FXA_MCP_TOKEN_TTL:-86400}" --argjson cap "${FXA_MCP_RUN_CAP_CALLS:-200}" \
      --arg p "$projects" --arg rp "$repos" --arg ch "$chans" --argjson dl "${dl:-0}" \
      '{run: $r, created: $now, expires: (if $dl > 0 then $dl else $now + $ttl end), connectors: ($c | split(",")), cap_calls: $cap, calls: 0}
       + (if ($p + $rp | gsub(" "; "")) != "" then {scope: {jira_projects: ($p | split(" ") | map(select(. != ""))), repos: ($rp | split(" ") | map(select(. != "")))}} else {} end)
       | if ($ch | gsub(" "; "")) != "" then .scope = ((.scope // {}) + {slack_channels: ($ch | split(" ") | map(select(. != "")))}) else . end' \
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
  # Set by a Slack session's boot and turns, and by a pipeline or fix run to its CI connectors (mcp_ci_only); never from .env.
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
  export MAX_MCP_OUTPUT_TOKENS=50000
fi'
# --strict-mcp-config: the gateway is the only MCP server the agent gets.
_MCP_CLAUDE_FLAGS=' ${FXA_MCP_CONFIG:+--mcp-config "$FXA_MCP_CONFIG" --strict-mcp-config}'
# Only the built-in tools runs call: the 12 others no run called cost about 12k tokens in every call (ai/docs/510).
# The first turn and each resume pass the same list, or the cached prefix changes.
_CLAUDE_TOOLS_FLAG=' --tools Bash,Read,Edit,Write,Agent,Skill,Monitor,TaskStop,WebFetch,SendMessage,ToolSearch'
