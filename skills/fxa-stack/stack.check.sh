#!/usr/bin/env bash
# Offline check for stack.sh argument parsing and the env that restart builds.
#   bash skills/fxa-stack/stack.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
S="$(cd "$(dirname "$0")" && pwd)/stack.sh"
export TMPDIR="$tmp" FXA_ROOT="$tmp/repo" PATH="$tmp/bin:$PATH"

# A fake repo with one pm2 app, and a pm2 that only logs its calls.
mkdir -p "$tmp/repo/packages/demo" "$tmp/bin"
echo "module.exports = { apps: [{ name: 'demo-svc', script: 'x.js', env: { NODE_ENV: 'dev', PORT: '1' } }] };" > "$tmp/repo/packages/demo/pm2.config.js"
printf '#!/bin/sh\necho "$@" >> %s/pm2.log\n' "$tmp" > "$tmp/bin/pm2"; chmod +x "$tmp/bin/pm2"

bash "$S" account bogus >/dev/null 2>&1; check "account rejects an unknown state" 2 $?
bash "$S" restart >/dev/null 2>&1; check "restart needs a service" 2 $?
bash "$S" restart demo-svc 1BAD=x >/dev/null 2>&1; check "restart rejects a bad key" 2 $?
bash "$S" restart demo-svc NOEQUALS >/dev/null 2>&1; check "restart rejects a word with no =" 2 $?
check "a rejected restart does not call pm2" "" "$(cat "$tmp/pm2.log" 2>/dev/null)"
# The rest reads pm2 configs with node, which the runner has and a bare test host may not.
command -v node >/dev/null || { echo "skip: restart needs node"; exit "$fail"; }
bash "$S" restart no-such-svc A=1 >/dev/null 2>&1; check "restart fails for a service no config defines" 1 $?

NODE_ENV=development bash "$S" restart demo-svc PORT=2 EXTRA='a=b c' >/dev/null 2>&1; check "restart with KEY=VAL succeeds" 0 $?
env_of() { node -e 'console.log(JSON.stringify(require(process.argv[1]).apps[0].env))' "$tmp/fxa-stack-restart-demo-svc.config.js"; }
check "restart merges KEY=VAL over the config env" '{"NODE_ENV":"dev","PORT":"2","EXTRA":"a=b c"}' "$(env_of)"
check "restart deletes then starts from the built config" "delete demo-svc|start $tmp/fxa-stack-restart-demo-svc.config.js" "$(paste -sd'|' "$tmp/pm2.log")"

bash "$S" restart demo-svc >/dev/null 2>&1
check "a plain restart goes back to the config env" '{"NODE_ENV":"dev","PORT":"1"}' "$(env_of)"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
