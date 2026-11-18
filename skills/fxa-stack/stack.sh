#!/usr/bin/env bash
# Check, start, and diagnose the FxA stack on the sandbox VM. See SKILL.md.
set -u
ok() { printf '  %-16s %-5s %s\n' "$1" "$2" "$3"; }
http() { curl -sf -o /dev/null --max-time 3 "$1"; }
tcp() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

CHECKS='mysql|mysqladmin ping -u root --silent
redis|redis-cli ping
firestore|tcp 9090
goaws|tcp 4100
auth|http http://localhost:9000/__heartbeat__
inbox|tcp 9001
content (nginx)|http http://localhost:3030/
settings|http http://localhost:3000/settings/static/js/bundle.js
profile|http http://localhost:1111/__heartbeat__
admin-server|tcp 8095
123done|http http://localhost:8080/
321done|http http://localhost:10139/'

status() {
  local down=0 name check
  while IFS='|' read -r name check; do
    if eval "$check" >/dev/null 2>&1; then ok "$name" up ""; else ok "$name" DOWN "$check"; down=$((down + 1)); fi
  done <<< "$CHECKS"
  return "$down"
}

# rec <action> <t0> <rc>   One line per stack start or restart, for the host's metrics.
rec() {
  printf '{"at":%s,"action":"%s","secs":%s,"ok":%s}\n' "$(date +%s)" "$1" "$(( $(date +%s) - $2 ))" "$([ "$3" = 0 ] && echo true || echo false)" \
    >> "${FXA_WORKSPACE:-/workspace}/.fxa-stack-times.jsonl" 2>/dev/null || true
}

# check_for <name>   The health check of a service, by the first word of its name.
check_for() { awk -F'|' -v n="$1" '{ split($1, w, " ") } w[1] == n { print $2 }' <<< "$CHECKS"; }

# wait [name...]   Block until each service is healthy (default: auth, content,
# settings), up to 3 minutes each. For a sleep or curl loop after a change.
wait_up() {
  local n check i
  [ $# -gt 0 ] || set -- auth content settings
  for n in "$@"; do
    check="$(check_for "$n")"
    [ -n "$check" ] || { echo "wait: no health check for $n; names: $(cut -d'|' -f1 <<< "$CHECKS" | cut -d' ' -f1 | paste -sd' ' -)" >&2; return 2; }
    for i in $(seq 60); do eval "$check" >/dev/null 2>&1 && break; [ "$i" = 60 ] || sleep 3; done
    eval "$check" >/dev/null 2>&1 || { echo "wait: $n not up after 3 minutes; run: bash $0 diagnose" >&2; return 1; }
    echo "wait: $n up"
  done
}

# The services a UI check cannot run without. Others are reported, not required.
core_up() { http http://localhost:9000/__heartbeat__ && http http://localhost:3030/ && http http://localhost:3000/settings/static/js/bundle.js; }

# OAuth functional tests need 321done, and fxa-start does not always bring it up.
# One try per boot (/tmp clears at boot): a 321done that cannot start would cost each ensure up to 2 minutes.
up_321done() {
  local m="${TMPDIR:-/tmp}/fxa-321done-failed"
  http http://localhost:10139/ && return 0
  [ -e "$m" ] && { echo "321done is down; it failed to start once this boot, so OAuth specs that need it fail (rm $m to retry)"; return 0; }
  echo "321done is down; starting it with pm2"; restart 321done || : > "$m"
  return 0
}

ensure() {
  if core_up; then echo "stack already up"; up_321done; status; return 0; fi
  echo "starting the stack with fxa-start (about 2 minutes)..."
  local t0; t0=$(date +%s)
  source /etc/agent-env.sh 2>/dev/null
  fxa-start > /tmp/fxa-start.log 2>&1 || echo "fxa-start exited non-zero; see /tmp/fxa-start.log"
  local i
  for i in $(seq 40); do core_up && break; sleep 3; done
  core_up && up_321done
  status || echo "(some optional services are down; bash $0 diagnose shows why)"
  core_up || { rec start "$t0" 1; echo "auth, content, or settings is down; run: bash $0 diagnose"; return 1; }
  rec start "$t0" 0
}

diagnose() {
  # Only what is broken: a failed health check, or a pm2 app in "errored".
  # One-shot build steps (settings-css, settings-ftl) are "stopped" when done.
  local down; down="$(status | awk '$2 == "DOWN" || $3 == "DOWN" {print $1}')"
  [ -z "$down" ] && ! pm2 jlist 2>/dev/null | jq -e 'any(.[]; .pm2_env.status == "errored")' >/dev/null && { echo "all services up"; return 0; }
  local name pm
  for name in $down; do
    case "$name" in auth|inbox|profile|content) pm="$name" ;; settings) pm=settings-react ;;
      admin-server) echo "== admin-server is down: pm2 logs admin-server, /tmp/admin-start.log, /tmp/admin-build.log"; pm2 logs admin-server --lines 5 --nostream 2>/dev/null; tail -5 /tmp/admin-build.log 2>/dev/null; continue ;;
      mysql|redis|firestore|goaws) echo "== ${name} is down: journalctl -u ${name/redis/redis-server} -n 30 (firestore: firestore-emulator)"; continue ;; *) continue ;; esac
    echo "== ${name} is down (pm2 ${pm}: $(pm2 jlist 2>/dev/null | jq -r --arg n "$pm" '.[] | select(.name == $n) | .pm2_env.status' || echo unknown))"
    pm2 logs "$pm" --lines 15 --nostream --err 2>/dev/null | grep -v TAILING | tail -15
  done
  pm2 jlist 2>/dev/null | jq -r '.[] | select(.pm2_env.status == "errored") | .name' | while read -r pm; do
    echo "== pm2 ${pm} is errored"; pm2 logs "$pm" --lines 15 --nostream --err 2>/dev/null | grep -v TAILING | tail -15
  done
}

