#!/usr/bin/env bash
# Offline check that a finishing marker a crash left behind stops counting after 30 min.
#   bash lib/finishing-marker.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
eval "$(sed -n '/^worktree_finishing() {/,/^}/p' "$(dirname "$0")/worktree.sh")"
LOG_DIR="$tmp"
check "no marker: not finishing" "no" "$(worktree_finishing /w/fxa-auto-1 && echo yes || echo no)"
touch "$tmp/fxa-auto-1.finishing"
check "a fresh marker: finishing" "yes" "$(worktree_finishing /w/fxa-auto-1 && echo yes || echo no)"
touch -t 202001010000 "$tmp/fxa-auto-1.finishing"
check "a marker a crash left days ago: not finishing" "no" "$(worktree_finishing /w/fxa-auto-1 && echo yes || echo no)"
_mtime() { return 1; }   # finish removed the marker after the -f test
touch "$tmp/fxa-auto-1.finishing"
check "a marker removed during the read: not finishing, and no abort" "no" "$( (set -euo pipefail; worktree_finishing /w/fxa-auto-1 && echo yes || echo no) )"
exit "$fail"
