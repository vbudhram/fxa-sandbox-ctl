#!/usr/bin/env bash
# Offline check for _session_sh_in: thread text on stdin stays data, the output cap, the time limit.
#   bash lib/session-sh-in.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
d="$(mktemp -d "${TMPDIR:-/tmp}/sh-in.XXXXXX")"; trap 'rm -rf "$d"' EXIT
eval "$(sed -n '/^_session_sh() {/p; /^_session_sh_in() {/,/^}/p' "$(dirname "$0")/session.sh")"
# The runner, here: vm_exec drops the name and the sudo, as the agent user would run it.
vm_exec() { shift 4; (cd "$d" && "$@"); }
command -v timeout >/dev/null || { timeout() { shift 3; "$@"; }; export -f timeout; }

check "text on stdin is data, not code" "\$(touch pwned)'\"" \
  "$(printf '%s' "\$(touch pwned)'\"" | _session_sh_in r 10 100 'cat')"
check "nothing ran from the text" "no" "$([ -e "$d/pwned" ] && echo yes || echo no)"
check "the output is capped" "12345" "$(printf '1234567890' | _session_sh_in r 10 5 'cat')"
check "a bad cap is refused" "2" "$(_session_sh_in r 10 '5; id' 'cat' 2>/dev/null; echo $?)"
if [ "$(type -t timeout)" != function ]; then
  s=$SECONDS; _session_sh_in r 1 100 'sleep 20' >/dev/null
  check "the time limit stops the script" "yes" "$([ $((SECONDS - s)) -lt 10 ] && echo yes || echo no)"
fi
exit $fail
