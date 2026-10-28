#!/bin/bash
# profiles/sync-storage/boot.sh: build and run syncstorage-rs beside the running FxA stack, with
# no Docker: Rust, the FxA MySQL, and FxA's auth server for the tokens. The controller runs it
# once as root on the runner, detached, after the egress firewall. Each step is skipped when its
# result is there. Repo code runs only as agent. Log: /var/log/profile-boot.log.
# Done: /run/fxa-profile/ready, or failed.
set -uo pipefail
S=/home/agent/syncstorage RH=/opt/rust/rustup CH=/opt/rust/cargo V=/home/agent/.syncstorage-venv IT=/home/agent/.syncstorage-it-venv
CONF=/home/agent/.syncstorage.toml LOG=/home/agent/.syncstorage.log
FEATURES="--no-default-features --features=syncstorage-db/mysql --features=py_verifier"
# CI's Spanner build. It shares target/ with the MySQL one: a second dir built the gRPC library
# and the common crates again and filled the runner's disk.
SPANNER_FEATURES="--no-default-features --features=syncserver/spanner --features=py_verifier --features=syncserver/last_seen"
R=/run/fxa-profile READY=/run/fxa-profile/ready FAIL=/run/fxa-profile/failed
install -d -m 755 -o root -g root "$R"; rm -f "$READY" "$FAIL"
step() { echo "$(date -u +%T) $*"; }
die() { step "FAILED: $*"; echo "$*" > "$FAIL"; chmod 644 "$FAIL"; exit 1; }
# The agent's cargo keeps its own registry and target dir; the toolchain is root's and read-only.
ENVS="export RUSTUP_HOME=$RH PATH=$CH/bin:\$PATH CARGO_HOME=/home/agent/.cargo"
as_agent() { sudo -u agent -H bash -c "cd $S && $ENVS && $1" < /dev/null; }
t0=$(date +%s)
[ -d "$S/.git" ] || die "no syncstorage-rs checkout at $S"

step "packages"
pk="build-essential pkg-config cmake libmysqlclient-dev libpq-dev libssl-dev python3-dev python3-venv"
dpkg -s $pk > /dev/null 2>&1 || { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pk; } > /dev/null || die "could not install the build packages"

step "Rust"
# CI's toolchain: the repo's rust-version line (RUST_VER) names it. A newer clippy flags code CI passes.
want="$(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' "$S/Cargo.toml" | head -1)"
ru() { RUSTUP_HOME=$RH CARGO_HOME=$CH "$CH/bin/rustup" "$@"; }
[ -x "$CH/bin/rustup" ] || curl -sSf https://sh.rustup.rs | RUSTUP_HOME=$RH CARGO_HOME=$CH sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain none > /dev/null \
  || die "could not install rustup"
# fmt and clippy are the repo's lint, as its CI runs them.
ru toolchain install "${want:-stable}" --profile minimal -c rustfmt -c clippy > /dev/null 2>&1 && ru default "${want:-stable}" > /dev/null 2>&1 \
  || die "could not install Rust ${want:-stable}"
