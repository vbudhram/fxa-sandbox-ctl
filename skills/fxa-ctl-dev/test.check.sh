#!/usr/bin/env bash
# Offline check for test.sh's pool: a check that fails, or never runs, must fail the run.
#   bash skills/fxa-ctl-dev/test.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_tmo() {/,/^}/p;/^check_one() {/,/^}/p;/^run_pool() {/,/^}/p' "$(dirname "$0")/test.sh")"
# The cases below count process levels (a killed grandparent): the CI job's timeout wrapper adds levels.
unset FXA_CHECK_TIMEOUT FXA_CHECK_PROGRESS FXA_CHECK_VERBOSE
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
check "FXA_CHECK_VERBOSE prints the failed check's own output under its FAIL line" "0|1" \
  "$(grep -c '^  | ' out)|$(FXA_CHECK_VERBOSE=1 run_pool mac c/a.check.sh 2>&1 | grep -c '^  | FAIL')"
# The check kills the xargs child that runs it (its grandparent, as an OOM kill would): xargs
# aborts, and b never runs.
echo 'kill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"' > c/a.check.sh
check "a killed check stops xargs: the pool fails and names what did not run" "1|yes" \
  "$(FXA_CHECK_JOBS=1 run_pool mac c/a.check.sh c/b.check.sh > out 2>&1; echo $?)|$(grep -q 'c/b.check.sh' out && echo yes)"
# FXA_CHECK_TIMEOUT: a hung check fails with its name, with its whole process group gone; a pass and an exit code stay as they are.
echo 'sleep 37.5 & wait' > c/h.check.sh; echo 'exit 3' > c/x.check.sh; s=$SECONDS
check "a hung check that holds the pipe through a child fails at the timeout, named, with no child left" "1|yes|0" \
  "$(FXA_CHECK_TIMEOUT=2 run_pool mac c/h.check.sh > out 2>&1; echo $?)|$(grep -q 'did not finish in 2s' out && [ $(( SECONDS - s )) -lt 6 ] && echo yes)|$(pgrep -fx 'sleep 37.5' | wc -l | tr -d ' ')"
check "with a timeout, a pass passes and an exit code is reported" "0|1|yes" \
  "$(FXA_CHECK_TIMEOUT=5 run_pool mac c/b.check.sh >/dev/null 2>&1; echo $?)|$(FXA_CHECK_TIMEOUT=5 run_pool mac c/x.check.sh > out 2>&1; echo $?)|$(grep -q 'exit 3' out && echo yes)"
# run_changed in a scratch repo: a Python module a check imports, a Python service's own test, and fake-ctl.sh's bot e2e.
r="$tmp/r"; mkdir -p "$r/skills/fxa-ctl-dev" "$r/lib" "$r/infra/llm-proxy" "$tmp/bot"
cp "$here/test.sh" "$r/skills/fxa-ctl-dev/test.sh"
echo 'X = 1' > "$r/lib/srv.py"; printf 'python3 -c "import os, srv" 2>/dev/null; echo "FAIL planted"\n' > "$r/lib/srv-api.check.sh"
printf '[ -z "${ANTHROPIC_BASE_URL:-}${ANTHROPIC_API_KEY:-}" ] || echo "FAIL the caller model setup leaked"\n' > "$r/lib/env.check.sh"
echo 'X = 1' > "$r/infra/llm-proxy/proxy.py"; printf 'print("FAIL: planted")\nraise SystemExit(1)\n' > "$r/infra/llm-proxy/proxy_test.py"
echo 'true' > "$r/skills/fxa-ctl-dev/fake-ctl.sh"
printf '{"scripts":{"e2e":"touch marker && exit 1"}}\n' > "$tmp/bot/package.json"
( cd "$r" && git init -q && git add -A && git -c user.email=t@example.com -c user.name=t commit -qm base )
changed() { ( cd "$r" && git checkout -q -- . && for f in "$@"; do echo '# edit' >> "$f"; done
  FXA_BOT_REPO="$tmp/bot" bash skills/fxa-ctl-dev/test.sh changed HEAD > "$tmp/out" 2>&1; echo $? ); }
