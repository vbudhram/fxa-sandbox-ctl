#!/usr/bin/env bash
# Offline check for idle-stop.sh, with a scratch /fc and a stub poweroff (Linux: GNU stat and touch).
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
stat -c %Y / >/dev/null 2>&1 || { echo "skip: needs GNU stat"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
S="$(cd "$(dirname "$0")" && pwd)/idle-stop.sh"
# Each run starts with the host on; booted defaults to 2 h ago, so only the mark decides.
run() { rm -f "$tmp/off"; FC_CMD="${FC_CMD:-true}" FC_ROOT="$tmp/fc" FC_IDLE_MIN=30 FC_POWEROFF="touch $tmp/off" FC_BOOTED="${BOOTED:-$(( $(date +%s) - 7200 ))}" PATH="$tmp/bin:$PATH" bash "$S"; }
mkdir -p "$tmp/bin" "$tmp/fc/run"; printf '#!/bin/sh\nexit 3\n' > "$tmp/bin/systemctl"; chmod +x "$tmp/bin/systemctl"
BOOTED=$(date +%s) run; check "a fresh host is not idle yet" "no" "$([ -e "$tmp/off" ] && echo yes || echo no)"
touch -d "@$(( $(date +%s) - 3600 ))" "$tmp/fc/run/last-busy"
mkdir -p "$tmp/fc/slots/1"; touch "$tmp/fc/slots/1/meta"
run; check "a slot in use keeps it up and marks it busy" "no|1" "$([ -e "$tmp/off" ] && echo yes || echo no)|$([ $(( $(date +%s) - $(stat -c %Y "$tmp/fc/run/last-busy") )) -lt 5 ] && echo 1)"
rm -rf "$tmp/fc/slots/1"; touch -d "@$(( $(date +%s) - 600 ))" "$tmp/fc/run/last-busy"
run; check "idle 10 min: still up" "no" "$([ -e "$tmp/off" ] && echo yes || echo no)"
touch -d "@$(( $(date +%s) - 1900 ))" "$tmp/fc/run/last-busy"
printf '#!/bin/sh\n[ "$1 $2" = "is-active --quiet" ] && exit 0; exit 3\n' > "$tmp/bin/systemctl"
run; check "idle 31 min during a refresh: still up" "no" "$([ -e "$tmp/off" ] && echo yes || echo no)"
touch -d "@$(( $(date +%s) - 1900 ))" "$tmp/fc/run/last-busy"; printf '#!/bin/sh\nexit 3\n' > "$tmp/bin/systemctl"
run; check "idle 31 min: powers off" "yes" "$([ -e "$tmp/off" ] && echo yes || echo no)"
# A dev slot idle 31 min is stopped; a fresh one and a session slot stay.
printf '#!/bin/sh\nexit 3\n' > "$tmp/bin/systemctl"; printf '#!/bin/sh\necho "$*" >> %s/fccalls\n' "$tmp" > "$tmp/bin/fc"; chmod +x "$tmp/bin/fc"
mkdir -p "$tmp/fc/slots/1" "$tmp/fc/slots/2" "$tmp/fc/slots/3"
printf 'agent-dev-monitor\t-\t0\n' > "$tmp/fc/slots/1/meta"; touch -d "@$(( $(date +%s) - 1900 ))" "$tmp/fc/slots/1/meta"
printf 'agent-dev-fxa\t-\t0\n' > "$tmp/fc/slots/2/meta"
printf 'agent-agent-1a2b3c\t-\t0\n' > "$tmp/fc/slots/3/meta"; touch -d "@$(( $(date +%s) - 9000 ))" "$tmp/fc/slots/3/meta"
FC_CMD="$tmp/bin/fc" run; check "only the idle dev slot is stopped" "stop 1" "$(cat "$tmp/fccalls" 2>/dev/null)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
