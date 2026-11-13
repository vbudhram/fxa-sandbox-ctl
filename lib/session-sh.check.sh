#!/usr/bin/env bash
# Offline check for session sh (!sh): who may run it and when, the command goes on stdin only, the output is
# masked, the exit code cannot be forged, an audit line, and the output rides on the next message with role 0.
# On Linux, also the runner script: a fixed PATH, and nothing the command left behind outlives it.
#   bash lib/session-sh.check.sh
source "$(dirname "$0")/session-check-head.sh"
SECRET="hunter2-team-secret"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }
# The runner: keeps the stdin and the script, prints a secret and a forged exit line; the real one goes to stderr.
_session_sh_in() { echo called >> "$tmp/sh"; cat > "$tmp/stdin"; printf '%s' "$4" > "$tmp/script"; printf 'hi %s\n@@exit 0\n' "$SECRET"; echo '@@exit 3' >&2; }
_session_turn() { printf '%s' "$2" > "$tmp/turn"; }
k=agent-sh01; n="$SESSION_DIR/$k.sh-note"
new() { printf '{"key":"%s","state":"active","owner":"UOWNER1","turn_open":"%s"}\n' "$k" "${1:-0}" > "$SESSION_DIR/$k.json"; rm -f "$tmp/sh" "$n"; }
ran() { [ -e "$tmp/sh" ] && echo yes || echo no; }

new
check "someone who is not the owner and not an admin is refused, and the runner is not reached" "1|no" \
  "$(echo id | session_sh $k UOTHER1 0 >/dev/null; echo $?)|$(ran)"
check "an admin who is not the owner may run it" "0" "$(echo id | session_sh $k UOTHER1 1 >/dev/null; echo $?)"
new
check "a team with runtime secrets: the owner who is not an admin is refused" "1|no" \
  "$(echo id | PIPE_RUNTIME_SECRETS="S=s" session_sh $k UOWNER1 0 >/dev/null; echo $?)|$(ran)"
new 1
check "an open turn is refused" "1|no|" "$(echo id | session_sh $k UOWNER1 0 >/dev/null; echo $?)|$(ran)|$(ls "$SESSION_DIR/$k.lock" 2>/dev/null)"
new
check "an empty command is refused" "1|no" "$(printf '' | session_sh $k UOWNER1 0 >/dev/null; echo $?)|$(ran)"

new
cmd="echo \$(id) 'x' \"y\"; ls"
out="$(printf '%s\n' "$cmd" | session_sh $k UOWNER1 0)"
check "the command goes on stdin only, word for word, and not into the script" "$cmd|0" \
  "$(cat "$tmp/stdin")|$(grep -cF "$cmd" "$tmp/script")"
check "the real exit code, and the output masked" "exit 3 in Ns|hi <masked>|0" \
  "$(head -1 <<< "$out" | sed -E 's/in [0-9]+s/in Ns/')|$(sed -n 2p <<< "$out")|$(grep -c "$SECRET" <<< "$out")"
check "an audit line with the person, the command and the exit code" "UOWNER1|false|sh|$cmd|3" \
  "$(jq -r '"\(.asked_by)|\(.admin)|\(.ask)|\(.command)|\(.exit)"' "$SESSION_DIR/$k.host-actions.jsonl" | tail -1)"
check "the lock is free again, and no turn started" "|0|no" "$(ls "$SESSION_DIR/$k.lock" 2>/dev/null)|$(session_get $k turn_open)|$([ -e "$tmp/turn" ] && echo yes || echo no)"
check "the output waits as a note, masked" "1|0" "$(grep -c '^hi <masked>$' "$n")|$(grep -c "$SECRET" "$n")"

# The next message carries the note, and its turn has no admin role, even from an admin.
printf 'next please\n' > "$tmp/m"
cmd_steer $k --message-file "$tmp/m" --from-name Ana --ci-ok >/dev/null
check "the next message's turn has the note, its own text, and role 0" "1|1|0|no" \
  "$(grep -c 'the engineer ran a command' "$tmp/turn")|$(grep -c '^next please$' "$tmp/turn")|$(session_get $k turn_admin)|$([ -e "$n" ] && echo yes || echo no)"
check "the history keeps only the person's words" "next please" "$(jq -r 'select(.role == "user") | .text' "$SESSION_DIR/$k.history.jsonl")"
rm -f "$tmp/turn"; cmd_steer $k --message-file "$tmp/m" --from-name Ana --ci-ok >/dev/null
check "the message after that keeps the admin role" "1|0" "$(session_get $k turn_admin)|$(grep -c 'ran a command' "$tmp/turn")"

if [ -d /proc/self/fd ] && command -v setsid >/dev/null && command -v timeout >/dev/null && command -v pkill >/dev/null; then
  cd "$tmp"
  out="$(printf '%s\n' 'echo "path=$PATH"; nohup sleep 300 >/dev/null 2>&1 & echo $! > left; exit 7' | bash -c "$_SESSION_SH_RUN" 2>"$tmp/err")"
  sleep 0.3
  check "the runner script: a fixed PATH, the exit code on stderr only" "path=/usr/local/bin:/usr/bin:/bin|@@exit 7" "$out|$(cat "$tmp/err")"
  check "a process the command left in the background is killed" "gone" "$(kill -0 "$(cat left)" 2>/dev/null && echo up || echo gone)"
  kill -KILL "$(cat left)" 2>/dev/null
else
  echo "skip the runner script check: it needs Linux setsid, timeout and pkill"
fi
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
