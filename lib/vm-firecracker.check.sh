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

# A start GCE refuses says why, so the fallback to GCE is not a mystery.
_gce() { echo "ERROR: (gcloud.compute.instances.start) ZONE_RESOURCE_POOL_EXHAUSTED" >&2; return 1; }
check "a refused start names the reason" "1" "$(_fc_wake 2>&1 >/dev/null | grep -c 'did not start (ERROR: (gcloud.compute.instances.start) ZONE_RESOURCE_POOL_EXHAUSTED)')"

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

# A stop when the host has stopped itself: its slots are gone, so the stop succeeds.
vm_name() { echo "$1"; }; _gce_ssh_forget() { :; }; _gce() { echo TERMINATED; }
_fc() { echo "fc $*" >> "$tmp/fc-calls"; return 1; }
check "host down: the stop succeeds and asks the host nothing" "0|0" \
  "$(UP=0; (set -e; vm_stop agent-a1 >/dev/null); echo "$?|$( [ -f "$tmp/fc-calls" ] && wc -l < "$tmp/fc-calls" | tr -d ' ' || echo 0)")"
_fc() { case "$1" in list) printf '3\tagent-a1\tx\ty\n' ;; *) echo "fc $*" >> "$tmp/fc-calls" ;; esac; }
check "host up: the slot is stopped" "fc stop 3" "$(UP=1 vm_stop agent-a1 >/dev/null; cat "$tmp/fc-calls")"
# A slot that cannot be stopped is an error, not a quiet skip: it keeps the host up.
_fc() { case "$1" in list) printf '3\tagent-a1\tx\ty\n' ;; *) return 1 ;; esac; }
check "the host refuses the stop: the stop fails" "1" "$(UP=1 vm_stop agent-a1 >/dev/null 2>&1; echo $?)"
_fc() { return 1; }
check "the host answers but cannot list: the stop fails" "1" "$(UP=1 vm_stop agent-a1 >/dev/null 2>&1; echo $?)"
_gce() { echo RUNNING; }
check "the probe misses but GCE says the host runs: the stop fails" "1" "$(UP=0 vm_stop agent-a1 >/dev/null 2>&1; echo $?)"
_gce() { return 1; }
check "the probe misses and GCE cannot say: the stop fails" "1" "$(UP=0 vm_stop agent-a1 >/dev/null 2>&1; echo $?)"
# fc install sends the repo's refresh and toolchain scripts, each to its path on the host.
SANDBOX_ROOT="$(cd "$here/.." && pwd)"; sent="$tmp/sent"; : > "$sent"
_fc_ssh() { printf '%s %s\n' "$(grep -o '/usr/local/[a-z/.0-9-]*' <<< "$1" | head -1)" "$(cksum | cut -d' ' -f1)" >> "$sent"; }
fc_install
check "fc install sends both scripts to their paths" \
  "/usr/local/sbin/fc-refresh $(cksum < "$SANDBOX_ROOT/infra/firecracker/refresh.sh" | cut -d' ' -f1)|/usr/local/share/fxa/03b-toolchain.sh $(cksum < "$SANDBOX_ROOT/packer/scripts/03b-toolchain.sh" | cut -d' ' -f1)" \
  "$(paste -sd'|' "$sent")"
# fc status with the host off shows the last read, which the alerts also use.
SESSION_DIR="$tmp/s"; mkdir -p "$SESSION_DIR"; printf 'refresh=success\n' > "$SESSION_DIR/.fc-status"
_fc_up() { return 1; }
check "fc status with the host off shows the last read" "1" "$(cmd_fc status | grep -c '^refresh=success')"
# fc status keeps only well-formed key=value lines from the host: the alerts read this file.
_fc_ssh() { printf 'snapshot=20261011-1700\nclaude=2.1.296\nclaude made=a[$(id)]\nmade=a[$(id)]\nmade=1791738213\nrefresh=success\nok_at=1791738300\n'; }
fc_status >/dev/null
check "fc status drops lines that are not plain key=value" "snapshot=20261011-1700|claude=2.1.296|made=1791738213|refresh=success|ok_at=1791738300" \
  "$(grep -v '^read=' "$SESSION_DIR/.fc-status" | paste -sd'|' -)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
