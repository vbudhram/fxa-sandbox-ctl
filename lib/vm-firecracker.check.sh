#!/usr/bin/env bash
# Offline check for the on-demand Firecracker host: the cached probe, the wake, and the GCE fallbacks.
#   bash lib/vm-firecracker.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
here="$(cd "$(dirname "$0")" && pwd)"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
LOG_DIR="$tmp/logs"; mkdir -p "$LOG_DIR"
# The GCE backend, as stubs; the file renames them _gce_* and dispatches.
for f in vm_exists vm_clone vm_start vm_is_running vm_stop vm_delete vm_list; do eval "$f() { echo gce-$f; }"; done
FXA_FC_HOST=10.0.0.9; source "$here/vm-firecracker.sh"
probes="$tmp/probes"
timeout() { echo x >> "$probes"; return 124; }   # the host drops the probe
check "a dropped probe: down" "1" "$(_fc_up; echo $?)"
_fc_up
check "a second call within the minute does not probe" "1" "$(wc -l < "$probes" | tr -d ' ')"
touch -t 202001010000 "$tmp"/fxa-fc-down-*
_fc_up
check "after a minute it probes again" "2" "$(wc -l < "$probes" | tr -d ' ')"
timeout() { echo x >> "$probes"; return 0; }      # the host is back
rm -f "$tmp"/fxa-fc-down-*
check "a host that answers is up, and clears the miss" "0|0" "$(_fc_up; echo $?)|$(ls "$tmp" | grep -c fxa-fc-down)"

# A session runner: up → a slot; down → wake, then a slot; no wake or no slot → GCE.
_fc_vm_clone() { echo fc-clone; }
_fc_up() { [ "$UP" = 1 ]; }; _fc_wake() { echo wake; [ "$WAKE" = 1 ]; }
check "host up: a slot" "fc-clone" "$(UP=1 vm_clone agent-a1 2>/dev/null)"
check "host down: wake, then a slot" "wake|fc-clone" "$(UP=0 WAKE=1 vm_clone agent-a1 2>/dev/null | paste -sd'|' -)"
check "host will not start: GCE" "wake|gce-vm_clone" "$(UP=0 WAKE=0 vm_clone agent-a1 2>/dev/null | paste -sd'|' -)"
_fc_vm_clone() { return 1; }
check "every slot taken: GCE" "gce-vm_clone" "$(UP=1 vm_clone agent-a1 2>/dev/null)"
check "a pipeline runner never wakes the host" "gce-vm_clone" "$(UP=0 WAKE=1 vm_clone fxa-auto-3 2>/dev/null)"
touch "$LOG_DIR/agent-a2.zone"
check "a runner already on GCE stays there" "gce-vm_clone" "$(UP=1 vm_clone agent-a2 2>/dev/null)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
