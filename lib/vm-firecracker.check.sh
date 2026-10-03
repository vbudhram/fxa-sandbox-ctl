#!/usr/bin/env bash
# Offline check: a host that drops the probe costs one 3 s wait a minute, not one per command.
#   bash lib/vm-firecracker.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
here="$(cd "$(dirname "$0")" && pwd)"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
probes="$tmp/probes"
timeout() { echo x >> "$probes"; return 124; }   # the host drops the probe
load() { ( FXA_FC_HOST=10.0.0.9; source "$here/vm-firecracker.sh"; echo "${FXA_FC_HOST:-unset}" ); }
check "a dropped probe turns the spike off" "unset" "$(load)"
check "a second command within the minute does not probe" "unset|1" "$(load)|$(wc -l < "$probes" | tr -d ' ')"
touch -t 202001010000 "$tmp"/fxa-fc-down-*
load >/dev/null
check "after a minute it probes again" "2" "$(wc -l < "$probes" | tr -d ' ')"
timeout() { echo x >> "$probes"; return 0; }      # the host is back
rm -f "$tmp"/fxa-fc-down-*
check "a host that answers stays on" "10.0.0.9" "$(load)"
check "an answer clears the remembered miss" "0" "$(ls "$tmp" | grep -c fxa-fc-down)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
