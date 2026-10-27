#!/usr/bin/env bash
# telemetry_merge_comment: the merged comment is a success panel with time, cost at list price and models.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^telemetry_merge_comment() {/,/^}/p' "$here/telemetry.sh")"
pipeline_require() { :; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
PIPE_STATE_DIR="$t" PIPE_RUNS_FILE="$t/runs.jsonl"
f=0
check() { [ "$2" = "$3" ] || { printf 'FAIL %s:\nwant [%s]\ngot  [%s]\n' "$1" "$2" "$3"; f=1; }; }
row='{"issue":"FXA-1","recorded_at":1,"kind":"fix","wall_seconds":600,"cost_usd":5.88,"model":"claude-opus-5-5","input":1,"output":2,"cache_write":3,"cache_read":4}'
printf '%s\n' "$row" > "$PIPE_RUNS_FILE"
check "one run: the time, the tokens, the cost" "::success
**Merged** · [PR #1](https://github.com/o/r/pull/1)
- Agent time: 10m in 1 run
- Tokens: in 1, out 2, cache write 3, cache read 4
- Cost: \$5.88 at Anthropic list prices. Models: claude-opus-5-5
- The rate that Mozilla pays can be lower." "$(telemetry_merge_comment FXA-1 https://github.com/o/r/pull/1)"
printf '%s\n' '{"issue":"FXA-1","recorded_at":2,"kind":"feedback","wall_seconds":300,"model":"claude-opus-5-5","source":"assistant-sum"}' >> "$PIPE_RUNS_FILE"
printf 'x FXA-1\nx FXA-1\nx FXA-1\n' > "$t/launches.log"
check "two runs: the rounds by kind, a run with no price says so, the undercount note, launches over runs" "::success
**Merged**
- Agent time: 15m in 2 runs: 1 fix, 1 review round (3 launched, 2 recorded)
- Tokens: in 1, out 2, cache write 3, cache read 4
- Cost: \$5.88 at Anthropic list prices, with no price for 1 of the runs. Models: claude-opus-5-5
- The rate that Mozilla pays can be lower. The real cost can be higher: the stream log does not count all output tokens for 1 of the runs." "$(telemetry_merge_comment FXA-1 '')"
printf '%s\n' '{"issue":"FXA-3","recorded_at":1,"kind":"fix","wall_seconds":60,"model":"m"}' >> "$PIPE_RUNS_FILE"
check "one run with no price shows no \$0" "- Cost: no price recorded. Models: m" "$(telemetry_merge_comment FXA-3 '' | grep '^- Cost')"
check "no row for the ticket: launches and the no-telemetry note" "::success
**Merged** · [PR #9](https://github.com/o/r/pull/9)
- Agent launches: 0
- No run telemetry was recorded for this ticket." "$(telemetry_merge_comment FXA-2 https://github.com/o/r/pull/9)"
: > "$PIPE_RUNS_FILE"
check "no run log: the same note from the shell branch" "::success
**Merged** · [PR #9](https://github.com/o/r/pull/9)
- Agent launches: 3
- No run telemetry was recorded for this ticket." "$(telemetry_merge_comment FXA-1 https://github.com/o/r/pull/9)"
[ "$f" = 0 ] && echo "merge-comment.check: ok"
exit "$f"
