#!/usr/bin/env bash
# Offline check for a mid-turn steer: the text goes to .fxa-steer/ from stdin and is queued after the turn only if unshown, a non-admin
# takes the admin role and the CI grant from the running turn, and the fxa-steer hook shows each file once.
#   bash lib/session-steer.check.sh
source "$(dirname "$0")/session-check-head.sh"
ws="$tmp/ws"; mkdir -p "$ws"
# The runner, here: the script runs on this host, with /workspace pointed at a scratch folder.
_session_sh_in() { echo called >> "$tmp/sh"; bash -c "${4//\/workspace/$ws}" | head -c "$3"; }
hook() { bash -c "$(sed "s#/workspace#$ws#g" "$(dirname "$0")/../hooks/fxa-steer.sh")"; }
k=agent-steer1; q="$SESSION_DIR/$k.queue"
new() { printf '{"key":"%s","state":"active","runtime":"%s","turn_open":"1","turn_admin":"1","turn_asker":"Ana","ci_ok":"1"}\n' "$k" "$1" > "$SESSION_DIR/$k.json"; rm -rf "$q" "$ws/.fxa-steer" "$tmp/sh" "$SESSION_DIR/$k".steer-*; }

new claude
msg="stop, wrong file \$(touch pwned)'\""; printf '%s\n' "$msg" > "$tmp/m"
out="$(cd "$ws" && cmd_steer $k --message-file "$tmp/m" --from-name Bo)"
check "mid-turn: the text is put for the hook, word for word, and nothing ran from it" "1|$msg|no" \
  "$(ls "$ws/.fxa-steer" | grep -c '\.txt$')|$(cat "$ws"/.fxa-steer/*.txt)|$([ -e "$ws/pwned" ] && echo yes || echo no)"
check "the text is not queued, the host keeps a copy, and the bot still sees queued" "no|$msg|$k queued (shown mid-turn)" \
  "$([ -e "$q" ] && echo yes || echo no)|$(cat "$SESSION_DIR/$k".steer-*)|$out"
check "a non-admin's words take the admin role and the CI grant from the running turn" "0|Bo|" \
  "$(session_get $k turn_admin)|$(session_get $k turn_asker)|$(session_get $k ci_ok)"
check "the next turn from the queue has no admin either" "0" "$(asks_from_queue $k; session_get $k turn_admin)"
check "after the turn, a message the hook did not show goes to the queue once" "$msg||0" \
  "$(_session_steer_unshown $k > "$tmp/u"; head -1 "$tmp/u")|$(_session_steer_unshown $k)|$(ls "$SESSION_DIR/$k".steer-* 2>/dev/null | wc -l | tr -d ' ')"
cmd_steer $k --message-file "$tmp/m" --from-name Bo >/dev/null; echo '{}' | hook >/dev/null
check "a message the hook showed is not sent again" "|0" \
  "$(_session_steer_unshown $k)|$(ls "$SESSION_DIR/$k".steer-* 2>/dev/null | wc -l | tr -d ' ')"
cmd_steer $k --message-file "$tmp/m" --from-name Bo >/dev/null; echo '{}' | hook >/dev/null
_session_sh_in() { return 255; }
check "a runner that cannot be reached gets the message again" "$msg" "$(_session_steer_unshown $k > "$tmp/u"; head -1 "$tmp/u")"
_session_sh_in() { echo called >> "$tmp/sh"; bash -c "${4//\/workspace/$ws}" | head -c "$3"; }

new claude
cmd_steer $k --message-file "$tmp/m" --from-name Cy --ci-ok >/dev/null
check "an admin's mid-turn words keep the role and the grant" "1|Ana|1" \
  "$(session_get $k turn_admin)|$(session_get $k turn_asker)|$(session_get $k ci_ok)"

new codex
out="$(cmd_steer $k --message-file "$tmp/m" --from-name Bo)"
check "Codex has no hook: queued only, no runner call, the turn keeps its role" "$k queued|no|1|$msg" \
  "$out|$([ -e "$tmp/sh" ] && echo yes || echo no)|$(session_get $k turn_admin)|$(head -1 "$q")"

new claude; _session_sh_in() { return 255; }
out="$(cmd_steer $k --message-file "$tmp/m" --from-name Bo)"
check "the runner cannot be reached: queued with no mark, and the role is lowered anyway" "$k queued|$msg|0" \
  "$out|$(head -1 "$q")|$(session_get $k turn_admin)"
_session_sh_in() { echo called >> "$tmp/sh"; bash -c "${4//\/workspace/$ws}" | head -c "$3"; }

session_set $k turn_open 0 state starting; rm -f "$tmp/sh"
cmd_steer $k --message-file "$tmp/m" --from-name Bo >/dev/null
check "a session that boots gets no file" "no" "$([ -e "$tmp/sh" ] && echo yes || echo no)"

# The hook on the runner.
new claude; mkdir -p "$ws/.fxa-steer"; printf 'first\n' > "$ws/.fxa-steer/1-a.txt"; printf 'second\n' > "$ws/.fxa-steer/2-b.txt"
printf 'half' > "$ws/.fxa-steer/.3-c"
check "a subagent's tool call leaves the files for the main agent" "|2" \
  "$(echo '{"hook_event_name":"PostToolUse","agent_id":"a1"}' | hook)|$(ls "$ws/.fxa-steer" | grep -c '\.txt$')"
out="$(echo '{"hook_event_name":"PostToolUseFailure","tool_response":"x"}' | hook)"
check "the main agent gets each message in order, as context of the event that ran" "PostToolUseFailure|first|second|1" \
  "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out")|$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out" | grep -v '^(Host' | grep . | paste -sd'|' -)|$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out" | grep -c '^(Host: a message from the thread')"
check "each file is shown once, and a half-written one is not read" "|.3-c" \
  "$(echo '{"hook_event_name":"PostToolUse"}' | hook)|$(ls -A "$ws/.fxa-steer" | paste -sd' ' -)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
