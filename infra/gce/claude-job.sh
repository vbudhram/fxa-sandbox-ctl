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
fi
claude -p --permission-mode auto --output-format json <<< "$input" > "$out"; rc=$?
jq -r '.result // empty' "$out" 2>/dev/null || cat "$out"
row="$(jq -c --arg job "$job" '{at: (now | todate), job: $job, cost_usd: (.total_cost_usd // null),
  turns: (.num_turns // null), duration_ms: (.duration_ms // null), is_error: (.is_error // false)}' "$out" 2>/dev/null)"
if [ -n "$row" ] && printf '%s\n' "$row" >> "${state}/job-costs.jsonl" 2>/dev/null; then
  ( source "$(dirname "$0")/../../lib/db.sh" && db_ingest job_costs "$row" )
else echo "WARN: could not record the ${job} cost" >&2; fi
exit "$rc"
