#!/bin/bash
# 03b-toolchain.sh — the runner's Node, Claude Code and Codex, in /usr/local, the one prefix
# that wins on PATH. The Packer build runs it, and infra/firecracker/refresh.sh runs it
# in the snapshot guest. Run as root: 03b-toolchain.sh [node-version], fxa main's
# .nvmrc when it is not given.
# Prints "node <version>", "claude <version>", "codex <version>" and "nightly <version>",
# and fails when one is not what was asked for.
set -euo pipefail

# Firefox Nightly, the v2 pairing authority: FIREFOX_BINARY in /etc/agent-env.sh (06-agent-init.sh).
NIGHTLY=/opt/firefox-nightly
# Nightly changes each day: fetch it once a day, not on each refresh. A failed fetch keeps the earlier copy.
nightly() {
  local day; day="$(date -u +%F)"
  [ "$(cat "$NIGHTLY/.fetched" 2>/dev/null)" != "$day" ] || return 0
  rm -rf "$NIGHTLY.new" && mkdir -p "$NIGHTLY.new"
  # The GCE images are arm64: an x86_64 build there unpacks, but never runs. The ELF machine byte
  # proves the CPU type with no GTK, which 08-playwright.sh installs later.
  local os=linux64 elf=3e; [ "$(uname -m)" = aarch64 ] && { os=linux64-aarch64; elf=b7; }
  if curl -fsSL "https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=${os}&lang=en-US" \
    | tar -xJ -C "$NIGHTLY.new" --strip-components=1 && [ "$(od -An -tx1 -j18 -N1 "$NIGHTLY.new/firefox" 2>/dev/null | tr -d ' ')" = "$elf" ]; then
    rm -rf "$NIGHTLY" && mv "$NIGHTLY.new" "$NIGHTLY" && echo "$day" > "$NIGHTLY/.fetched"
  else
    rm -rf "$NIGHTLY.new"
    [ -x "$NIGHTLY/firefox" ] || { echo "ERROR: Firefox Nightly did not install" >&2; return 1; }
    echo "WARN: the Nightly fetch failed; the earlier copy stays" >&2
  fi
}

# opt_tool <dir> <version> <url>   A tar.gz unpacked into <dir> once for each version. A failed
# fetch keeps the earlier copy and only warns: these are one team's tools, never FxA's.
opt_tool() {
  [ "$(cat "$1/.version" 2>/dev/null)" != "$2" ] || return 0
  rm -rf "$1.new" && mkdir -p "$1.new"
  if curl -fsSL "$3" | tar -xz -C "$1.new" && echo "$2" > "$1.new/.version"; then
    rm -rf "$1" && mv "$1.new" "$1" && chmod -R a+rX "$1"
  else
    rm -rf "$1.new"; echo "WARN: $1 $2 did not install; the earlier copy stays" >&2
  fi
}

# The storage team's Spanner path with no Docker (profiles/sync-storage/boot.sh): CI's Spanner
# and Pub/Sub emulators and fake GCS, idle files for every other team. The emulator pin follows
# SPANNER_EMULATOR_VER in syncstorage-rs. Each has an amd64 and an arm64 build.
SPANNER_EMULATOR_VERSION=1.5.52
FAKE_GCS_VERSION=1.56.1
PUBSUB_EMULATOR_COMPONENT=google-cloud-sdk-pubsub-emulator-20261009074343
sync_tools() {
  local a=amd64; [ "$(uname -m)" = aarch64 ] && a=arm64
  opt_tool /opt/spanner-emulator "$SPANNER_EMULATOR_VERSION" \
    "https://storage.googleapis.com/cloud-spanner-emulator/releases/${SPANNER_EMULATOR_VERSION}/cloud-spanner-emulator_linux_${a}-${SPANNER_EMULATOR_VERSION}.tar.gz"
  opt_tool /opt/fake-gcs "$FAKE_GCS_VERSION" \
    "https://github.com/fsouza/fake-gcs-server/releases/download/v${FAKE_GCS_VERSION}/fake-gcs-server_${FAKE_GCS_VERSION}_Linux_${a}.tar.gz"
  opt_tool /opt/pubsub-emulator "$PUBSUB_EMULATOR_COMPONENT" \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/components/${PUBSUB_EMULATOR_COMPONENT}.tar.gz"
}