ROOT="${FXA_ROOT:-/workspace}"

# Same auth client and TOTP math as packages/functional-tests (targets/local.ts, lib/totp.ts).
account() {
  case "${1:-}" in verified|unverified|2fa) ;; *) echo "usage: $0 account verified|unverified|2fa" >&2; return 2 ;; esac
  STATE="$1" ROOT="$ROOT" node - <<'JS'
const r = (m) => require(require.resolve(m, { paths: [process.env.ROOT] }));
const mod = r('fxa-auth-client'), AuthClient = mod.default || mod;
const client = new AuthClient('http://localhost:9000');
const state = process.env.STATE;
const email = `stack-${require('crypto').randomBytes(6).toString('hex')}@restmail.net`;
const password = 'stack-test-password';
(async () => {
  const opts = state === 'unverified' ? { lang: 'en' } : { lang: 'en', preVerified: 'true' };
  const { uid, sessionToken } = await client.signUp(email, password, opts);
  const out = { email, password, uid, sessionToken, verified: state !== 'unverified' };
  if (state === '2fa') {
    const { authenticator } = r('otplib');
    const totp = new authenticator.Authenticator();
    totp.options = { ...authenticator.options, encoding: 'hex' };
    const { secret } = await client.createTotpToken(sessionToken, {});
    await client.verifyTotpSetupCode(sessionToken, totp.generate(secret));
    await client.completeTotpSetup(sessionToken);
    out.totpSecret = secret;
  }
  console.log(JSON.stringify(out));
})().catch((e) => { console.error(`account: ${e.message}`); process.exit(1); });
JS
}

