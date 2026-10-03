#!/usr/bin/env bash
# eval.sh: run one eval through the dev bot end to end, then have a judge model score it.
#
#   eval.sh <evals/name.json>                  run it, then judge it
#   eval.sh <evals/name.json> --judge <dir>    judge a saved run again
#
# The run: pin the dev bot's new sessions to the spec's base (newer refs hidden), post
# the prompt in the test channel, answer each question with the spec's answer, then save
# the thread, the report, the diff and the agent's commands, stop the session, unpin.
# The judge (FXA_EVAL_JUDGE, default claude-fable-5-1) scores it against the rubric and
# the reference fix. Results: ai/evals/<time>-<name>/ (local only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/skills/fxa-manager/vm.sh" D="$ROOT/skills/fxa-ctl-dev/slack-drive.sh"
spec="${1:?usage: eval.sh <evals/name.json> [--judge <run dir>]}"
s() { jq -r "$1" "$spec"; }
name="$(s .name)" base="$(s .base)" fix="$(s .fix)"
FXA="${FXA_CLONE:-$ROOT/../fxa}" JUDGE="${FXA_EVAL_JUDGE:-claude-fable-5-1}"

run() {
  out="$ROOT/ai/evals/$(date +%Y%m%d-%H%M)-$name"; mkdir -p "$out"; cp "$spec" "$out/spec.json"
  echo "== pinning the dev bot to ${base:0:10}"
  FXA_SESSION_BASE_SHA="$base" bash "$H" dev | tail -1
  trap 'echo "== unpinning the dev bot"; bash "$H" dev | tail -1' EXIT
  local ts n=0
  ts="$("$D" start "$(s .prompt)")"; echo "$ts" > "$out/thread_ts"; echo "== thread $ts"
  while :; do
    "$D" wait "$ts" "$(s '.turn_seconds // 2700')" > "$out/thread.txt"
    tail -4 "$out/thread.txt"
    # A question ends the turn with numbered option buttons on the bot's last message.
    if tail -3 "$out/thread.txt" | grep -q '^    buttons: \[1\]' && [ "$n" -lt "$(s '.max_replies // 3')" ]; then
      n=$((n + 1)); echo "== answering question $n"; "$D" reply "$ts" "$(s .answer)" >/dev/null
    else break; fi
  done
  bash "$H" dev report "$ts" > "$out/report.txt" 2>&1 || true
  local key; key="$(sed -n 's/^# \(agent-[0-9a-z]*\)$/\1/p' "$out/report.txt" | head -1)"
  [ -n "$key" ] || { echo "eval: no session for thread $ts" >&2; return 1; }
  echo "$key" > "$out/key"
  bash "$H" dev ctl diff "$key" > "$out/diff.patch" 2>/dev/null || true
  bash "$H" dev ctl stop "$key" >/dev/null 2>&1 || true
  # Every tool call of the main agent and its subagents, from the saved transcripts: one line each.
  bash "$H" run "t=\$(mktemp -d); tar xzf ~/.claude/state/agent-sessions-dev/${key}.claude.tgz -C \$t 2>/dev/null; find \$t -name '*.jsonl' -exec cat {} + | jq -r 'select(.type == \"assistant\") | .message.content[]? | select(.type == \"tool_use\") | \"\\(.name): \\(.input.command // .input.file_path // .input.pattern // .input.description // \"\" | tostring | gsub(\"\\n\"; \" \") | .[0:300])\"' 2>/dev/null; rm -rf \$t" > "$out/commands.txt" 2>/dev/null || true
  echo "== saved to $out ($(wc -l < "$out/commands.txt" | tr -d ' ') commands, $(grep -c '^diff --git' "$out/diff.patch" || true) files changed)"
}

judge() {
  local p="$out/judge-prompt.md" ref
  # shellcheck disable=SC2046
  ref="$(git -C "$FXA" show --format='%s%n%n%b' "$fix" -- $(jq -r '.fix_paths[]' "$spec"))"
  {
    echo "You grade one run of a coding agent. A person asked it, in Slack, to do a task on the repo at commit ${base}."
    echo "A reference fix from the real history is below. The agent never saw it. Grade what the agent did against the rubric."
    echo "Give credit for a different fix that solves the same problem as well. Base every score on the evidence below, not on what the agent claims."
    echo "Also say whether the agent looked past its base commit: a git fetch, a log of other branches, a lookup of a pull request, reading git objects directly. That would make the run invalid."
    echo
    echo "Reply with only one JSON object: {\"scores\": {<rubric id>: <integer>}, \"total\": <integer>, \"max\": <integer>, \"looked_past_base\": <true|false>, \"notes\": {<rubric id>: <one sentence>}, \"summary\": <two sentences>}"
    echo; echo "## The task"; s .prompt
    echo; echo "## Rubric"; jq -r '.rubric[] | "- \(.id) (0 to \(.max)): \(.text)"' "$spec"
    echo; echo "## Reference fix"; echo '```'; echo "$ref"; echo '```'
    echo; echo "## The agent's diff"; echo '```diff'; head -c 60000 "$out/diff.patch"; echo '```'
    echo; echo "## The Slack thread (the bot's messages are the agent's replies)"; echo '```'; head -c 30000 "$out/thread.txt"; echo '```'
    echo; echo "## The agent's tool calls, in order"; echo '```'; head -c 40000 "$out/commands.txt"; echo '```'
    echo; echo "## The session report"; echo '```'; head -c 15000 "$out/report.txt"; echo '```'
  } > "$p"
  echo "== judging with $JUDGE"
  # An empty folder and no settings: the judge reads only the prompt.
  local t; t="$(mktemp -d)"
  ( cd "$t" && claude -p --model "$JUDGE" --output-format json --setting-sources project < "$p" ) > "$out/judge-raw.json"
  rm -rf "$t"
  jq -r .result "$out/judge-raw.json" | sed -n '/^[[:space:]]*{/,/}[[:space:]]*$/p' | jq . > "$out/judge.json"
  jq -r '"score \(.total)/\(.max)\(if .looked_past_base then "  (INVALID: looked past the base)" else "" end)", (.scores | to_entries[] | "  \(.key): \(.value)"), "", .summary' "$out/judge.json"
}

if [ "${2:-}" = --judge ]; then out="${3:?usage: eval.sh <spec> --judge <run dir>}"; else run; fi
judge
