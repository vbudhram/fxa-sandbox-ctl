#!/usr/bin/env bash
# PreToolUse hook for Bash on the runner: blocks two habits the guide forbids but agents
# keep: a sleep loop in the foreground (it cannot see the job die, so it runs to the
# 10-minute cap), and `pkill -f <pattern>` (the pattern also matches the agent's own
# shell, so the call kills itself: exit 144). Exit 2 sends the message to the agent.
in="$(cat)"
cmd="$(jq -r '.tool_input.command // ""' <<< "$in")"
[ "$(jq -r '.tool_input.run_in_background // false' <<< "$in")" = true ] && exit 0
# Not what runs here: the bodies of heredocs (a script written to a file).
sh="$(awk 'h { if ($0 ~ "^[[:space:]]*" h "[[:space:]]*$") h = ""; next }
  { print } match($0, /<<-?[[:space:]]*["\x27]?[A-Za-z_]+/) { h = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\x27]?/, "", h) }' <<< "$cmd")"

# A loop with no end but a condition (until, while), unless it runs in the background
# (a memory sampler, `done &`). A `for` loop has a bound, so it passes.
if grep -qE '(^|[;&|({[:space:]])(until|while)[[:space:]]' <<< "$sh" && grep -qE '(^|[^a-z_.-])sleep[[:space:]]' <<< "$sh" \
     && ! grep -qE 'done[[:space:]]*\)?[[:space:]]*&([^&]|$)' <<< "$sh" \
   || grep -qE '(^|[^a-z_.-])sleep[[:space:]]+([3-9][0-9]|[0-9]{3,})' <<< "$sh"; then
  cat >&2 <<'EOF'
Blocked: an until or while loop with sleep, or a sleep of 30 s or more. It cannot see the job die, so it waits until the timeout.
Wait on the job instead:
- a functional run: run.sh --bg <spec>, then `bash ~/.claude/skills/fxa-functional-local/run.sh wait`
- the stack: `bash ~/.claude/skills/fxa-stack/stack.sh wait <service>`, or `stack.sh restart <service> [KEY=VAL...]`, which waits
- any other background job: `timeout 570 tail --pid=<pid> -f /dev/null` (it returns when the job ends)
EOF
  exit 2
fi

if grep -qE "pkill[[:space:]]([^;&|]*[[:space:]])?-[a-zA-Z0-9]*f[a-zA-Z0-9]*[[:space:]]+(-[^[:space:]]+[[:space:]]+)*['\"]?[^['\"[:space:]-]" <<< "$sh"; then
  cat >&2 <<'EOF'
Blocked: `pkill -f <pattern>` also matches this command's own shell, so it kills itself (exit 144).
Bracket the first letter of the pattern: pkill -f '[p]laywright test' matches the process, not this shell.
EOF
  exit 2
fi
exit 0
