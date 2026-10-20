#!/usr/bin/env bash
# Offline check of _lock_take_stale: a stale lock is taken by one taker at a time, so racing takers end
# with exactly one holder, and a fresh lock or one under another take is left alone.
#   bash lib/lock-take.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_lock_take_stale() {/,/^}/p' "$here/config.sh")"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
old() { touch -t 202001010000 "$1"; }
mkdir "$tmp/a.lock"; _lock_take_stale "$tmp/a.lock" 120
check "a fresh lock stays" "yes" "$([ -d "$tmp/a.lock" ] && echo yes)"
mkdir "$tmp/b.lock" "$tmp/b.lock.take"; old "$tmp/b.lock"; _lock_take_stale "$tmp/b.lock" 120
check "a stale lock that another taker is taking stays" "yes" "$([ -d "$tmp/b.lock" ] && echo yes)"
mkdir "$tmp/c.lock"; old "$tmp/c.lock"; _lock_take_stale "$tmp/c.lock" 120
check "a stale lock with no other taker goes, and the take is released" "no|no" "$([ -d "$tmp/c.lock" ] && echo yes || echo no)|$([ -d "$tmp/c.lock.take" ] && echo yes || echo no)"
# 20 takers race one stale lock: each takes over then mkdirs; exactly one may hold it.
for r in 1 2 3; do
  rm -rf "$tmp/r.lock"* "$tmp/won"; mkdir "$tmp/r.lock"; old "$tmp/r.lock"
  for i in $(seq 20); do ( _lock_take_stale "$tmp/r.lock" 120; mkdir "$tmp/r.lock" 2>/dev/null && echo "$i" >> "$tmp/won" ) & done; wait
  check "round $r: racing takers of a stale lock leave one holder" "1" "$(grep -c . "$tmp/won" 2>/dev/null || echo 0)"
done
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
