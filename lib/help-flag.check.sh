#!/usr/bin/env bash
# Offline check that --help after a subcommand prints its usage and runs nothing.
#   bash lib/help-flag.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
ctl="$(cd "$(dirname "$0")/.." && pwd)/fxa-sandbox-ctl"
out="$(PIPE_REPO=/nonexistent "$ctl" relock FXA-1 --help 2>&1)"; rc=$?
check "relock --help exits 0 and prints the relock usage" "0|1" "$rc|$(grep -c '^  relock' <<< "$out")"
check "relock --help runs no relock" "0" "$(grep -c 'ERROR' <<< "$out")"
exit "$fail"
