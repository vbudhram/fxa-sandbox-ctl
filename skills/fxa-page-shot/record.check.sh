#!/usr/bin/env bash
# Offline check for record.sh argument handling. Needs no X or ffmpeg.
#   bash skills/fxa-page-shot/record.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp" FXA_WORKSPACE="$tmp/ws"
R="$(cd "$(dirname "$0")" && pwd)/record.sh"
bash "$R" start >/dev/null 2>&1; check "start needs a name" 2 $?
bash "$R" start '../x' >/dev/null 2>&1; check "start refuses a path in the name" 2 $?
bash "$R" stop >/dev/null 2>&1; check "stop with nothing recording fails" 1 $?
bash "$R" stop --speed 0 >/dev/null 2>&1; check "stop refuses a speed of 0" 2 $?
bash "$R" bogus >/dev/null 2>&1; check "an unknown command fails" 2 $?
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
