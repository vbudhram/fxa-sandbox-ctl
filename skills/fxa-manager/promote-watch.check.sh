#!/usr/bin/env bash
# vm.sh promote's live watch: a TERM during the sleep still checks live errors and prints a verdict.
#   bash skills/fxa-manager/promote-watch.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; t="$(mktemp -d "${TMPDIR:-/tmp}/watch.XXXXXX")"; trap 'rm -rf "$t"' EXIT
body="$(sed -n '/A wait cut short/,/promote_watch "\$errs_before" || exit 1/p' "$here/vm.sh")"
[ -n "$body" ] || { echo "FAIL the watch lines are not in vm.sh"; exit 1; }
printf '%s\n' 'set -euo pipefail; errs_before=x; w=31.379' 'promote_watch() { echo "verdict"; }' "$body" > "$t/w.sh"
# Wait for the watch's sleep to exist: on a busy CI host a fixed 1 s could pass before it starts (i570).
sleeping() { local i; for i in $(seq 100); do pgrep -P "$1" sleep >/dev/null && return 0; sleep 0.1; done; return 1; }
bash "$t/w.sh" > "$t/out" 2>&1 & p=$!; sleeping "$p"; kill -TERM "$p" 2>/dev/null; sleep 0.2; pkill -TERM -P "$p" sleep 2>/dev/null; wait "$p"
if grep -q 'cut short' "$t/out" && grep -q verdict "$t/out"; then echo "ok   a watch cut short by TERM still prints its verdict"; else echo "FAIL a watch cut short by TERM: $(tr '\n' ' ' < "$t/out")"; exit 1; fi
# Only the sleep killed (what bg.check.sh's pkill once did): set -e must not end the run before the verdict.
bash "$t/w.sh" > "$t/out2" 2>&1 & p=$!; sleeping "$p"; pkill -TERM -P "$p" sleep 2>/dev/null; wait "$p"
if grep -q 'cut short' "$t/out2" && grep -q verdict "$t/out2"; then echo "ok   a killed sleep under set -e still prints the verdict"; else echo "FAIL a killed sleep under set -e: $(tr '\n' ' ' < "$t/out2")"; exit 1; fi
