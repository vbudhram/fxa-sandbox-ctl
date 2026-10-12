#!/bin/bash
# claude-job.sh <job> <prompt file>: one pass or triage run, as fxa-pass and
# fxa-triage start it. Prints Claude's reply for the journal, and appends the
# run's cost to job-costs.jsonl, which nothing else records.
set -uo pipefail
job="${1:?job name}" prompt="${2:?prompt file}"
state="${PIPE_STATE_DIR:-$HOME/.claude/state/fxa-ai-fixme}"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
# A pass runs precheck in shell first: a quiet pass then costs no model turn.
# Claude gets precheck's output and must not run it again: a second run would
# not report review comments the first one already marked as noted.
input="$(cat "$prompt")"
if [ "$job" = pass ]; then
  pre="$("$(dirname "$0")/../../fxa-sandbox-ctl" precheck 2>&1)"
  case "$pre" in quiet*|locked*|paused*) printf '%s\n' "$pre" | head -1; exit 0 ;; esac
  input="${input}

precheck already ran for this pass. Its output is below; do not run precheck again.
<precheck>
${pre}
</precheck>"
  # A pass that may launch or must judge (queue, reconcile, feedback lines) keeps the default model
  # (Opus): the launch-or-skip call and the grounding need it. One that can only report (drain and
  # reap lines) runs on FXA_PASS_REPORT_MODEL; empty keeps the default for those too.
  if ! printf '%s\n' "$pre" | grep -qE '^(queue|reconcile|feedback):'; then
    report_model="${FXA_PASS_REPORT_MODEL-claude-sonnet-5-5}"
  fi
fi
model=(); [ -n "${report_model:-}" ] && model=(--model "$report_model")
# A pass reads a ticket's Figma design and Bugzilla bugs through the MCP gateway on this host,
# which holds the Runlayer credential: a token for this run, those two only, expired when the run ends.
run="${job}-$(date +%s)"
mcp=() url="${FXA_PASS_MCP_URL-http://127.0.0.1:8789}"  # set it empty to turn this off
if [ "$job" = pass ] && [ -n "$url" ]; then
  if tok="$(source "$(dirname "$0")/../../lib/mcp-token.sh" && FXA_MCP_TOKEN_TTL=3600 mcp_token_for "$run" figma,bugzilla)"; then
    cfg="$(mktemp)"; trap 'rm -f "$out" "$cfg"; (source "$(dirname "$0")/../../lib/mcp-token.sh" && mcp_token_revoke "$run")' EXIT
    printf '{"mcpServers":{"fxa":{"type":"http","url":"%s/mcp","headers":{"Authorization":"Bearer %s"}}}}\n' \
      "$url" "$tok" > "$cfg"
    # --strict-mcp-config: the gateway only, not the unauthenticated plugin servers.
    mcp=(--mcp-config "$cfg" --strict-mcp-config)
  else echo "WARN: no MCP gateway token; this pass cannot read Figma or Bugzilla" >&2; fi
fi
# Through the LLM proxy, as sessions are: a token for this run, capped and revoked at the end, so the
# proxy logs and prices each call. No token (no proxy): the API key, as before.
llm=()
if [ -n "${FXA_LLM_PROXY_URL:-}" ]; then
  if tok="$(source "$(dirname "$0")/../../lib/llm-token.sh" && FXA_LLM_TOKEN_TTL=10800 FXA_LLM_RUN_CAP_USD="${FXA_PASS_CAP_USD:-10}" llm_token_for "$run")"; then
    llm=(ANTHROPIC_BASE_URL="$FXA_LLM_PROXY_URL" ANTHROPIC_API_KEY="$tok")
  else echo "WARN: no LLM proxy token; this ${job} uses the API key directly" >&2; fi
fi
env ${llm[@]+"${llm[@]}"} claude -p --permission-mode auto --output-format json ${model[@]+"${model[@]}"} ${mcp[@]+"${mcp[@]}"} <<< "$input" > "$out"; rc=$?
[ ${#llm[@]} -eq 0 ] || ( source "$(dirname "$0")/../../lib/llm-token.sh" && llm_token_revoke "$run" )
jq -r '.result // empty' "$out" 2>/dev/null || cat "$out"
row="$(jq -c --arg job "$job" --arg run "$run" '{at: (now | todate), job: $job, run: $run, cost_usd: (.total_cost_usd // null), models: ((.modelUsage // {}) | keys),
  turns: (.num_turns // null), duration_ms: (.duration_ms // null), is_error: (.is_error // false)}' "$out" 2>/dev/null)"
if [ -n "$row" ] && printf '%s\n' "$row" >> "${state}/job-costs.jsonl" 2>/dev/null; then
  ( source "$(dirname "$0")/../../lib/db.sh" && db_ingest job_costs "$row" )
else echo "WARN: could not record the ${job} cost" >&2; fi
exit "$rc"