check "a check never sees the caller's ANTHROPIC_BASE_URL or ANTHROPIC_API_KEY (a Claude Code session sets them)" "0" \
  "$(ANTHROPIC_BASE_URL=http://example.invalid ANTHROPIC_API_KEY=sk-test changed lib/env.check.sh)"
check "a changed module selects the check that imports it" "1|yes" "$(changed lib/srv.py)|$(grep -q 'FAIL [a-z]*: lib/srv-api.check.sh' "$tmp/out" && echo yes)"
check "a changed proxy runs proxy_test.py" "1|yes" "$(changed infra/llm-proxy/proxy.py)|$(grep -q 'FAIL [a-z]*: infra/llm-proxy/proxy_test.py' "$tmp/out" && echo yes)"
rm -f "$tmp/bot/marker"
printf 'import time\ntime.sleep(37)\n' > "$r/infra/llm-proxy/proxy_test.py"; ( cd "$r" && git -c user.email=t@example.com -c user.name=t commit -qam hang ); s=$SECONDS
check "with FXA_CHECK_TIMEOUT, a hung Python test fails at the timeout, named" "1|yes" \
  "$(FXA_CHECK_TIMEOUT=2 changed infra/llm-proxy/proxy.py)|$(grep -q 'FAIL [a-z]*: infra/llm-proxy/proxy_test.py did not finish in 2s' "$tmp/out" && [ $(( SECONDS - s )) -lt 8 ] && echo yes)"
check "a changed fake-ctl.sh runs the bot e2e" "1|yes|yes" "$(changed skills/fxa-ctl-dev/fake-ctl.sh)|$(grep -q 'FAIL [a-z]*: the bot e2e' "$tmp/out" && echo yes)|$([ -e "$tmp/bot/marker" ] && echo yes)"
# The selection alone (FXA_CHANGED_DRY): a skill's check.sh, a page check that names the controller as text, a common word.
mkdir -p "$r/skills/s" "$r/dashboard"; echo true > "$r/skills/s/check.sh"; echo '<html>' > "$r/dashboard/index.html"; printf 'w() {\n  :\n}\n' > "$r/lib/w.sh"
echo '# runs skills/s/check.sh' > "$r/lib/s-user.check.sh"; echo '# renders dashboard/index.html; fixture: fxa-sandbox-ctl stop; w' > "$r/skills/fxa-ctl-dev/page-x.check.sh"
for i in 1 2 3 4 5; do echo "# w is a word here; see other.check.sh" > "$r/lib/word$i.check.sh"; done; echo '# echo' > "$r/fxa-sandbox-ctl"
( cd "$r" && git add -A && git -c user.email=t@example.com -c user.name=t commit -qm sel )
picks() { ( cd "$r" && git checkout -q -- . && for f in "$@"; do case "$f" in lib/w.sh) sed -i.bak 's/^  :$/  : edit/' "$f" && rm -f "$f.bak" ;; *) echo '# edit' >> "$f" ;; esac; done
  FXA_CHANGED_DRY=1 bash skills/fxa-ctl-dev/test.sh changed HEAD 2>/dev/null | sed 1d | paste -sd, - ); }
check "a skill's check.sh picks the checks that name its folder, not every check" "lib/s-user.check.sh" "$(picks skills/s/check.sh)"
check "a controller change does not pick a page check that only names it as text" "" "$(picks fxa-sandbox-ctl)"
check "a dashboard change picks the page check" "skills/fxa-ctl-dev/page-x.check.sh" "$(picks dashboard/index.html)"
check "a function whose name is in most checks picks none by that name" "" "$(picks lib/w.sh)"
exit "$fail"
