#!/usr/bin/env bash
# Offline check that a pass runs precheck in shell and calls Claude only for work.
#   bash lib/claude-job.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/infra/gce" "$tmp/bin" "$tmp/state" "$tmp/lib"
cp "$(dirname "$0")/../infra/gce/claude-job.sh" "$tmp/infra/gce/"
cp "$(dirname "$0")/mcp-token.sh" "$tmp/lib/"
export FXA_MCP_GATEWAY_DIR="$tmp/gw"
printf '#!/bin/sh\necho x >> %s/precheck-runs; cat %s/precheck-out\n' "$tmp" "$tmp" > "$tmp/fxa-sandbox-ctl"
printf '#!/bin/bash\ncat > %s/claude-in\necho "$*" > %s/claude-args\nfor ((i=1; i<=$#; i++)); do [ "${!i}" = --mcp-config ] && j=$((i+1)) && cp "${!j}" %s/claude-mcp; done\necho %s\n' "$tmp" "$tmp" "$tmp" "'{\"result\":\"did the pass\",\"total_cost_usd\":0.5}'" > "$tmp/bin/claude"
chmod +x "$tmp/fxa-sandbox-ctl" "$tmp/bin/claude"
echo "Invoke /fxa-ai-fixme." > "$tmp/prompt.txt"
run() { rm -f "$tmp/claude-in"; printf '%s\n' "$1" > "$tmp/precheck-out"
  PATH="$tmp/bin:$PATH" PIPE_STATE_DIR="$tmp/state" bash "$tmp/infra/gce/claude-job.sh" "${2:-pass}" "$tmp/prompt.txt"; }

check "a quiet pass prints the quiet line" "quiet: 3 queued" "$(run 'quiet: 3 queued')"
check "a quiet pass calls no model" "no" "$([ -e "$tmp/claude-in" ] && echo yes || echo no)"
check "a quiet pass records no cost" "0" "$(cat "$tmp/state/job-costs.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
run 'locked: another pass started 5s ago' >/dev/null; check "a locked pass calls no model" "no" "$([ -e "$tmp/claude-in" ] && echo yes || echo no)"
run 'paused: deploy' >/dev/null; check "a paused pass calls no model" "no" "$([ -e "$tmp/claude-in" ] && echo yes || echo no)"

check "a pass with work runs Claude" "did the pass" "$(run 'queue: FXA-1 new (run: ground FXA-1)')"
check "Claude gets the prompt and precheck's output" "Invoke /fxa-ai-fixme.|queue: FXA-1 new (run: ground FXA-1)|do not run precheck again" \
  "$(head -1 "$tmp/claude-in")|$(grep '^queue:' "$tmp/claude-in")|$(grep -o 'do not run precheck again' "$tmp/claude-in")"
check "the work pass records its cost" "pass 0.5" "$(tail -1 "$tmp/state/job-costs.jsonl" | jq -r '"\(.job) \(.cost_usd)"')"

: > "$tmp/precheck-runs"; run 'quiet' triage >/dev/null
check "triage does not run precheck" "0" "$(wc -l < "$tmp/precheck-runs" | tr -d ' ')"
check "triage gets the prompt only" "Invoke /fxa-ai-fixme." "$(cat "$tmp/claude-in")"

check "triage gets no MCP" "no" "$(grep -q -- --mcp-config "$tmp/claude-args" && echo yes || echo no)"

# A pass reads Figma and Bugzilla through the gateway: a token for those two, expired when the run ends.
rm -f "$tmp/claude-mcp"; run 'queue: FXA-2 new (run: ground FXA-2)' >/dev/null
tok="$(jq -r '.mcpServers.fxa.headers.Authorization' "$tmp/claude-mcp" 2>/dev/null | sed 's/^Bearer //')"
check "a pass gets the gateway, strict" "http://127.0.0.1:8789/mcp|yes" \
  "$(jq -r '.mcpServers.fxa.url' "$tmp/claude-mcp")|$(grep -q -- --strict-mcp-config "$tmp/claude-args" && echo yes || echo no)"
check "its token is figma and bugzilla only, and expired after the run" '["figma","bugzilla"]|true' \
  "$(jq -c .connectors "$tmp/gw/tokens/$tok.json")|$(jq '.expires <= now' "$tmp/gw/tokens/$tok.json")"
FXA_PASS_MCP_URL= run 'queue: FXA-3 new (run: ground FXA-3)' >/dev/null
check "an empty FXA_PASS_MCP_URL turns it off" "no" "$(grep -q -- --mcp-config "$tmp/claude-args" && echo yes || echo no)"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
