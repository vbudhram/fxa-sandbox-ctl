#!/usr/bin/env bash
# spanner.sh: CI's Spanner jobs with no Docker, fresh each time.
#   spanner.sh up      the reconciliation stack: the Spanner and Pub/Sub emulators, fake GCS, the
#                      payload-link publisher and reconciler, and a Spanner syncserver on :8001 with
#                      payload offload on, as docker-compose.e2e.reconciliation.yaml sets it up
#   spanner.sh unit '<nextest filter>'   build-and-unit-test-spanner for those packages, on the emulator
#                      alone; needs SYNC_SPANNER_FEATURES and SYNC_MYSQL_FEATURES; exit 3 (SKIP) under 4 GB free
#   spanner.sh down
#   spanner.sh wait    until the boot's Spanner stage ends; exit 3 when it failed
set -uo pipefail
R="${SYNC_REPO:-/home/agent/syncstorage}" P=test-project I=test-instance D=test-database
L="$HOME/.syncstorage-spanner" PIDS="$HOME/.syncstorage-spanner/pids"
SPURL="spanner://projects/$P/instances/$I/databases/$D"
mkdir -p "$L"
# Each process leads its own group (setsid): kill the group, or gateway_main's emulator_main stays on :9010.
down() { [ -f "$PIDS" ] && while read -r p; do kill -- "-$p" 2>/dev/null; done < "$PIDS"; rm -f "$PIDS"; sleep 1; }
start() { local n="$1"; shift; nohup setsid "$@" > "$L/$n.log" 2>&1 < /dev/null & echo $! >> "$PIDS"; }
wait_for() { for _ in $(seq 60); do curl -s -o /dev/null -m 3 "$1" && return 0; sleep 1; done; echo "spanner.sh: $2 did not start; see $L/$2.log" >&2; tail -5 "$L/$2.log" >&2; exit 1; }
# The Spanner emulator with the repo's schema, as CI's prepare-spanner.sh makes it.
emulator() {
  start spanner-emulator /opt/spanner-emulator/gateway_main --hostname 127.0.0.1 --grpc_port 9010 --http_port 9020
  wait_for "localhost:9020/v1/projects/$P/instances" spanner-emulator
  SYNC_SYNCSTORAGE__SPANNER_EMULATOR_HOST=http://localhost:9020 bash scripts/prepare-spanner.sh > "$L/prepare.log" 2>&1 || { echo "spanner.sh: prepare-spanner.sh failed" >&2; tail -5 "$L/prepare.log" >&2; exit 1; }
  for _ in $(seq 30); do [ "$(curl -s "localhost:9020/v1/projects/$P/instances/$I/databases/$D" | jq -r .state)" = READY ] && break; sleep 1; done
  [ "$(curl -s "localhost:9020/v1/projects/$P/instances/$I/databases/$D" | jq -r .state)" = READY ] \
    || { echo "spanner.sh: the Spanner database is not ready" >&2; tail -5 "$L/prepare.log" >&2; exit 1; }
}
# The token server's tables for a Spanner run only: node_type spanner differs from the MySQL server's.
tokendb() { mysql -usync -ptest -h127.0.0.1 -e "DROP DATABASE IF EXISTS $1; CREATE DATABASE $1" 2> /dev/null || { echo "spanner.sh: could not reset $1" >&2; exit 1; }; }
pysite() { "$HOME/.syncstorage-venv/bin/python" -c 'import site; print(site.getsitepackages()[0])'; }
case "${1:-}" in
  down) down; exit 0 ;;
  wait)
    RUN="${SYNC_PROFILE_RUN:-/run/fxa-profile}"
    for _ in $(seq 240); do
      [ -f "$RUN/spanner-ready" ] && exit 0
      [ -f "$RUN/spanner-failed" ] && { echo "the runner has no Spanner stack: $(cat "$RUN/spanner-failed"); CI runs these"; exit 3; }
      sleep 5
    done
    echo "the boot's Spanner stage did not end in 20 min; CI runs these"; exit 3 ;;
  unit)
    [ -n "${2:-}" ] && [ -n "${SYNC_SPANNER_FEATURES:-}" ] && [ -n "${SYNC_MYSQL_FEATURES:-}" ] \
      || { echo "usage: SYNC_SPANNER_FEATURES=... SYNC_MYSQL_FEATURES=... spanner.sh unit '<nextest filter>'" >&2; exit 2; }
    # A second test build of the workspace takes about 2 GB: below 4 GB free it could fill the disk.
    free="$(df -Pk "$R" | awk 'NR == 2 { print $4 }')"
    [ "${free:-0}" -ge 4194304 ] || { echo "only $(( ${free:-0} / 1048576 )) GB free on the runner disk; CI runs the Spanner unit tests"; exit 3; }
    cd "$R" || exit 2
    down; emulator; tokendb tokenserver_spanner_test
    # The test build relinks syncserver with Spanner: put the MySQL one back for restart.sh, after a kill too.
    trap 'cargo build -q --bin syncserver $SYNC_MYSQL_FEATURES; down' EXIT; trap 'exit 143' TERM INT
    # As CI's job: the whole workspace (its feature set), the ci profile (it retries the emulator's spurious ABORTED).
    SYNC_SYNCSTORAGE__DATABASE_URL="$SPURL" SYNC_SYNCSTORAGE__SPANNER_EMULATOR_HOST=localhost:9010 \
      SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver_spanner_test SYNC_TOKENSERVER__NODE_TYPE=spanner \
      RUST_TEST_THREADS=1 CARGO_INCREMENTAL=0 PYTHONPATH="$(pysite)" \
      cargo nextest run --workspace $SYNC_SPANNER_FEATURES --profile ci --color never -E "$2"
    exit $? ;;
  up) ;;
  *) echo "usage: spanner.sh up|unit|down|wait" >&2; exit 2 ;;
