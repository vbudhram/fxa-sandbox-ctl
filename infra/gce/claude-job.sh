#!/bin/bash
# claude-job.sh <job> <prompt file>: one pass or triage run, as fxa-pass and
# fxa-triage start it. Prints Claude's reply for the journal, and appends the
# run's cost to job-costs.jsonl, which nothing else records.
set -uo pipefail
job="${1:?job name}" prompt="${2:?prompt file}"
state="${PIPE_STATE_DIR:-$HOME/.claude/state/fxa-ai-fixme}"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
claude -p --permission-mode auto --output-format json < "$prompt" > "$out"; rc=$?
jq -r '.result // empty' "$out" 2>/dev/null || cat "$out"
jq -c --arg job "$job" '{at: (now | todate), job: $job, cost_usd: (.total_cost_usd // null),
  turns: (.num_turns // null), duration_ms: (.duration_ms // null), is_error: (.is_error // false)}' "$out" \
  >> "${state}/job-costs.jsonl" 2>/dev/null || echo "WARN: could not record the ${job} cost" >&2
exit "$rc"
