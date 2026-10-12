#!/usr/bin/env bash
# Offline check that stack.sh records a start and a restart with their seconds.
#   bash skills/fxa-stack/times.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_WORKSPACE="$tmp"
eval "$(sed -n '/^rec() {/,/^}/p' "$(dirname "$0")/stack.sh")"
# A fixed clock: the real one can tick between the start time and rec's own read.
date() { if [ "${1:-}" = +%s ]; then echo 2000000000; else command date "$@"; fi; }
rec start 1999999905 0; rec "restart auth" 2000000000 1
check "a start: its seconds and ok" '"start" 95 true' "$(jq -r 'select(.action == "start") | "\"\(.action)\" \(.secs) \(.ok)"' "$tmp/.fxa-stack-times.jsonl")"
check "a failed restart" 'false' "$(jq -r 'select(.action == "restart auth") | .ok' "$tmp/.fxa-stack-times.jsonl")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