# FxA's Sync server (syncstorage-rs: storage and token server) as a native binary, no Docker:
# a Docker daemon gives root, and its containers skip the agent's egress and metadata rules.
# Built once for each pin, with no Python verifier (the native one asks FxA's :9000). The unit
# is not enabled: port 8000 is free for other teams, and the agent starts it in about a second.
SYNCSTORAGE_TAG=0.24.1
SYNCSTORAGE_SHA=741f609cf2e2e0fe0a812bf093e85e694098a1ce
SYNC=/opt/syncserver SYNC_CONF=/etc/syncserver.toml
syncserver_build() {
  local t; t="$(mktemp -d /tmp/syncserver.XXXXXX)" || return 1
  local env="RUSTUP_HOME=$t/rustup CARGO_HOME=$t/cargo"
  # With the sync-storage boot's build packages, so its boot runs no apt; a refresh upgrades none.
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-upgrade build-essential pkg-config cmake libmysqlclient-dev libpq-dev libssl-dev python3-dev python3-venv > /dev/null || { rm -rf "$t"; return 1; }
  git clone -q --filter=blob:none https://github.com/mozilla-services/syncstorage-rs "$t/src" \
    && git -C "$t/src" checkout -q "$SYNCSTORAGE_SHA" || { rm -rf "$t"; return 1; }
  local rv; rv="$(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' "$t/src/Cargo.toml" | head -1)"
  curl -sSf https://sh.rustup.rs | env $env sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain "${rv:-stable}" > /dev/null \
    && (cd "$t/src" && env $env "$t/cargo/bin/cargo" build -q --release --locked --bin syncserver --no-default-features --features=mysql) > "$t/build.log" 2>&1 \
    && rm -rf "$SYNC.new" && mkdir -p "$SYNC.new" && install -m 755 -s "$t/src/target/release/syncserver" "$SYNC.new/syncserver" \
    && echo "$SYNCSTORAGE_TAG" > "$SYNC.new/.version" && rm -rf "$SYNC" && mv "$SYNC.new" "$SYNC" \
    || { tail -20 "$t/build.log" >&2 2>/dev/null; rm -rf "$t" "$SYNC.new"; return 1; }
  rm -rf "$t"
}
# The databases, the migrations and the token server's node, so a start serves at once.
syncserver_setup() {
  local up=1 my="mysql -uroot -h127.0.0.1 -Nse" pid ok=""
  systemctl is-active -q mysql || { up=""; systemctl start mysql; }
  [ -f "$SYNC_CONF" ] || cat > "$SYNC_CONF" <<TOML
# FxA's Sync server for the sandbox, on :8000; tokens are checked against FxA's auth server on :9000.
master_secret = "$(openssl rand -hex 32)"
host = "127.0.0.1"
port = 8000
human_logs = 1
syncstorage.database_url = "mysql://sync:test@127.0.0.1:3306/syncstorage"
syncstorage.enabled = true
syncstorage.enable_quota = 0
syncstorage.run_migrations = true
tokenserver.database_url = "mysql://sync:test@127.0.0.1:3306/tokenserver"
tokenserver.enabled = true
tokenserver.node_type = "mysql"
tokenserver.run_migrations = true
tokenserver.fxa_email_domain = "api-accounts.stage.mozaws.net"
tokenserver.fxa_oauth_server_url = "http://localhost:9000"
tokenserver.fxa_metrics_hash_secret = "$(openssl rand -hex 16)"
TOML
  chmod 644 "$SYNC_CONF"
  $my "CREATE USER IF NOT EXISTS 'sync'@'localhost' IDENTIFIED BY 'test'; CREATE USER IF NOT EXISTS 'sync'@'%' IDENTIFIED BY 'test';
    CREATE DATABASE IF NOT EXISTS syncstorage; CREATE DATABASE IF NOT EXISTS tokenserver;
    GRANT ALL PRIVILEGES ON \`syncstorage%\`.* TO 'sync'@'localhost'; GRANT ALL PRIVILEGES ON \`tokenserver%\`.* TO 'sync'@'localhost';
    GRANT ALL PRIVILEGES ON \`syncstorage%\`.* TO 'sync'@'%'; GRANT ALL PRIVILEGES ON \`tokenserver%\`.* TO 'sync'@'%';" || return 1
  # One run as nobody makes the tables; the token server then needs its service and node rows.
  setpriv --reuid=nobody --regid=nogroup --clear-groups "$SYNC/syncserver" --config "$SYNC_CONF" > /tmp/syncserver-setup.log 2>&1 < /dev/null & pid=$!
  for _ in $(seq 60); do curl -sf -m 2 -o /dev/null localhost:8000/__heartbeat__ && { ok=1; break; }; sleep 1; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  [ -n "$ok" ] || { tail -20 /tmp/syncserver-setup.log >&2; return 1; }
  [ "$($my "select count(*) from tokenserver.services where service = 'sync-1.5'")" -gt 0 ] \
    || $my "INSERT INTO tokenserver.services (service, pattern) VALUES ('sync-1.5', '{node}/1.5/{uid}')" || return 1
  [ "$($my "select count(*) from tokenserver.nodes where node = 'http://localhost:8000'")" -gt 0 ] \
    || $my "INSERT INTO tokenserver.nodes (service, node, available, capacity, current_load, backoff, downed)
       VALUES ((select id from tokenserver.services where service = 'sync-1.5'), 'http://localhost:8000', 100, 100, 0, 0, 0)" || return 1
  cat > /etc/systemd/system/syncserver.service <<UNIT
[Unit]
Description=FxA Sync server (syncstorage-rs $SYNCSTORAGE_TAG) on :8000
After=mysql.service
Requires=mysql.service
[Service]
User=agent
ExecStart=$SYNC/syncserver --config $SYNC_CONF
Environment=RUST_LOG=info
Restart=on-failure
UNIT
  systemctl daemon-reload
  [ -n "$up" ] || systemctl stop mysql
  echo "$SYNCSTORAGE_TAG" > "$SYNC/.setup"
}
syncserver() {
  [ "$(cat "$SYNC/.version" 2>/dev/null)" = "$SYNCSTORAGE_TAG" ] \
    || syncserver_build || { echo "WARN: syncserver $SYNCSTORAGE_TAG did not build; the earlier copy stays" >&2; return 0; }
  [ "$(cat "$SYNC/.setup" 2>/dev/null)" = "$SYNCSTORAGE_TAG" ] || syncserver_setup || echo "WARN: the syncserver setup failed" >&2
}

# The one pin for each runtime: manager.sh reads them for the manager, and refresh.sh
# for the snapshot (lib/claude-pin.check.sh).
CLAUDE_CODE_VERSION=2.1.322
CODEX_VERSION=0.167.0

want="${1:-$(curl -fsSL https://raw.githubusercontent.com/mozilla/fxa/main/.nvmrc)}"
want="$(printf '%s' "$want" | tr -d 'v \n')"
# FxA's preinstall refuses any Node but the exact one in .nvmrc.
[[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: .nvmrc is not a plain version: ${want}" >&2; exit 1; }

# The marker, not node -v: a release unpacked over another leaves a mixed npm that
# cannot install, so a release is always unpacked onto a clean npm and corepack.
if [ "$(cat /usr/local/.node-release 2>/dev/null)" != "$want" ]; then
  a="$(uname -m)"; case "$a" in x86_64) a=x64 ;; aarch64) a=arm64 ;; esac
  rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack
  curl -fsSL "https://nodejs.org/dist/v${want}/node-v${want}-linux-${a}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
  echo "$want" > /usr/local/.node-release
fi
hash -r
corepack enable

# One copy of each: an older image put another under /usr, beside the apt Node.
rm -rf /usr/lib/node_modules/@anthropic-ai/claude-code /usr/bin/claude /usr/lib/node_modules/@openai/codex /usr/bin/codex
cc() { /usr/local/bin/claude --version 2>/dev/null | cut -d' ' -f1; }
cx() { /usr/local/bin/codex --version 2>/dev/null | awk '{ print $NF }'; }
# npm 11 skips install scripts unless they are allowed by name.
[ "$(cc)" = "$CLAUDE_CODE_VERSION" ] || npm install -g --prefix /usr/local --allow-scripts=@anthropic-ai/claude-code \
  "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" >&2
[ "$(cx)" = "$CODEX_VERSION" ] || npm install -g --prefix /usr/local --allow-scripts=@openai/codex "@openai/codex@${CODEX_VERSION}" >&2

echo "node $(node -v | tr -d v)"
echo "claude $(cc)"
echo "codex $(cx)"
[ "$(node -v | tr -d v)" = "$want" ] || { echo "ERROR: node is $(node -v), not ${want}" >&2; exit 1; }
[ "$(cc)" = "$CLAUDE_CODE_VERSION" ] || { echo "ERROR: claude is '$(cc)', not ${CLAUDE_CODE_VERSION}" >&2; exit 1; }
[ "$(cx)" = "$CODEX_VERSION" ] || { echo "ERROR: codex is '$(cx)', not ${CODEX_VERSION}" >&2; exit 1; }
npm -v > /dev/null || { echo "ERROR: npm does not run" >&2; exit 1; }

nightly
echo "nightly $(sed -n 's/^Version=//p' "$NIGHTLY/application.ini" | head -1)"
sync_tools
echo "spanner-emulator $(cat /opt/spanner-emulator/.version 2>/dev/null || echo none)"
syncserver
echo "syncserver $(cat "$SYNC/.setup" 2>/dev/null || echo none)"
