#!/usr/bin/env bash
# Offline check for per-run proxy tokens and the credential line a runner gets.
#   bash lib/llm-token.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FXA_LLM_PROXY_DIR="$tmp"; source "$(dirname "$0")/llm-token.sh"; source "$(dirname "$0")/mcp-token.sh"
eval "$(sed -n '/^_claude_auth_line() {/,/^}/p' "$(dirname "$0")/agent.sh")"

t1="$(llm_token_for fxa-1)"; t2="$(llm_token_for fxa-1)"
check "a run keeps one token" "$t1" "$t2"
# With SIGPIPE ignored (a GitHub runner, a systemd unit) the token still comes back, in seconds.
check "a token with SIGPIPE ignored" "yes" "$(FXA_LLM_PROXY_DIR="$tmp/sp" perl -e '$SIG{PIPE} = "IGNORE"; alarm 10; exec @ARGV' bash -c 'source "$1/llm-token.sh"; source "$1/mcp-token.sh"; llm_token_for sp-1; FXA_MCP_GATEWAY_DIR="$2" mcp_token_for sp-1 jira' _ "$(dirname "$0")" "$tmp/spg" 2>/dev/null | grep -cE '^fx[lm]_[A-Za-z0-9]{32}$' | sed 's/^2$/yes/')"
check "the token has the proxy's form" "yes" "$([[ "$t1" =~ ^fxl_[A-Za-z0-9]{32}$ ]] && echo yes)"
check "another run gets another token" "no" "$([ "$(llm_token_for fxa-2)" = "$t1" ] && echo yes || echo no)"
check "the token file is private" "600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$tmp/tokens/$t1.json")"

check "no thread: none in the token" "null" "$(jq -c .thread "$tmp/tokens/$t1.json")"
check "FXA_THREAD goes in the token" "C0AB12CD3:1791135361.015169" "$(jq -r .thread "$tmp/tokens/$(FXA_THREAD=C0AB12CD3:1791135361.015169 llm_token_for ask-ab12).json")"
session_get() { [ "$1:$2" = "agent-ab12:thread" ] && echo C0AB12CD3:1791135361.015169; }
check "a session's thread comes from its record" "C0AB12CD3:1791135361.015169" "$(jq -r .thread "$tmp/tokens/$(llm_token_for agent-ab12).json")"
unset -f session_get

ANTHROPIC_API_KEY=sk-real FXA_LLM_PROXY_URL=http://10.0.0.1:8788
line="$(_claude_auth_line fxa-1)"
check "the runner gets the proxy and its token" "export ANTHROPIC_BASE_URL=http://10.0.0.1:8788|export ANTHROPIC_API_KEY=$t1" "$(printf '%s' "$line" | paste -sd'|' -)"
check "never the real key" "no" "$(printf '%s' "$line" | grep -q sk-real && echo yes || echo no)"
check "no run name: the old key line" "export ANTHROPIC_API_KEY=sk-real" "$(_claude_auth_line)"

llm_token_revoke fxa-1
check "revoke expires the token and keeps its spend" "0 0" "$(jq -r '"\(.expires) \(.spent_usd)"' "$tmp/tokens/$t1.json")"
check "a revoked run gets a new token" "no" "$([ "$(llm_token_for fxa-1)" = "$t1" ] && echo yes || echo no)"
# The controller runs with set -euo pipefail: minting must not die of SIGPIPE when head stops tr.
check "a token mints under pipefail, called bare" "ok" "$(set -euo pipefail; tok=""; tok="$(llm_token_for fxa-pf1)"; llm_token_for fxa-pf2 >/dev/null; echo ok)"
# A GCE runner's deadline: vm_clone sets it; both tokens of the run end then, a run with none keeps 24 h.
FXA_MCP_GATEWAY_DIR="$tmp/gw"; now="$(date +%s)"; dl=$(( now + 6000 ))
tg="$(llm_token_for gce-1)"; mg="$(mcp_token_for gce-1 jira)"
run_tokens_deadline gce-1 "$dl"
check "the deadline moves the run's live LLM and MCP tokens" "$dl $dl" "$(jq -r .expires "$tmp/tokens/$tg.json") $(jq -r .expires "$tmp/gw/tokens/$mg.json")"
check "a run with no deadline keeps the 24 h default" "yes" "$(e="$(jq -r .expires "$tmp/tokens/$(llm_token_for fc-1).json")"; [ "$e" -ge $(( now + 86000 )) ] && echo yes)"
run_tokens_deadline gce-2 "$dl"
check "a token made after the deadline was set expires at it" "$dl $dl" "$(jq -r .expires "$tmp/tokens/$(llm_token_for gce-2).json") $(jq -r .expires "$tmp/gw/tokens/$(mcp_token_for gce-2 jira).json")"
dl2=$(( now + 9000 )); run_tokens_deadline gce-1 "$dl2"
check "a new runner for the run (a resume) moves the token on, same token" "$tg $dl2" "$(llm_token_for gce-1) $(jq -r .expires "$tmp/tokens/$tg.json")"
llm_token_revoke gce-1; run_tokens_deadline gce-1 "$dl2"
check "a revoked token stays revoked" "0" "$(jq -r .expires "$tmp/tokens/$tg.json")"
printf '%s\n' $(( now - 10 )) > "$tmp/runs/gce-3.deadline"
check "a past deadline is ignored" "yes" "$(e="$(jq -r .expires "$tmp/tokens/$(llm_token_for gce-3).json")"; [ "$e" -ge $(( now + 86000 )) ] && echo yes)"
exit "$fail"
