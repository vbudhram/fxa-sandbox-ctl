#!/usr/bin/env bash
# Offline check for per-run MCP gateway tokens and the MCP config a runner writes.
#   bash lib/mcp-token.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FXA_MCP_GATEWAY_DIR="$tmp/gw"; FXA_LLM_PROXY_DIR="$tmp/llm"
source "$(dirname "$0")/llm-token.sh"; source "$(dirname "$0")/mcp-token.sh"
eval "$(sed -n '/^_claude_auth_line() {/,/^}/p' "$(dirname "$0")/agent.sh")"

check "no connectors: no token" "1" "$(mcp_token_for fxa-1 >/dev/null 2>&1; echo $?)"
check "a bad connector list is refused" "1" "$(mcp_token_for fxa-1 'jira;rm' >/dev/null 2>&1; echo $?)"
t1="$(mcp_token_for fxa-1 jira,github)"
check "the token has the gateway's form" "yes" "$([[ "$t1" =~ ^fxm_[A-Za-z0-9]{32}$ ]] && echo yes)"
check "it holds the connectors" '["jira","github"]' "$(jq -c .connectors "$tmp/gw/tokens/$t1.json")"
check "a later turn reuses it, whatever it asks" "$t1" "$(mcp_token_for fxa-1)"
check "the token file is private" "600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$tmp/gw/tokens/$t1.json")"

ANTHROPIC_API_KEY=sk-real
check "no gateway: the Claude line only" "export ANTHROPIC_API_KEY=sk-real" "$(_claude_auth_line fxa-1)"
FXA_MCP_GATEWAY_URL=http://10.0.0.2:8789/
check "with a gateway: its URL and the run's token" \
  "export ANTHROPIC_API_KEY=sk-real|export FXA_MCP_URL=http://10.0.0.2:8789/mcp|export FXA_MCP_TOKEN=$t1" \
  "$(_claude_auth_line fxa-1 | paste -sd'|' -)"
check "a run with no connectors gets no MCP lines" "export ANTHROPIC_API_KEY=sk-real" "$(_claude_auth_line fxa-2)"
check "a pipeline run gets none, even with connectors in .env" "export ANTHROPIC_API_KEY=sk-real" \
  "$(FXA_MCP_CONNECTORS=jira _claude_auth_line fxa-3)"
check "a session gets its own connectors" "jira" \
  "$(_FXA_SESSION_MCP=jira _claude_auth_line agent-s1 >/dev/null; jq -r '.connectors | join(",")' "$tmp/gw/tokens/$(cat "$tmp/gw/runs/agent-s1").json")"
check "a pipeline run gets the pipeline's connectors" "bugzilla" \
  "$(PIPE_MCP_CONNECTORS=bugzilla _claude_auth_line fxa-4 >/dev/null; jq -r '.connectors | join(",")' "$tmp/gw/tokens/$(cat "$tmp/gw/runs/fxa-4").json")"
check "a session with no connectors gets none of the pipeline's" "export ANTHROPIC_API_KEY=sk-real" \
  "$(_FXA_SESSION_MCP= PIPE_MCP_CONNECTORS=bugzilla _claude_auth_line agent-s2)"
check "no credential still fails" "1" "$(ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= _claude_auth_line fxa-1 >/dev/null; echo $?)"

# The launch snippet and flags, run as the runner would, with the config path moved into $tmp.
snippet="${_MCP_LAUNCH_SNIPPET//\/home\/agent/$tmp}"
out="$(FXA_MCP_URL=http://10.0.0.2:8789/mcp FXA_MCP_TOKEN="$t1" bash -c "$snippet
printf '%s\n' ${_MCP_CLAUDE_FLAGS}")"
check "the runner passes the config, strictly" "--mcp-config|$tmp/.fxa-mcp.json|--strict-mcp-config" "$(printf '%s' "$out" | paste -sd'|' -)"
check "the config is valid and points at the gateway" "http://10.0.0.2:8789/mcp Bearer $t1" \
  "$(jq -r '.mcpServers.fxa | "\(.url) \(.headers.Authorization)"' "$tmp/.fxa-mcp.json")"
check "the config is private" "600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$tmp/.fxa-mcp.json")"
check "no MCP exports: no flags" "" "$(bash -c "$snippet
printf '%s\n' ${_MCP_CLAUDE_FLAGS}")"
check "the snippet has no single quote" "no" "$(printf '%s%s' "$_MCP_LAUNCH_SNIPPET" "$_MCP_CLAUDE_FLAGS" | grep -q "'" && echo yes || echo no)"

mcp_token_revoke fxa-1
check "revoke expires the token and keeps its count" "0 0" "$(jq -r '"\(.expires) \(.calls)"' "$tmp/gw/tokens/$t1.json")"
check "a revoked run gets no MCP lines without connectors" "" "$(mcp_auth_lines fxa-1)"
exit "$fail"
