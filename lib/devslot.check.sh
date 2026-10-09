#!/usr/bin/env bash
# Offline check for devslot: the Firecracker host and the slot are stubbed.
#   bash lib/devslot.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
exec < /dev/null  # the stubs read stdin, as ssh does
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"
source "$here/devslot.sh"
eval "$(sed -n '/^_fc_vm_exists() /p;/^_fc_slot_of() /p' "$here/vm-firecracker.sh")"
vm_name() { echo "agent-$1"; }
# The host: slots in $tmp/slots as "<n>\t<label>"; each call is logged.
: > "$tmp/slots"
_fc_up() { true; }; _fc_wake() { echo wake >> "$tmp/calls"; }
_fc() { cat > /dev/null; echo "fc $*" >> "$tmp/calls"; [ "$1" = list ] && cat "$tmp/slots"; return 0; }  # ssh reads stdin, like the real one
_fc_vm_clone() { echo "clone $1" >> "$tmp/calls"; printf '3\tagent-%s\t10.0.0.3\t0\n' "$1" >> "$tmp/slots"; }
_fc_vm_delete() { echo "delete $1" >> "$tmp/calls"; : > "$tmp/slots"; }
_gce_vm_clone() { echo "gce $1" >> "$tmp/calls"; }
vm_exec_as_agent() { echo "exec $1 $2" >> "$tmp/calls"; }
vm_put() { echo "put $1 $3 $(wc -c < "$2" | tr -d ' ')" >> "$tmp/calls"; }
export FXA_FC_HOST=10.0.0.1

check "a profile name cannot be a path" "1" "$(cmd_devslot up ../x >/dev/null 2>&1; echo $?)"
check "no host, no slot" "1" "$(FXA_FC_HOST= cmd_devslot up monitor >/dev/null 2>&1; echo $?)"
: > "$tmp/calls"; cmd_devslot up monitor >/dev/null
check "up restores a Firecracker slot, never a GCE runner" "clone dev-monitor" "$(grep -E '^(clone|gce)' "$tmp/calls")"
: > "$tmp/calls"; cmd_devslot up monitor >/dev/null
check "a second up keeps the warm slot and touches it" "0|fc touch 3" "$(grep -c '^clone' "$tmp/calls")|$(grep '^fc touch' "$tmp/calls")"
: > "$tmp/calls"; printf 'abc' | cmd_devslot sync monitor /home/agent/monitor >/dev/null
check "sync sends stdin to the guest dir and touches the slot" "put dev-monitor /home/agent/monitor 3|1" "$(grep '^put' "$tmp/calls")|$(grep -c '^fc touch' "$tmp/calls")"
check "sync needs an absolute dir" "1" "$(printf x | cmd_devslot sync monitor rel >/dev/null 2>&1; echo $?)"
: > "$tmp/calls"; out="$(cmd_devslot run monitor 'bash ready.sh')"
check "run executes as agent and reports the exit" "bash ready.sh|1" "$(grep '^exec dev-monitor echo' "$tmp/calls" | awk '{print $4}' | base64 -d)|$(grep -c '^── exit 0 after' <<< "$out")"
: > "$tmp/calls"; cmd_devslot run monitor "$(printf 'a "b" $c\nd')" >/dev/null
check "a multi-line script with quotes arrives intact" 'a "b" $c|d' "$(grep '^exec dev-monitor echo' "$tmp/calls" | awk '{print $4}' | base64 -d | paste -sd'|' -)"
vm_exec() { echo "root $1 ${*: -1}" >> "$tmp/calls"; }
: > "$tmp/calls"; cmd_devslot root monitor "$(printf 'id\nwhoami')" >/dev/null
check "root runs the script as root, intact" "id|whoami" "$(grep '^root dev-monitor' "$tmp/calls" | sed 's/.*echo \([^ ]*\) .*/\1/' | base64 -d | paste -sd'|' -)"
vm_exec_as_agent() { [ "$2" = "free -m" ] && echo "Mem: 16016 7390 100 1 2000 8626"; [ "$(awk '{print $2}' <<< "$2" | base64 -d 2>/dev/null)" = fail ] && return 7; return 0; }
check "run reports the memory" "7390 MB used, 8626 MB available" "$(cmd_devslot run monitor true | sed -n 's/.* · //p')"
check "run passes the command's exit code" "7" "$(cmd_devslot run monitor fail >/dev/null 2>&1; echo $?)"
: > "$tmp/calls"; cmd_devslot reset monitor >/dev/null
check "reset drops the slot and restores a clean one" "delete dev-monitor,clone dev-monitor" "$(grep -E '^(delete|clone)' "$tmp/calls" | paste -sd, -)"
cmd_devslot down monitor >/dev/null
check "run on a slot that is down says so" "1" "$(cmd_devslot run monitor true >/dev/null 2>&1; echo $?)"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
