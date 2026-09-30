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
admin-server|tcp 8095'

status() {
  local down=0 name check
  while IFS='|' read -r name check; do
    if eval "$check" >/dev/null 2>&1; then ok "$name" up ""; else ok "$name" DOWN "$check"; down=$((down + 1)); fi
  done <<< "$CHECKS"
  return "$down"
}

# The services a UI check cannot run without. Others are reported, not required.
core_up() { http http://localhost:9000/__heartbeat__ && http http://localhost:3030/ && http http://localhost:3000/settings/static/js/bundle.js; }

ensure() {
  if core_up; then echo "stack already up"; status; return 0; fi
  echo "starting the stack with fxa-start (about 2 minutes)..."
  source /etc/agent-env.sh 2>/dev/null
  fxa-start > /tmp/fxa-start.log 2>&1 || echo "fxa-start exited non-zero; see /tmp/fxa-start.log"
  local i
  for i in $(seq 40); do core_up && break; sleep 3; done
  status || echo "(some optional services are down; bash $0 diagnose shows why)"
  core_up || { echo "auth, content, or settings is down; run: bash $0 diagnose"; return 1; }
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
  # cwd: 123done's config has a cwd relative to the repo root.
  (cd "$ROOT" && env -u NODE_ENV pm2 start "$cfg" >/dev/null) || { echo "restart: pm2 start failed" >&2; return 1; }
  local name="$svc" check i; [ "$svc" = settings-react ] && name=settings
  check="$(awk -F'|' -v n="$name" '{ split($1, w, " ") } w[1] == n { print $2 }' <<< "$CHECKS")"
  [ -n "$check" ] || { echo "restart: $svc started; no health check for it, see pm2 list"; return 0; }
  for i in $(seq 40); do eval "$check" >/dev/null 2>&1 && { echo "restart: $svc up"; return 0; }; sleep 3; done
  echo "restart: $svc not healthy after 2 minutes; run: pm2 logs $svc --lines 50 --nostream" >&2; return 1
}

case "${1:-status}" in
  status) echo "FxA stack:"; status; exit $? ;;
  ensure) ensure ;;
  diagnose) diagnose ;;
  account) account "${2:-}" ;;
  restart) shift; restart "$@" ;;
  *) echo "usage: $0 status|ensure|diagnose|account <state>|restart <service> [KEY=VAL...]" >&2; exit 2 ;;
esac
