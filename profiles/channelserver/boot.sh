#!/bin/bash
# profiles/channelserver/boot.sh: build mozilla-services/channelserver and run it on :8058, and point
# FxA's content server at it (now if it runs, and at each fxa-start), so a pairing flow uses this build.
# The controller runs it once as root on the runner, detached, after the egress firewall. Each step
# is skipped when its result is there. Repo code runs only as agent. Log: /var/log/profile-boot.log.
# Done: /run/fxa-profile/ready, or failed.
set -uo pipefail
S=/home/agent/channelserver RH=/opt/rust/rustup CH=/opt/rust/cargo
R=/run/fxa-profile READY=/run/fxa-profile/ready FAIL=/run/fxa-profile/failed
install -d -m 755 -o root -g root "$R"; rm -f "$READY" "$FAIL"
step() { echo "$(date -u +%T) $*"; }
die() { step "FAILED: $*"; echo "$*" > "$FAIL"; chmod 644 "$FAIL"; exit 1; }
t0=$(date +%s)
[ -d "$S/.git" ] || die "no channelserver checkout at $S"

step "packages"
pk="build-essential pkg-config libssl-dev"
dpkg -s $pk > /dev/null 2>&1 || { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-upgrade $pk; } > /dev/null || die "could not install the build packages"

step "Rust"
# The repo's CI builds and lints on stable, not on its rust-version line.
ru() { RUSTUP_HOME=$RH CARGO_HOME=$CH "$CH/bin/rustup" "$@"; }
[ -x "$CH/bin/rustup" ] || curl -sSf https://sh.rustup.rs | RUSTUP_HOME=$RH CARGO_HOME=$CH sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain none > /dev/null \
  || die "could not install rustup"
ru toolchain install stable --profile minimal -c rustfmt -c clippy > /dev/null 2>&1 && ru default stable > /dev/null 2>&1 || die "could not install Rust stable"
chmod -R a+rX /opt/rust
step "rustc $(RUSTUP_HOME=$RH $CH/bin/rustc --version | cut -d' ' -f2)"

# fxa-start's pm2 passes the shell's env to the content server: each start pairs through :8058.
step "the content server's channel server"
grep -q '^export PAIRING_SERVER_BASE_URI=' /etc/agent-env.sh || cat >> /etc/agent-env.sh <<'ENV' || die "could not write /etc/agent-env.sh"
# The FxA Channelserver team: the content server pairs through the local channelserver (profiles/channelserver/boot.sh).
export PAIRING_SERVER_BASE_URI=ws://localhost:8058
ENV

# The helper rebuilds and restarts the server; the agent runs it again after a change.
step "channelserver-local"
cat > /usr/local/bin/channelserver-local <<'SH' || die "could not write channelserver-local"
#!/bin/bash
# channelserver-local [--no-build]: build channelserver and run it on :8058. A running FxA content
# server that pairs elsewhere restarts to pair through it (its config and its CSP). Run it as agent.
set -euo pipefail
[ "$(id -un)" = agent ] || { echo "ERROR: run channelserver-local as agent" >&2; exit 1; }
export RUSTUP_HOME=/opt/rust/rustup PATH=/opt/rust/cargo/bin:$PATH
S=/home/agent/channelserver URI=ws://localhost:8058 LOG=/home/agent/.channelserver.log
cd "$S"
[ "${1:-}" = --no-build ] || cargo build -q 2>&1 | tail -20
# By name, never -f: the agent's own command line holds the guide, which names this binary.
pkill -u agent -x channelserver || true; sleep 1
PAIR_PORT=8058 PAIR_HOSTNAME=127.0.0.1 PAIR_HUMAN_LOGS=true PAIR_MMDB_LOC="$S/mmdb/latest/GeoLite2-City.mmdb" RUST_LOG=info \
  nohup setsid target/debug/channelserver > "$LOG" 2>&1 < /dev/null &
for _ in $(seq 30); do [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' localhost:8058/__heartbeat__)" = 200 ] && break; sleep 1; done
[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' localhost:8058/__heartbeat__)" = 200 ] || { echo "ERROR: channelserver did not answer on :8058 (see $LOG)" >&2; exit 1; }
# No content server yet (GCE starts FxA on demand): fxa-start reads PAIRING_SERVER_BASE_URI from /etc/agent-env.sh.
cur="$(curl -s -m 5 localhost:3030/.well-known/fxa-client-configuration | jq -r '.pairing_server_base_uri // empty' || true)"
if [ -z "$cur" ]; then
  echo "channelserver $(git rev-parse --short HEAD) on $URI; FxA is not running, and fxa-start pairs through it"; exit 0
fi
if [ "$cur" != "$URI" ]; then
  [ -f /tmp/content-pm2.config.js ] || { echo "ERROR: no /tmp/content-pm2.config.js: run fxa-start" >&2; exit 1; }
  # The config's cwd can name /workspace, which a session with several repos turns into a folder of links.
  node -e 'const fs = require("fs"), c = require("/tmp/content-pm2.config.js"), a = c.apps[0];
    a.env.PAIRING_SERVER_BASE_URI = process.argv[1]; a.cwd = a.cwd.replace(/^\/workspace(?=\/)/, process.argv[2]);
    fs.writeFileSync("/tmp/content-pairing.json", JSON.stringify(c));' "$URI" "${FXA_WORKSPACE:-/home/agent/fxa}"
  pm2 delete content > /dev/null 2>&1 || true
  pm2 start /tmp/content-pairing.json > /dev/null
  for _ in $(seq 60); do
    cur="$(curl -s -m 5 localhost:3030/.well-known/fxa-client-configuration | jq -r '.pairing_server_base_uri // empty' || true)"
    [ "$cur" = "$URI" ] && break; sleep 2
  done
  [ "$cur" = "$URI" ] || { echo "ERROR: the content server still gives pairing ${cur:-nothing}, not $URI" >&2; exit 1; }
fi
echo "channelserver $(git rev-parse --short HEAD) on $URI; the content server pairs through it"
SH
chmod 755 /usr/local/bin/channelserver-local

step "cargo build and the server on :8058 (the first build takes a few minutes)"
sudo -u agent -H bash -lc channelserver-local < /dev/null > /var/log/channelserver-build.log 2>&1 || die "$(tail -1 /var/log/channelserver-build.log) (see /var/log/channelserver-build.log)"
tail -1 /var/log/channelserver-build.log

echo "ready after $(( $(date +%s) - t0 ))s" > "$READY"; chmod 644 "$READY"
step "ready after $(( $(date +%s) - t0 ))s"
