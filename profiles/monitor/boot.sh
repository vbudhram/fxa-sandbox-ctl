#!/bin/bash
# profiles/monitor/boot.sh: set up Monitor beside the running FxA stack. The controller
# runs it once as root on the runner, detached, after the egress firewall and before
# the agent edits anything. Steps from the spike (ai/docs/004); each one is skipped
# when its result is already there. Repo code runs only as agent, behind the firewall.
# Log: /var/log/profile-boot.log. Done: /run/fxa-profile/ready, or failed.
set -uo pipefail
M=/home/agent/monitor N=/opt/node20 S=/home/agent/.monitor-oauth
# Root writes the markers where the agent cannot plant a link: it runs beside this script.
R=/run/fxa-profile READY=/run/fxa-profile/ready FAIL=/run/fxa-profile/failed
install -d -m 755 -o root -g root "$R"; rm -f "$READY" "$FAIL"
step() { echo "$(date -u +%T) $*"; }
die() { step "FAILED: $*"; echo "$*" > "$FAIL"; chmod 644 "$FAIL"; exit 1; }
as_agent() { sudo -u agent -H bash -c "cd $M && export PATH=$N/bin:\$PATH && $1" < /dev/null; }
t0=$(date +%s)

step "Node 20"
[ -x "$N/bin/node" ] || N_PREFIX="$N" n 20.20.2 > /dev/null || die "could not install Node 20"

step "Postgres"
if ! command -v psql > /dev/null; then
  { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q postgresql; } > /dev/null || die "could not install Postgres"
fi
systemctl start postgresql || die "Postgres did not start"
pg() { sudo -u postgres psql -qtAc "$1"; }
[ "$(pg "select 1 from pg_roles where rolname = 'blurts'")" = 1 ] || pg "CREATE USER blurts WITH PASSWORD 'blurts' CREATEDB;" || die "could not create the Postgres user"
for db in blurts test-blurts; do
  [ "$(pg "select 1 from pg_database where datname = '$db'")" = 1 ] || pg "CREATE DATABASE \"$db\" OWNER blurts;" || die "could not create database $db"
done

# The auth server fills its client table on its first OAuth DB call, which a restored
# slot has not made yet; a client inserted before that fill is not seen. Make the call.
step "OAuth client"
for i in $(seq 60); do
  curl -s -o /dev/null -m 10 localhost:9000/v1/client/0000000000000000
  [ "$(mysql -uroot -h127.0.0.1 -Nse 'select count(*) from fxa_oauth.clients' 2>/dev/null || echo 0)" -gt 0 ] && break; sleep 5
done
if [ ! -s "$S" ]; then
  cid="$(openssl rand -hex 8)"
  sudo -u agent bash -c "umask 077; { echo $cid; openssl rand -hex 32; } > $S"
  hs="$(sed -n 2p "$S" | xxd -r -p | sha256sum | cut -d' ' -f1)"
  mysql -uroot -h127.0.0.1 fxa_oauth -e "INSERT INTO clients (id, name, imageUri, redirectUri, canGrant, publicClient, trusted, allowedScopes, hashedSecret)
    VALUES (UNHEX('$cid'), 'Mozilla Monitor (local)', '', 'http://localhost:6060/api/auth/callback/fxa', 1, 0, 1, 'https://identity.mozilla.com/account/subscriptions', UNHEX('$hs'))" \
    || { rm -f "$S"; die "could not seed the OAuth client"; }
fi

step ".env.local"
[ -f "$M/.env.local" ] || sudo -u agent bash -c "umask 077; cat > $M/.env.local" <<EOF || die "could not write .env.local"
APP_ENV=local
SERVER_URL=http://localhost:6060
NEXTAUTH_URL=http://localhost:6060
NEXTAUTH_SECRET=$(openssl rand -base64 32)
DATABASE_URL=postgres://blurts:blurts@localhost:5432/blurts
REDIS_URL=redis://redis.mock
HIBP_KANON_API_ROOT=http://localhost:6060/api/mock/hibp
HIBP_API_ROOT=http://localhost:6060/api/mock/hibp
HIBP_KANON_API_TOKEN=mock-api-token
HIBP_NOTIFY_TOKEN=unsafe-default-token-for-dev
SMTP_URL=
SENTRY_DSN=
NEXT_PUBLIC_SENTRY_DSN=
OAUTH_AUTHORIZATION_URI=http://localhost:3030/authorization
OAUTH_TOKEN_URI=http://localhost:9000/v1/token
OAUTH_ACCOUNT_URI=http://localhost:9000/v1
OAUTH_PROFILE_URI=http://localhost:1111/v1/profile
OAUTH_METRICS_FLOW_URI=http://localhost:3030/metrics-flow
FXA_SETTINGS_URL=http://localhost:3030/settings
OAUTH_CLIENT_ID=$(sed -n 1p "$S")
OAUTH_CLIENT_SECRET=$(sed -n 2p "$S")
EOF

step "npm ci"
[ -d "$M/node_modules" ] || as_agent "npm ci --no-audit --no-fund" || die "npm ci failed"
step "glean, nimbus and the migrations"
as_agent "npm run build-glean && npm run build-nimbus && npm run db:migrate && npm run test:db:migrate" || die "the build or migration steps failed"

step "dev server"
as_agent "nohup setsid npm run dev > /home/agent/.monitor-dev.log 2>&1 < /dev/null &"
for i in $(seq 120); do
  [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' localhost:6060/__heartbeat__)" = 200 ] && break; sleep 2
done
[ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' localhost:6060/__heartbeat__)" = 200 ] || die "the dev server did not answer on :6060 (see /home/agent/.monitor-dev.log)"

# next dev rewrites this tracked file; it is not the agent's change.
as_agent "git update-index --skip-worktree next-env.d.ts" || true

echo "ready after $(( $(date +%s) - t0 ))s" > "$READY"; chmod 644 "$READY"
step "ready after $(( $(date +%s) - t0 ))s"
