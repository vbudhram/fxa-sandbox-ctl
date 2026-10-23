#!/usr/bin/env bash
# Offline check that manager.sh sync runs one at a time: a second sync waits, then stops with nothing changed.
#   bash infra/gce/sync-lock.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v flock >/dev/null || { echo "skip: no flock here (the manager VM has it)"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
step="$(sed -n '/sudo touch \/run\/fxa-sync.lock/,/flock -n 9/p' "$here/manager.sh" | sed "s#^  ssh_vm '##; s#/run/fxa-sync.lock#$t/lock#g; s#-w 600#-w 1#")"
run() { ( sudo() { "$@"; }; eval "$step"; echo synced ) 2>&1; }
check "no other sync: it runs at once" "synced" "$(run)"
( exec 9>"$t/lock"; flock 9; sleep 4 ) & sleep 1
check "while another sync runs: it waits, then stops with nothing changed" \
  "another sync runs; waiting for it (up to 10 min)|sync: another sync still runs after 10 min; nothing changed" "$(run | paste -sd'|' -)"
wait
check "after the other sync ends: it runs" "synced" "$(run)"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
