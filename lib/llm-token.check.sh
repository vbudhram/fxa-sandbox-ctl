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
check "the token has the proxy's form" "yes" "$([[ "$t1" =~ ^fxl_[A-Za-z0-9]{32}$ ]] && echo yes)"
check "another run gets another token" "no" "$([ "$(llm_token_for fxa-2)" = "$t1" ] && echo yes || echo no)"
check "the token file is private" "600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$tmp/tokens/$t1.json")"

ANTHROPIC_API_KEY=sk-real FXA_LLM_PROXY_URL=http://10.0.0.1:8788
line="$(_claude_auth_line fxa-1)"
check "the runner gets the proxy and its token" "export ANTHROPIC_BASE_URL=http://10.0.0.1:8788|export ANTHROPIC_API_KEY=$t1" "$(printf '%s' "$line" | paste -sd'|' -)"
check "never the real key" "no" "$(printf '%s' "$line" | grep -q sk-real && echo yes || echo no)"
check "no run name: the old key line" "export ANTHROPIC_API_KEY=sk-real" "$(_claude_auth_line)"

llm_token_revoke fxa-1
check "revoke expires the token and keeps its spend" "0 0" "$(jq -r '"\(.expires) \(.spent_usd)"' "$tmp/tokens/$t1.json")"
check "a revoked run gets a new token" "no" "$([ "$(llm_token_for fxa-1)" = "$t1" ] && echo yes || echo no)"
exit "$fail"
