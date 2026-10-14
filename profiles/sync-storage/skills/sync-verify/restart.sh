#!/usr/bin/env bash
# Restart the local syncserver on the last build and wait for its heartbeat.
set -uo pipefail
cd "${SYNC_WORKSPACE:-/workspace}" || exit 2
# By name, never -f: the agent's own command line holds text that names the binary.
pkill -u "$(id -un)" -x syncserver; sleep 1
PYTHONPATH="$("$HOME/.syncstorage-venv/bin/python" -c 'import site; print(site.getsitepackages()[0])')" RUST_LOG=info \
  nohup setsid target/debug/syncserver --config "$HOME/.syncstorage.toml" > "$HOME/.syncstorage.log" 2>&1 < /dev/null &
for i in $(seq 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' localhost:8000/__heartbeat__)" = 200 ] && { echo "syncserver up"; exit 0; }; sleep 1; done
echo "syncserver did not answer on :8000; see ~/.syncstorage.log"; tail -20 "$HOME/.syncstorage.log"; exit 1
