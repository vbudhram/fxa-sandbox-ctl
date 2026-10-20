#!/usr/bin/env bash
# Offline check for the gce zone lookup and stop: with no zone file the instance is found by name, so a
# delete hits its real zone, and agent_stop on gce deletes with no separate stop.
#   bash lib/vm-gce-zone.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$tmp/logs" FXA_GCE_ZONE=z-a FXA_GCE_ZONES="z-a z-b" _GCE_SSH_HOSTS="$tmp"; mkdir -p "$LOG_DIR"
for f in _vm_zone _gce_zone vm_delete vm_exists; do pat="/^${f}() {/,/^}/p"; eval "$(sed -n "$pat" "$here/vm-gce.sh")"; done
vm_name() { echo "agent-$1"; }; _gce_ssh_forget() { :; }
# The instance lives in z-b; HERE names the zone it is in, or none.
_gce() { local a z=""; for a in "$@"; do case "$a" in --zone=*) z="${a#--zone=}" ;; esac; done; prev=""; for a in "$@"; do [ "$prev" = --zone ] && z="$a"; prev="$a"; done
  echo "$*" >> "$tmp/calls"
  case "$2 $3" in
    "instances list") [ "${HERE:-}" = none ] || ! grep -q -- "--filter name=agent-x1 " <<< "$* " || echo z-b ;;
    "instances delete") [ "$z" = "${HERE:-z-b}" ] || { echo "ERROR: The resource was not found"; return 1; } ;;
  esac; }
HERE=z-b vm_delete x1 >/dev/null 2>&1; rc=$?
check "no zone file: the delete finds the instance in z-b and deletes it there" "0|1" "$rc|$(grep -c 'instances delete.*z-b' "$tmp/calls")"
: > "$tmp/calls"; HERE=none vm_delete x2 >/dev/null 2>&1; rc=$?
check "an instance in no zone: the delete counts it done" "0" "$rc"
# vm_exists with no zone file: one by-name list answers it, with no describe after.
: > "$tmp/calls"; rm -f "$LOG_DIR"/*.zone; HERE=none vm_exists x3; rc=$?
check "an instance that is not there: one list, no describe" "1|1|0" "$rc|$(grep -c 'instances list' "$tmp/calls")|$(grep -c 'instances describe' "$tmp/calls")"
: > "$tmp/calls"; rm -f "$LOG_DIR"/*.zone; HERE=z-b vm_exists x1; rc=$?
check "an instance found by name: it exists, with no describe" "0|0" "$rc|$(grep -c 'instances describe' "$tmp/calls")"
# agent_stop on gce: a delete, no stop.
eval "$(sed -n '/^agent_stop() {/,/^}/p' "$here/agent.sh")"
pipeline_launch_log() { :; }; _runner_postmortem() { :; }; llm_token_revoke() { :; }; mcp_token_revoke() { :; }; vm_exec() { :; }; sleep() { :; }
vm_stop() { echo stop >> "$tmp/ops"; }; vm_delete() { echo delete >> "$tmp/ops"; }; VM_SCREEN_SESSION=s
for b in gce tart; do : > "$tmp/ops"; FXA_VM_BACKEND=$b agent_stop agent-y1 >/dev/null 2>&1; eval "ops_$b=\"\$(paste -sd, "$tmp/ops")\""; done
check "agent_stop on gce deletes with no stop first; tart still stops first" "delete|stop,delete" "$ops_gce|$ops_tart"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
