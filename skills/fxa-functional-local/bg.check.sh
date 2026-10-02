#!/usr/bin/env bash
# Offline check for run.sh --bg and wait, with a stand-in for the test run.
#   bash skills/fxa-functional-local/bg.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_FUNCTIONAL_JOB_DIR="$tmp/job"
# The real run after the wait block becomes: sleep <spec seconds>, then PASS, or FAIL for "fail".
awk '/^if \[ "\$\{1:-\}" = wait \]/ { w = 1 } { print } w && /^fi$/ { exit }' "$(dirname "$0")/run.sh" > "$tmp/run.sh"
cat >> "$tmp/run.sh" <<'FAKE'
sleep "$1"; [ "${2:-}" = fail ] && { echo "FAIL fake"; exit 1; }; echo "video: /workspace/.fxa-auto-media/x.webm"; echo "PASS fake"; exit 0
FAKE
R="bash $tmp/run.sh"
check "wait with no run says so" 2 "$($R wait 1 >/dev/null 2>&1; echo $?)"
$R --bg 12 >/dev/null
check "a second start while one runs is refused" 2 "$($R --bg 12 >/dev/null 2>&1; echo $?)"
out="$($R wait 1)"; rc=$?
check "a short wait on a long run: still running, exit 75" "75|1" "$rc|$(grep -c 'still running' <<< "$out")"
out="$($R wait 20)"; rc=$?
check "the result once it ends: PASS and the video" "0|PASS fake|1" "$rc|$(grep '^PASS' <<< "$out")|$(grep -c '^video:' <<< "$out")"
$R --bg 1 fail >/dev/null; out="$($R wait 20)"; rc=$?
check "a failed run returns its exit code" "1|FAIL fake" "$rc|$out"
# The run dies whole: the wrapper first, so it cannot write an exit code.
$R --bg 30 >/dev/null; sleep 1; kill "$(cat "$tmp/job/pid")" 2>/dev/null; pkill -f "sleep 30"
t0=$(date +%s); out="$($R wait 20)"; rc=$?
check "a run that dies is reported at once, not at the time limit" "4|1|yes" "$rc|$(grep -c 'died' <<< "$out")|$([ $(( $(date +%s) - t0 )) -lt 10 ] && echo yes)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
