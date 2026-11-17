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
bash "$S" wait nosuch >/dev/null 2>&1; check "wait rejects an unknown service" 2 $?
check "wait names the known services" 1 "$(bash "$S" wait nosuch 2>&1 | grep -c 'names: mysql redis firestore goaws auth inbox content settings profile admin-server 123done 321done')"
# The rest reads pm2 configs with node, which the runner has and a bare test host may not.
command -v node >/dev/null || { echo "skip: restart needs node"; exit "$fail"; }
bash "$S" restart no-such-svc A=1 >/dev/null 2>&1; check "restart fails for a service no config defines" 1 $?

NODE_ENV=development bash "$S" restart demo-svc PORT=2 EXTRA='a=b c' >/dev/null 2>&1; check "restart with KEY=VAL succeeds" 0 $?
env_of() { node -e 'console.log(JSON.stringify(require(process.argv[1]).apps[0].env))' "$tmp/fxa-stack-restart-demo-svc.config.js"; }
check "restart merges KEY=VAL over the config env" '{"NODE_ENV":"dev","PORT":"2","EXTRA":"a=b c"}' "$(env_of)"
check "restart deletes then starts from the built config" "delete demo-svc|start $tmp/fxa-stack-restart-demo-svc.config.js" "$(paste -sd'|' "$tmp/pm2.log")"

bash "$S" restart demo-svc >/dev/null 2>&1
check "a plain restart goes back to the config env" '{"NODE_ENV":"dev","PORT":"1"}' "$(env_of)"

# ensure starts 321done with pm2 when the core is up and 10139 does not answer.
mkdir -p "$tmp/repo/packages/123done"
echo "module.exports = { apps: [{ name: '321done', script: 'node server.js', env: { PORT: '10139' } }] };" > "$tmp/repo/packages/123done/pm2.config.js"
printf '#!/bin/sh\ncase "$*" in *10139*) grep -q "^start" %s/pm2.log 2>/dev/null ;; *) exit 0 ;; esac\n' "$tmp" > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
: > "$tmp/pm2.log"
bash "$S" ensure >/dev/null 2>&1
check "ensure starts a down 321done with pm2" "delete 321done|start $tmp/fxa-stack-restart-321done.config.js" "$(paste -sd'|' "$tmp/pm2.log")"

# A 321done that never answers: one start per boot, then ensure skips it (a marker in TMPDIR, which /tmp clears at boot).
printf '#!/bin/sh\ncase "$*" in *10139*) exit 7 ;; *) exit 0 ;; esac\n' > "$tmp/bin/curl"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"; chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"
: > "$tmp/pm2.log"; rm -f "$tmp/fxa-321done-failed"; bash "$S" ensure >/dev/null 2>&1
check "a 321done start that fails leaves the boot marker" "yes" "$([ -e "$tmp/fxa-321done-failed" ] && echo yes)"
: > "$tmp/pm2.log"; out="$(bash "$S" ensure 2>&1)"
check "the next ensure skips the start and says why" "0|1" "$(grep -c 321done "$tmp/pm2.log")|$(grep -c 'failed to start once this boot' <<< "$out")"

# strapi: seeds each entry (add, then update), and restarts auth and content with CMS on.
bash "$S" strapi "$tmp/none.json" >/dev/null 2>&1; check "strapi needs a seed file" 2 $?
for s in auth content; do echo "module.exports = { apps: [{ name: '$s', script: 'x.js', env: { CMS_ENABLED: 'false' } }] };" > "$tmp/repo/packages/demo/$s.js"; done
echo "module.exports = { apps: [...require('./auth.js').apps, ...require('./content.js').apps] };" > "$tmp/repo/packages/demo/pm2.config.js"
mkdir -p "$tmp/strapi/.git" "$tmp/strapi/node_modules" "$tmp/strapi/build" "$tmp/strapi/src"; : > "$tmp/strapi/.env"
echo "const METERING_POC_TOKEN = 'tok-local';" > "$tmp/strapi/src/index.js"
echo '[{"clientId":"c1","entrypoint":"e1","shared":{"buttonColor":"#000"}}]' > "$tmp/seed.json"
printf '#!/bin/sh\ncase "$*" in *cms/config*) echo "{\\"clientId\\":\\"c1\\"}" ;; esac; exit 0\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
node -e '
let n = 0; require("http").createServer((q, r) => { let b = ""; q.on("data", (c) => b += c); q.on("end", () => {
  require("fs").appendFileSync(process.argv[1], `${q.method} ${decodeURIComponent(q.url)} ${q.headers.authorization}\n`);
  r.end(JSON.stringify({ data: q.method === "GET" ? (n++ ? [{ documentId: "d1" }] : []) : {} })); }); }).listen(0, "127.0.0.1", function () {
  require("fs").writeFileSync(process.argv[2], String(this.address().port)); });' "$tmp/strapi.log" "$tmp/port" & srv=$!
# /bin/sleep: an ensure check above stubs sleep in PATH.
for i in $(seq 50); do [ -s "$tmp/port" ] && break; /bin/sleep 0.2; done
export FXA_STRAPI_DIR="$tmp/strapi" FXA_STRAPI_URL="http://127.0.0.1:$(cat "$tmp/port")"
: > "$tmp/pm2.log"; bash "$S" strapi "$tmp/seed.json" >/dev/null 2>&1; rc1=$?; bash "$S" strapi "$tmp/seed.json" >/dev/null 2>&1; rc2=$?
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
check "strapi runs twice" "0 0" "$rc1 $rc2"
check "strapi adds the entry, then updates it, with the seeded token" \
  "GET /api/relying-parties?filters[clientId][\$eq]=c1&filters[entrypoint][\$eq]=e1&status=published Bearer tok-local|POST /api/relying-parties?status=published Bearer tok-local|GET /api/relying-parties?filters[clientId][\$eq]=c1&filters[entrypoint][\$eq]=e1&status=published Bearer tok-local|PUT /api/relying-parties/d1?status=published Bearer tok-local" \
  "$(paste -sd'|' "$tmp/strapi.log")"
check "strapi turns CMS on in auth with the token and a Stripe key" "true|tok-local|true|true" \
  "$(node -e 'const e = require(process.argv[1]).apps[0].env; console.log([e.CMS_ENABLED, e.STRAPI_CLIENT_API_KEY, !!e.SUBHUB_STRIPE_APIKEY, e.RECOVERY_PHONE__ENABLED].join("|"))' "$tmp/fxa-stack-restart-auth.config.js")"
check "strapi turns CMS on in content" "true" "$(node -e 'console.log(require(process.argv[1]).apps[0].env.CMS_ENABLED)' "$tmp/fxa-stack-restart-content.config.js")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