# Recreate one pm2 app from the pm2 config that defines it, with KEY=VAL added to its env.
# Not `pm2 restart --update-env`: that copies the caller's whole env (NODE_ENV) into the app.
restart() {
  local svc="${1:-}" kv
  [ -n "$svc" ] || { echo "usage: $0 restart <pm2 service> [KEY=VAL...]" >&2; return 2; }
  shift
  for kv in "$@"; do [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "restart: not KEY=VAL: $kv" >&2; return 2; }; done
  local cfg="${TMPDIR:-/tmp}/fxa-stack-restart-$svc.config.js"
  # fxa-start runs from /tmp/<svc>-pm2.config.js wrappers when they exist, so those win.
  SVC="$svc" OUT="$cfg" ROOT="$ROOT" node - "$@" <<'JS' || return 1
const fs = require('fs'), path = require('path');
const { SVC, OUT, ROOT } = process.env;
const ls = (d, f) => { try { return fs.readdirSync(d).filter(f).map((n) => path.join(d, n)); } catch { return []; } };
const files = [...ls('/tmp', (n) => n.endsWith('-pm2.config.js')),
  ...ls(path.join(ROOT, 'packages'), () => true).map((d) => path.join(d, 'pm2.config.js')).filter(fs.existsSync)];
for (const f of files) {
  let apps; try { apps = require(f).apps || []; } catch { continue; }
  const app = apps.find((a) => a.name === SVC);
  if (!app) continue;
  const extra = Object.fromEntries(process.argv.slice(2).map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
  fs.writeFileSync(OUT, `module.exports = ${JSON.stringify({ apps: [{ ...app, env: { ...app.env, ...extra } }] }, null, 2)};\n`);
  console.log(`restart: ${SVC} from ${f}${Object.keys(extra).length ? ' with ' + Object.keys(extra).join(', ') : ''}`);
  process.exit(0);
}
console.error(`restart: no pm2 config defines ${SVC}`); process.exit(1);
JS
  pm2 delete "$svc" >/dev/null 2>&1
  # cwd: 123done's config has a cwd relative to the repo root. agent-env.sh: the env fxa-start gave it (GEODB_LOCATION_OVERRIDE).
  (cd "$ROOT" && { source /etc/agent-env.sh 2>/dev/null; true; } && env -u NODE_ENV pm2 start "$cfg" >/dev/null) || { echo "restart: pm2 start failed" >&2; return 1; }
  local name="$svc" check i; [ "$svc" = settings-react ] && name=settings
  check="$(check_for "$name")"
  [ -n "$check" ] || { echo "restart: $svc started; no health check for it, see pm2 list"; return 0; }
  for i in $(seq 40); do eval "$check" >/dev/null 2>&1 && { echo "restart: $svc up"; return 0; }; sleep 3; done
  echo "restart: $svc not healthy after 2 minutes; run: pm2 logs $svc --lines 50 --nostream" >&2; return 1
}

STRAPI_DIR="${FXA_STRAPI_DIR:-/home/agent/fxa-strapi}"
# 127.0.0.1, not localhost: Node resolves localhost to ::1 first, and Strapi listens on IPv4 only.
STRAPI="${FXA_STRAPI_URL:-http://127.0.0.1:1337}"

# strapi [seed.json|off]   Run fxa-strapi on :1337, seed Relying Parties, and turn CMS on in auth and content.
# The default seed is the content the CMS functional tests expect. `off` undoes it all.
strapi() {
  if [ "${1:-}" = off ]; then
    pm2 delete strapi >/dev/null 2>&1; restart auth && restart content; return
  fi
  local seed="${1:-$(dirname "$0")/strapi-seed.json}"
  [ -f "$seed" ] || { echo "strapi: no seed file $seed" >&2; return 2; }
  if [ ! -d "$STRAPI_DIR/.git" ]; then
    echo "strapi: cloning mozilla/fxa-strapi to $STRAPI_DIR"
    git clone -q -b dev https://github.com/mozilla/fxa-strapi "$STRAPI_DIR" || return 1
  fi
  cd "$STRAPI_DIR" || return 1
  # npm 11 rejects its lockfile (esbuild optional deps), and one dependency is a git+ssh URL.
  [ -d node_modules ] || GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=ssh://git@github.com/ \
    npx -y npm@10.9.2 ci --no-audit --no-fund --loglevel=error || { echo "strapi: npm ci failed" >&2; return 1; }
  [ -f .env ] || { local r i; for i in 1 2 3 4 5 6; do r[$i]="$(openssl rand -base64 16)"; done
    printf 'HOST=127.0.0.1\nPORT=1337\nAPP_KEYS=%s,%s\nAPI_TOKEN_SALT=%s\nADMIN_JWT_SECRET=%s\nTRANSFER_TOKEN_SALT=%s\nJWT_SECRET=%s\n' "${r[@]}" > .env; }
  [ -d build ] || npm run build > /tmp/strapi-build.log 2>&1 || { echo "strapi: build failed; see /tmp/strapi-build.log" >&2; return 1; }
  if ! http "$STRAPI/_health"; then
    pm2 delete strapi >/dev/null 2>&1
    NODE_ENV=production pm2 start npm --name strapi --cwd "$STRAPI_DIR" -- run start >/dev/null || return 1
    local i; for i in $(seq 60); do http "$STRAPI/_health" && break; sleep 2; done
    http "$STRAPI/_health" || { echo "strapi: not up after 2 minutes; run: pm2 logs strapi --lines 50 --nostream" >&2; return 1; }
  fi
  echo "strapi: up on :1337 (admin: $STRAPI/admin)"
  # fxa-strapi seeds no API token: make a local admin and a full-access token once. They live in .tmp with the database.
  mkdir -p .tmp; BASE="$STRAPI" DIR="$STRAPI_DIR/.tmp" node <<'JS' || return 1
const fs = require('fs'), { BASE, DIR } = process.env;
const tokFile = `${DIR}/fxa-stack-token`, admFile = `${DIR}/fxa-stack-admin.json`;
const call = async (method, path, body, auth) => {
  const r = await fetch(BASE + path, { method, headers: { 'Content-Type': 'application/json', ...(auth && { Authorization: `Bearer ${auth}` }) },
    body: body && JSON.stringify(body) });
  if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${await r.text()}`);
  return r.json();
};
(async () => {
  if (fs.existsSync(tokFile)) {
    const t = fs.readFileSync(tokFile, 'utf8').trim();
    if ((await fetch(`${BASE}/api/relying-parties?pagination[pageSize]=1`, { headers: { Authorization: `Bearer ${t}` } })).ok) return;
  }
  let jwt;
  if (!(await call('GET', '/admin/init')).data.hasAdmin) {
    const adm = { email: 'fxa-stack@example.com', password: `Aa1${require('crypto').randomBytes(12).toString('hex')}` };
    jwt = (await call('POST', '/admin/register-admin', { firstname: 'FxA', lastname: 'Stack', ...adm })).data;
    fs.writeFileSync(admFile, JSON.stringify(adm), { mode: 0o600 });
  } else if (fs.existsSync(admFile)) {
    jwt = (await call('POST', '/admin/login', JSON.parse(fs.readFileSync(admFile, 'utf8')))).data;
  } else throw new Error(`an admin exists that stack.sh did not make: make a full-access API token in ${BASE}/admin and write it to ${tokFile}`);
  jwt = jwt.accessToken || jwt.token;
  const key = (await call('POST', '/admin/api-tokens', { name: `fxa-stack-${Date.now()}`, type: 'full-access', lifespan: null, description: 'stack.sh strapi' }, jwt)).data.accessKey;
  fs.writeFileSync(tokFile, key, { mode: 0o600 });
})().catch((e) => { console.error(`strapi: no API token: ${e.message}`); process.exit(1); });
JS
  local tok; tok="$(cat .tmp/fxa-stack-token)"
  TOK="$tok" SEED="$seed" BASE="$STRAPI" node <<'JS' || return 1
const { TOK, SEED, BASE } = process.env;
const h = { Authorization: `Bearer ${TOK}`, 'Content-Type': 'application/json' };
const call = async (method, path, body) => {
  const r = await fetch(BASE + path, { method, headers: h, body: body && JSON.stringify({ data: body }) });
  if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${await r.text()}`);
  return r.json();
};
(async () => {
  for (const rp of JSON.parse(require('fs').readFileSync(SEED, 'utf8'))) {
    const q = `filters[clientId][$eq]=${rp.clientId}&filters[entrypoint][$eq]=${encodeURIComponent(rp.entrypoint)}`;
    const [old] = (await call('GET', `/api/relying-parties?${q}&status=published`)).data;
    if (old) await call('PUT', `/api/relying-parties/${old.documentId}?status=published`, rp);
    else await call('POST', '/api/relying-parties?status=published', rp);
    console.log(`strapi: ${old ? 'updated' : 'added'} ${rp.clientId} entrypoint=${rp.entrypoint}`);
  }
})().catch((e) => { console.error(`strapi: seed failed: ${e.message}`); process.exit(1); });
JS
  cd - >/dev/null
  # TTLs of 1 s: a change published in the admin shows on the next page load.
  # auth makes its CMS clients only when a Stripe key is set; without them it answers {}. JWT tokens and subscriptions stay off.
  # Recovery phone as CI has it, for the CMS 2FA specs' recovery choice step. No Twilio credentials: no SMS is sent.
  restart auth CMS_ENABLED=true STRAPI_CLIENT_GRAPHQL_API_URI="$STRAPI/graphql" STRAPI_CLIENT_API_KEY="$tok" \
    STRAPI_CLIENT_MEM_CACHE_TTL=1 STRAPI_CLIENT_FIRESTORE_CACHE_TTL=1 STRAPI_CLIENT_FIRESTORE_OFFLINE_CACHE_TTL=1 SUBHUB_STRIPE_APIKEY=sk_test_local_cms_only \
    RECOVERY_PHONE__ENABLED=true RECOVERY_PHONE__MAX_UID_PER_NUMBER=50 RECOVERY_PHONE__TWILIO__CREDENTIAL_MODE= || return 1
  restart content CMS_ENABLED=true || return 1
  local rp; rp="$(jq -r '.[0] | "clientId=\(.clientId)&entrypoint=\(.entrypoint)"' "$seed")"
  curl -sf --max-time 10 "http://localhost:9000/v1/cms/config?$rp" | jq -e 'has("clientId")' >/dev/null \
    || { echo "strapi: auth returns no CMS config for $rp" >&2; return 1; }
  echo "strapi: CMS on in auth and content; config for $rp OK"
}

case "${1:-status}" in
  status) echo "FxA stack:"; status; exit $? ;;
  ensure) ensure ;;
  diagnose) diagnose ;;
  account) account "${2:-}" ;;
  restart) shift; t0=$(date +%s); restart "$@"; rc=$?; rec "restart ${1:-}" "$t0" "$rc"; exit "$rc" ;;
  wait) shift; wait_up "$@" ;;
  strapi) shift; t0=$(date +%s); strapi "$@"; rc=$?; rec strapi "$t0" "$rc"; exit "$rc" ;;
  *) echo "usage: $0 status|ensure|diagnose|account <state>|restart <service> [KEY=VAL...]|wait [service...]|strapi [seed.json|off]" >&2; exit 2 ;;
esac
