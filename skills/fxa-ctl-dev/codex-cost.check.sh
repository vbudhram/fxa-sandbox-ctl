#!/usr/bin/env bash
# codex-cost.check.sh: the Codex cost line against hand-worked numbers.
set -uo pipefail
cd "$(dirname "$0")/../.."
t="$(mktemp -d "${TMPDIR:-/tmp}/codex-cost.XXXXXX")"; trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }; bad() { echo "FAIL $1: $2"; }
cost() { jq -rs --arg m "$1" --slurpfile p "$t/prices.json" -f skills/fxa-ctl-dev/codex-cost.jq "$t/events.jsonl"; }
echo '{"as_of":"x","models":{"m":{"input":10,"cached_input":1,"cache_write":12.5,"output":50}}}' > "$t/prices.json"
# Two turns: 1.2M in (1M cached, 100K cache writes), 20K out.
# (100K x 10 + 1M x 1 + 100K x 12.5 + 20K x 50) / 1M = 1 + 1 + 1.25 + 1 = 4.25
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":600000,"cached_input_tokens":500000,"cache_write_input_tokens":50000,"output_tokens":10000,"reasoning_output_tokens":100}}' \
  '{"type":"item.completed","item":{}}' \
  '{"type":"turn.completed","usage":{"input_tokens":600000,"cached_input_tokens":500000,"cache_write_input_tokens":50000,"output_tokens":10000}}' > "$t/events.jsonl"
r="$(cost m)"; case "$r" in *'$4.25 at API rates'*) ok "turns add up, each kind at its rate" ;; *) bad "cost" "$r" ;; esac
r="$(cost other)"; case "$r" in *'no price for this model'*) ok "an unknown model gets no made-up price" ;; *) bad "unknown" "$r" ;; esac
: > "$t/events.jsonl"; r="$(cost m)"; case "$r" in *'0 in'*'$0 at API rates'*) ok "no turn: zero, not an error" ;; *) bad "empty" "$r" ;; esac
