#!/usr/bin/env bash
# Offline check that `run` refuses to boot a VM with no prompt.
#   bash lib/run-prompt.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eval "$(sed -n '/^cmd_run() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
check_prerequisites() { :; }
agent_run() { echo "started $3"; }
DEFAULT_VM_CPU=4 DEFAULT_VM_MEMORY_MB=8192

check "no prompt is refused" "1 " "$(cmd_run /tmp 2>/dev/null; echo "$? ")"
check "prompt starts the agent" "started fix it" "$(cmd_run /tmp -p "fix it")"

exit "$fail"
