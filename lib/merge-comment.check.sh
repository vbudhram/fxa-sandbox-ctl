#!/usr/bin/env bash
# telemetry_merge_comment: the cost summary on a merged ticket ends with the list-price note.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^telemetry_merge_comment() {/,/^}/p' "$here/telemetry.sh")"
pipeline_require() { :; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
PIPE_STATE_DIR="$t" PIPE_RUNS_FILE="$t/runs.jsonl"
printf '%s\n' '{"issue":"FXA-1","recorded_at":1,"kind":"fix","wall_seconds":600,"cost_usd":5.88,"model":"claude-opus-5-5","input":1,"output":2,"cache_write":3,"cache_read":4}' > "$PIPE_RUNS_FILE"
out="$(telemetry_merge_comment FXA-1 https://example.com/pr/1)"
f=0
grep -q 'Estimated API cost at list price: \$5.88' <<< "$out" || { echo "FAIL: no cost line"; f=1; }
[ "$(tail -1 <<< "$out")" = "Note: these costs use Anthropic list prices with the token counts from the API. The rate that Mozilla pays can be lower." ] \
  || { echo "FAIL: the last line is not the list-price note: $(tail -1 <<< "$out")"; f=1; }
: > "$PIPE_RUNS_FILE"
grep -q 'Note:' <<< "$(telemetry_merge_comment FXA-1 '')" && { echo "FAIL: the note shows with no cost"; f=1; }
[ "$f" = 0 ] && echo "merge-comment.check: ok"
exit "$f"
