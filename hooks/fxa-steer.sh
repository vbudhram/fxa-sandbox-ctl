#!/usr/bin/env bash
# PostToolUse hook on the runner: shows the main agent each message that the host put in /workspace/.fxa-steer/
# while its turn runs (cmd_steer). The host also queues each message for the next turn, so this hook only makes
# it sooner: a file it misses, or a hook the agent turns off, loses nothing.
in="$(cat)"
# A subagent's tool call: the message is for the main agent, so the file waits for its next tool call.
[ -z "$(jq -r '.agent_id // ""' <<< "$in" 2>/dev/null)" ] || exit 0
ev="$(jq -r '.hook_event_name // ""' <<< "$in" 2>/dev/null)"
[ "$ev" = PostToolUseFailure ] || ev=PostToolUse
t=""
for f in /workspace/.fxa-steer/*.txt; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  # Two tool calls can end at once: the rename gives each file to one hook only.
  mv "$f" "$f.shown" 2>/dev/null || continue
  t="${t}$(head -c 16384 "$f.shown")"$'\n\n'
  rm -f "$f.shown"
done
[ -n "$t" ] || exit 0
jq -nc --arg e "$ev" --arg t "(Host: a message from the thread arrived while you work. Read it now: it can change your next step. The host sends it again after this turn, marked as already shown.)

${t}" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $t}}'
