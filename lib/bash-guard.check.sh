#!/usr/bin/env bash
# Offline check for hooks/fxa-bash-guard.sh, the runner's Bash PreToolUse hook.
#   bash lib/bash-guard.check.sh
set -u
fail=0
hook="$(dirname "$0")/../hooks/fxa-bash-guard.sh"
check() { # check <want exit> <command> [run_in_background]
  local got
  jq -n --arg c "$2" --argjson bg "${3:-false}" '{tool_input: {command: $c, run_in_background: $bg}}' | bash "$hook" 2>/dev/null; got=$?
  if [ "$got" = "$1" ]; then printf 'ok   %s: %s\n' "$1" "$2"
  else printf 'FAIL want %s got %s: %s\n' "$1" "$got" "$2"; fail=1; fi
}
check 2 'until grep -q DONE out.log; do sleep 3; done; cat out.log'
# The block names the way that passes, for a server or app the agent started.
msg="$(jq -n '{tool_input: {command: "while ! curl -sf localhost:3000; do sleep 2; done"}}' | bash "$hook" 2>&1 >/dev/null)"
case "$msg" in *'for i in $(seq 1 60)'*) printf 'ok   the block shows a bounded for loop\n' ;; *) printf 'FAIL the block shows no bounded for loop\n'; fail=1 ;; esac
check 2 'while true; do curl -sf localhost:9000 && break; sleep 2; done'
check 2 'sleep 240; cat /workspace/.fxa-cov/small.summary'
check 2 'pkill -f snake-profile; sleep 1'
check 2 'pkill -9 -f "playwright test --project=local"'
check 0 'until grep -q DONE out.log; do sleep 3; done' true
check 0 "pkill -f '[p]laywright test'"
check 2 "sed -i 's/a/b/' serve.js && pkill -f '[s]erv'"
check 2 "pkill -f '[/]tmp/perf/serve.js'; sleep 1; nohup node /tmp/perf/serve.js > /tmp/s.log 2>&1 &"
check 0 "pkill -f '[s]erve.js'; echo restarted"
check 0 'pkill -x firefox-bin; sleep 1; ls'
check 0 'timeout 270 tail --pid=$(pgrep -f "[p]laywright test" | head -1) -f /dev/null; tail -20 run.log'
check 2 'pid=$(pgrep -f "[m]easure.js" | head -1); timeout 570 tail --pid=$pid -f /dev/null; cat out.log'
check 0 'for f in a b; do echo $f; done'
check 0 'grep -n "sleep" lib/x.ts; git log --oneline -3'
check 0 'for i in $(seq 1 60); do curl -sf -m2 localhost:9000/__heartbeat__ && break; sleep 2; done'
check 0 '(while true; do free -m >> mem.log; sleep 3; done) & npx jest x.spec.ts'
check 0 "cat > launch.sh <<'EOF'
until curl -sf localhost:3030; do sleep 2; done
EOF
bash launch.sh &"
check 2 'cat > a.sh <<EOF
x
EOF
until grep -q DONE out; do sleep 3; done'
check 0 'bash ~/.claude/skills/fxa-functional-local/run.sh wait'
exit "$fail"
