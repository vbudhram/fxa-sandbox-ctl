#!/usr/bin/env bash
# Offline check for test.sh's pool: a check that fails, or never runs, must fail the run.
#   bash skills/fxa-ctl-dev/test.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^check_one() {/,/^}/p;/^run_pool() {/,/^}/p' "$(dirname "$0")/test.sh")"
# The cases below count process levels (a killed grandparent): the CI job's timeout wrapper adds levels.
unset FXA_CHECK_TIMEOUT FXA_CHECK_PROGRESS
cd "$tmp" && mkdir -p c
echo 'echo ok' > c/a.check.sh; echo 'echo ok' > c/b.check.sh
check "all pass: the pool passes" "0" "$(run_pool mac c/a.check.sh c/b.check.sh >/dev/null 2>&1; echo $?)"
echo 'echo "skip: needs bash 4"; exit 0' > c/s.check.sh
check "a check that skips itself passes, and the pool names the skip" "0|skip mac: c/s.check.sh: needs bash 4" "$(run_pool mac c/s.check.sh > out 2>&1; echo $?)|$(cat out)"
for x in c d e f; do echo 'echo ok' > c/$x.check.sh; done; echo 'sleep 2; echo ok' > c/z.check.sh
check "a run of 5 or more checks names the slowest first" "1" \
  "$(run_pool mac c/a.check.sh c/c.check.sh c/d.check.sh c/e.check.sh c/z.check.sh 2>&1 | grep -cE '^mac: slowest: [2-9]s c/z.check.sh, [0-9]s c/')"
check "a run of fewer checks prints no slowest line" "0" "$(run_pool mac c/a.check.sh c/b.check.sh 2>&1 | grep -c slowest)"
echo 'echo "FAIL planted"' > c/a.check.sh
check "a FAIL line fails the pool and names the check" "1|yes" "$(run_pool mac c/a.check.sh c/b.check.sh > out 2>&1; echo $?)|$(grep -q 'FAIL mac: c/a.check.sh' out && echo yes)"
# The check kills the xargs child that runs it (its grandparent, as an OOM kill would): xargs
# aborts, and b never runs.
echo 'kill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"' > c/a.check.sh
check "a killed check stops xargs: the pool fails and names what did not run" "1|yes" \
  "$(FXA_CHECK_JOBS=1 run_pool mac c/a.check.sh c/b.check.sh > out 2>&1; echo $?)|$(grep -q 'c/b.check.sh' out && echo yes)"
# run_changed in a scratch repo: a Python module a check imports, a Python service's own test, and fake-ctl.sh's bot e2e.
r="$tmp/r"; mkdir -p "$r/skills/fxa-ctl-dev" "$r/lib" "$r/infra/llm-proxy" "$tmp/bot"
cp "$here/test.sh" "$r/skills/fxa-ctl-dev/test.sh"
echo 'X = 1' > "$r/lib/srv.py"; printf 'python3 -c "import os, srv" 2>/dev/null; echo "FAIL planted"\n' > "$r/lib/srv-api.check.sh"
echo 'X = 1' > "$r/infra/llm-proxy/proxy.py"; printf 'print("FAIL: planted")\nraise SystemExit(1)\n' > "$r/infra/llm-proxy/proxy_test.py"
echo 'true' > "$r/skills/fxa-ctl-dev/fake-ctl.sh"
printf '{"scripts":{"e2e":"touch marker && exit 1"}}\n' > "$tmp/bot/package.json"
( cd "$r" && git init -q && git add -A && git -c user.email=t@example.com -c user.name=t commit -qm base )
changed() { ( cd "$r" && git checkout -q -- . && for f in "$@"; do echo '# edit' >> "$f"; done
  FXA_BOT_REPO="$tmp/bot" bash skills/fxa-ctl-dev/test.sh changed HEAD > "$tmp/out" 2>&1; echo $? ); }
check "a changed module selects the check that imports it" "1|yes" "$(changed lib/srv.py)|$(grep -q 'FAIL [a-z]*: lib/srv-api.check.sh' "$tmp/out" && echo yes)"
check "a changed proxy runs proxy_test.py" "1|yes" "$(changed infra/llm-proxy/proxy.py)|$(grep -q 'FAIL [a-z]*: infra/llm-proxy/proxy_test.py' "$tmp/out" && echo yes)"
rm -f "$tmp/bot/marker"
check "a changed fake-ctl.sh runs the bot e2e" "1|yes|yes" "$(changed skills/fxa-ctl-dev/fake-ctl.sh)|$(grep -q 'FAIL [a-z]*: the bot e2e' "$tmp/out" && echo yes)|$([ -e "$tmp/bot/marker" ] && echo yes)"
exit "$fail"