esac
down
[ -x "$R/target/debug/syncserver-spanner" ] || { echo "spanner.sh: no Spanner build yet; see /var/log/profile-boot.log" >&2; exit 1; }
cd "$R" || exit 2
emulator
start fake-gcs /opt/fake-gcs/fake-gcs-server -scheme http -host 127.0.0.1 -port 4443 -public-host 127.0.0.1:4443 -backend memory -log-level warn
start pubsub-emulator /opt/pubsub-emulator/platform/pubsub-emulator/bin/cloud-pubsub-emulator --host=127.0.0.1 --port=8085
wait_for localhost:4443/storage/v1/b fake-gcs
wait_for localhost:8085 pubsub-emulator
curl -sf -X PUT "localhost:8085/v1/projects/$P/topics/payload-link-changes" -H 'Content-Type: application/json' -d '{}' > /dev/null \
  && curl -sf -X PUT "localhost:8085/v1/projects/$P/subscriptions/payload-link-reconciler-sub" -H 'Content-Type: application/json' \
       -d "{\"topic\":\"projects/$P/topics/payload-link-changes\",\"ackDeadlineSeconds\":60}" > /dev/null \
  && curl -sf -X POST "localhost:4443/storage/v1/b?project=$P" -H 'Content-Type: application/json' -d '{"name":"test-payloads"}' > /dev/null \
  || { echo "spanner.sh: could not create the topic, subscription or bucket" >&2; exit 1; }
# The publisher reads the change stream from POLL_OVERLAP_SECONDS back; a start before the stream
# existed ends it with OUT_OF_RANGE, and the publisher then reads nothing.
sleep 6
SPANNER_PROJECT_ID=$P SPANNER_INSTANCE_ID=$I SPANNER_DATABASE_ID=$D SPANNER_EMULATOR_HOST=localhost:9010 PUBSUB_PROJECT_ID=$P \
  PUBSUB_TOPIC=payload-link-changes PUBSUB_EMULATOR_HOST=localhost:8085 SPANNER_CHANGE_STREAM_NAME=payload_link_changes \
  HEARTBEAT_MS=1000 POLL_OVERLAP_SECONDS=5 \
  start publisher "$HOME/.syncstorage-publisher-venv/bin/python" tools/payload-link-dataflow/payload-link-publisher-py/publisher.py
PUBSUB_PROJECT_ID=$P PUBSUB_SUBSCRIPTION=payload-link-reconciler-sub PUBSUB_EMULATOR_HOST=localhost:8085 \
  GCS_PAYLOAD_BUCKET=test-payloads STORAGE_EMULATOR_HOST=http://localhost:4443 \
  start reconciler "$HOME/.syncstorage-reconciler-venv/bin/python" tools/payload-reconciler/reconcile_payload_links.py
# A test that runs before the publisher's first poll finds its object not finalized: wait for one.
for _ in $(seq 30); do grep -q 'starting: change_stream' "$L/publisher.log" 2> /dev/null && break; sleep 1; done
grep -q 'starting: change_stream' "$L/publisher.log" 2> /dev/null || { echo "spanner.sh: the publisher did not start; see $L/publisher.log" >&2; tail -5 "$L/publisher.log" >&2; exit 1; }
sleep 3
tokendb tokenserver_spanner
SYNC_HOST=127.0.0.1 SYNC_PORT=8001 SYNC_HUMAN_LOGS=1 RUST_LOG=info \
  SYNC_MASTER_SECRET="$(sed -n 's/^master_secret *= *"\(.*\)"/\1/p' "$HOME/.syncstorage.toml")" \
  SYNC_SYNCSTORAGE__DATABASE_URL="$SPURL" SYNC_SYNCSTORAGE__SPANNER_EMULATOR_HOST=localhost:9010 \
  SYNC_SYNCSTORAGE__GCS_PAYLOAD_BUCKET=test-payloads SYNC_SYNCSTORAGE__GCS_ENDPOINT=http://localhost:4443 \
  SYNC_SYNCSTORAGE__GCS_PAYLOAD_OFFLOAD_COLLECTIONS=apis-1,crypto,meta,passwords,xxx_col,xxx_col1,xxx_col2,xxx_meh,xxxx,nonexistent \
  SYNC_TOKENSERVER__ENABLED=true SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver_spanner \
  SYNC_TOKENSERVER__NODE_TYPE=spanner SYNC_TOKENSERVER__RUN_MIGRATIONS=true \
  SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN=api-accounts.stage.mozaws.net SYNC_TOKENSERVER__FXA_METRICS_HASH_SECRET=secret0 \
  PYTHONPATH="$(pysite)" \
  start syncserver-spanner target/debug/syncserver-spanner
wait_for localhost:8001/__heartbeat__ syncserver-spanner
echo "spanner stack up: syncserver on :8001 (Spanner, offload on); logs in $L"
