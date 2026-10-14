#!/bin/bash
# profiles/sync-storage/boot.sh: build and run syncstorage-rs beside the running FxA stack, with
# no Docker: Rust, the FxA MySQL, and FxA's auth server for the tokens. The controller runs it
# once as root on the runner, detached, after the egress firewall. Each step is skipped when its
# result is there. Repo code runs only as agent. Log: /var/log/profile-boot.log.
# Done: /run/fxa-profile/ready, or failed.
set -uo pipefail
S=/home/agent/syncstorage RH=/opt/rust/rustup CH=/opt/rust/cargo V=/home/agent/.syncstorage-venv
CONF=/home/agent/.syncstorage.toml LOG=/home/agent/.syncstorage.log
FEATURES="--no-default-features --features=syncstorage-db/mysql --features=py_verifier"
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
want="$(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' "$S/Cargo.toml" | head -1)"
if [ ! -x "$CH/bin/cargo" ]; then
  curl -sSf https://sh.rustup.rs | RUSTUP_HOME=$RH CARGO_HOME=$CH sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain stable > /dev/null \
    || die "could not install Rust"
  chmod -R a+rX /opt/rust
fi
# The repo's tests run under nextest, as its CI does; a plain cargo test fails some of them.
[ -x "$CH/bin/cargo-nextest" ] || { curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$CH/bin" && chmod a+rx "$CH/bin/cargo-nextest"; } \
  || die "could not install cargo-nextest"
step "rustc $(RUSTUP_HOME=$RH $CH/bin/rustc --version | cut -d' ' -f2), the repo wants ${want:-any}"

# The verifier is PyFxA inside the server's Python, at the versions the repo's poetry.lock pins.
# A current pyOpenSSL too: Ubuntu's own (python3-openssl) breaks against the pinned cryptography.
# marionette-driver drives Firefox for the sync-e2e skill.
step "Python for the token verifier"
deps="$(python3 - "$S/poetry.lock" <<'PY'
import sys, tomllib
pk = {p["name"].lower(): p for p in tomllib.load(open(sys.argv[1], "rb"))["package"]}
seen = set()
def walk(n):
    n = n.lower()
    if n in seen or n not in pk: return
    seen.add(n); [walk(d) for d in pk[n].get("dependencies", {})]
for n in ("pyfxa", "tokenlib", "cryptography"): walk(n)
print(" ".join(f"{n}=={pk[n]['version']}" for n in sorted(seen)))
PY
)" || die "could not read poetry.lock"
sudo -u agent -H bash -c "[ -x $V/bin/python ] || python3 -m venv $V; $V/bin/pip install -q $deps pyopenssl marionette-driver" < /dev/null \
  || die "could not set up the Python venv"

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
step "config"
[ -f "$CONF" ] || sudo -u agent bash -c "umask 077; cat > $CONF" <<TOML || die "could not write $CONF"
# syncstorage-rs for the sandbox: storage and token server on :8000, FxA's auth server on :9000.
master_secret = "$(openssl rand -hex 32)"
host = "127.0.0.1"
port = 8000
human_logs = 1
cors_allowed_origin = "localhost"
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
pysite="$($V/bin/python -c 'import site; print(site.getsitepackages()[0])')"
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
