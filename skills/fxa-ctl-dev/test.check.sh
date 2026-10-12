#!/usr/bin/env bash
# Offline check for test.sh's pool: a check that fails, or never runs, must fail the run.
#   bash skills/fxa-ctl-dev/test.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^check_one() {/,/^}/p;/^run_pool() {/,/^}/p' "$(dirname "$0")/test.sh")"
cd "$tmp" && mkdir -p c
echo 'echo ok' > c/a.check.sh; echo 'echo ok' > c/b.check.sh
check "all pass: the pool passes" "0" "$(run_pool mac c/a.check.sh c/b.check.sh >/dev/null 2>&1; echo $?)"
echo 'echo "FAIL planted"' > c/a.check.sh
check "a FAIL line fails the pool and names the check" "1|yes" "$(run_pool mac c/a.check.sh c/b.check.sh > out 2>&1; echo $?)|$(grep -q 'FAIL mac: c/a.check.sh' out && echo yes)"
# The check kills the xargs child that runs it (its grandparent, as an OOM kill would): xargs
# aborts, and b never runs.
echo 'kill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"' > c/a.check.sh
check "a killed check stops xargs: the pool fails and names what did not run" "1|yes" \
  "$(FXA_CHECK_JOBS=1 run_pool mac c/a.check.sh c/b.check.sh > out 2>&1; echo $?)|$(grep -q 'c/b.check.sh' out && echo yes)"
exit "$fail"