chmod -R a+rX /opt/rust
step "rustc $(RUSTUP_HOME=$RH $CH/bin/rustc --version | cut -d' ' -f2), as the repo's CI (${want:-stable})"
# The repo's tests run under nextest, as its CI does; a plain cargo test fails some of them.
[ -x "$CH/bin/cargo-nextest" ] || { curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$CH/bin" && chmod a+rx "$CH/bin/cargo-nextest"; } \
  || die "could not install cargo-nextest"

# locked <poetry.lock> <name>...   pip pins for the named packages and their dependencies, at the
# versions a poetry.lock fixes; with no name, the main dependencies of the pyproject.toml beside it.
locked() { python3 - "$@" <<'PY'
import os, sys, tomllib
lock = sys.argv[1]
pk = {p["name"].lower(): p for p in tomllib.load(open(lock, "rb"))["package"]}
roots = sys.argv[2:] or list(tomllib.load(open(os.path.join(os.path.dirname(lock), "pyproject.toml"), "rb"))["tool"]["poetry"]["dependencies"])
seen = set()
def walk(n):
    n = n.lower()
    if n in seen or n not in pk: return
    seen.add(n); [walk(d) for d in pk[n].get("dependencies", {})]
for n in roots: walk(n)
print(" ".join(f"{n}=={pk[n]['version']}" for n in sorted(seen)))
PY
}

# The verifier is PyFxA inside the server's Python, at the versions the repo's poetry.lock pins.
# A current pyOpenSSL too: Ubuntu's own (python3-openssl) breaks against the pinned cryptography.
# marionette-driver drives Firefox for the sync-e2e skill.
step "Python for the token verifier"
# ruff is CI's python-checks job (ruff format and ruff check on tools/).
deps="$(locked "$S/poetry.lock" pyfxa tokenlib cryptography ruff)" || die "could not read poetry.lock"
sudo -u agent -H bash -c "[ -x $V/bin/python ] || python3 -m venv $V; $V/bin/pip install -q $deps pyopenssl marionette-driver" < /dev/null \
  || die "could not set up the Python venv"

# The repo's own e2e tests (tools/integration_tests), at their own lock: no poetry on the runner.
step "Python for the integration tests"
deps="$(locked "$S/tools/integration_tests/poetry.lock")" || die "could not read the integration tests' poetry.lock"
sudo -u agent -H bash -c "[ -x $IT/bin/python ] || python3 -m venv $IT; $IT/bin/pip install -q $deps" < /dev/null \
  || die "could not set up the integration tests' venv"

# The server's databases, and a pair for the tests: they expect tables nobody else wrote to.
step "MySQL databases"
my() { mysql -uroot -h127.0.0.1 -Nse "$1"; }
my "CREATE USER IF NOT EXISTS 'sync'@'%' IDENTIFIED BY 'test'; CREATE USER IF NOT EXISTS 'sync'@'localhost' IDENTIFIED BY 'test';
    CREATE DATABASE IF NOT EXISTS syncstorage; CREATE DATABASE IF NOT EXISTS tokenserver;
    CREATE DATABASE IF NOT EXISTS syncstorage_test; CREATE DATABASE IF NOT EXISTS tokenserver_test;
    GRANT ALL PRIVILEGES ON \`syncstorage%\`.* TO 'sync'@'%'; GRANT ALL PRIVILEGES ON \`tokenserver%\`.* TO 'sync'@'%';
    GRANT ALL PRIVILEGES ON \`syncstorage%\`.* TO 'sync'@'localhost'; GRANT ALL PRIVILEGES ON \`tokenserver%\`.* TO 'sync'@'localhost';" \
  || die "could not create the sync databases"

# Outside the repo: the repo's own config/local.toml is a path its rules keep agents out of.
# Full debug info put 24 GB in target/ and filled the runner's disk; line tables keep backtraces.
step "cargo config"
# No incremental data, as CI builds: it took 2.1 GB of the runner's disk.
sudo -u agent bash -c "mkdir -p /home/agent/.cargo && cat > /home/agent/.cargo/config.toml" <<'CARGO' || die "could not write the cargo config"
[build]
incremental = false
[profile.dev]
debug = "line-tables-only"
[profile.test]
debug = "line-tables-only"
CARGO

step "config"
[ -f "$CONF" ] || sudo -u agent bash -c "umask 077; cat > $CONF" <<TOML || die "could not write $CONF"
# syncstorage-rs for the sandbox: storage and token server on :8000, FxA's auth server on :9000.
master_secret = "$(openssl rand -hex 32)"
host = "127.0.0.1"
port = 8000
human_logs = 1
syncstorage.database_url = "mysql://sync:test@127.0.0.1:3306/syncstorage"
syncstorage.enabled = true
syncstorage.enable_quota = 0
syncstorage.limits.max_total_records = 1666
syncstorage.run_migrations = true
tokenserver.database_url = "mysql://sync:test@127.0.0.1:3306/tokenserver"
tokenserver.enabled = true
tokenserver.node_type = "mysql"
tokenserver.run_migrations = true
tokenserver.fxa_email_domain = "api-accounts.stage.mozaws.net"
tokenserver.fxa_oauth_server_url = "http://localhost:9000"
tokenserver.fxa_metrics_hash_secret = "$(openssl rand -hex 16)"
TOML

step "cargo build (the first build takes several minutes)"
as_agent "cargo build -q --bin syncserver $FEATURES" > /var/log/syncstorage-build.log 2>&1 || die "cargo build failed (see /var/log/syncstorage-build.log)"

step "syncserver on :8000"
# As agent: the venv is the agent's, so its python (or a .pth file in it) must never run as root.
pysite="$(sudo -u agent -H $V/bin/python -c 'import site; print(site.getsitepackages()[0])' < /dev/null)"
# By name, never -f: the agent's own command line holds the guide, which names this binary.
pkill -u agent -x syncserver; sleep 1
as_agent "PYTHONPATH=$pysite RUST_LOG=info nohup setsid target/debug/syncserver --config $CONF > $LOG 2>&1 < /dev/null &"
for i in $(seq 90); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' localhost:8000/__heartbeat__)" = 200 ] && break; sleep 2; done
[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' localhost:8000/__heartbeat__)" = 200 ] || die "syncserver did not answer on :8000 (see $LOG)"

# The token server assigns users to a node; the migrations make the tables, not the rows.
step "token server node"
for i in $(seq 30); do [ "$(my "select count(*) from information_schema.tables where table_schema = 'tokenserver' and table_name = 'nodes'")" = 1 ] && break; sleep 2; done
[ "$(my "select count(*) from tokenserver.services where service = 'sync-1.5'")" -gt 0 ] \
  || my "INSERT INTO tokenserver.services (service, pattern) VALUES ('sync-1.5', '{node}/1.5/{uid}')" || die "could not add the sync-1.5 service"
[ "$(my "select count(*) from tokenserver.nodes where node = 'http://localhost:8000'")" -gt 0 ] \
  || my "INSERT INTO tokenserver.nodes (service, node, available, capacity, current_load, backoff, downed)
         VALUES ((select id from tokenserver.services where service = 'sync-1.5'), 'http://localhost:8000', 100, 100, 0, 0, 0)" \
  || die "could not add the localhost node"

echo "ready after $(( $(date +%s) - t0 ))s" > "$READY"; chmod 644 "$READY"
step "ready after $(( $(date +%s) - t0 ))s"

# Stage 2: CI's Spanner path with payload offload, the team's production backend, with no Docker.
# The MySQL server is ready first; sync-verify waits for spanner-ready only for its Spanner rows.
SREADY=/run/fxa-profile/spanner-ready SFAIL=/run/fxa-profile/spanner-failed; rm -f "$SREADY" "$SFAIL"
sdie() { step "SPANNER FAILED: $*"; echo "$*" > "$SFAIL"; chmod 644 "$SFAIL"; exit 1; }
step "Spanner tools"
# The image has them (packer/scripts/03b-toolchain.sh): the egress firewall allows none of these
# hosts. A download here is for an older image, on a runner with open egress.
ev="$(sed -n 's|.*cloud-spanner-emulator/emulator:\([0-9.]*\).*|\1|p' "$S/docker/docker-compose.spanner.yaml" | head -1)"
[ -x /opt/spanner-emulator/gateway_main ] || { [ -n "$ev" ] && mkdir -p /opt/spanner-emulator \
  && curl -fsSL "https://storage.googleapis.com/cloud-spanner-emulator/releases/$ev/cloud-spanner-emulator_linux_amd64-$ev.tar.gz" | tar xz -C /opt/spanner-emulator \
  && echo "$ev" > /opt/spanner-emulator/.version; } || sdie "the image has no Spanner emulator, and the download failed"
[ "$(cat /opt/spanner-emulator/.version 2>/dev/null)" = "$ev" ] \
  || step "note: the Spanner emulator is $(cat /opt/spanner-emulator/.version 2>/dev/null), CI pins ${ev:-none} (SPANNER_EMULATOR_VERSION in 03b-toolchain.sh)"
[ -x /opt/fake-gcs/fake-gcs-server ] || { mkdir -p /opt/fake-gcs \
  && curl -fsSL https://github.com/fsouza/fake-gcs-server/releases/download/v1.56.1/fake-gcs-server_1.56.1_Linux_amd64.tar.gz | tar xz -C /opt/fake-gcs; } \
  || sdie "could not download fake-gcs-server"
# The Pub/Sub emulator is a gcloud component: its tarball alone, with no gcloud.
pe=/opt/pubsub-emulator/platform/pubsub-emulator/bin/cloud-pubsub-emulator CL=https://dl.google.com/dl/cloudsdk/channels/rapid
[ -x "$pe" ] || { src="$(curl -fsSL "$CL/components-2.json" | jq -r '.components[] | select(.id == "pubsub-emulator") | .data.source')" \
  && [ -n "$src" ] && mkdir -p /opt/pubsub-emulator && curl -fsSL "$CL/$src" | tar xz -C /opt/pubsub-emulator; } \
  || sdie "could not download the Pub/Sub emulator"
chmod -R a+rX /opt/spanner-emulator /opt/fake-gcs /opt/pubsub-emulator

step "Python for the payload-link publisher and reconciler"
for n in publisher:tools/payload-link-dataflow/payload-link-publisher-py reconciler:tools/payload-reconciler; do
  v=/home/agent/.syncstorage-${n%%:*}-venv
  deps="$(locked "$S/${n#*:}/poetry.lock")" || sdie "could not read ${n#*:}/poetry.lock"
  sudo -u agent -H bash -c "[ -x $v/bin/python ] || python3 -m venv $v; $v/bin/pip install -q $deps" < /dev/null || sdie "could not set up the ${n%%:*} venv"
done
# The reconciliation test reads GCS itself: CI's image has the reconciler's client for it.
deps="$(locked "$S/tools/payload-reconciler/poetry.lock" google-cloud-storage)" && sudo -u agent -H bash -c "$IT/bin/pip install -q $deps" < /dev/null \
  || sdie "could not add google-cloud-storage to the integration tests' venv"

step "cargo build with Spanner (several minutes)"
# The copy keeps the Spanner binary; the MySQL build after it only relinks, so restart.sh still starts MySQL.
as_agent "CARGO_INCREMENTAL=0 cargo build -q --bin syncserver $SPANNER_FEATURES && cp target/debug/syncserver target/debug/syncserver-spanner \
  && cargo build -q --bin syncserver $FEATURES" > /var/log/syncstorage-spanner-build.log 2>&1 \
  || sdie "the Spanner cargo build failed (see /var/log/syncstorage-spanner-build.log)"
# grpc's C++ objects are linked from the .a archives alone: drop the .o files and the archives'
# debug info (about 3 of the 3.9 GB). The build script's fingerprint reads its inputs, not these.
as_agent "find target/debug/build -path '*/grpcio-sys-*/out/*' -name '*.o' -delete; find target/debug/build -path '*/grpcio-sys-*/out/*' -name '*.a' -exec strip -g {} +" \
  >> /var/log/syncstorage-spanner-build.log 2>&1
echo "spanner ready after $(( $(date +%s) - t0 ))s" > "$SREADY"; chmod 644 "$SREADY"
step "spanner ready after $(( $(date +%s) - t0 ))s"
