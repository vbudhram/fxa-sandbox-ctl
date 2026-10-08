#!/usr/bin/env bash
# Offline check of `fxa-sandbox-ctl exec`: a name with or without the prefix, and no crash for an unknown runner.
#   bash lib/exec-name.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
pat='/^cmd_exec() {/,/^}/p'; eval "$(sed -n "$pat" "$here/../fxa-sandbox-ctl")"
VM_PREFIX=agent
vm_name() { echo "${VM_PREFIX}-$1"; }
vm_exists() { [ "$1" = 1a2b3c ]; }
vm_exec_as_agent() { echo "ran on $1: $2"; }
check "the bare name reaches the runner" "ran on 1a2b3c: uptime" "$(cmd_exec 1a2b3c uptime 2>&1)"
check "the prefixed name reaches the same runner" "ran on 1a2b3c: uptime" "$(cmd_exec agent-1a2b3c uptime 2>&1)"
out="$(cmd_exec agent-agent uptime 2>&1)"; rc=$?
check "an unknown runner is a clear error" "1|ERROR: no runner 'agent-agent'; see fxa-sandbox-ctl list" "$rc|$out"
check "no command is the usage" "1" "$(cmd_exec 1a2b3c >/dev/null 2>&1; echo $?)"
exit "$fail"
